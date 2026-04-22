# U2 — Sharded Parallel htsim Runner — Design Document

> Status: **Design + skeleton only** (2026-04-22). A full implementation
> requires STG-side workload splitting (1–2 weeks), documented below.

## Problem Statement

§11.6 gold standard (`megatron_gpt_76b_1024`, 1024 NPU) is blocked by two
independent walls:

1. **Event-loop throughput wall (P1)**: htsim's `EventList::doNextEvent`
   processes ~10⁶ events / wall-sec on a single core. A Megatron iteration
   at 1024 NPU generates ~10⁷⁺ events. A single iteration would take
   ≥ 3 hours wall-time — orders of magnitude beyond the `wall ≤ 3 ×
   analytical` target.

2. **Memory wall (U12)**: 30 GiB RAM cannot hold 1024 Chakra ET files +
   1024 `Sys` instances simultaneously — peak RSS ~22 GB + kernel overhead
   triggers OOM kill (137).

This document describes a **sharded parallel runner** that addresses wall (1)
by splitting the simulation along a parallelism dimension of the workload
and running N independent htsim processes concurrently. Wall (2) is an
external hardware constraint independent of this design.

## Sharding Strategy

The workload has three orthogonal parallelism dimensions:

- **DP** (data parallel): replicas synchronize via AllReduce at iteration
  end. Inter-DP flows are the AR fan-in/fan-out.
- **TP** (tensor parallel): ranks in a TP group exchange partial activations
  during forward/backward. Inter-TP flows are small AllReduce/AllGather
  between each layer.
- **PP** (pipeline parallel): stages forward activations and backward
  gradients via P2P send/recv at stage boundaries. Inter-PP flows are
  1-to-1 and well-structured.

**Sharding by PP is the natural choice.** Each PP stage can run as an
independent htsim process because:

1. The *compute* within a stage is independent;
2. The *intra-stage TP/DP collectives* involve only ranks in that stage;
3. The *inter-stage flows* are the narrow 1-to-1 P2P boundary (forward
   activation, backward gradient), which can be modeled either as
   (a) a fixed delay added at the boundary, or (b) a shared "send
   timeline" file that downstream stages consume.

Sharding by DP or TP is harder because inter-shard collectives bracket
every layer, not just stage boundaries.

## High-Level Architecture

```
                      driver (bash/python)
                      |        |        |
                      v        v        v
               proc_PP0  proc_PP1   ...  proc_PP(N-1)
                 |          |             |
                 |          |             |
                 v          v             v
           htsim_PP0   htsim_PP1     htsim_PP(N-1)
                   \\         |            //
                    \\        v           //
                     >  pipeline_timeline.txt  <
                     (cross-stage send timestamps)
                              |
                              v
                         aggregator
                              |
                              v
                     combined max_cycle.csv
```

Each `htsim_PPi` process:

- reads only the ranks in its stage (`workload.<rank_in_stage>.et`);
- loads a reduced `workload.json` listing only comm-groups internal to the stage;
- at a stage boundary, instead of scheduling a real htsim flow, looks up the
  peer stage's earliest-possible-receive time from
  `pipeline_timeline.txt`, adds the boundary latency + size/bw, and
  registers the completion locally;
- writes its own `pipeline_timeline.txt` entries for downstream stages.

The timeline file is append-only and written atomically (flock). Processes
poll it with a bounded wait, failing fast if the simulation deadlocks.

## Prerequisites — STG Workload Splitter

**This is the 1–2 week blocker.** STG (`dnn_workload/symbolic_tensor_graph/main.py`)
must be extended with a `--shard-pp` option that, given a generated workload,
writes out N sub-workload directories:

```
workload_shard_pp0/
  workload.json         # comm-groups restricted to stage 0 ranks
  workload.0.et         # stage 0 rank 0
  workload.1.et
  ...
  workload.(dp*tp-1).et
  pp_boundary.json      # declares stage 0 -> stage 1 send points: [(step, size, to_rank), ...]

workload_shard_pp1/
  workload.json
  workload.0.et
  ...
```

Splitter requirements:

- Deterministic rank renumbering (within a shard, ranks are 0..dp*tp-1).
- `workload.json` comm-groups are *intersected* with the shard rank set.
- Chakra `.et` nodes that send/recv to a rank outside the shard are
  rewritten to reference a *timeline* node that the driver fills in.
- `pp_boundary.json` describes the directed flow across stage boundaries.

## Driver (Skeleton in this PR)

`htsim_experiment/tools/sharded_runner.sh` spawns N processes on a
single-shard workload (N=1 trivial case) and computes combined max_cycle.
This validates the spawn / collect / aggregate path; actual PP-split
execution requires the STG splitter.

## Correctness & Validation

After the splitter lands, validation plan:

1. Run `gpt_39b_512` unsharded (RoCE, lossless, 512 NPU) if U12 hardware
   allows — baseline B₀.
2. Run `gpt_39b_512` sharded with PP=8 × 64 NPU each — result S₀.
3. Compare: `|S₀ − B₀| / B₀` must be < 15% for the approximation to be
   accepted as within the §11.6 cycle tolerance.

If deviation is too large, the boundary-delay approximation is too loose and
the shared timeline file approach must be used (costlier but more accurate).

## Known Limitations

- PP is required > 1. Workloads without pipeline parallelism cannot be
  sharded this way. For those (pure DP / TP), consider:
  * `workload.json` sharding along DP (lose AllReduce fidelity);
  * No sharding (fall back to single-process, accept large wall time).

- Inter-shard contention on backbone links is not modeled when stages run
  as separate processes. This is the approximation; errors grow with
  backbone utilization.

- The driver assumes all processes finish; a hung shard halts the whole
  run. Per-shard timeouts + partial aggregation is a future enhancement.

## Open Questions

1. **Where should the boundary delay come from?** Two options:
   - Load-free: `boundary_latency + size / bw_min`
   - Load-aware: run a short calibration run first to estimate typical queue
     waits on the backbone link.

2. **Should we write timeline to shared memory instead of a file?** File is
   simplest and debuggable; shm would avoid kernel write overhead on very
   large timelines. For N ≤ 16 shards × ~10⁴ boundary flows each, a file
   is ~tens of MB — manageable.

3. **Replicated Sys state vs shared**: each htsim process currently has its
   own `Sys` instance. Sharing state (compute tracking, memory) across
   processes is unnecessary since compute is local; communication timing
   is what we serialize via the timeline file.

## Priority After This Session

Items U2 remains at **P0** in §16.2 — it is the only path to §11.6 gold
standard acceptance. A full dev session should:

1. **Week 1**: implement STG splitter (`--shard-pp`) with unit tests that
   assert (a) every rank appears in exactly one shard; (b) `workload.json`
   comm-groups are well-formed per shard; (c) boundary flows are
   accounted for in `pp_boundary.json`.
2. **Week 2**: wire the timeline file into the driver; validate vs
   unsharded on a 32 NPU toy case; then scale to 512 NPU gpt_39b_512.
