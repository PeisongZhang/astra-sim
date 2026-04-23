#!/usr/bin/env python3
"""PP-shard a Chakra workload directory.

Given a workload directory produced by STG (workload.N.et + workload.json),
split it into N shards along the pipeline-parallel dimension. Each shard
is a self-contained workload that can be simulated by AstraSim_HTSim
independently in its own process.

Cross-PP P2P sends/recvs that reference ranks outside the shard are
rewritten as dummy COMP_NODE entries with a fixed duration approximation.
Dependency edges (node IDs) are preserved so the intra-shard DAG stays
valid.

Usage:
    shard_workload_pp.py --workload-dir <path> --out-dir <path> \\
        --pp <N> --dp <D> --tp <T>

If DP and TP are omitted they default to sensible values and the tool
tries to infer from workload.json size.

Assumption: rank ordering is [stage0_dp0_tp0, stage0_dp0_tp1, ...,
stage0_dpD-1_tpT-1, stage1_dp0_tp0, ...] - i.e. DP-major TP-inner within
each PP stage (matching STG `graph_distributer` conventions for Megatron).

Rank R belongs to shard `R // (DP * TP)`.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

os.environ.setdefault("PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION", "python")

HERE = Path(__file__).resolve().parent
CHAKRA_ROOT = HERE.parent.parent / "extern" / "graph_frontend" / "chakra"
sys.path.insert(0, str(CHAKRA_ROOT / "schema" / "protobuf"))
sys.path.insert(0, str(CHAKRA_ROOT / "src"))

import et_def_pb2  # noqa: E402
from third_party.utils.protolib import (  # noqa: E402
    decodeMessage,
    encodeMessage,
    openFileRd,
)


def openFileWt(path: str):
    """Counterpart to protolib.openFileRd — plain binary write handle.

    protolib only exposes `openFileRd`; encodeMessage just needs a file
    object supporting `write(bytes)`. Use a plain `open(path, "wb")`.
    """
    return open(path, "wb")


# Estimated per-direction PP P2P latency (microseconds) used to replace
# cross-shard COMM_SEND / COMM_RECV with a COMP_NODE of equivalent runtime.
# For gpt_39b/76b, P2P comm_size is 524288 bytes → at 200 Gbps backbone bw
# the transmission alone is ~20 µs; plus two-switch store-and-forward
# latency gives ~25 µs. Setting num_ops to the equivalent compute-at-
# peak-perf keeps the dep chain timing faithful.
DEFAULT_BOUNDARY_LATENCY_US = 25.0


def _load_comm_groups(workload_json: Path) -> dict:
    with workload_json.open() as f:
        return json.load(f)


def _infer_dp_tp(workload_json: dict, pp: int, total_npus: int) -> tuple[int, int]:
    """Infer (DP, TP) from workload.json group sizes."""
    sizes = sorted({len(v) for v in workload_json.values() if len(v) > 1})
    if not sizes:
        raise RuntimeError("comm_group.json contains only singletons; cannot infer DP/TP")
    # Heuristic: largest non-singleton group = DP group (one per layer's DP-AR).
    # Next smallest non-singleton group = TP group.
    # For Megatron, DP group size >= TP group size typically.
    tp = sizes[0]
    dp = sizes[-1]
    # Sanity: dp * tp * pp should equal total_npus (no SP variation here)
    if dp * tp * pp != total_npus:
        raise RuntimeError(
            f"DP={dp} * TP={tp} * PP={pp} = {dp*tp*pp} != total NPUs {total_npus}; "
            f"cannot auto-infer — pass --dp and --tp explicitly."
        )
    return dp, tp


def _rewrite_node_for_shard(node, shard_rank_set: set[int],
                            rank_renumber: dict[int, int],
                            boundary_num_ops: int,
                            stats: dict) -> et_def_pb2.Node:
    """Return a copy of `node` with cross-shard peer references rewritten.

    If the node is a COMM_SEND/RECV whose peer is out-of-shard, convert to
    a COMP_NODE with the boundary latency approximation. Otherwise
    renumber the peer to its shard-local ID.
    """
    out = et_def_pb2.Node()
    out.CopyFrom(node)

    if node.type not in (et_def_pb2.COMM_SEND_NODE, et_def_pb2.COMM_RECV_NODE):
        return out

    # find the peer attribute
    peer_attr = None
    for i, a in enumerate(out.attr):
        if a.name in ("comm_dst", "comm_src"):
            peer_attr = (i, a)
            break
    if peer_attr is None:
        # malformed; leave as-is
        return out

    _, attr = peer_attr
    peer_rank = attr.int32_val or attr.uint32_val or attr.int64_val
    if peer_rank in shard_rank_set:
        # rewrite peer_rank to shard-local
        new_peer = rank_renumber[peer_rank]
        attr.int32_val = new_peer
        # clear other oneof values just in case
        attr.uint32_val = 0
        attr.int64_val = 0
        stats["intra_rewrite"] += 1
        return out

    # Out-of-shard: convert to COMP_NODE with boundary latency
    stats["cross_to_comp"] += 1
    new = et_def_pb2.Node()
    new.id = out.id
    new.name = f"boundary_{et_def_pb2.NodeType.Name(out.type)}_{out.id}"
    new.type = et_def_pb2.COMP_NODE
    new.duration_micros = 0
    for dep in out.data_deps:
        new.data_deps.append(dep)
    for dep in out.ctrl_deps:
        new.ctrl_deps.append(dep)
    # Build minimal attrs for COMP_NODE: inputs, outputs, num_ops,
    # tensor_size, op_type. IMPORTANT: tensor_size must be > 0, otherwise
    # astra-sim workload/Workload.cc::issue_comp takes the skip_invalid
    # branch (treats node as invalid) which calls finish_node() but does
    # NOT re-invoke issue_dep_free_nodes(). That leaves children hung
    # when the whole shard's initial roots are boundary nodes (common
    # for PP stage > 0, where the first thing a rank does is RECV).
    # Use a small tensor_size so the regular roofline path runs and
    # registers an event, keeping the dep-resolver loop alive.
    # We size num_ops to match the desired boundary latency; tensor_size
    # is chosen so operational_intensity = num_ops / tensor_size stays
    # moderate (~1024 flop/byte, roofline is compute-bound).
    boundary_tensor_size = max(1, boundary_num_ops // 1024)
    for nm, kind, val in (
        ("inputs", "int32_val", 0),
        ("outputs", "int32_val", 0),
        ("num_ops", "int64_val", boundary_num_ops),
        ("tensor_size", "uint64_val", boundary_tensor_size),
        ("op_type", "int32_val", 0),
        ("is_cpu_op", "int32_val", 0),
    ):
        a = new.attr.add()
        a.name = nm
        setattr(a, kind, val)
    return new


def _process_rank(args):
    """Worker: translate one rank's .et. Runs in a multiprocessing child."""
    (src_path, dst_path, shard_ranks_list, rank_renumber_items,
     boundary_num_ops, shard_id) = args
    shard_ranks = set(shard_ranks_list)
    rank_renumber = dict(rank_renumber_items)
    stats = {"intra_rewrite": 0, "cross_to_comp": 0, "nodes": 0,
             "shard": shard_id}
    fin = openFileRd(src_path)
    fout = openFileWt(dst_path)
    gm = et_def_pb2.GlobalMetadata()
    if decodeMessage(fin, gm):
        encodeMessage(fout, gm)
    while True:
        node = et_def_pb2.Node()
        if not decodeMessage(fin, node):
            break
        new_node = _rewrite_node_for_shard(
            node, shard_ranks, rank_renumber, boundary_num_ops, stats
        )
        encodeMessage(fout, new_node)
        stats["nodes"] += 1
    fin.close()
    fout.close()
    return stats


