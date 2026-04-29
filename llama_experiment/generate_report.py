#!/usr/bin/env python3
"""Aggregate per-experiment simulator logs into report.md / report.csv.

Walks the configured experiment directories. For each backend log present
(`analytical.log` / `htsim.log` / `ns3.log`), picks the GPU with the largest
`Wall time` (the workload bottleneck) and emits a comparison report.

Usage:
    python generate_report.py
    python generate_report.py --experiments in_dc inter_dc --backends htsim
    python generate_report.py --output-dir traffic_analysis
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

DEFAULT_EXPERIMENTS = [
    "in_dc",
    "in_dc_dp",
    "inter_dc",
    "inter_dc_dp",
    "inter_dc_dp_localsgd",
]
DEFAULT_BACKENDS = ["analytical", "htsim", "ns3"]

FINISH_RE = re.compile(
    r"sys\[(\d+)\] finished,\s*(\d+) cycles, exposed communication\s*(\d+) cycles"
)
STAT_RE = re.compile(r"sys\[(\d+)\],\s*(.*)")

STAT_PATTERNS = [
    ("wall_time",         re.compile(r"Wall time:\s*(\d+)")),
    ("gpu_time",          re.compile(r"GPU time:\s*(\d+)")),
    ("comm_time",         re.compile(r"Comm time:\s*(\d+)")),
    ("total_overlap",     re.compile(r"Total compute-communication overlap:\s*(\d+)")),
    ("bubble_pct",        re.compile(r"Bubble time:\s*\d+\s*\(([\d.]+)%\)")),
    ("comm_bytes",        re.compile(r"Comm bytes:\s*(\d+)")),
    ("eff_bw_gbs",        re.compile(r"Effective BW:\s*([\d.]+) GB/s")),
    ("compute_bound_pct", re.compile(r"Compute bound percentage:\s*([\d.]+)%")),
    ("compute_util_pct",  re.compile(r"Average compute utilization:\s*([\d.]+)%")),
    ("memory_util_pct",   re.compile(r"Average memory utilization:\s*([\d.]+)%")),
    ("op_intensity",      re.compile(r"Average operation intensity:\s*([\d.]+)")),
]


@dataclass
class RunStats:
    experiment: str
    backend: str
    log: str
    last_gpu: int = -1
    finish_cycles: int | None = None
    exposed_comm: int | None = None
    wall_time: int | None = None
    gpu_time: int | None = None
    comm_time: int | None = None
    total_overlap: int | None = None
    bubble_pct: float | None = None
    comm_bytes: int | None = None
    eff_bw_gbs: float | None = None
    compute_bound_pct: float | None = None
    compute_util_pct: float | None = None
    memory_util_pct: float | None = None
    op_intensity: float | None = None
    wall_time_rel: float | None = None
    note: str = ""


def parse_log(path: Path, experiment: str, backend: str, log_label: str) -> RunStats | None:
    if not path.exists():
        return None
    by_gpu: dict[int, dict] = {}
    text = path.read_text(errors="replace")
    for line in text.splitlines():
        m = FINISH_RE.search(line)
        if m:
            gpu = int(m.group(1))
            d = by_gpu.setdefault(gpu, {})
            d["finish_cycles"] = int(m.group(2))
            d["exposed_comm"] = int(m.group(3))
            continue
        m = STAT_RE.search(line)
        if not m:
            continue
        gpu = int(m.group(1))
        rest = m.group(2)
        d = by_gpu.setdefault(gpu, {})
        for name, regex in STAT_PATTERNS:
            mm = regex.search(rest)
            if mm:
                d[name] = mm.group(1)

    candidates = [(g, d) for g, d in by_gpu.items() if "wall_time" in d]
    if not candidates:
        return RunStats(experiment=experiment, backend=backend, log=log_label,
                        note="no completed sys[*] stats found")
    candidates.sort(key=lambda kv: int(kv[1]["wall_time"]))
    best_gpu, best = candidates[-1]

    def to_int(v):
        return int(v) if v is not None else None

    def to_float(v):
        return float(v) if v is not None else None

    return RunStats(
        experiment=experiment,
        backend=backend,
        log=log_label,
        last_gpu=best_gpu,
        finish_cycles=to_int(best.get("finish_cycles")),
        exposed_comm=to_int(best.get("exposed_comm")),
        wall_time=to_int(best.get("wall_time")),
        gpu_time=to_int(best.get("gpu_time")),
        comm_time=to_int(best.get("comm_time")),
        total_overlap=to_int(best.get("total_overlap")),
        bubble_pct=to_float(best.get("bubble_pct")),
        comm_bytes=to_int(best.get("comm_bytes")),
        eff_bw_gbs=to_float(best.get("eff_bw_gbs")),
        compute_bound_pct=to_float(best.get("compute_bound_pct")),
        compute_util_pct=to_float(best.get("compute_util_pct")),
        memory_util_pct=to_float(best.get("memory_util_pct")),
        op_intensity=to_float(best.get("op_intensity")),
    )


def fill_relative_wall(stats: list[RunStats]) -> None:
    """Per-backend, normalize wall_time against the first experiment in that backend."""
    by_backend: dict[str, list[RunStats]] = {}
    for s in stats:
        if s.wall_time is not None:
            by_backend.setdefault(s.backend, []).append(s)
    for rows in by_backend.values():
        baseline = rows[0].wall_time
        for r in rows:
            r.wall_time_rel = r.wall_time / baseline if baseline else None


def fmt_int(v):
    return "" if v is None else f"{v}"


def fmt_float(v, digits=3):
    return "" if v is None else f"{v:.{digits}f}"


def fmt_pct(v):
    return "" if v is None else f"{v:.3f}%"


def render_markdown(stats: list[RunStats], experiments: list[str], backends: list[str]) -> str:
    lines: list[str] = []
    lines.append("# Simulation Report")
    lines.append("")
    lines.append("Generated by `generate_report.py`. For each `<experiment>/<backend>.log`,")
    lines.append("the GPU with the largest `Wall time` (the workload bottleneck) is reported.")
    lines.append("`Wall time (rel.)` is relative to the first experiment in the same backend.")
    lines.append("")

    by_key = {(s.experiment, s.backend): s for s in stats}

    lines.append("## Wall-time pivot (cycles)")
    lines.append("")
    header = ["Experiment"] + [b for b in backends]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("| " + " | ".join(["---"] + ["---:"] * len(backends)) + " |")
    for exp in experiments:
        row = [exp]
        for b in backends:
            s = by_key.get((exp, b))
            row.append(fmt_int(s.wall_time) if s else "")
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")

    for backend in backends:
        rows = [s for s in stats if s.backend == backend]
        if not rows:
            continue
        lines.append(f"## Backend: {backend}")
        lines.append("")
        cols = [
            "Experiment", "Last GPU", "Wall time", "Wall time (rel.)",
            "Exposed comm", "GPU time", "Comm time", "Total overlap",
            "Bubble", "Comm bytes", "Eff BW (GB/s)",
            "Compute bound", "Compute util", "Memory util", "Op intensity",
            "Log",
        ]
        align = ["---"] + ["---:"] * (len(cols) - 2) + ["---"]
        lines.append("| " + " | ".join(cols) + " |")
        lines.append("| " + " | ".join(align) + " |")
        for s in rows:
            if s.note:
                lines.append(
                    "| " + " | ".join([
                        s.experiment, "", "", "", "", "", "", "", "", "", "",
                        "", "", "", "", f"`{s.log}` ({s.note})",
                    ]) + " |"
                )
                continue
            lines.append("| " + " | ".join([
                s.experiment,
                f"sys[{s.last_gpu}]",
                fmt_int(s.wall_time),
                fmt_float(s.wall_time_rel, 4),
                fmt_int(s.exposed_comm),
                fmt_int(s.gpu_time),
                fmt_int(s.comm_time),
                fmt_int(s.total_overlap),
                fmt_pct(s.bubble_pct),
                fmt_int(s.comm_bytes),
                fmt_float(s.eff_bw_gbs),
                fmt_pct(s.compute_bound_pct),
                fmt_pct(s.compute_util_pct),
                fmt_pct(s.memory_util_pct),
                fmt_float(s.op_intensity),
                f"`{s.log}`",
            ]) + " |")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def write_csv(stats: list[RunStats], path: Path) -> None:
    fieldnames = list(asdict(stats[0]).keys()) if stats else [
        f.name for f in RunStats.__dataclass_fields__.values()
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for s in stats:
            writer.writerow(asdict(s))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent,
                    help="experiment root directory (default: script directory)")
    ap.add_argument("--experiments", nargs="+", default=DEFAULT_EXPERIMENTS,
                    help="experiment subdirs to include")
    ap.add_argument("--backends", nargs="+", default=DEFAULT_BACKENDS,
                    help="backend names; expects <experiment>/<backend>.log")
    ap.add_argument("--output-dir", type=Path, default=None,
                    help="where to write report.md / report.csv (default: --root)")
    args = ap.parse_args(argv)

    out_dir = (args.output_dir or args.root).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    stats: list[RunStats] = []
    missing: list[str] = []
    for exp in args.experiments:
        for backend in args.backends:
            log_path = args.root / exp / f"{backend}.log"
            log_label = f"{exp}/{backend}.log"
            s = parse_log(log_path, exp, backend, log_label)
            if s is None:
                missing.append(log_label)
                continue
            stats.append(s)

    fill_relative_wall(stats)

    md = render_markdown(stats, args.experiments, args.backends)
    (out_dir / "report.md").write_text(md)
    write_csv(stats, out_dir / "report.csv")

    print(f"wrote {out_dir / 'report.md'}")
    print(f"wrote {out_dir / 'report.csv'}")
    if missing:
        print(f"skipped {len(missing)} missing log(s):", file=sys.stderr)
        for m in missing:
            print(f"  - {m}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
