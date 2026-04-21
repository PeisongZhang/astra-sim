"""Post-check for roofline_per_op test. Reads run.log and asserts:

- rank 1 (SOFTMAX, peak=100 TFLOP/s) wall ≈ 4x rank 0 (GEMM, peak=400 TFLOP/s)
- op_category 2 nodes got a distinct effective peak from op_category 0 nodes
  (i.e. the per-op-type Roofline path was actually taken)
"""
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def parse_walls(log_path):
    # line like: "[workload] sys[0] finished, 12345 cycles, exposed communication 0 cycles."
    pat = re.compile(
        r"sys\[(\d+)\] finished, (\d+) cycles, exposed communication (\d+) cycles"
    )
    walls = {}
    with open(log_path) as f:
        for line in f:
            m = pat.search(line)
            if m:
                walls[int(m.group(1))] = int(m.group(2))
    return walls


def main():
    log = os.path.join(_HERE, "run.log")
    if not os.path.exists(log):
        print(f"ERROR: {log} missing; run.sh did not produce a log", file=sys.stderr)
        sys.exit(2)
    walls = parse_walls(log)
    assert 0 in walls and 1 in walls, f"missing rank finish line; got {walls}"
    w0, w1 = walls[0], walls[1]
    ratio = w1 / max(w0, 1)
    # GEMM peak = 400, SOFTMAX peak = 100 → ratio ≈ 4.0. Allow ±10% for
    # simulator rounding and bw-limited branch.
    lo, hi = 3.6, 4.4
    print(f"[roofline_per_op] rank0(GEMM) wall={w0} cycles")
    print(f"[roofline_per_op] rank1(SOFTMAX) wall={w1} cycles")
    print(f"[roofline_per_op] ratio w1/w0={ratio:.3f} (expected in [{lo}, {hi}])")
    if not (lo <= ratio <= hi):
        print(
            "FAIL: per-op-type Roofline scaling not observed. "
            "Either op_category attr is not being read, or "
            "peak-perf-per-op-category JSON was not applied.",
            file=sys.stderr,
        )
        sys.exit(1)
    print("[roofline_per_op] OK")


if __name__ == "__main__":
    main()
