#!/usr/bin/env python3
"""Render static visualizations of an htsim time-binned traffic matrix.

Input: .npz produced by extract_traffic_matrix.py (keys: matrix [T,N,N],
bin_ns, t0_ns, num_nodes, shard_ids, global_ids).

Outputs (next to the input by default):
  <stem>_timeline.png      — aggregate bytes/bin vs time
  <stem>_heatmap.png       — total (src,dst) bytes, log colour
  <stem>_heatmap_dpblock.png — downsampled by (dp,tp) groups for readability
  <stem>_src_time.png      — [src, time] bytes, shows who is active when
  <stem>_top_pairs.png     — time series for top-N (src,dst) pairs

Designed for the 512-node gpt_39b run (matrix shape [~1700, 512, 512]).
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LogNorm


def _safe_log(mat):
    out = mat.astype(np.float64)
    out[out <= 0] = np.nan
    return out


def timeline_plot(matrix, bin_ns, out_path):
    totals = matrix.sum(axis=(1, 2)).astype(np.float64)  # [T]
    t_ms = np.arange(len(totals)) * (bin_ns / 1e6)
    bytes_per_sec_TBs = totals / (bin_ns * 1e-9) / 1e12

    fig, ax1 = plt.subplots(figsize=(12, 4.5))
    ax1.fill_between(t_ms, bytes_per_sec_TBs, color="steelblue", alpha=0.6, linewidth=0)
    ax1.plot(t_ms, bytes_per_sec_TBs, color="navy", linewidth=0.8)
    ax1.set_xlabel("Time (ms)")
    ax1.set_ylabel("Aggregate throughput (TB/s)")
    ax1.set_title(
        f"Aggregate traffic vs time — {len(totals)} bins × {bin_ns/1000:.0f} µs"
    )
    ax1.grid(True, linestyle="--", alpha=0.4)
    ax1.set_xlim(0, t_ms[-1] if len(t_ms) else 1)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return bytes_per_sec_TBs.max()


def full_heatmap(matrix, out_path):
    total = matrix.sum(axis=0)  # [N, N]
    N = total.shape[0]
    fig, ax = plt.subplots(figsize=(9, 8))
    data = _safe_log(total)
    vmax = np.nanmax(data) if np.isfinite(np.nanmax(data)) else 1.0
    vmin = max(1.0, vmax / 1e6)
    im = ax.imshow(
        data,
        cmap="magma",
        norm=LogNorm(vmin=vmin, vmax=vmax),
        aspect="equal",
        interpolation="nearest",
    )
    ax.set_xlabel("Destination rank")
    ax.set_ylabel("Source rank")
    ax.set_title(f"Total bytes per (src,dst) pair — {N}×{N}, log colour")
    cb = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
    cb.set_label("Bytes (log)")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def block_heatmap(matrix, block_size, out_path, label):
    """Average bytes within (block_size × block_size) rank blocks."""
    total = matrix.sum(axis=0).astype(np.float64)
    N = total.shape[0]
    if N % block_size != 0:
        # Skip if block doesn't divide; caller can choose a valid one.
        return False
    B = N // block_size
    blk = total.reshape(B, block_size, B, block_size).sum(axis=(1, 3))
    fig, ax = plt.subplots(figsize=(8, 7))
    data = _safe_log(blk)
    vmax = np.nanmax(data) if np.isfinite(np.nanmax(data)) else 1.0
    vmin = max(1.0, vmax / 1e6)
    im = ax.imshow(data, cmap="magma",
                   norm=LogNorm(vmin=vmin, vmax=vmax),
                   aspect="equal", interpolation="nearest")
    ax.set_xlabel(f"Destination block ({block_size} ranks/block)")
    ax.set_ylabel(f"Source block ({block_size} ranks/block)")
    ax.set_title(f"Block-aggregated bytes — {B}×{B} blocks [{label}]")
    cb = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
    cb.set_label("Bytes in block (log)")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return True


def src_time_heatmap(matrix, bin_ns, out_path):
    per_src = matrix.sum(axis=2)  # [T, N_src]
    N = per_src.shape[1]
    T = per_src.shape[0]
    fig, ax = plt.subplots(figsize=(12, 6))
    data = _safe_log(per_src.T)  # [N, T]
    vmax = np.nanmax(data) if np.isfinite(np.nanmax(data)) else 1.0
    vmin = max(1.0, vmax / 1e5)
    im = ax.imshow(
        data,
        cmap="inferno",
        norm=LogNorm(vmin=vmin, vmax=vmax),
        aspect="auto",
        interpolation="nearest",
        extent=[0, T * (bin_ns / 1e6), N, 0],
    )
    ax.set_xlabel("Time (ms)")
    ax.set_ylabel("Source rank")
    ax.set_title(f"Outbound bytes per rank over time ({N} ranks × {T} bins)")
    cb = fig.colorbar(im, ax=ax, fraction=0.022, pad=0.02)
    cb.set_label("Bytes (log)")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def top_pairs_timelines(matrix, bin_ns, out_path, top_k=8):
    total_pair = matrix.sum(axis=0)
    flat = total_pair.flatten()
    order = np.argsort(flat)[::-1]
    N = total_pair.shape[0]
    picked = []
    for idx in order:
        if flat[idx] == 0:
            break
        s = int(idx // N)
        d = int(idx % N)
        if s == d:
            continue
        picked.append((s, d, int(flat[idx])))
        if len(picked) >= top_k:
            break
    if not picked:
        return
    T = matrix.shape[0]
    t_ms = np.arange(T) * (bin_ns / 1e6)
    fig, ax = plt.subplots(figsize=(12, 5))
    for s, d, b in picked:
        series = matrix[:, s, d].astype(np.float64)
        ax.plot(t_ms, series / 1e6, linewidth=0.9,
                label=f"{s}→{d}  ({b/1e9:.1f} GB)")
    ax.set_xlabel("Time (ms)")
    ax.set_ylabel("Bytes per bin (MB)")
    ax.set_title(f"Top {len(picked)} (src,dst) pairs by total bytes")
    ax.legend(loc="upper right", fontsize=8, ncol=2)
    ax.grid(True, linestyle="--", alpha=0.4)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", required=True, help=".npz from extract_traffic_matrix.py")
    p.add_argument("--outdir", default=None, help="Output directory (default: alongside input)")
    p.add_argument("--block", type=int, default=32,
                   help="Rank block size for aggregated heatmap (default 32 = DP group).")
    p.add_argument("--top-k", type=int, default=8)
    args = p.parse_args()

    in_path = Path(args.input)
    data = np.load(in_path, allow_pickle=False)
    matrix = data["matrix"]
    bin_ns = int(data["bin_ns"])
    num_nodes = int(data["num_nodes"])
    print(f"[viz] matrix shape={matrix.shape} bin_ns={bin_ns} N={num_nodes}")

    outdir = Path(args.outdir) if args.outdir else in_path.parent
    outdir.mkdir(parents=True, exist_ok=True)
    stem = in_path.stem

    peak_tbps = timeline_plot(matrix, bin_ns, outdir / f"{stem}_timeline.png")
    print(f"[viz] timeline: peak aggregate {peak_tbps:.2f} TB/s")
    full_heatmap(matrix, outdir / f"{stem}_heatmap.png")
    ok = block_heatmap(matrix, args.block,
                       outdir / f"{stem}_heatmap_dpblock.png",
                       f"block={args.block}")
    if not ok:
        print(f"[viz] block size {args.block} does not divide N={num_nodes}; skipped")
    src_time_heatmap(matrix, bin_ns, outdir / f"{stem}_src_time.png")
    top_pairs_timelines(matrix, bin_ns, outdir / f"{stem}_top_pairs.png",
                        top_k=args.top_k)
    print(f"[viz] wrote {len(list(outdir.glob(stem + '_*.png')))} PNGs under {outdir}")


if __name__ == "__main__":
    main()
