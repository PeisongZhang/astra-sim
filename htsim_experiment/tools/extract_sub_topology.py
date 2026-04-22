#!/usr/bin/env python3
"""Extract a sub-topology for the first N hosts from an ASTRA-sim Custom
topology.txt file.

Input topology format:
    <num_nodes> <num_switches> <num_links>
    <switch_id_0> <switch_id_1> ...
    <src> <dst> <bw> <lat> <err> [link_type] [@<rev_bw>/<rev_lat>]
    ...

We keep hosts [0..keep_hosts) and drop higher-numbered hosts. All links
touching a kept host are retained. Transitively, we also keep switches
reachable through kept hosts. Then a BFS through the retained switch
graph keeps paths toward the root intact (preserves leaf/spine/root
hierarchy).

Resulting node IDs are re-densified so hosts stay contiguous [0..N) and
switches follow. The output is a valid Custom topology.txt.

Usage:
    extract_sub_topology.py --in <path> --out <path> --keep-hosts <N> \
        [--total-hosts <T>]

--total-hosts is inferred as num_nodes - num_switches if omitted.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def parse_topology(path: Path):
    with path.open() as f:
        lines = f.readlines()
    header = lines[0].split()
    num_nodes = int(header[0])
    num_switches = int(header[1])
    num_links = int(header[2])
    switches = [int(x) for x in lines[1].split()]
    links = []
    for line in lines[2:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        src = int(parts[0])
        dst = int(parts[1])
        rest = parts[2:]
        links.append((src, dst, rest))
    return num_nodes, num_switches, num_links, switches, links


def extract(topology_path: Path, out_path: Path, keep_hosts: int,
            total_hosts: int | None = None) -> None:
    num_nodes, num_switches, _, switches, links = parse_topology(topology_path)
    if total_hosts is None:
        total_hosts = num_nodes - num_switches
    if keep_hosts > total_hosts:
        raise ValueError(f"keep_hosts={keep_hosts} exceeds total_hosts={total_hosts}")

    switch_set = set(switches)
    # Find hosts — they're all node IDs that are not switches (IDs below
    # num_nodes that are not in switch_set). We keep IDs [0..keep_hosts).
    kept_hosts = set(range(keep_hosts))

    # BFS from kept hosts through the original link graph (treating links
    # as undirected) to find all reachable nodes — this pulls in the
    # upstream switches those hosts need.
    adj: dict[int, set[int]] = {}
    for s, d, _ in links:
        adj.setdefault(s, set()).add(d)
        adj.setdefault(d, set()).add(s)
    reachable = set(kept_hosts)
    frontier = list(kept_hosts)
    while frontier:
        n = frontier.pop()
        for m in adj.get(n, ()):
            if m in switch_set and m not in reachable:
                reachable.add(m)
                frontier.append(m)

    # Filter links: keep only links where both endpoints are in `reachable`.
    kept_links = []
    for s, d, rest in links:
        if s in reachable and d in reachable:
            # Drop links to any host outside kept_hosts.
            if s not in switch_set and s >= keep_hosts:
                continue
            if d not in switch_set and d >= keep_hosts:
                continue
            kept_links.append((s, d, rest))

    # Densify node IDs: hosts 0..keep_hosts-1 remain unchanged; switches
    # get remapped to [keep_hosts, keep_hosts + num_kept_switches).
    kept_switches_sorted = sorted(x for x in reachable if x in switch_set)
    switch_remap = {old: keep_hosts + i for i, old in enumerate(kept_switches_sorted)}
    host_remap = {i: i for i in kept_hosts}
    remap = {**host_remap, **switch_remap}

    new_num_switches = len(kept_switches_sorted)
    new_num_nodes = keep_hosts + new_num_switches
    new_switches = [switch_remap[s] for s in kept_switches_sorted]

    # Rewrite kept_links with new IDs, filter self-loops that might arise.
    new_links = []
    for s, d, rest in kept_links:
        ns = remap[s]
        nd = remap[d]
        if ns == nd:
            continue
        new_links.append((ns, nd, rest))

    with out_path.open("w") as f:
        f.write(f"{new_num_nodes} {new_num_switches} {len(new_links)}\n")
        f.write(" ".join(str(x) for x in new_switches) + "\n")
        for s, d, rest in new_links:
            f.write(" ".join([str(s), str(d), *rest]) + "\n")
    print(f"[extract_sub_topology] wrote {out_path}: hosts={keep_hosts} "
          f"switches={new_num_switches} links={len(new_links)} "
          f"(from {num_nodes} nodes / {num_switches} switches / "
          f"{len(links)} links)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_path", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--keep-hosts", required=True, type=int)
    ap.add_argument("--total-hosts", type=int)
    args = ap.parse_args()
    extract(args.in_path, args.out, args.keep_hosts, args.total_hosts)


if __name__ == "__main__":
    main()
