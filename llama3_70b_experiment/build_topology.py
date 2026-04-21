#!/usr/bin/env python3
"""Generate a 4-DC ASTRA-sim custom topology for Llama3-70B (1024 GPUs = 128 DGX).

Each DC contains 32 DGX nodes sharing one DC-spine. The 4 DC-spines connect to
a single global core switch via WAN links with per-DC one-way latencies that
match astra-sim/llama_experiment/inter_dc (modeling Shanghai Lingang / Suzhou
Changshu / Hangzhou Binjiang / Ningbo Hangzhou Bay <-> Jiaxing).

Layer         | Device                | Count | Link to layer above              | BW      | Latency
------------- | --------------------- | ----- | --------------------------------- | ------- | ---------
L0 GPUs       | GPU                   | 1024  | (endpoints)                       |         |
L1 NVSwitch   | one per DGX, 8 GPUs   |  128  | NVSwitch <-> 8 GPUs of its DGX    | 4800G   | 0.00015ms
L1 Leaf/ToR   | one per DGX, 8 NICs   |  128  | Leaf <-> 8 GPUs of its DGX        |  200G   | 0.0005 ms
L2 DC-spine   | one per DC            |    4  | Leaf <-> DC-spine (32 leaves/DC)  | 1600G   | 0.0005 ms
L3 Core       | global                |    1  | DC-spine <-> Core (WAN)           |  800G   | 0.317..0.562 ms

Partition controls which DGXs go into which DC:
  --partition pp:  DGX k -> DC (k // 32).   Matches PP-per-DC layout (E2).
                    DC0={DGX 0..31}, DC1={32..63}, DC2={64..95}, DC3={96..127}.
  --partition dp:  DGX k -> DC (k mod 4).   Matches DP-striped-across-DC layout (E3/E4).
                    DC0={0,4,8,...,124}, DC1={1,5,...,125}, ...

Node ID layout (contiguous blocks):
  GPUs            : 0 .. 1023
  NVSwitches      : 1024 .. 1151   (one per DGX)
  Leaves (TORs)   : 1152 .. 1279   (one per DGX)
  DC-spines       : 1280 .. 1283   (one per DC)
  Core            : 1284
"""

import argparse
import os


NUM_DGX = 128
GPUS_PER_DGX = 8
NUM_DCS = 4

NVLINK_BW = "4800Gbps"
NVLINK_LAT = "0.00015ms"
HDR_BW = "200Gbps"
HDR_LAT = "0.0005ms"
LEAF_SPINE_BW = "1600Gbps"
LEAF_SPINE_LAT = "0.0005ms"
WAN_BW = "800Gbps"
# Per DC one-way WAN latency (DC-spine <-> global core). Copied from
# astra-sim/llama_experiment/inter_dc/topology.txt (Shanghai/Suzhou/Hangzhou/Ningbo).
WAN_LATENCIES = ["0.562ms", "0.501ms", "0.402ms", "0.317ms"]


def partition_dgx_to_dc(partition: str):
    if partition == "pp":
        return [k // (NUM_DGX // NUM_DCS) for k in range(NUM_DGX)]
    elif partition == "dp":
        return [k % NUM_DCS for k in range(NUM_DGX)]
    else:
        raise ValueError(f"unknown partition: {partition!r}; expected pp or dp")


def build(partition: str):
    num_gpus = NUM_DGX * GPUS_PER_DGX
    nvsw_start = num_gpus                        # 1024
    leaf_start = nvsw_start + NUM_DGX            # 1152
    dc_spine_start = leaf_start + NUM_DGX        # 1280
    core_id = dc_spine_start + NUM_DCS           # 1284

    num_switches = NUM_DGX + NUM_DGX + NUM_DCS + 1   # 128+128+4+1 = 261
    total_entities = num_gpus + num_switches          # 1024 + 261 = 1285

    dgx_to_dc = partition_dgx_to_dc(partition)

    links = []

    # L1a: NVSwitch <-> 8 GPUs of its DGX
    for n in range(NUM_DGX):
        nvsw = nvsw_start + n
        for g in range(GPUS_PER_DGX):
            gpu = n * GPUS_PER_DGX + g
            links.append((nvsw, gpu, NVLINK_BW, NVLINK_LAT))

    # L1b: Leaf <-> 8 GPUs of its DGX (one HDR NIC per GPU)
    for n in range(NUM_DGX):
        leaf = leaf_start + n
        for g in range(GPUS_PER_DGX):
            gpu = n * GPUS_PER_DGX + g
            links.append((leaf, gpu, HDR_BW, HDR_LAT))

    # L2: Leaf <-> DC-spine (each leaf is attached to exactly one DC spine)
    for n in range(NUM_DGX):
        leaf = leaf_start + n
        dc = dgx_to_dc[n]
        dc_spine = dc_spine_start + dc
        links.append((leaf, dc_spine, LEAF_SPINE_BW, LEAF_SPINE_LAT))

    # L3: DC-spine <-> Core (WAN)
    for d in range(NUM_DCS):
        dc_spine = dc_spine_start + d
        links.append((dc_spine, core_id, WAN_BW, WAN_LATENCIES[d]))

    # Basic invariants
    dc_leaf_counts = [0] * NUM_DCS
    for n in range(NUM_DGX):
        dc_leaf_counts[dgx_to_dc[n]] += 1
    assert all(c == NUM_DGX // NUM_DCS for c in dc_leaf_counts), (
        f"uneven DC leaf assignment: {dc_leaf_counts}"
    )

    switch_ids = (
        [str(nvsw_start + i) for i in range(NUM_DGX)]
        + [str(leaf_start + i) for i in range(NUM_DGX)]
        + [str(dc_spine_start + i) for i in range(NUM_DCS)]
        + [str(core_id)]
    )

    lines = [f"{total_entities} {num_switches} {len(links)}"]
    lines.append(" ".join(switch_ids))
    for src, dst, bw, lat in links:
        lines.append(f"{src} {dst} {bw} {lat} 0")

    summary = {
        "partition": partition,
        "num_gpus": num_gpus,
        "num_dgx": NUM_DGX,
        "num_dcs": NUM_DCS,
        "dgxs_per_dc": NUM_DGX // NUM_DCS,
        "gpus_per_dc": NUM_DGX // NUM_DCS * GPUS_PER_DGX,
        "num_switches": num_switches,
        "num_links": len(links),
        "expected_switches": 261,
        "expected_links": 2180,
    }
    return "\n".join(lines) + "\n", summary, dgx_to_dc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--partition", required=True, choices=["pp", "dp"])
    ap.add_argument("--out", required=True, help="output topology.txt path")
    args = ap.parse_args()

    body, summary, dgx_to_dc = build(args.partition)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(body)
    print(f"Wrote {args.out}")
    for k, v in summary.items():
        print(f"  {k}: {v}")
    # Show GPU-to-DC mapping digest.
    print("  DC membership (first/last 3 DGXs per DC):")
    for dc in range(NUM_DCS):
        members = [n for n, d in enumerate(dgx_to_dc) if d == dc]
        head = members[:3]
        tail = members[-3:]
        print(f"    DC{dc}: DGX {head} ... {tail}  (GPU "
              f"{head[0]*GPUS_PER_DGX}..{tail[-1]*GPUS_PER_DGX+GPUS_PER_DGX-1})")


if __name__ == "__main__":
    main()
