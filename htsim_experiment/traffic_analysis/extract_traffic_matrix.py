#!/usr/bin/env python3
"""Build a time-binned traffic matrix from htsim offline flow-event logs.

Input: one or more binary logs produced by the htsim backend when run with
ASTRASIM_HTSIM_FLOW_LOG=<path>.  See FlowLogger.hh for the record layout.

Each flow's bytes are distributed across the bins it overlaps, proportional
to the overlap length.  Zero-duration flows are deposited entirely in the
bin containing the completion timestamp.

Output (numpy .npz):
    matrix     [T, N, N] int64, bytes src->dst per bin
    bin_ns     int, bin width in nanoseconds
    t0_ns      int, start of bin 0
    num_nodes  int
    shard_ids  [N] int32, per-node shard id (-1 if unknown)
    global_ids [N] int32, per-node global rank id (-1 if unknown)

Also writes a JSON summary next to it.

Usage:
    extract_traffic_matrix.py \\
        --log shard_0/flow_log.bin --shard-id 0 --stage-size 256 \\
        --log shard_1/flow_log.bin --shard-id 1 --stage-size 256 \\
        --bin-us 100 \\
        --output traffic_matrix.npz
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from pathlib import Path

import numpy as np

HEADER_MAGIC = b"HTSMFLOG"
HEADER_FMT = "<8sII"  # magic, version, rec_sz
HEADER_SIZE = struct.calcsize(HEADER_FMT)
RECORD_FMT = "<QQIIII"  # t_start, t_end, flow_id, src, dst, size
RECORD_SIZE = struct.calcsize(RECORD_FMT)
assert RECORD_SIZE == 32


def read_log(path: Path):
    """Yield (t_start_ns, t_end_ns, flow_id, src, dst, size) from one log."""
    with path.open("rb") as f:
        hdr = f.read(HEADER_SIZE)
        if len(hdr) != HEADER_SIZE:
            raise RuntimeError(f"{path}: truncated header")
        magic, version, rec_sz = struct.unpack(HEADER_FMT, hdr)
        if magic != HEADER_MAGIC:
            raise RuntimeError(f"{path}: bad magic {magic!r}")
        if version != 1 or rec_sz != RECORD_SIZE:
            raise RuntimeError(
                f"{path}: unsupported version/rec_sz ({version}, {rec_sz})"
            )
        # Bulk-read in ~8 MiB chunks for throughput.
        CHUNK = (8 * 1024 * 1024 // RECORD_SIZE) * RECORD_SIZE
        while True:
            buf = f.read(CHUNK)
            if not buf:
                return
            if len(buf) % RECORD_SIZE != 0:
                raise RuntimeError(f"{path}: trailing partial record")
            n = len(buf) // RECORD_SIZE
            # numpy unpack for speed
            arr = np.frombuffer(buf, dtype=np.uint8).reshape(n, RECORD_SIZE)
            t_start = arr[:, 0:8].copy().view("<u8").ravel()
            t_end = arr[:, 8:16].copy().view("<u8").ravel()
            flow_id = arr[:, 16:20].copy().view("<u4").ravel()
            src = arr[:, 20:24].copy().view("<u4").ravel()
            dst = arr[:, 24:28].copy().view("<u4").ravel()
            size = arr[:, 28:32].copy().view("<u4").ravel()
            yield t_start, t_end, flow_id, src, dst, size


def _deposit_bulk(matrix, src_global, dst_global, t_start, t_end, size,
                  t0, bin_ns):
    """Distribute each flow's bytes proportionally across overlapping bins.

    Operates row-at-a-time (per-flow) — simple, correct; fast enough with
    numpy bulk dispatch of small loops.  For very large flows (duration >>
    bin width) the inner loop stays at T_bins_overlap steps, so total cost
    is O(total_flow_duration / bin_ns), which equals wall work anyway.
    """
    n_bins = matrix.shape[0]
    # Clamp to valid ranges
    src_global = src_global.astype(np.int64)
    dst_global = dst_global.astype(np.int64)
    for i in range(len(size)):
        s = int(size[i])
        if s == 0:
            continue
        si = int(src_global[i])
        di = int(dst_global[i])
        if si < 0 or di < 0:
            continue
        ts = int(t_start[i]) - t0
        te = int(t_end[i]) - t0
        if te < ts:
            ts, te = te, ts
        if te < 0:
            continue
        if ts < 0:
            ts = 0
        b0 = ts // bin_ns
        b1 = te // bin_ns
        if b0 >= n_bins:
            continue
        if b1 >= n_bins:
            b1 = n_bins - 1
        if b0 == b1:
            matrix[b0, si, di] += s
            continue
        duration = max(te - ts, 1)
        # First bin
        first_end = (b0 + 1) * bin_ns
        first_bytes = s * (first_end - ts) // duration
        matrix[b0, si, di] += first_bytes
        remaining = s - first_bytes
        # Middle bins
        if b1 > b0 + 1:
            middle = b1 - b0 - 1
            per_bin = s * bin_ns // duration
            matrix[b0 + 1:b1, si, di] += per_bin
            remaining -= per_bin * middle
        # Last bin
        if remaining < 0:
            remaining = 0
        matrix[b1, si, di] += remaining


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", action="append", required=True,
                        help="Path to flow_log.bin.  Repeat for multi-shard runs.")
    parser.add_argument("--shard-id", action="append", type=int,
                        help="Shard id for the matching --log (defaults to 0).")
    parser.add_argument("--stage-size", type=int, default=None,
                        help="Ranks-per-shard; required when combining shards.  "
                             "global_rank = shard_id * stage_size + local_rank.")
    parser.add_argument("--bin-us", type=float, default=100.0,
                        help="Time bin width in microseconds (default 100).")
    parser.add_argument("--output", required=True, help="Output .npz path.")
    parser.add_argument("--summary", default=None,
                        help="Optional summary JSON path (default: <output>.json).")
    parser.add_argument("--max-bins", type=int, default=200000,
                        help="Safety cap on number of time bins.")
    args = parser.parse_args()

    logs = [Path(p) for p in args.log]
    shard_ids = args.shard_id if args.shard_id else [0] * len(logs)
    if len(shard_ids) != len(logs):
        print("[extract] --shard-id count must match --log count", file=sys.stderr)
        return 2
    if len(logs) > 1 and args.stage_size is None:
        print("[extract] --stage-size required when combining multiple logs",
              file=sys.stderr)
        return 2
    stage_size = args.stage_size or 0

    bin_ns = int(round(args.bin_us * 1000.0))
    if bin_ns <= 0:
        print("[extract] bin_us must be positive", file=sys.stderr)
        return 2

    # Pass 1: scan to find time range and node range.
    t_min = None
    t_max = 0
    max_local_rank = -1
    total_records = 0
    for path in logs:
        for t_start, t_end, _fid, src, dst, _sz in read_log(path):
            if len(t_start) == 0:
                continue
            lo = int(t_start.min())
            hi = int(t_end.max())
            if t_min is None or lo < t_min:
                t_min = lo
            if hi > t_max:
                t_max = hi
            m = int(max(src.max(), dst.max()))
            if m > max_local_rank:
                max_local_rank = m
            total_records += len(t_start)
    if total_records == 0:
        print("[extract] no records found", file=sys.stderr)
        return 1
    if t_min is None:
        t_min = 0
    # Align t0 to a bin boundary for nicer axes.
    t0 = (t_min // bin_ns) * bin_ns
    span = max(t_max - t0, 1)
    n_bins = int(span // bin_ns) + 1
    if n_bins > args.max_bins:
        print(f"[extract] n_bins={n_bins} > --max-bins={args.max_bins}; "
              f"re-run with a larger --bin-us", file=sys.stderr)
        return 2

    # Node layout: if combining shards, num_nodes = max_shard * stage_size +
    # stage_size.  Otherwise, nodes = max_local_rank + 1.
    if len(logs) > 1 or (stage_size > 0 and max(shard_ids) > 0):
        n_shards = max(shard_ids) + 1
        num_nodes = n_shards * stage_size
    else:
        num_nodes = max_local_rank + 1

    print(f"[extract] records={total_records} t0={t0}ns t_end={t_max}ns "
          f"n_bins={n_bins} bin_ns={bin_ns} num_nodes={num_nodes}")

    matrix = np.zeros((n_bins, num_nodes, num_nodes), dtype=np.int64)

    # Pass 2: deposit.
    for path, sid in zip(logs, shard_ids):
        offset = sid * stage_size if stage_size > 0 else 0
        print(f"[extract] loading {path} (shard {sid}, offset +{offset})...")
        seen = 0
        for t_start, t_end, _fid, src, dst, size in read_log(path):
            # Remap to global node ids.
            src_g = src.astype(np.int64) + offset
            dst_g = dst.astype(np.int64) + offset
            # Guard against bogus data
            oob = (src_g >= num_nodes) | (dst_g >= num_nodes)
            if oob.any():
                src_g = np.where(oob, -1, src_g)
                dst_g = np.where(oob, -1, dst_g)
            _deposit_bulk(matrix, src_g, dst_g, t_start, t_end, size,
                          t0, bin_ns)
            seen += len(t_start)
        print(f"[extract]   deposited {seen} records")

    shard_ids_arr = -np.ones(num_nodes, dtype=np.int32)
    global_ids_arr = -np.ones(num_nodes, dtype=np.int32)
    if stage_size > 0:
        for sid in set(shard_ids):
            lo = sid * stage_size
            hi = lo + stage_size
            shard_ids_arr[lo:hi] = sid
            global_ids_arr[lo:hi] = np.arange(lo, hi, dtype=np.int32)
    else:
        shard_ids_arr[:] = 0
        global_ids_arr[:] = np.arange(num_nodes, dtype=np.int32)

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        out,
        matrix=matrix,
        bin_ns=np.int64(bin_ns),
        t0_ns=np.int64(t0),
        num_nodes=np.int32(num_nodes),
        shard_ids=shard_ids_arr,
        global_ids=global_ids_arr,
    )

    total_bytes = int(matrix.sum())
    nonzero_bins = int((matrix.sum(axis=(1, 2)) > 0).sum())
    peak_bin_bytes = int(matrix.sum(axis=(1, 2)).max())
    pair_bytes = matrix.sum(axis=0)
    top_pairs = []
    flat = pair_bytes.flatten()
    order = np.argsort(flat)[::-1][:10]
    for idx in order:
        b = int(flat[idx])
        if b == 0:
            break
        s = int(idx // num_nodes)
        d = int(idx % num_nodes)
        top_pairs.append({"src": s, "dst": d, "bytes": b})

    summary = {
        "logs": [str(p) for p in logs],
        "shard_ids": shard_ids,
        "stage_size": stage_size,
        "records": total_records,
        "t0_ns": t0,
        "t_end_ns": t_max,
        "bin_ns": bin_ns,
        "n_bins": n_bins,
        "num_nodes": num_nodes,
        "total_bytes": total_bytes,
        "total_GB": total_bytes / 1e9,
        "nonzero_bins": nonzero_bins,
        "peak_bin_bytes": peak_bin_bytes,
        "peak_bin_Bps": peak_bin_bytes / (bin_ns * 1e-9) if bin_ns else 0,
        "top_pairs_by_total_bytes": top_pairs,
    }
    summary_path = Path(args.summary) if args.summary else out.with_suffix(out.suffix + ".json")
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"[extract] wrote {out} ({os.path.getsize(out)/1e6:.1f} MB) "
          f"and {summary_path}")
    print(f"[extract] total_bytes={total_bytes/1e9:.3f} GB nonzero_bins="
          f"{nonzero_bins}/{n_bins}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
