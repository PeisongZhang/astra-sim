# Ring All-Gather Bottleneck Analysis

## Scope

This note analyzes the latest complete successful run in `astra-sim/qwen_experiment/ring_ag/log/log.log`, specifically lines `430-510`.

Relevant setup:

- `all-gather` on `16` GPUs with ring collective implementation: `astra-sim/qwen_experiment/ring_ag/astra_system.json`
- workload is a symmetric microbenchmark: `astra-sim/examples/workload/microbenchmarks/generator_scripts/all_gather.py`
- current topology file is a uniform directed 16-node ring with `400Gbps` and `0.5us` per hop: `astra-sim/qwen_experiment/ring_ag/topology.txt`

## What the log says

From `log.log:430-510`:

- fastest GPU: `sys[0] = 558635 cycles`
- slowest GPU: `sys[1] = 629620 cycles`
- spread: `70985 cycles`
- slowest vs fastest: about `12.71%`

Per-GPU completion time is strictly monotonic:

| GPU | Wall/Comm Time (cycles) |
| --- | ---: |
| 0 | 558635 |
| 15 | 563358 |
| 14 | 568091 |
| 13 | 572824 |
| 12 | 577557 |
| 11 | 582290 |
| 10 | 587023 |
| 9 | 591756 |
| 8 | 596489 |
| 7 | 601222 |
| 6 | 605955 |
| 5 | 610688 |
| 4 | 615421 |
| 3 | 620154 |
| 2 | 624887 |
| 1 | 629620 |

The adjacent gap is essentially constant:

- `sys[15] - sys[0] = 4723 cycles`
- every next step after that is `4733 cycles`

## Main conclusion

The bottleneck in this run is **pure communication tail latency in the ring**, not compute.

Reason:

1. For every GPU in the cited run, `Comm time == Wall time`.
2. There is no reported `GPU time`.
3. This workload is a single `COMM_COLL_NODE` all-gather microbenchmark, so there is no real compute phase to hide communication behind.

That means the entire runtime is determined by how the ring communication pipeline fills and drains.

## Why `sys[1]` is the slowest

The completion times form a near-perfect arithmetic progression. That pattern is too regular to be explained by random contention or one broken GPU. It points to a **deterministic drain-order effect**:

- all ranks start from a symmetric all-gather workload
- data chunks circulate around the ring in a fixed order
- some GPUs receive their last required chunk later in that order
- the GPU whose final chunk arrives last becomes the tail rank

In this run, that tail rank is `sys[1]`, and `sys[0]` drains first.

So the practical bottleneck is:

`the last chunk delivery on the communication tail of the ring`

not:

- local compute throughput
- local memory bandwidth
- a single isolated GPU fault

## What this does and does not imply

### What is supported by the log

- The run is communication-bound.
- The imbalance is systematic, not noisy.
- The dominant cost is ring startup/drain serialization.

### What the log does not prove

The current log does **not** include per-link bandwidth or queue occupancy, so it does not prove that one physical link is uniquely congested.

Also, although the current `topology.txt` is uniform, `log.log` contains outputs from several runs and does not embed a topology checksum. So for cross-run comparisons, we should avoid claiming that all runs definitely used the exact same topology contents unless that is verified elsewhere.

## Comparison with other runs in the same log

### Earlier imbalanced run

`log.log:175-250` shows the same shape, but worse:

- fastest GPU: `1030505 cycles`
- slowest GPU: `1258780 cycles`
- spread: `228275 cycles`
- slowest vs fastest: about `22.15%`
- adjacent step: about `15219 cycles`

This is the same bottleneck pattern, just under a harsher effective communication cost.

### Balanced runs

`log.log:260-340` and later balanced segments show all GPUs at `345160 cycles`.

That is the opposite case:

- no visible tail-rank skew
- no per-rank communication imbalance
- ring communication completed with uniform finish time

So the repository already contains evidence of both modes:

- a balanced communication regime
- a tail-dominated communication regime

## Engineering interpretation

Because the workload itself is symmetric, the skew is not coming from different per-rank work. The bottleneck is introduced by the **collective execution over the ring/network path**.

For this run, the critical path is:

`all-gather chunk forwarding along the ring -> tail chunk arrival at sys[1]`

If you care about end-to-end completion time, the number that matters is the slowest rank:

- current analyzed run: `629620 cycles`

Everything faster than that is slack; the job still waits for the tail.

## What to verify next

To isolate the root cause more precisely, the next useful checks are:

1. Confirm which exact topology file contents were active for the `12:25:11` run.
2. Enable more detailed network statistics if available, especially per-link achieved bandwidth and queueing delay.
3. Compare ring with a less tail-sensitive collective or with more parallelism, for example:
   - more queues per dimension
   - more active chunks
   - bidirectional or alternative all-gather implementation if supported
4. Keep using the slowest rank time, not the average rank time, as the primary bottleneck metric.

