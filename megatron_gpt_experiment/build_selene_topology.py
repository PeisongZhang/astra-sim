#!/usr/bin/env python3
"""Generate an ASTRA-sim custom topology.txt approximating NVIDIA Selene
(the cluster used in arXiv:2104.04473) for a given GPU count.

Selene key facts (paper §5 and public literature):
  - 8 A100 per DGX node, fully connected via NVSwitch (NVLink 3; ~600 GB/s per GPU).
  - 8x NVIDIA Mellanox 200 Gbps HDR InfiniBand per node (one NIC per GPU).
  - Three-stage HDR fat-tree across ~560 nodes (Scalable Units → spines → core).

We model a **three-level fat-tree** (previously two-level; upgraded because
the single-spine bottleneck inflated exposed-comm on the 76.1B run and
flipped the 76.1B ≥ 39.1B ordering the paper reports):

  Level 0  (per-node NVSwitch, `nvlink_bw` per link)
      each NVSwitch ↔ the 8 GPUs of its node
  Level 1  (per-node leaf/TOR, `hdr_bw` per link)
      each leaf ↔ the 8 GPUs of its node (one 200 Gbps HDR NIC per GPU)
  Level 2  (per-pod spines, `leaf_spine_bw` per link)
      each pod holds `nodes_per_pod` leaves and `spines_per_pod` spine switches;
      every leaf in a pod links to every spine in the same pod.
  Level 3  (cluster-wide cores, `spine_core_bw` per link)
      `num_cores` core switches; every pod-spine links to every core.

With `spines_per_pod = 1` and `num_cores = 1` the output degenerates to the
previous 2-level topology (kept as a regression option for direct
comparison with earlier runs).

Bandwidth defaults aim to keep the fat-tree non-blocking for cross-node
all-reduce:
  - Each node's outgoing BW through its leaf = 8 × 200 Gbps = 1600 Gbps.
  - Leaf → pod-spine: 1600 / spines_per_pod per link (so the pod's uplinks
    sum to 1600 × nodes_per_pod Gbps across all spines — the full pod
    outbound capacity).
  - Pod-spine → core: aggregate of all nodes in pod divided by
    (spines_per_pod × num_cores): 1600 × nodes_per_pod / (spines_per_pod *
    num_cores) per link.

Node ID layout (contiguous blocks):
  GPUs            : 0 .. num_gpus - 1
  NVSwitches      : num_gpus ..                         (one per node)
  Leaves (TORs)   : next                                (one per node)
  Pod-spines      : next                                (num_pods * spines_per_pod)
  Cores           : next                                (num_cores)
"""

import argparse
import math
import os


def _parse_gbps(value: str) -> int:
    """Accept either a plain int (raw Gbps) or a string like '1600Gbps'."""
    s = str(value)
    if s.endswith("Gbps"):
        s = s[:-4]
    if s.endswith("gbps"):
        s = s[:-4]
    return int(round(float(s)))


def _gbps_str(bw_gbps: int) -> str:
    return f"{bw_gbps}Gbps"


