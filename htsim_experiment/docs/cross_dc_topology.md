# Native cross-DC topology support (htsim)

Originally landed: Phase 1.5 (2026-04-22). Status (2026-04-23): shipped
and stable; see "What's deferred" at the bottom for the residual TODO list.

## Extended topology.txt format

`GenericCustomTopology::load()` now accepts the following extension on top of ASTRA-sim's Custom topology.txt:

```
<num_nodes> <num_switches> <num_links>
<switch_id_0> <switch_id_1> ...

#REGIONS <num_regions>
<node_id> <region_id> <node_id> <region_id> ...

<src> <dst> <bw> <lat> <err> [link_type] [@<rev_bw>/<rev_lat>]
```

Rules:

- `#REGIONS` line is **optional** and fully backward-compatible. If missing, every node gets `region_id = 0` (single-DC).
- The mapping line immediately after `#REGIONS` is free-form `node_id region_id node_id region_id …` pairs (whitespace-separated). Nodes not listed default to region 0.
- Link lines take an optional 6th column `link_type`, one of `intra`, `inter_leaf`, `inter_spine`, `wan`. Default `intra` if omitted.
- An optional `@<rev_bw>/<rev_lat>` token (after `link_type`) overrides the reverse-direction bandwidth / latency — see "Asymmetric WAN links" below.
- The link-type tag is stored on each `GenLinkDesc` and used for gateway-queue selection (see "Consumers" below).

## Consumers

- **Routing**: Dijkstra (default; edge weight `1 / bw_Gbps`) is region-agnostic. `ASTRASIM_HTSIM_ROUTE=bfs` falls back to hop-count. Region-aware policies (e.g. prefer `inter_leaf` over `wan` when a choice exists) are still TODO — see "What's deferred".
- **OCS mutator**: `schedule_link_change(at_ps, src, dst, bw, up)` exposes per-link mutation; driven from the shell via `ASTRASIM_HTSIM_OCS_SCHEDULE`. Pair with `ASTRASIM_HTSIM_OCS_REROUTE=1` to clear the path cache on reroute. This is the entry-point for cross-DC optical circuit reconfiguration in the MoE-OCS project.
- **Gateway queues**: ✅ shipped. Inter-region links (i.e. links whose endpoints are in different regions per `#REGIONS`, *or* whose `link_type` is `wan` / `inter_spine`) get a deeper per-port queue, sized by `ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES` (default 4 MB = 4× `QUEUE_BYTES`). PFC thresholds are still shared with intra-region queues; per-class PFC tunables are deferred (U5).

## Legacy inter-DC experiments

All `llama_experiment/inter_dc*_htsim/` and `llama3_70b_experiment/inter_dc_*_htsim/` directories use plain `topology.txt` without the `#REGIONS` block. They pick up region 0 by default and still route correctly (latency/bandwidth differences stay in the per-link data, not in the routing table). This is by design — no edits to the existing topology files were required for the Phase 2 migration, and acceptance ratios (0.985 – 1.008 vs analytical/ns-3, see `htsim_usage_manual.md` §1.2) remain inside §11.6.

## Asymmetric WAN links

A 6th column (or 7th, after `link_type`) of the form `@<rev_bw>/<rev_lat>`
sets a different bandwidth / latency on the reverse (dst → src) direction
of the same link. Forward stays as written.

```
38 39 800Gbps 0.3ms 0 wan @200Gbps/0.3ms
```

The reverse `Pipe` and `Queue` are constructed independently (see
`GenericCustomTopology::add_link`). Useful for modelling
asymmetric WAN tiers where uplink and downlink rates differ.

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
# spines + gateway (asymmetric: 800G fwd / 200G rev)
38 39 800Gbps 0.3ms 0 wan @200Gbps/0.3ms
```

The WAN link type makes inter-DC bytes separable in any future
per-class report; today it controls gateway queue sizing only.

## What's deferred

- Per-class PFC (multiple priority queues + per-class PAUSE thresholds). Single-priority PFC ships today via `QUEUE_TYPE=lossless`. Tracked as U5.
- Region-aware multi-path routing (e.g. prefer shortest-within-region, or split traffic across multiple gateway links proportionally).
- Per-`link_type` PFC threshold overrides (today all `lossless` ports share `ASTRASIM_HTSIM_PFC_HIGH_KB`/`LOW_KB`; gateway links only get a deeper queue, not different thresholds).
