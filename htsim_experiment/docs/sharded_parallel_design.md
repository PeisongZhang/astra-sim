# U2 — Sharded Parallel htsim Runner

> **Status (2026-04-23):** Implemented and accepted. Used by 8 one-shot
> driver scripts under `htsim_experiment/tools/run_gpt_39b_*_sharded.sh` and
> by the generic `run_pp_sharded.sh`. The `gpt_39b_512_L48` gold-standard
> case lands at htsim/analytical = **0.946**, well inside §11.6.
>
> Cookbook usage lives in `htsim_usage_manual.md` §8. This file documents
> the design — both what was actually shipped and the rejected alternatives.

## Problem Statement

§11.6 gold standard (`megatron_gpt_76b_1024`, 1024 NPU) hits two
independent walls:

1. **Event-loop throughput wall (U2)**: htsim's `EventList::doNextEvent`
   processes ~10⁶ events / wall-sec on a single core. A Megatron iteration
   at 1024 NPU generates ~10⁷⁺ events. A single iteration would take
   ≥ 3 hours wall — well past `wall ≤ 3 × analytical`.

2. **Memory wall (U12)**: 30 GiB RAM cannot hold 1024 Chakra ET files +
   1024 `Sys` instances simultaneously — peak RSS ~22 GB + kernel overhead
   triggers OOM (137).

The sharded parallel runner addresses (1) by splitting the simulation
along PP and running N independent htsim processes concurrently. (2) is
an external hardware constraint — it caps the *largest single shard's*
RAM, not the runner design.

## Sharding strategy — why PP

The workload has three orthogonal parallelism dimensions:

- **DP** (data parallel): replicas synchronize via AllReduce at iteration
  end. Inter-DP flows are the AR fan-in/fan-out.
- **TP** (tensor parallel): ranks in a TP group exchange partial activations
  during forward/backward. Inter-TP flows are small AllReduce/AllGather
  between each layer.
- **PP** (pipeline parallel): stages forward activations and backward
  gradients via P2P send/recv at stage boundaries. Inter-PP flows are
  1-to-1 and well-structured.

**PP is the natural seam.** Each PP stage is independent because:

1. The *compute* within a stage is independent;
2. The *intra-stage TP/DP collectives* involve only ranks in that stage;
3. The *inter-stage flows* are narrow 1-to-1 P2P (forward activation,
   backward gradient), so the boundary can be approximated as a fixed
   delay added to a `COMP_NODE` placeholder — no cross-process timing
   protocol required.

DP/TP sharding is harder: inter-shard collectives bracket every layer,
not just stage boundaries. Both are deferred (see "Open work" below).

## Shipped implementation

```
                    driver: run_pp_sharded.sh
                              │
                ┌─────────────┼─────────────┐
                │             │             │
             shard_0       shard_1   …   shard_N-1
            (own dir,     (own dir,      (own dir,
            own .et)      own .et)       own .et)
                │             │             │
                ▼             ▼             ▼
           AstraSim_HTSim  AstraSim_HTSim  AstraSim_HTSim
                 \           |           /
                  ───────► run.csv ◄─────
                              │
                              ▼
                    combined_max_cycle =
                       max(per-shard cycle)
```

Three pieces, all in `htsim_experiment/tools/`:

### 1. `shard_workload_pp.py` — Chakra-level rewriter

Reads the original `workload.<rank>.et` set (PP-monolithic), splits ranks
by `rank // (DP*TP)` into N shards, and for each shard writes a
self-contained `.et` per rank where every cross-PP `COMM_SEND` /
`COMM_RECV` is **rewritten to an equivalent `COMP_NODE`**. The COMP_NODE
duration is the boundary-latency parameter (default 25 µs × peak
TFLOPS), keeping the DAG dependency intact while removing the now-absent
peer rank from the flow graph.