def build_topology(
    num_nodes: int,
    gpus_per_node: int = 8,
    nodes_per_pod: int | None = None,
    spines_per_pod: int = 2,
    num_cores: int = 4,
    nvlink_bw: str = "4800Gbps",
    nvlink_lat: str = "0.00015ms",
    hdr_bw: str = "200Gbps",
    hdr_lat: str = "0.0005ms",
    leaf_spine_lat: str = "0.0005ms",
    spine_core_lat: str = "0.001ms",
    leaf_spine_bw: str | None = None,
    spine_core_bw: str | None = None,
):
    """Build a 3-level fat-tree topology string.

    If `spines_per_pod * num_cores == 1` this degenerates to the legacy
    2-level tree (single spine), useful for apples-to-apples comparison.
    """
    num_gpus = num_nodes * gpus_per_node

    if nodes_per_pod is None:
        # Default: aim for ~8 pods; pick the divisor closest to that.
        target_pods = 8
        best = (num_nodes, 1)  # (cost, candidate) initial worst
        for cand in range(1, num_nodes + 1):
            if num_nodes % cand != 0:
                continue
            pods = num_nodes // cand
            cost = abs(pods - target_pods)
            if cost < best[0]:
                best = (cost, cand)
        nodes_per_pod = best[1]

    if num_nodes % nodes_per_pod != 0:
        raise ValueError(
            f"num_nodes={num_nodes} not divisible by nodes_per_pod={nodes_per_pod}"
        )
    num_pods = num_nodes // nodes_per_pod

    # Link-BW derivation (non-blocking sizing, paper §5.9 motivated).
    hdr_gbps = _parse_gbps(hdr_bw)
    node_uplink_gbps = gpus_per_node * hdr_gbps           # 8 × 200 = 1600
    if leaf_spine_bw is None:
        leaf_spine_bw = _gbps_str(
            max(1, node_uplink_gbps // max(spines_per_pod, 1))
        )
    if spine_core_bw is None:
        pod_uplink_gbps = node_uplink_gbps * nodes_per_pod
        spine_core_bw = _gbps_str(
            max(1, pod_uplink_gbps // max(spines_per_pod * num_cores, 1))
        )

    # Switch IDs (contiguous blocks).
    nvsw_start = num_gpus
    leaf_start = nvsw_start + num_nodes
    spine_start = leaf_start + num_nodes
    core_start = spine_start + num_pods * spines_per_pod
    # num_cores == 0 means "no core layer"; the spine(s) are the top level.
    num_switches = num_nodes + num_nodes + num_pods * spines_per_pod + max(num_cores, 0)
    total_entities = num_gpus + num_switches

    links = []

    # Level 0: per-node NVSwitch ↔ GPU
    for n in range(num_nodes):
        nvsw = nvsw_start + n
        for g in range(gpus_per_node):
            gpu = n * gpus_per_node + g
            links.append((nvsw, gpu, nvlink_bw, nvlink_lat))

    # Level 1: per-node leaf (TOR) ↔ GPU (one HDR NIC per GPU)
    for n in range(num_nodes):
        leaf = leaf_start + n
        for g in range(gpus_per_node):
            gpu = n * gpus_per_node + g
            links.append((leaf, gpu, hdr_bw, hdr_lat))

    # Level 2: leaf ↔ pod-spine (full bipartite within pod)
    for p in range(num_pods):
        for n in range(nodes_per_pod):
            leaf = leaf_start + p * nodes_per_pod + n
            for s in range(spines_per_pod):
                spine = spine_start + p * spines_per_pod + s
                links.append((leaf, spine, leaf_spine_bw, leaf_spine_lat))

    # Level 3: pod-spine ↔ core (full bipartite). Skipped if num_cores == 0.
    for p in range(num_pods):
        for s in range(spines_per_pod):
            spine = spine_start + p * spines_per_pod + s
            for c in range(num_cores):
                core = core_start + c
                links.append((spine, core, spine_core_bw, spine_core_lat))

    # Cross-pod bipartite at the spine level (only when there is no core layer
    # and we still have multiple pods). Each pod's spines connect directly to
    # every other pod's spines with `spine_core_bw` links. This gives a flat
    # 2-level fat-tree when num_cores == 0.
    if num_cores == 0 and num_pods > 1:
        all_spines = [spine_start + i for i in range(num_pods * spines_per_pod)]
        for i in range(len(all_spines)):
            for j in range(i + 1, len(all_spines)):
                links.append((all_spines[i], all_spines[j], spine_core_bw, spine_core_lat))

    lines = [f"{total_entities} {num_switches} {len(links)}"]
    switch_ids = (
        [str(nvsw_start + i) for i in range(num_nodes)]
        + [str(leaf_start + i) for i in range(num_nodes)]
        + [str(spine_start + i) for i in range(num_pods * spines_per_pod)]
        + [str(core_start + i) for i in range(max(num_cores, 0))]
    )
    lines.append(" ".join(switch_ids))
    for src, dst, bw, lat in links:
        lines.append(f"{src} {dst} {bw} {lat} 0")

    summary = {
        "num_gpus": num_gpus,
        "num_nodes": num_nodes,
        "num_pods": num_pods,
        "nodes_per_pod": nodes_per_pod,
        "spines_per_pod": spines_per_pod,
        "num_cores": num_cores,
        "num_switches": num_switches,
        "num_links": len(links),
        "leaf_spine_bw": leaf_spine_bw,
        "spine_core_bw": spine_core_bw,
    }
    return "\n".join(lines) + "\n", summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--num_nodes", type=int, required=True,
                    help="number of 8-GPU DGX nodes (512 GPUs -> 64, 1024 GPUs -> 128)")
    ap.add_argument("--gpus_per_node", type=int, default=8)
    ap.add_argument("--nodes_per_pod", type=int, default=None,
                    help="nodes per pod (default: pick divisor closest to 8 pods)")
    ap.add_argument("--spines_per_pod", type=int, default=2,
                    help="number of pod-spine switches per pod (1 recovers the legacy topology)")
    ap.add_argument("--num_cores", type=int, default=4,
                    help="number of cluster-wide core switches")
    ap.add_argument("--leaf_spine_bw", type=str, default=None,
                    help="override leaf↔pod-spine BW (e.g. 800Gbps); default is "
                         "node_uplink / spines_per_pod")
    ap.add_argument("--spine_core_bw", type=str, default=None,
                    help="override pod-spine↔core BW; default is "
                         "pod_uplink / (spines_per_pod * num_cores)")
    ap.add_argument("--out", type=str, required=True, help="output topology.txt path")
    args = ap.parse_args()

    body, summary = build_topology(
        args.num_nodes,
        gpus_per_node=args.gpus_per_node,
        nodes_per_pod=args.nodes_per_pod,
        spines_per_pod=args.spines_per_pod,
        num_cores=args.num_cores,
        leaf_spine_bw=args.leaf_spine_bw,
        spine_core_bw=args.spine_core_bw,
    )
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(body)
    print(f"Wrote {args.out}")
    for k, v in summary.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
