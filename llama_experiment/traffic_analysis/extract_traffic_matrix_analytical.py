#!/usr/bin/env python3
"""Aggregate an ASTRA-sim analytical chunk-level trace into an N x N x T
time-windowed traffic matrix.

Input trace format (emitted by TraceManager):
    # src dst size send_time_ns finish_time_ns chunk_id tag
    <src> <dst> <size> <send_ns> <finish_ns> <chunk_id> <tag>
    ...

Usage:
    python3 extract_traffic_matrix_analytical.py \\
        --trace analytical_trace.txt \\
        --window 50000000 \\
        --attribution spread \\
        --output analytical_traffic_matrix_50ms.npy

The output .npy has shape (T, N, N) and dtype int64, compatible with the
existing visualize_traffic.py / animate_traffic.py tooling.
"""
import argparse
import os
import sys

import numpy as np


def parse_args():
    p = argparse.ArgumentParser(
        description="Extract traffic matrix from ASTRA-sim analytical chunk "
                    "trace.")
    p.add_argument("--trace", required=True,
                   help="Path to analytical chunk-level trace (text).")
    p.add_argument("--output", required=True,
                   help="Output .npy file path.")
    p.add_argument("--window", type=int, default=50_000_000,
                   help="Time window size in ns (default: 50ms = 5e7).")
    p.add_argument(
        "--attribution", choices=["finish", "spread"], default="spread",
        help="How to attribute a chunk's bytes across windows. "
             "'finish' credits the whole chunk to the window containing "
             "finish_time. 'spread' (default) distributes bytes linearly "
             "across [send_time, finish_time], matching ns-3 packet-level "
             "aggregation more closely.")
    p.add_argument("--start_ns", type=int, default=None,
                   help="Only include chunks whose finish_time >= start_ns.")
    p.add_argument("--end_ns", type=int, default=None,
                   help="Only include chunks whose send_time < end_ns.")
    p.add_argument("--src_filter", type=str, default=None,
                   help="Comma-separated src node IDs to keep.")
    p.add_argument("--dst_filter", type=str, default=None,
                   help="Comma-separated dst node IDs to keep.")
    p.add_argument("--num_nodes", type=int, default=None,
                   help="Force N (matrix side). If omitted, inferred from "
                        "max(src, dst) + 1.")
    return p.parse_args()


def parse_int_set(s):
    if s is None:
        return None
    return {int(x) for x in s.split(",") if x.strip()}


def iter_chunks(path):
    """Yield (src, dst, size, send_ns, finish_ns, chunk_id, tag)."""
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 7:
                continue
            try:
                src = int(parts[0])
                dst = int(parts[1])
                size = int(parts[2])
                send_ns = int(parts[3])
                finish_ns = int(parts[4])
                chunk_id = int(parts[5])
                tag = int(parts[6])
            except ValueError:
                continue
            yield src, dst, size, send_ns, finish_ns, chunk_id, tag


def first_pass(path, src_filter, dst_filter, start_ns, end_ns):
    """Scan once to determine N (node count) and T (window count)."""
    max_node = -1
    max_finish = 0
    count = 0
    for src, dst, size, send_ns, finish_ns, _chunk_id, _tag in iter_chunks(path):
        if src_filter is not None and src not in src_filter:
            continue
        if dst_filter is not None and dst not in dst_filter:
            continue
        if start_ns is not None and finish_ns < start_ns:
            continue
        if end_ns is not None and send_ns >= end_ns:
            continue
        if src > max_node:
            max_node = src
        if dst > max_node:
            max_node = dst
        if finish_ns > max_finish:
            max_finish = finish_ns
        count += 1
    return max_node + 1, max_finish, count


def attribute_finish(matrix, src, dst, size, send_ns, finish_ns, window):
    bin_idx = finish_ns // window
    if bin_idx >= matrix.shape[0]:
        return
    matrix[bin_idx, src, dst] += size


def attribute_spread(matrix, src, dst, size, send_ns, finish_ns, window):
    """Linearly spread `size` bytes across windows covered by
    [send_ns, finish_ns]. If send_ns == finish_ns the full size lands in the
    finish window."""
    if finish_ns <= send_ns:
        bin_idx = finish_ns // window
        if 0 <= bin_idx < matrix.shape[0]:
            matrix[bin_idx, src, dst] += size
        return

    duration = finish_ns - send_ns
    start_bin = send_ns // window
    end_bin = finish_ns // window
    # Integer byte accounting: assign floor to each window, dump remainder
    # into the last window so totals are preserved exactly.
    remaining = size
    for b in range(start_bin, end_bin + 1):
        if b >= matrix.shape[0]:
            break
        lo = max(send_ns, b * window)
        hi = min(finish_ns, (b + 1) * window)
        overlap = max(0, hi - lo)
        if b == end_bin:
            # last covered window gets whatever is left so sum == size
            contrib = remaining
        else:
            contrib = (size * overlap) // duration
            remaining -= contrib
        matrix[b, src, dst] += contrib


def main():
    args = parse_args()

    if not os.path.exists(args.trace):
        print(f"Error: trace file not found: {args.trace}", file=sys.stderr)
        sys.exit(1)

    src_filter = parse_int_set(args.src_filter)
    dst_filter = parse_int_set(args.dst_filter)

    print(f"[extract] scanning {args.trace} for dimensions...")
    inferred_n, max_finish, matched = first_pass(
        args.trace, src_filter, dst_filter, args.start_ns, args.end_ns)
    if matched == 0:
        print("No chunks matched filters; nothing to do.", file=sys.stderr)
        sys.exit(2)

    n = args.num_nodes if args.num_nodes is not None else inferred_n
    # Number of windows = ceil((max_finish + 1) / window). If --end_ns is set,
    # cap at end_ns.
    upper = args.end_ns if args.end_ns is not None else max_finish + 1
    num_bins = max(1, (upper + args.window - 1) // args.window)

    print(f"[extract] N={n}, window={args.window} ns, T={num_bins}, "
          f"chunks={matched}, attribution={args.attribution}")
    matrix = np.zeros((num_bins, n, n), dtype=np.int64)

    attribute = attribute_spread if args.attribution == "spread" \
        else attribute_finish

    processed = 0
    for src, dst, size, send_ns, finish_ns, _chunk_id, _tag in iter_chunks(
            args.trace):
        if src_filter is not None and src not in src_filter:
            continue
        if dst_filter is not None and dst not in dst_filter:
            continue
        if args.start_ns is not None and finish_ns < args.start_ns:
            continue
        if args.end_ns is not None and send_ns >= args.end_ns:
            continue
        if src >= n or dst >= n:
            continue
        attribute(matrix, src, dst, size, send_ns, finish_ns, args.window)
        processed += 1

    np.save(args.output, matrix)
    total_bytes = int(matrix.sum())
    print(f"[extract] wrote {args.output} shape={matrix.shape} "
          f"dtype={matrix.dtype} processed={processed} "
          f"total_bytes={total_bytes}")


if __name__ == "__main__":
    main()