def shard_workload(
    workload_dir: Path,
    out_dir: Path,
    pp: int,
    dp: Optional[int] = None,
    tp: Optional[int] = None,
    boundary_latency_us: float = DEFAULT_BOUNDARY_LATENCY_US,
    peak_tflops: float = 312.0,
    workers: Optional[int] = None,
) -> list[Path]:
    import multiprocessing as mp
    out_dir.mkdir(parents=True, exist_ok=True)
    et_files = sorted(workload_dir.glob("workload.*.et"),
                      key=lambda p: int(p.name.split(".")[1]))
    if not et_files:
        raise RuntimeError(f"no workload.*.et in {workload_dir}")
    total_npus = len(et_files)
    workload_json_path = workload_dir / "workload.json"
    comm_groups = _load_comm_groups(workload_json_path)

    if dp is None or tp is None:
        dp, tp = _infer_dp_tp(comm_groups, pp, total_npus)

    stage_size = dp * tp
    if stage_size * pp != total_npus:
        raise RuntimeError(
            f"DP={dp} * TP={tp} * PP={pp} = {stage_size*pp} != total NPUs {total_npus}"
        )

    boundary_num_ops = int(boundary_latency_us * 1e-6 * peak_tflops * 1e12)
    if workers is None:
        workers = max(1, (os.cpu_count() or 2) - 1)
    print(f"[splitter] total_npus={total_npus}, pp={pp}, dp={dp}, tp={tp}, "
          f"stage_size={stage_size}, boundary_latency_us={boundary_latency_us} "
          f"(num_ops={boundary_num_ops}), workers={workers}")

    shard_dirs: list[Path] = []
    per_shard_boundary = [0] * pp  # cross_to_comp per shard
    # Build all rank tasks across all shards so we keep CPUs saturated.
    tasks = []
    for shard in range(pp):
        shard_start = shard * stage_size
        shard_end = shard_start + stage_size
        shard_ranks = list(range(shard_start, shard_end))
        rank_renumber = [(orig, orig - shard_start) for orig in shard_ranks]
        sdir = out_dir / f"pp_shard_{shard}"
        sdir.mkdir(parents=True, exist_ok=True)
        shard_dirs.append(sdir)
        for orig_rank in shard_ranks:
            src = workload_dir / f"workload.{orig_rank}.et"
            dst = sdir / f"workload.{orig_rank - shard_start}.et"
            tasks.append((str(src), str(dst), shard_ranks, rank_renumber,
                          boundary_num_ops, shard))

    totals = {"intra_rewrite": 0, "cross_to_comp": 0, "nodes": 0}
    if workers <= 1:
        for t in tasks:
            s = _process_rank(t)
            per_shard_boundary[s["shard"]] += s["cross_to_comp"]
            for k in totals:
                totals[k] += s[k]
    else:
        with mp.Pool(workers) as pool:
            for i, s in enumerate(pool.imap_unordered(_process_rank, tasks,
                                                      chunksize=4)):
                per_shard_boundary[s["shard"]] += s["cross_to_comp"]
                for k in totals:
                    totals[k] += s[k]
                if (i + 1) % 64 == 0:
                    print(f"[splitter]   processed {i + 1}/{len(tasks)} ranks")

    # Write per-shard workload.json (small; no need to parallelize).
    for shard, sdir in enumerate(shard_dirs):
        shard_start = shard * stage_size
        shard_ranks = set(range(shard_start, shard_start + stage_size))
        rank_renumber = {orig: orig - shard_start for orig in shard_ranks}
        shard_cg = {}
        for gid, ranks in comm_groups.items():
            rs = set(ranks)
            if rs.issubset(shard_ranks):
                shard_cg[gid] = [rank_renumber[r] for r in ranks]
        with (sdir / "workload.json").open("w") as f:
            json.dump(shard_cg, f, indent=2)
        print(f"[splitter] shard {shard}: ranks [{shard_start}..{shard_start+stage_size}), "
              f"{len(shard_cg)}/{len(comm_groups)} comm_groups kept")
    print(f"[splitter] totals: intra_rewrite={totals['intra_rewrite']}, "
          f"cross_to_comp={totals['cross_to_comp']}, nodes={totals['nodes']}")

    # D2: emit splitter stats for later boundary-latency calibration
    # (calibrate_boundary below consumes this + analytical log + htsim run.csv).
    stats_out = {
        "pp": pp,
        "dp": dp,
        "tp": tp,
        "stage_size": stage_size,
        "total_npus": total_npus,
        "boundary_latency_us": boundary_latency_us,
        "boundary_num_ops": boundary_num_ops,
        "peak_tflops": peak_tflops,
        "per_shard_boundary_count": per_shard_boundary,
        "totals": totals,
    }
    with (out_dir / "shard_stats.json").open("w") as f:
        json.dump(stats_out, f, indent=2)
    return shard_dirs


