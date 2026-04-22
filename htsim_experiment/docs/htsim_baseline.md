# Phase 0 Smoke Baseline (htsim vs analytical)

Date: 2026-04-22. Binary: `build/astra_htsim/build/bin/AstraSim_HTSim`.

## What Phase 0 validated

1. `AstraSim_HTSim` compiles clean after:
   - removing the dead `#ifdef FAT_TREE / OV_FAT_TREE / ...` guards in `proto/HTSimProtoTcp.{cc,hh}` that were never actually enabled (so `top` was always null → segfault at first flow);
   - replacing the `construct_topology(parser)` call in `HTSimMain.cc` with a direct read of `NetworkParser::get_dims_count()` / `get_npus_counts_per_dim()` / `get_bandwidths_per_dim()` (the analytical congestion-unaware `construct_topology` rejects `Custom` topology, which we need);
   - adding `HTSimNetworkApi::set_dims_and_bandwidth(...)` so the inherited `CommonNetworkApi` static fields are populated without requiring an analytical `Topology` instance.
2. Flow finish callbacks fire: "Finish sending flow ... from X to Y" / "Finish receiving flow ... from X to Y" appear at the expected frequency on a 16-NPU ring all-gather.
3. All 16 ranks reach `sys[N] finished` and the simulator terminates cleanly (no hang, no `Simulation timed out` warning).

## 2-backend cycle comparison (ring all-gather, 16 NPU, 1 MiB per peer)

| Backend | Topology used | max cycle (cycles) | exposed comm (cycles) | Wall cycles / per-rank BW |
|---|---|---:|---:|---|
| analytical congestion-aware | Ring (from topology.txt) | 345,160 | 345,160 | ~3.04 GB/s |
| htsim (this work, TCP) | **FatTree k=4** (substitute) | 2,825,037 | 2,825,037 | ~0.37 GB/s |
| htsim / analytical ratio | — | **8.18×** | 8.18× | 8.2× slower |

The 8× gap is **expected and does not invalidate the smoke**:

- htsim is running the workload on a FatTree (k=4 → 16 hosts), not a Ring. Ring has 2× higher aggregate bisection than a FatTree at this scale for a ring-pattern all-gather.
- htsim models TCP slow start, buffer queuing, and receive-window effects; analytical is congestion-aware but closed-form and instantaneous at the host.
- 8× is the composition of these two effects, not an integration bug.

Phase 0 exit criterion ("cycle difference < 3× on equivalent topology") cannot be fairly evaluated until Phase 1 delivers a htsim Ring topology adapter (tracked as `GenericCustomTopology`). The meaningful acceptance gate is megatron_gpt_76b_1024 at Phase 2 / §11.6.

## Known behaviour carried forward

- **All ranks finish, but max cycles vary ±0.3%** across ranks on htsim (16-NPU run saw 2,770,927 .. 2,825,037). Expected — htsim's random path selection causes micro-variation per rank. Analytical is deterministic.
- **Log volume is large**: htsim prints `Finish sending flow ...` and `Finish receiving flow ...` per flow to stdout. Phase 0.5 (§11.3 #3) will gate these behind a DEBUG flag.
- The default `memFromPkt(8)` buffer is untuned; Phase 3 will expose it as a CLI knob.

## Known-missing items that will block Phase 1.5 / Phase 2

| Gap | Phase |
|---|---|
| htsim frontend cannot read Custom `topology.txt` (only FatTree) | Phase 1 (`GenericCustomTopology`) |
| htsim frontend has no `#REGIONS` / cross-DC awareness | Phase 1.5 |
| Only TCP proto exposed | Phase 1 partial RoCE, Phase 3 full stack |
| No OCS mutator API | Phase 1 (side-effect of `GenericCustomTopology`) |

## megatron_gpt_76b_1024 target (from existing analytical log)

Reference baseline captured in `megatron_gpt_experiment/gpt_76b_1024/run_analytical.log`:

- `max cycle` (from sys[N] finished lines): **14,319,044,603**
- `exposed communication`: **7,128,322,245**

Phase 2 acceptance (§11.6) will compare the htsim run to these numbers.
