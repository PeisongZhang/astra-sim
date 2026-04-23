# htsim Backend — Reference

> **Scope:** authoritative reference for environment variables, supported
> topologies, and the protocol matrix. For the full cookbook (build,
> run, add experiment, port from ns-3, sharded runner, troubleshooting,
> directory layout) see `htsim_usage_manual.md` — this file is its
> companion reference.

## Quick build / run

Full procedure in `htsim_usage_manual.md` §3 / §4. Minimal form:

```bash
cd /home/ps/sow/part2/astra-sim
bash build/astra_htsim/build.sh
build/astra_htsim/build/bin/AstraSim_HTSim \
  --workload-configuration=<dir>/workload \
  --comm-group-configuration=<dir>/workload.json \
  --system-configuration=<sys>.json \
  --remote-memory-configuration=no_memory_expansion.json \
  --network-configuration=<net>.yml \
  --htsim-proto=roce              # tcp | roce | dcqcn | hpcc
```

If `--network-configuration` YAML uses `topology: [Custom]` +
`topology_file:`, the htsim frontend loads it through
`GenericCustomTopology`; otherwise it falls back to a native FatTree.

## Environment variables — full table

Set on the shell that launches `AstraSim_HTSim`. All names start with
`ASTRASIM_HTSIM_*` unless noted. "Default" of *unset* means the variable
has no effect when absent.

### Logging / debug

| Variable | Default | Purpose |
|---|---|---|
| `ASTRASIM_HTSIM_VERBOSE` | unset | Per-flow `Send flow / Finish sending flow / Finish receiving flow` stdout lines, plus `[pfc]`, `[ocs]`, and Clock dot/pipe progress. ~100× log volume at 1024 NPU. Keep off for production. |
| `ASTRASIM_HTSIM_LOGGERS` | unset | Enable htsim's sampled queue + sink loggers (writes `logout.dat`). Adds ~30 % wall on large runs. Trace-level debugging only. |
| `ASTRASIM_LOG_LEVEL` | `debug` | Level of the rotating-file sink in `astra-sim/common/Logging.cc`. Accepts `trace`/`debug`/`info`/`warn`/`err`/`off`. **Set to `info` or `off` for any acceptance run** — `debug` emits hundreds of thousands of lines per second on 256-NPU+ runs. The console sink stays at `info` regardless. |
| `ASTRASIM_FLUSH_ON` | `err` | When the async spdlog backend flushes. Same level set as above. **Set to `info` for long acceptance runs** so you can `tail` `log.log` for `sys[X] finished` progress; default keeps the buffered-until-shutdown behaviour and looks like a hang. |

### Queue / fabric

| Variable | Default | Purpose |
|---|---|---|
| `ASTRASIM_HTSIM_QUEUE_TYPE` | `random` | `random` (legacy lossy `RandomQueue`), `composite` (`CompositeQueue`, ECN + fair drop), `lossless` (`LosslessOutputQueue` + paired `LosslessInputQueue`, PFC backpressure). **Production: `lossless`.** |
| `ASTRASIM_HTSIM_QUEUE_BYTES` | `1048576` (1 MB) | Per-port Queue size in `GenericCustomTopology`. Raise above BDP on high-BW WAN links; lower to stress incast. |
| `ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES` | `4194304` (4 MB) | Per-port Queue size for **inter-region (gateway)** links — i.e. links whose endpoints are in different regions per the `#REGIONS` block, or whose `link_type` is `wan`/`inter_spine`. Defaults to 4× `QUEUE_BYTES`. |
| `ASTRASIM_HTSIM_PFC_HIGH_KB` | `200` | Lossless mode: per-iq PAUSE-on threshold in KB. For N-way incast to one egress queue, keep `N * high_threshold < output_maxsize` to avoid "LOSSLESS not working". |
| `ASTRASIM_HTSIM_PFC_LOW_KB` | `50`  | Lossless mode: per-iq PAUSE-off threshold. The default 4× ratio avoids oscillation. |
| `ASTRASIM_HTSIM_PACKET_BYTES` | `4096` | MTU / packet payload. Range [256, 65536]. 4 KB is realistic for RoCE fabrics. |
| `ASTRASIM_HTSIM_NIC_GBPS` | *auto* | Override NIC pacing rate (Gbps). Default `recommended_nic_linkspeed_bps()` = min(max host adj link, min backbone link). |
| `ASTRASIM_HTSIM_NIC_WIRE_SPEED` | unset | Force legacy max-host-link pacing (debug only — causes retransmission storms on heterogeneous fabrics). |
| `ASTRASIM_HTSIM_ENDTIME_SEC` | `1000` | Hard cap on simulation simtime (seconds). If a workload legitimately needs >1000 s, raise; otherwise a timeout typically indicates livelock. |

### Routing / OCS

| Variable | Default | Purpose |
|---|---|---|
| `ASTRASIM_HTSIM_ROUTE` | `dijkstra` | `bfs` restores hop-count routing. Dijkstra (default, edge weight = `1 / bw_Gbps`) prefers high-BW paths. |
| `ASTRASIM_HTSIM_RANDOM_SEED` | `0xA571A517` | Seed for `std::srand` / `::srandom`. Override to study seed sensitivity. |
| `ASTRASIM_HTSIM_OCS_SCHEDULE` | unset | `<at_us>:<src>:<dst>:<bw_gbps>:<up>[,...]`. Calls `GenericCustomTopology::schedule_link_change` on init; OCS / failure injection. |
| `ASTRASIM_HTSIM_OCS_REROUTE` | unset | When an OCS link change fires, also re-run Dijkstra and clear the path cache so *new* flows pick new paths. Flows already in flight keep their original Route (old cache entries move to a graveyard, never freed mid-run). Off by default — preserves legacy behaviour where bandwidth changes only affect queue service rate. |

