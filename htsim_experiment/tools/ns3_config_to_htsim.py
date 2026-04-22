#!/usr/bin/env python3
"""U9 — map ns-3 config fields to htsim frontend env vars.

Reads an `ns3_config.txt` file and prints a shell snippet of `export VAR=...`
lines that a `run_htsim.sh` can `eval` to propagate the ns-3 settings.

Mapping (per plan §3.2 + actual htsim env vars):
    CC_MODE                 → HTSIM_PROTO (1=dcqcn, 3=hpcc, 7=timely→tcp,
                                          4=hpccpint→hpcc, else tcp)
    ENABLE_QCN=1            → ASTRASIM_HTSIM_QUEUE_TYPE=lossless
    PACKET_PAYLOAD_SIZE     → ASTRASIM_HTSIM_PACKET_BYTES
    BUFFER_SIZE (MB)        → ASTRASIM_HTSIM_QUEUE_BYTES
                              (BUFFER_SIZE is switch total in MB; we divide
                               by 16 ports as a rough per-port estimate and
                               cap at 16 MiB)
    KMAX_MAP / KMIN_MAP     → ASTRASIM_HTSIM_KMAX_MAP / KMIN_MAP (consumed
                              when DCQCN/ECN is enabled; currently passthrough
                              for U3 follow-up)
    LINK_DOWN t s d         → appended to ASTRASIM_HTSIM_OCS_SCHEDULE
                              (units: t ns → t/1000 us; down direction only)
    ENABLE_TRACE=1          → ASTRASIM_HTSIM_LOGGERS=1
    ACK_HIGH_PRIO=1         → ASTRASIM_HTSIM_ACK_HIGH_PRIO=1 (passthrough)

Usage: python3 ns3_config_to_htsim.py <path/to/ns3_config.txt>
Output goes to stdout as `export K=V` lines; intended for `eval "$(...)"`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


CC_MODE_TO_PROTO = {
    "1": "dcqcn",
    "3": "hpcc",
    "4": "hpcc",   # hpcc-pint -> hpcc (PINT variant not implemented)
    "7": "tcp",    # TIMELY: no htsim native equivalent; fall back to TCP
    "8": "tcp",    # DCTCP
}


def parse_ns3_config(path: Path) -> dict[str, str]:
    cfg: dict[str, str] = {}
    link_downs: list[str] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        key, rest = parts[0], " ".join(parts[1:])
        # LINK_DOWN can appear multiple times.
        if key == "LINK_DOWN":
            # Format: LINK_DOWN <time_ns> <src> <dst>
            if rest.strip().split() == ["0", "0", "0"]:
                continue  # no link-down scheduled
            link_downs.append(rest)
        else:
            cfg[key] = rest
    if link_downs:
        cfg["_LINK_DOWNS"] = "|".join(link_downs)
    return cfg


def emit(name: str, value: str) -> str:
    # Shell-safe single-quote escape.
    return f'export {name}={shell_quote(value)}'


def shell_quote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def parse_size_to_bytes(tok: str) -> int:
    m = re.match(r"^\s*([0-9.]+)\s*([KkMmGg]?[Bb]?)?\s*$", tok)
    if not m:
        return 0
    val = float(m.group(1))
    unit = (m.group(2) or "").upper()
    if unit in ("K", "KB"):
        return int(val * 1024)
    if unit in ("M", "MB"):
        return int(val * 1024 * 1024)
    if unit in ("G", "GB"):
        return int(val * 1024 * 1024 * 1024)
    return int(val)


def convert(cfg: dict[str, str]) -> list[str]:
    out: list[str] = []

    cc_mode = cfg.get("CC_MODE", "").strip()
    if cc_mode in CC_MODE_TO_PROTO:
        out.append(emit("HTSIM_PROTO", CC_MODE_TO_PROTO[cc_mode]))

    if cfg.get("ENABLE_QCN", "0").strip() == "1":
        out.append(emit("ASTRASIM_HTSIM_QUEUE_TYPE", "lossless"))

    payload = cfg.get("PACKET_PAYLOAD_SIZE")
    if payload:
        try:
            b = int(payload.strip())
            # htsim range: 256..65536
            b = max(256, min(65536, b))
            out.append(emit("ASTRASIM_HTSIM_PACKET_BYTES", str(b)))
        except ValueError:
            pass

    # BUFFER_SIZE is the per-switch buffer in MiB in ns-3/HPCC configs.
    # Rough conversion to per-port: divide by 16 ports, cap at 16 MiB.
    buf = cfg.get("BUFFER_SIZE")
    if buf:
        try:
            total_mib = int(buf.strip())
            per_port_bytes = min(16 * 1024 * 1024,
                                 max(64 * 1024,
                                     (total_mib * 1024 * 1024) // 16))
            out.append(emit("ASTRASIM_HTSIM_QUEUE_BYTES", str(per_port_bytes)))
        except ValueError:
            pass

    # KMAX_MAP / KMIN_MAP are passthrough — consumed by U3 real DCQCN.
    # Format: "<count> <bw0> <thr0> <bw1> <thr1> ..."
    for kn in ("KMAX_MAP", "KMIN_MAP", "PMAX_MAP"):
        if kn in cfg:
            out.append(emit(f"ASTRASIM_HTSIM_{kn}", cfg[kn].strip()))

    # ENABLE_TRACE → LOGGERS (creates logout.dat).  Default off since it's
    # slow; user explicitly enabling it is a deliberate choice.
    if cfg.get("ENABLE_TRACE", "0").strip() == "1":
        out.append(emit("ASTRASIM_HTSIM_LOGGERS", "1"))

    # ACK_HIGH_PRIO passthrough — relevant for future PFC multi-class U5.
    if cfg.get("ACK_HIGH_PRIO", "0").strip() == "1":
        out.append(emit("ASTRASIM_HTSIM_ACK_HIGH_PRIO", "1"))

    # LINK_DOWN → OCS_SCHEDULE entries.  ns-3 LINK_DOWN is one-shot down
    # (permanent); encode as "<us>:<src>:<dst>:0:0" (bw=0, up=false).
    ldowns = cfg.get("_LINK_DOWNS")
    if ldowns:
        entries: list[str] = []
        for spec in ldowns.split("|"):
            toks = spec.strip().split()
            if len(toks) != 3:
                continue
            try:
                t_ns = int(toks[0])
                src = int(toks[1])
                dst = int(toks[2])
            except ValueError:
                continue
            # ns-3 LINK_DOWN times are in ns; OCS_SCHEDULE is in us.
            t_us = max(0, t_ns // 1000)
            entries.append(f"{t_us}:{src}:{dst}:0:0")
        if entries:
            out.append(emit("ASTRASIM_HTSIM_OCS_SCHEDULE", ",".join(entries)))

    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <ns3_config.txt>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.exists():
        print(f"error: {path} does not exist", file=sys.stderr)
        return 1
    cfg = parse_ns3_config(path)
    lines = convert(cfg)
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