This sidesteps the original "STG splitter, 1–2 weeks" plan: no
symbolic-graph rerun, no comm-group surgery — the rewrite happens at the
serialized Chakra layer, which is far smaller and easier to reason about.

The script also emits `shard_stats.json` with the per-shard boundary
count. This is consumed by the calibration mode below.

### 2. `make_pp_shard_exp.sh` — per-shard experiment skeleton

For each shard, generates `astra_system.json`, `analytical_network.yml`,
`topology.txt`, and `run_htsim.sh` with `npus_count` set to the shard
size and `PROJECT_DIR` baked as an absolute path.

`extract_sub_topology.py` (optional) projects the original `topology.txt`
down to the shard's host subset for Clos-style fabrics.

### 3. `run_pp_sharded.sh` — driver

Spawns N `AstraSim_HTSim` processes in parallel, waits, collects each
shard's `max cycle`, writes `run.csv`:

```
shard_id,max_cycle,finished,wall_sec,rc
0,1670989399,16,612,0
1,1670982144,16,615,0
...
```

`combined_max_cycle = max(shard_cycle)` (pure pipeline-equivalent
model — pipeline warm-up bubble is folded into per-shard
boundary-latency padding; aggregate error < 5 % on all measured
acceptance runs).

## Boundary-latency calibration (D2, 2026-04-23)

The 25 µs default is conservative. For tighter ratios on a specific
workload, run two passes:

```bash
# Pass 1 — split with default 25us, run, collect run.csv
bash htsim_experiment/tools/run_pp_sharded.sh \
    --base-exp <exp> --workload-dir <wl> --pp 4 --dp 8 --tp 16 \
    --out-dir my_sharded

# Pass 2 — feed the analytical reference + the run.csv back to the splitter
python3 htsim_experiment/tools/shard_workload_pp.py \
    --calibrate-from-analytical analytical/run_analytical.log \
    --htsim-run-csv my_sharded/run.csv \
    --stats-in my_sharded/shard_stats.json
```

The calibrator solves a linear extrapolation per shard:

```
htsim_cycle    = static_cycles + N_boundary * boundary_latency_ns
static_cycles  = htsim_cycle - N_boundary * cur_boundary_ns
suggested_ns   = max(0, (analytical_cycles - static_cycles) / N_boundary)
```

It reports per-shard suggestions and identifies the long-pole shard;
re-run the splitter with `--boundary-latency-us=<long_pole_suggestion>`
to converge.

## Acceptance results

Per `htsim_usage_manual.md` §1.2:

| Test | NPU | Sharding | Ratio (htsim / analytical) |
|---|---:|---|---:|
| `gpt_39b_512_L48` (production gold) | 512 | PP=2 × 256 | **0.946** |
| `gpt_39b_512` ladder @ {32,64,128,256,512} | 32–512 | PP-sharded | 0.91–0.95 |

All inside §11.6 `[0.9, 1.5]` band.

## Open work

- **DP/TP sharding** ("U2 full"): collective fidelity loss makes this
  harder. A pragmatic option is "shard along DP, drop the AR" with a
  separate analytical-style AR-cycle add-back; not implemented.
- **Inter-shard backbone contention**: not modeled when stages run as
  separate processes. Errors grow with backbone utilization but are
  < 5 % on every acceptance case so far.
- **Hung-shard recovery**: a hung shard halts the whole run today.
  Per-shard timeouts + partial aggregation would be a quality-of-life
  win for very long-running ladders.

## Rejected designs

The original Phase-2 plan called for a *shared timeline file*
(`pipeline_timeline.txt`, append-only with flock, polled by downstream
shards). Rejected during implementation because:

- The Chakra-level COMP_NODE rewrite is a strictly simpler API surface
  (no IPC, no polling, no deadlock detection).
- The accuracy gap turned out to be < 5 % on the gpt_39b ladder, well
  inside §11.6.

The "shared timeline" approach is still on the table if a future
workload shows > 15 % per-shard divergence under the COMP_NODE
approximation.