### Congestion control (DCQCN/HPCC)

| Variable | Default | Purpose |
|---|---|---|
| `ASTRASIM_HTSIM_DCQCN_KMIN_KB` / `KMAX_KB` | unset | Global ECN marking thresholds for `CompositeQueue` when `--htsim-proto=dcqcn` or `QUEUE_TYPE=composite`. Below `kmin` no mark; between `kmin`/`kmax` probabilistic; above `kmax` always marked. |
| `ASTRASIM_HTSIM_DCQCN_AIMD` | (auto-set by `--htsim-proto=dcqcn`) | Enables the AIMD rate-control loop in `RoceSrc` on ECN_ECHO ACKs. Off for plain RoCE; on for DCQCN. |
| `ASTRASIM_HTSIM_DCQCN_AI_MBPS` | auto | Additive-increase step (Mbps) per DCQCN update window. Auto = ~1 % of link rate, clamped to [1, 50] Mbps. |
| `ASTRASIM_HTSIM_DCQCN_MIN_MBPS` | auto | Minimum rate (Mbps) DCQCN will cut to. Auto = 0.1 % of link rate, clamped above 100 Mbps. |
| `ASTRASIM_HTSIM_DCQCN_BYTES` | `131072` | Bytes ACKed between AI/MI rate-update cycles (the DCQCN "B" parameter). |
| `ASTRASIM_HTSIM_DCQCN_G_RECIP` | `16` | Reciprocal of the α EWMA weight `g` (paper default 16, i.e. g ≈ 0.0625). |

### ns-3 passthrough

These are read by `ns3_config_to_htsim.py` so legacy `ns3_config.txt`
files port over without source edits.

| Variable | Default | Purpose |
|---|---|---|
| `ASTRASIM_HTSIM_KMAX_MAP` / `KMIN_MAP` / `PMAX_MAP` | unset | Per-bandwidth ECN map form. Currently passthrough only; use the single-value `DCQCN_KMIN_KB`/`KMAX_KB` form above to actually wire ECN marking. |
| `ASTRASIM_HTSIM_ACK_HIGH_PRIO` | unset | Reserved for PFC multi-class (U5). Passthrough today. |

## Supported topologies

| YAML `topology:` | htsim back-end used |
|---|---|
| `[Custom]` + `topology_file:` | `GenericCustomTopology` (Dijkstra over Pipes/Queues; supports `#REGIONS` cross-DC + asymmetric BW + OCS mutator) |
| `[Ring]` / `[Switch]` / `[FullyConnected]` | `FatTreeTopology` (substitute — same host count, different internal fabric; quick smoke only — topology-equivalence is not guaranteed) |
| _none, `-topo` CLI_ | `FatTreeTopology::load(-topo <file>)` native fat-tree format |

For cross-DC (`#REGIONS`, `link_type`, asymmetric BW) details see
`cross_dc_topology.md`.

## Protocol matrix

| `--htsim-proto` | Status | Notes |
|---|---|---|
| `tcp` | Available | htsim's `TcpSrc` + `TcpSink`, slow-start + Reno. Multipath wrapper disabled — always 1 subflow under ASTRA-sim. Use as historical baseline. |
| `roce` | **Default — §11.6 acceptance** | Minimal RoCE v2 via `RoceSrc` / `RoceSink` with our flow-finish hooks. No DCQCN tuning unless `DCQCN_*` vars are set. |
| `dcqcn` | Available | RoCE + ECN marking on `CompositeQueue` — configure via `ASTRASIM_HTSIM_DCQCN_KMIN_KB` / `KMAX_KB`. Auto-selects `QUEUE_TYPE=composite` if unset. AIMD rate-control on CNP is enabled (`DCQCN_AIMD` auto-on). |
| `hpcc` | Available | htsim's native `HPCCSrc`/`HPCCSink` with INT telemetry injected by `LosslessOutputQueue` at every switch. Ctor force-selects `QUEUE_TYPE=lossless` (only `LosslessOutputQueue` injects INT). HPCC's AIMD `_cwnd` adaptation is live on INT-marked ACKs. |

PFC is enabled implicitly via `QUEUE_TYPE=lossless`; there is no
separate `ASTRASIM_HTSIM_PFC` toggle. Per-class PFC (multi-priority) is
deferred (U5).

## Reference timings (observed — no guarantee)

Reference hardware: 32-core / 31 GiB RAM box, RoCE, `lossless`,
`LOG_LEVEL=info`.

| Experiment | NPUs | Wall time | Peak RSS |
|---|---:|---:|---:|
| `qwen/ring_ag_htsim` | 16 | < 0.1 s | < 150 MB |
| `llama/in_dc_htsim` | 16 | ~ 5 s | < 200 MB |
| `gpt_39b_512` (sharded PP=2, L48) | 512 | ~ 55 min | ~ 15 GB |
| `gpt_39b_512` (ladder smoke, L4) | 32 | ~ 10 s | < 500 MB |
| `gpt_39b_512` direct (no shard) | 512 | blocked (U2) | — |
| `gpt_76b_1024` direct (no shard) | 1024 | blocked (U2 + U12) | — |
| `llama3_70b/in_dc_htsim` | 1024 | blocked (U2 + U12) | — |

The 1024-NPU direct runs are gated by U2 (single-thread DES throughput)
and U12 (RAM ≥ 64 GiB). Use the sharded runner (`htsim_usage_manual.md`
§8) for anything ≥ 128 NPU.