## Bottom line

For the latest successful run, the bottleneck is **communication tail latency in the ring all-gather**. The evidence is the exact match between `Comm time` and `Wall time` on every GPU, plus the highly regular per-rank finish-time gradient from `sys[0]` to `sys[1]`.

## Appendix: Roofline Metric Derivation

This section summarizes the three roofline-related metrics used by ASTRA-sim:

- `operation intensity`
- `compute utilization`
- `memory utilization`

These metrics are defined in the implementation at:

- `astra-sim/astra-sim/workload/Workload.cc`
- `astra-sim/astra-sim/workload/Statistics.cc`

### Unified symbols

For a single compute operator `i`:

- `num_ops_i`: total amount of computation
- `tensor_size_i`: associated data size
- `peak_perf`: GPU peak compute throughput
- `local_mem_bw`: local memory peak bandwidth
- `OI_i`: operation intensity
- `perf_i`: achievable performance predicted by roofline
- `duration_i`: execution time

### Unified formula table

| Metric | Per-operator formula | Meaning | Typical range |
| --- | --- | --- | --- |
| `operation_intensity_i` | `OI_i = num_ops_i / tensor_size_i` | computation per unit data | `> 0` |
| `perf_i` | `perf_i = roofline.get_perf(OI_i)` | roofline-predicted achievable performance | `<= peak_perf` |
| `duration_i` | `duration_i = num_ops_i / perf_i` | operator execution time | `> 0` |
| `compute_utilization_i` | `perf_i / peak_perf` | fraction of peak compute reached | `0 ~ 1` |
| `memory_utilization_i` | `(perf_i / OI_i) / local_mem_bw` | fraction of peak memory bandwidth used | `0 ~ 1` |

### Standard roofline form

The standard roofline interpretation is:

```text
perf_i = min(peak_perf, OI_i * local_mem_bw)
```

This means:

- low `OI_i`: likely memory-bound
- high `OI_i`: likely compute-bound

### Operation intensity

```text
OI_i = num_ops_i / tensor_size_i
```

This is an input property of the operator. It describes whether the operator is more bandwidth-heavy or compute-heavy.

### Compute utilization

Per operator:

```text
compute_utilization_i = perf_i / peak_perf
```

Substituting the standard roofline:

```text
compute_utilization_i
= min(peak_perf, OI_i * local_mem_bw) / peak_perf
= min(1, OI_i * local_mem_bw / peak_perf)
```

So:

- if memory-bound:

```text
compute_utilization_i = OI_i * local_mem_bw / peak_perf < 1
```

- if compute-bound:

```text
compute_utilization_i = 1
```

### Memory utilization

Per operator:

```text
memory_utilization_i = (perf_i / OI_i) / local_mem_bw
```

Because:

```text
OI_i = perf_i / mem_throughput_i
```

we get:

```text
mem_throughput_i = perf_i / OI_i
```

and then normalize by `local_mem_bw`.

Substituting the standard roofline:

```text
memory_utilization_i
= min(peak_perf, OI_i * local_mem_bw) / (OI_i * local_mem_bw)
= min(peak_perf / (OI_i * local_mem_bw), 1)
```

So:

- if memory-bound:

```text
memory_utilization_i = 1
```

- if compute-bound:

```text
memory_utilization_i = peak_perf / (OI_i * local_mem_bw) < 1
```

### Relationship among the three metrics

These metrics form one chain:

```text
(num_ops_i, tensor_size_i)
        ->
operation_intensity_i
        ->
roofline perf_i
        ->
compute_utilization_i and memory_utilization_i
```

More explicitly:

```text
OI_i = num_ops_i / tensor_size_i
perf_i = min(peak_perf, OI_i * local_mem_bw)

compute_utilization_i = perf_i / peak_perf
memory_utilization_i  = (perf_i / OI_i) / local_mem_bw
```

Interpretation:

- low `OI_i`: high memory utilization, low compute utilization
- high `OI_i`: high compute utilization, low memory utilization

### Averaging in the log output

The logged averages are time-weighted averages over compute operators, not plain arithmetic means.

Average compute utilization:

```text
avg_compute_util
= sum(compute_utilization_i * duration_i) / sum(duration_i)
```

Average memory utilization:

```text
avg_memory_util
= sum(memory_utilization_i * duration_i) / sum(duration_i)
```

Average operation intensity:

```text
avg_op_intensity
= sum(OI_i * duration_i) / sum(duration_i)
```

So these averages mean:

- during compute time, what fraction of peak compute was used on average
- during compute time, what fraction of peak memory bandwidth was used on average
- during compute time, what operator intensity was seen on average

### Note for the current ring all-gather setup

In `astra-sim/qwen_experiment/ring_ag/astra_system.json`, `roofline-enabled` is currently `0`. So this run does not report these three metrics, even though the formulas above are the code-level definitions ASTRA-sim uses when roofline is enabled.