# ----------------------------------------------------------------------------
# D2: boundary-latency calibration from analytical reference run.
# ----------------------------------------------------------------------------
#
# Model:
#   htsim_cycle_ns      = static_cycle_ns + N_boundary × boundary_latency_ns
#   analytical_cycle_ns = static_cycle_ns + real_cross_shard_comm_ns
#
# Given a previous sharded run's (htsim_cycles, boundary_latency_us) we solve:
#   static = htsim_cycle - N_boundary × current_boundary_ns
#   suggested_boundary_ns = (analytical_cycle - static) / N_boundary
#
# All 'cycles' reported by astra-sim are nanoseconds (1ns tick period), so
# the ns-vs-us conversion is just /1000.

_FINISHED_RE_TEXT = r"sys\[([0-9]+)\] finished, ([0-9]+) cycles"


def _parse_analytical_max_cycle(log_path: Path) -> int:
    import re
    pat = re.compile(_FINISHED_RE_TEXT)
    max_c = 0
    with log_path.open() as f:
        for line in f:
            m = pat.search(line)
            if m:
                c = int(m.group(2))
                if c > max_c:
                    max_c = c
    if max_c == 0:
        raise RuntimeError(f"no 'sys[N] finished, C cycles' lines in {log_path}")
    return max_c


