# Phase 1.5 — Native cross-DC topology support (htsim)

Date: 2026-04-22.

## Extended topology.txt format

`GenericCustomTopology::load()` now accepts the following extension on top of ASTRA-sim's Custom topology.txt:

```
<num_nodes> <num_switches> <num_links>
<switch_id_0> <switch_id_1> ...

#REGIONS <num_regions>
<node_id> <region_id> <node_id> <region_id> ...

<src> <dst> <bw> <lat> <err> [link_type]
```

Rules:

- `#REGIONS` line is **optional** and fully backward-compatible. If missing, every node gets `region_id = 0` (single-DC).
- The mapping line immediately after `#REGIONS` is free-form `node_id region_id node_id region_id …` pairs (whitespace-separated). Nodes not listed default to region 0.
- Link lines take an optional 6th column `link_type`, one of `intra`, `inter_leaf`, `inter_spine`, `wan`. Default `intra` if omitted.
- The link-type tag is stored on each `GenLinkDesc` and exposed for reporting / future PFC-per-class work.

## Consumers

- **Routing**: BFS routing is region-agnostic today. Phase 3 will add region-aware policies (e.g. prefer `inter_leaf` over `wan` when a choice exists).
- **OCS mutator**: `schedule_link_change(at_ps, src, dst, bw, up)` already exposes per-link mutation. This becomes the entry-point for cross-DC optical circuit reconfiguration in the MoE-OCS project.
- **Gateway queues (stub)**: the plan (§11.5) calls for `GatewayQueue` with independent buffer / PFC tunables on inter-region links. Currently all Pipes/Queues use the same defaults; add a per-`link_type` override in Phase 3 when we expose PFC-per-class (§11.2 P3.1d).

## Legacy inter-DC experiments

All 9 inter-DC experiments in `llama_experiment/inter_dc*` and `llama3_70b_experiment/inter_dc_*` use plain topology.txt without the `#REGIONS` block. They pick up region 0 by default and still route correctly (latency/bandwidth differences stay in the per-link data, not in the routing table). This is by design — no edits to the existing topology files are required for Phase 2 migration.

## Example (two-DC skeleton)

```
# 2 DCs, 16 hosts each, each DC has a leaf/spine pair; gateway at region edges.
40 8 36
32 33 34 35 36 37 38 39
#REGIONS 2
0 0 1 0 2 0 3 0 4 0 5 0 6 0 7 0 8 0 9 0 10 0 11 0 12 0 13 0 14 0 15 0
16 1 17 1 18 1 19 1 20 1 21 1 22 1 23 1 24 1 25 1 26 1 27 1 28 1 29 1 30 1 31 1
# leaves in DC0
32 0 400Gbps 0.0005us 0 intra
32 1 400Gbps 0.0005us 0 intra
...
# spines + gateway
38 39 800Gbps 0.3ms 0 wan
```

The WAN link type lets future reporting clearly separate cross-DC bytes from intra-DC bytes.

## What's deferred to Phase 3

- Per-class PFC (`#REGIONS` + link_type × priority queues)
- `GatewayQueue` with independent buffer pools
- Region-aware multi-path routing (e.g. prefer shortest-within-region)
- Asymmetric BW/latency per direction (`@<reverse_bw>/<reverse_lat>` suffix — parser hook exists in `parse_link_line`, storage not yet wired for separate forward/reverse rates).
