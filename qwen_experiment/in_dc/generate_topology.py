#!/usr/bin/env python3
"""Generate Astra-Sim analytical custom topology files.

The generated topology follows this hierarchy:

1. Each NVLink node contains `gpus_per_nvlink_node` GPUs and one NVSwitch.
2. Each GPU connects to its own NIC switch.
3. A leaf switch aggregates a configurable number of NVLink nodes.
4. Every leaf switch connects to every spine switch.

This matches the structure used by qwen_experiment/in_dc/topology.txt.
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class LinkSpec:
    bandwidth: str
    latency: str
    error_rate: float = 0.0


def format_error_rate(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return str(value)


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError(f"value must be > 0, got {value}")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate an Astra-Sim custom topology.txt file.",
    )
    parser.add_argument(
        "--gpus-per-nvlink-node",
        type=positive_int,
        required=True,
        help="Number of GPUs connected to one NVSwitch.",
    )
    parser.add_argument(
        "--nvlink-node-count",
        type=positive_int,
        required=True,
        help="Number of NVLink nodes.",
    )
    parser.add_argument(
        "--nvlink-nodes-per-leaf",
        type=positive_int,
        default=4,
        help="How many NVLink nodes are aggregated by one leaf switch.",
    )
    parser.add_argument(
        "--spine-count",
        type=positive_int,
        default=1,
        help="Number of spine switches. Each leaf connects to every spine.",
    )
    parser.add_argument(
        "--gpu-nvswitch-bandwidth",
        required=True,
        help='GPU <-> NVSwitch bandwidth, e.g. "4800Gbps".',
    )
    parser.add_argument(
        "--gpu-nvswitch-latency",
        required=True,
        help='GPU <-> NVSwitch latency, e.g. "0.00015ms".',
    )
    parser.add_argument(
        "--gpu-nicswitch-bandwidth",
        required=True,
        help='GPU <-> NIC Switch bandwidth, e.g. "200Gbps".',
    )
    parser.add_argument(
        "--gpu-nicswitch-latency",
        required=True,
        help='GPU <-> NIC Switch latency, e.g. "0.000001ms".',
    )
    parser.add_argument(
        "--nicswitch-leaf-bandwidth",
        required=True,
        help='NIC Switch <-> Leaf bandwidth, e.g. "200Gbps".',
    )
    parser.add_argument(
        "--nicswitch-leaf-latency",
        required=True,
        help='NIC Switch <-> Leaf latency, e.g. "0.0005ms".',
    )
    parser.add_argument(
        "--leaf-spine-bandwidth",
        required=True,
        help='Leaf <-> Spine bandwidth, e.g. "3200Gbps".',
    )
    parser.add_argument(
        "--leaf-spine-latency",
        required=True,
        help='Leaf <-> Spine latency, e.g. "0.0006ms".',
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("topology.txt"),
        help="Output topology file path.",
    )
    return parser


def generate_topology(
    *,
    gpus_per_nvlink_node: int,
    nvlink_node_count: int,
    nvlink_nodes_per_leaf: int,
    spine_count: int,
    gpu_nvswitch: LinkSpec,
    gpu_nicswitch: LinkSpec,
    nicswitch_leaf: LinkSpec,
    leaf_spine: LinkSpec,
) -> str:
    total_gpus = gpus_per_nvlink_node * nvlink_node_count
    leaf_count = math.ceil(nvlink_node_count / nvlink_nodes_per_leaf)

    nvlink_node_groups: list[list[int]] = []
    for leaf_idx in range(leaf_count):
        start = leaf_idx * nvlink_nodes_per_leaf
        end = min(start + nvlink_nodes_per_leaf, nvlink_node_count)
        nvlink_node_groups.append(list(range(start, end)))

    next_switch_id = total_gpus
    nv_switch_ids: list[int] = [-1] * nvlink_node_count
    nic_switch_ids: list[int] = [-1] * total_gpus
    leaf_ids: list[int] = [-1] * leaf_count

    for leaf_idx, node_group in enumerate(nvlink_node_groups):
        for node_idx in node_group:
            nv_switch_ids[node_idx] = next_switch_id
            next_switch_id += 1

        for node_idx in node_group:
            gpu_start = node_idx * gpus_per_nvlink_node
            gpu_end = gpu_start + gpus_per_nvlink_node
            for gpu_id in range(gpu_start, gpu_end):
                nic_switch_ids[gpu_id] = next_switch_id
                next_switch_id += 1

        leaf_ids[leaf_idx] = next_switch_id
        next_switch_id += 1

    spine_ids = list(range(next_switch_id, next_switch_id + spine_count))
    total_nodes = next_switch_id + spine_count
    switch_ids = list(range(total_gpus, total_nodes))

    links: list[str] = []

    for node_idx in range(nvlink_node_count):
        nv_switch_id = nv_switch_ids[node_idx]
        gpu_start = node_idx * gpus_per_nvlink_node
        gpu_end = gpu_start + gpus_per_nvlink_node
        for gpu_id in range(gpu_start, gpu_end):
            links.append(
                f"{gpu_id} {nv_switch_id} "
                f"{gpu_nvswitch.bandwidth} {gpu_nvswitch.latency} "
                f"{format_error_rate(gpu_nvswitch.error_rate)}"
            )

    for gpu_id, nic_switch_id in enumerate(nic_switch_ids):
        links.append(
            f"{gpu_id} {nic_switch_id} "
            f"{gpu_nicswitch.bandwidth} {gpu_nicswitch.latency} "
            f"{format_error_rate(gpu_nicswitch.error_rate)}"
        )

    for leaf_idx, node_group in enumerate(nvlink_node_groups):
        leaf_id = leaf_ids[leaf_idx]
        for node_idx in node_group:
            gpu_start = node_idx * gpus_per_nvlink_node
            gpu_end = gpu_start + gpus_per_nvlink_node
            for gpu_id in range(gpu_start, gpu_end):
                nic_switch_id = nic_switch_ids[gpu_id]
                links.append(
                    f"{nic_switch_id} {leaf_id} "
                    f"{nicswitch_leaf.bandwidth} {nicswitch_leaf.latency} "
                    f"{format_error_rate(nicswitch_leaf.error_rate)}"
                )

    for leaf_id in leaf_ids:
        for spine_id in spine_ids:
            links.append(
                f"{leaf_id} {spine_id} "
                f"{leaf_spine.bandwidth} {leaf_spine.latency} "
                f"{format_error_rate(leaf_spine.error_rate)}"
            )

    header = f"{total_nodes} {len(switch_ids)} {len(links)}"
    return "\n".join([header, " ".join(map(str, switch_ids)), *links, ""])


def main() -> None:
    args = build_parser().parse_args()
    topology = generate_topology(
        gpus_per_nvlink_node=args.gpus_per_nvlink_node,
        nvlink_node_count=args.nvlink_node_count,
        nvlink_nodes_per_leaf=args.nvlink_nodes_per_leaf,
        spine_count=args.spine_count,
        gpu_nvswitch=LinkSpec(args.gpu_nvswitch_bandwidth, args.gpu_nvswitch_latency),
        gpu_nicswitch=LinkSpec(
            args.gpu_nicswitch_bandwidth,
            args.gpu_nicswitch_latency,
        ),
        nicswitch_leaf=LinkSpec(
            args.nicswitch_leaf_bandwidth,
            args.nicswitch_leaf_latency,
        ),
        leaf_spine=LinkSpec(args.leaf_spine_bandwidth, args.leaf_spine_latency),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(topology, encoding="utf-8")


if __name__ == "__main__":
    main()
