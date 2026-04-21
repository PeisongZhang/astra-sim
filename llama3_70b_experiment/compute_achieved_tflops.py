#!/usr/bin/env python3
"""Compute per-GPU achieved TFLOPs/s and % of peak for the 4 llama3_70b experiments.

Uses Narayanan et al. (arXiv:2104.04473) convention: HW FLOPs with activation
recompute = 4 × forward pass (fwd + bwd×2 + recompute×1). Directly counts
GQA attention + SwiGLU MLP + LM-head, not the 96·B·s·l·h² vanilla approximation.

Reads wall cycles from each experiment's run_analytical.log (max "sys[*] finished"
cycles field). ASTRA-sim reports cycles in nanoseconds, so wall_s = max_cycles / 1e9.
"""

import os
import re
import sys

EXPERIMENTS = [
    ("E1 in_dc",               "in_dc"),
    ("E2 inter_dc_pp",         "inter_dc_pp"),
    ("E3 inter_dc_dp",         "inter_dc_dp"),
    ("E4 inter_dc_dp_localsgd","inter_dc_dp_localsgd"),
]

# Workload (match dnn_workload/llama3_70b/llama3_70b.sh BATCH=512 run)
BATCH = 512
SEQ = 2048
LAYERS = 80
HIDDEN = 8192
FF = 28672        # SwiGLU intermediate
HEADS = 64
KV_HEADS = 8
VOCAB = 128256
ITER = 2
NUM_GPUS = 1024
PEAK_TFLOPS = 312  # A100 bf16 peak


def hw_flops_per_iter():
    B, s, h, dff, V = BATCH, SEQ, HIDDEN, FF, VOCAB
    # Attention (GQA): QKV proj + Q·K^T + softmax·V + output proj
    qkv = 2 * B * s * (h * h + 2 * h * (h * KV_HEADS / HEADS))
    attn_core = 2 * 2 * B * HEADS * s * s * (h / HEADS)
    out_proj = 2 * B * s * h * h
    # SwiGLU MLP: 3 matrices of (h ↔ dff)
    mlp = 3 * 2 * B * s * h * dff
    per_layer_fwd = qkv + attn_core + out_proj + mlp
    body_fwd = per_layer_fwd * LAYERS
    lm_head = 2 * B * s * h * V
    fwd_per_iter = body_fwd + lm_head
    # Activation recompute: total HW compute = 4 × forward
    return 4 * fwd_per_iter


def max_wall_cycles(log_path):
    best = 0
    rx = re.compile(r"sys\[\d+\] finished, (\d+) cycles")
    with open(log_path) as f:
        for line in f:
            m = rx.search(line)
            if m:
                best = max(best, int(m.group(1)))
    return best


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    flops_per_iter = hw_flops_per_iter()
    total_flops = ITER * flops_per_iter
    print(f"Per-iter HW FLOPs (Llama3-70B, BATCH={BATCH}, SwiGLU+GQA, w/ AR): {flops_per_iter:.3e}")
    print(f"Total HW FLOPs ({ITER} iters): {total_flops:.3e}")
    print()
    header = f"{'experiment':<30}{'wall (s)':>12}{'TFLOPs/s/GPU':>18}{'% of peak':>14}"
    print(header)
    print("-" * len(header))
    for label, sub in EXPERIMENTS:
        log = os.path.join(base, sub, "run_analytical.log")
        cyc = max_wall_cycles(log)
        wall_s = cyc / 1e9
        tflops_per_gpu = total_flops / wall_s / NUM_GPUS / 1e12
        pct = tflops_per_gpu / PEAK_TFLOPS * 100
        print(f"{label:<30}{wall_s:>12.3f}{tflops_per_gpu:>18.2f}{pct:>13.2f}%")


if __name__ == "__main__":
    main()
