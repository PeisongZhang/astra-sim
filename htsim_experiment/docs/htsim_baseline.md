# Phase 0 Smoke Baseline (htsim vs analytical) — historical record

> **Status (2026-04-23):** Superseded. All Phase 0 gaps closed. Live acceptance
> numbers live in `htsim_usage_manual.md` §1.2. This file is kept for context
> on the original FatTree-substitute baseline and the bring-up bugs we fixed.

## What Phase 0 validated (2026-04-22)

1. `AstraSim_HTSim` compiles clean after:
   - removing the dead `#ifdef FAT_TREE / OV_FAT_TREE / ...` guards in `proto/HTSimProtoTcp.{cc,hh}` that were never actually enabled (so `top` was always null → segfault at first flow);
   - replacing the `construct_topology(parser)` call in `HTSimMain.cc` with a direct read of `NetworkParser::get_dims_count()` / `get_npus_counts_per_dim()` / `get_bandwidths_per_dim()` (the analytical congestion-unaware `construct_topology` rejects `Custom` topology, which we need);
   - adding `HTSimNetworkApi::set_dims_and_bandwidth(...)` so the inherited `CommonNetworkApi` static fields are populated without requiring an analytical `Topology` instance.
2. Flow finish callbacks fire: "Finish sending flow ... from X to Y" / "Finish receiving flow ... from X to Y" appear at the expected frequency on a 16-NPU ring all-gather.
3. All 16 ranks reach `sys[N] finished` and the simulator terminates cleanly (no hang, no `Simulation timed out` warning).

## Original 2-backend cycle comparison (ring all-gather, 16 NPU, 1 MiB per peer)

| Backend | Topology used | max cycle (cycles) | exposed comm (cycles) | Wall cycles / per-rank BW |
|---|---|---:|---:|---|
| analytical congestion-aware | Ring (from topology.txt) | 345,160 | 345,160 | ~3.04 GB/s |
| htsim (original) | **FatTree k=4** (substitute) | 2,825,037 | 2,825,037 | ~0.37 GB/s |
| ratio | — | **8.18×** | 8.18× | 8.2× slower |

The 8× gap was a *topology-substitution artifact*, not an integration bug:
htsim was running the workload on a FatTree (k=4 → 16 hosts), not a Ring,
because Phase 0 had no Custom-topology adapter. Phase 1 delivered
`GenericCustomTopology`, after which the htsim/analytical ratio on equivalent
fabrics dropped into the §11.6 acceptance band.

## Phase 0 → current resolution table

| Phase 0 gap | Status (2026-04-23) |
|---|---|
| htsim frontend cannot read Custom `topology.txt` (only FatTree) | ✅ `GenericCustomTopology` ships; covers Custom topo + `#REGIONS` + asymmetric BW + OCS mutator |
| htsim frontend has no `#REGIONS` / cross-DC awareness | ✅ Phase 1.5 done — see `cross_dc_topology.md` |
| Only TCP protocol exposed | ✅ TCP / RoCE / DCQCN / HPCC all wired (see `htsim_user_guide.md` "Protocol matrix") |
| No OCS mutator API | ✅ `GenericCustomTopology::schedule_link_change` + `ASTRASIM_HTSIM_OCS_SCHEDULE` env |
| Per-flow stdout debug log spam | ✅ Gated behind `ASTRASIM_HTSIM_VERBOSE` |
| Default `memFromPkt(8)` buffer untuned | ✅ Per-port queue exposed as `ASTRASIM_HTSIM_QUEUE_BYTES`; gateway override `ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES` |
| 16-NPU max-cycle ±0.3% rank variation | ✅ Determinised by fixed `ASTRASIM_HTSIM_RANDOM_SEED` (default `0xA571A517`) |

## §11.6 acceptance — actual

The ratio band `[0.9, 1.5]` (htsim_cycles / analytical_cycles) is met by the
9 × 16-NPU experiments and by `gpt_39b_512` under the sharded runner; see
`htsim_usage_manual.md` §1.2 for the full table. The original
`megatron_gpt_76b_1024` target (analytical baseline 14,319,044,603 cycles)
remains blocked on hardware (U12 — needs ≥ 64 GiB RAM) and on the
single-thread DES throughput wall (U2). Both are external constraints, not
Phase 0 issues.