def _parse_htsim_run_csv(csv_path: Path) -> dict:
    """Return {shard_name -> {max_cycle, finished, wall_sec, rc}} from run.csv."""
    import csv
    out = {}
    with csv_path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            out[row["shard"]] = {
                "finished": int(row["finished"]),
                "max_cycle": int(row["max_cycle"]),
                "wall_sec": int(row["wall_sec"]),
                "rc": int(row["rc"]),
            }
    return out


def calibrate_boundary(analytical_log: Path, htsim_run_csv: Path,
                        stats_in: Path) -> dict:
    analytical_ns = _parse_analytical_max_cycle(analytical_log)
    htsim = _parse_htsim_run_csv(htsim_run_csv)
    with stats_in.open() as f:
        stats = json.load(f)
    pp = stats["pp"]
    cur_us = stats["boundary_latency_us"]
    cur_ns = cur_us * 1000.0
    per_shard_boundary = stats["per_shard_boundary_count"]

    shard_max_cycles = []
    suggested_per_shard = []
    for i in range(pp):
        name = f"shard_{i}_exp"
        if name not in htsim:
            raise RuntimeError(f"{name} missing from htsim run.csv")
        mc = htsim[name]["max_cycle"]
        nb = per_shard_boundary[i]
        shard_max_cycles.append(mc)
        if nb <= 0:
            suggested_per_shard.append(None)
            continue
        static_ns = mc - nb * cur_ns
        if static_ns < 0:
            static_ns = 0  # defensive; N_boundary over-estimate
        sug_ns = max(0.0, (analytical_ns - static_ns) / nb)
        suggested_per_shard.append(sug_ns / 1000.0)

    # Global suggestion: target the shard whose static cycles are largest
    # so the pipeline's long-pole stage matches analytical wall.
    htsim_global_max = max(shard_max_cycles)
    # Pick the long-pole shard for the global knob.
    lp = shard_max_cycles.index(htsim_global_max)
    global_sug_us = suggested_per_shard[lp] if suggested_per_shard[lp] is not None else cur_us
    return {
        "analytical_max_cycle_ns": analytical_ns,
        "htsim_max_cycle_ns": htsim_global_max,
        "ratio_current": htsim_global_max / analytical_ns if analytical_ns else 0.0,
        "current_boundary_latency_us": cur_us,
        "suggested_boundary_latency_us_global": global_sug_us,
        "suggested_boundary_latency_us_per_shard": suggested_per_shard,
        "long_pole_shard": lp,
        "per_shard_htsim_max_cycle_ns": shard_max_cycles,
        "per_shard_boundary_count": per_shard_boundary,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workload-dir", type=Path,
                    help="unsharded STG workload dir (not used in --calibrate mode)")
    ap.add_argument("--out-dir", type=Path,
                    help="shard output dir (also where calibrate reads stats.json from)")
    ap.add_argument("--pp", type=int)
    ap.add_argument("--dp", type=int)
    ap.add_argument("--tp", type=int)
    ap.add_argument("--boundary-latency-us", type=float,
                    default=DEFAULT_BOUNDARY_LATENCY_US)
    ap.add_argument("--peak-tflops", type=float, default=312.0)
    ap.add_argument("--workers", type=int, default=0,
                    help="parallel workers (default = max(1, cpu_count-1))")
    ap.add_argument("--calibrate-from-analytical", type=Path, metavar="LOG",
                    help="Calibration mode: analyze a previous sharded run "
                         "and print the suggested --boundary-latency-us. "
                         "Needs --htsim-run-csv and --stats-in.")
    ap.add_argument("--htsim-run-csv", type=Path,
                    help="run.csv from a previous run_pp_sharded.sh invocation")
    ap.add_argument("--stats-in", type=Path,
                    help="shard_stats.json from the prior splitter run "
                         "(defaults to <out-dir>/shard_stats.json)")
    args = ap.parse_args()

    if args.calibrate_from_analytical:
        # Calibration mode: no sharding, just report suggested boundary_us.
        if not args.htsim_run_csv:
            ap.error("--calibrate-from-analytical requires --htsim-run-csv")
        stats_in = args.stats_in
        if stats_in is None:
            if args.out_dir is None:
                ap.error("--stats-in or --out-dir required in calibrate mode")
            stats_in = args.out_dir / "shard_stats.json"
        if not stats_in.exists():
            ap.error(f"stats file not found: {stats_in}")
        result = calibrate_boundary(
            args.calibrate_from_analytical, args.htsim_run_csv, stats_in
        )
        print(json.dumps(result, indent=2))
        ratio = result["ratio_current"]
        sug = result["suggested_boundary_latency_us_global"]
        cur = result["current_boundary_latency_us"]
        print(f"\n[calibrate] current ratio = {ratio:.4f}")
        print(f"[calibrate] current --boundary-latency-us = {cur}")
        print(f"[calibrate] suggested --boundary-latency-us = {sug:.3f}")
        if 0.9 <= ratio <= 1.5:
            print(f"[calibrate] ratio already within [0.9, 1.5] window; no re-shard needed")
        return

    # Shard mode: all sharding args are required.
    if not args.workload_dir or not args.out_dir or args.pp is None:
        ap.error("--workload-dir, --out-dir, --pp are required in shard mode")
    shard_workload(
        workload_dir=args.workload_dir,
        out_dir=args.out_dir,
        pp=args.pp,
        dp=args.dp,
        tp=args.tp,
        boundary_latency_us=args.boundary_latency_us,
        peak_tflops=args.peak_tflops,
        workers=(args.workers if args.workers > 0 else None),
    )


if __name__ == "__main__":
    main()
