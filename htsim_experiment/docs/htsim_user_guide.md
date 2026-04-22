# htsim Backend — User Guide

## Build

```bash
cd /home/ps/sow/part2/astra-sim
bash build/astra_htsim/build.sh         # incremental build
bash build/astra_htsim/build.sh -l      # clean (remove build dir + generated et_def.pb.*)
bash build/astra_htsim/build.sh -d      # debug build (-O0 -g, no sanitizers by default)
```

Binary: `build/astra_htsim/build/bin/AstraSim_HTSim`.

On first run the script applies `build/astra_htsim/htsim_astrasim.patch` to
`extern/network_backend/csg-htsim/sim/{tcp,roce}.{cpp,h}`, which adds the
ASTRA-sim flow-finish hooks.  Apply is idempotent; rerun is safe.

## Run

```bash
AstraSim_HTSim \
  --workload-configuration=<dir>/workload \
  --comm-group-configuration=<dir>/workload.json \
  --system-configuration=<sys>.json \
  --remote-memory-configuration=no_memory_expansion.json \
  --network-configuration=<net>.yml \
  --htsim-proto=roce              # tcp | roce | dcqcn | hpcc
```

All the existing analytical/ns-3 config files work unchanged — if the
`--network-configuration` YAML uses `topology: [Custom]` + `topology_file:`,
the htsim frontend loads it through `GenericCustomTopology` instead of a
native htsim FatTree.

## Environment knobs

| Variable | Default | Purpose |
|---|---|---|
| `ASTRASIM_HTSIM_VERBOSE` | unset | Per-flow `Send flow / Finish sending flow / Finish receiving flow` stdout lines, plus `[pfc]`, `[ocs]`, and Clock dot/pipe progress. 100× log volume at 1024 NPU.  Keep off for production. |
| `ASTRASIM_HTSIM_LOGGERS` | unset | Enable htsim's sampled queue + sink loggers (writes `logout.dat`). Adds ~30% wall on large runs. Useful for trace-level debugging. |
| `ASTRASIM_HTSIM_QUEUE_TYPE` | `random` | `random` (legacy, lossy RandomQueue), `composite` (CompositeQueue, ECN + fair drop), `lossless` (LosslessOutputQueue + paired LosslessInputQueue, PFC backpressure — **recommended for realistic incast**). |
| `ASTRASIM_HTSIM_PFC_HIGH_KB` | `200` | Lossless mode: per-iq PAUSE-on threshold in KB. For N-way incast to one egress queue, keep `N * high_threshold < output_maxsize` to avoid "LOSSLESS not working" diagnostics. |
| `ASTRASIM_HTSIM_PFC_LOW_KB` | `50`  | Lossless mode: per-iq PAUSE-off threshold in KB. Lower `low`/`high` ratio causes oscillation; default 4× avoids it. |
| `ASTRASIM_HTSIM_QUEUE_BYTES` | `1048576` (1 MB) | Per-port Queue size in GenericCustomTopology. Raise above BDP on high-BW WAN links; lower to stress incast. |
| `ASTRASIM_HTSIM_ENDTIME_SEC` | `1000` | Hard cap on simulation time (seconds simtime).  If the workload legitimately needs >1000s, bump; otherwise a timeout typically indicates a livelock. |
| `ASTRASIM_HTSIM_PACKET_BYTES` | `4096` | MTU / packet payload. Range [256, 65536]. 4 KB is realistic for RoCE fabrics. |
| `ASTRASIM_HTSIM_NIC_GBPS` | *auto* | Override NIC pacing rate (Gbps). Defaults to `recommended_nic_linkspeed_bps()` = min(max host adj link, min backbone link). |
| `ASTRASIM_HTSIM_NIC_WIRE_SPEED` | unset | Force legacy max-host-link pacing (for debugging only — causes retransmission storms on heterogeneous fabrics). |
| `ASTRASIM_HTSIM_RANDOM_SEED` | `0xA571A517` | Seed for `std::srand` / `::srandom`. Override to explore seed-sensitivity. |
| `ASTRASIM_HTSIM_ROUTE` | `dijkstra` | `bfs` restores hop-count routing (Dijkstra with edge weight = 1/bw_Gbps is the default — prefers high-BW paths). |
| `ASTRASIM_HTSIM_OCS_SCHEDULE` | unset | `<at_us>:<src>:<dst>:<bw_gbps>:<up>[,...]`. Calls `GenericCustomTopology::schedule_link_change` on init; useful for OCS / failure-injection studies. |
| `ASTRASIM_HTSIM_OCS_REROUTE` | unset | When an OCS link change fires (via `OCS_SCHEDULE` or library call), also re-run Dijkstra with the updated bandwidth and clear the path cache so *new* flows pick new paths.  Flows already in flight keep their original Route (old cache entries move to a graveyard, never freed mid-run).  Off by default — preserves legacy behaviour where bandwidth changes only affect queue service rate. |
| `ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES` | `4194304` (4 MB) | Per-port Queue size for **inter-region** (gateway) links — i.e. links whose endpoints are in different regions per the `#REGIONS` block or whose explicit link_type is `wan`/`inter_spine`. Defaults to 4× `ASTRASIM_HTSIM_QUEUE_BYTES`. |
| `ASTRASIM_HTSIM_KMAX_MAP` / `KMIN_MAP` / `PMAX_MAP` | unset | Passthrough from ns-3 `KMAX_MAP/KMIN_MAP/PMAX_MAP` (per-bandwidth ECN marking). The *per-bandwidth* map form is still passthrough only; use the `ASTRASIM_HTSIM_DCQCN_KMIN_KB/KMAX_KB` single-value form below to actually wire ECN marking to CompositeQueue. |
| `ASTRASIM_HTSIM_DCQCN_KMIN_KB` / `KMAX_KB` | unset | Global ECN marking thresholds for CompositeQueue when `--htsim-proto=dcqcn` or `ASTRASIM_HTSIM_QUEUE_TYPE=composite`. Below `kmin` no mark; between `kmin`/`kmax` probabilistic; above `kmax` always marked. |
| `ASTRASIM_HTSIM_DCQCN_AIMD` | (auto-set by `--htsim-proto=dcqcn`) | Enable the full AIMD rate-control loop in `RoceSrc` on ECN_ECHO ACKs. Off for plain RoCE; on for DCQCN. |
| `ASTRASIM_HTSIM_DCQCN_AI_MBPS` | auto | Additive-increase step (Mbps) per DCQCN update window. Auto default = ~1% of link rate, clamped to [1, 50] Mbps. |
| `ASTRASIM_HTSIM_DCQCN_MIN_MBPS` | auto | Minimum rate (Mbps) DCQCN will cut to. Auto default = 0.1% of link rate, clamped above 100 Mbps. |
| `ASTRASIM_HTSIM_DCQCN_BYTES` | `131072` | Bytes acked between AI/MI rate-update cycles (the DCQCN "B" parameter). Smaller = more reactive, more CPU. |
| `ASTRASIM_HTSIM_DCQCN_G_RECIP` | `16` | Reciprocal of the α EWMA weight g — i.e. higher = slower α response. DCQCN paper default is 16 (1/g ≈ 16, so g = 0.0625). |
| `ASTRASIM_HTSIM_ACK_HIGH_PRIO` | unset | Passthrough from ns-3 `ACK_HIGH_PRIO`. Reserved for PFC multi-class (U5). |
| `ASTRASIM_LOG_LEVEL` | `debug` | Sets the level of the rotating-file sink in `astra-sim/common/Logging.cc`. Accepts `trace`/`debug`/`info`/`warn`/`err`/`off`. On long simulations (e.g. 256-NPU gpt_39b) debug-level emits hundreds of thousands of lines / second; set to `info` or `off` for acceptance runs. The console sink stays at `info` regardless. |
| `ASTRASIM_FLUSH_ON` | `err` | When the async spdlog backend flushes. Accepts `trace`/`debug`/`info`/`warn`/`err`/`off`. For long acceptance runs where you want to tail `log.log` for `sys[X] finished` progress, set to `info`. Default preserves the historical buffered-until-shutdown behaviour. |

## Supported topologies

| YAML `topology:` | htsim back-end used |
|---|---|
| `[Custom]` + `topology_file:` | `GenericCustomTopology` (BFS routing over Pipes/Queues) |
| `[Ring]` / `[Switch]` / `[FullyConnected]` | `FatTreeTopology` (substitute — same host count, different internal fabric; use only for quick smoke / topology-equivalence not required) |
| _none, `-topo` CLI_ | `FatTreeTopology::load(-topo <file>)` native fat-tree format |

For Phase 1.5 cross-DC work, see [cross_dc_topology.md](cross_dc_topology.md) — the `#REGIONS` extension on top of Custom topology.txt.

## Protocol matrix

| `--htsim-proto` | Status | Notes |
|---|---|---|
| `tcp` | Phase 0 baseline | htsim's default `TcpSrc` + `TcpSink`, slow-start + Reno. Multipath wrapper disabled — we always run 1 subflow for ASTRA-sim. |
| `roce` | **Phase 1 default** (§11.6 acceptance) | Minimal RoCE v2 via `RoceSrc` / `RoceSink` with our flow-finish hooks. No DCQCN tuning yet. |
| `dcqcn` | Phase 3.1b **ECN path enabled** | ECN marking on CompositeQueue — configure with `ASTRASIM_HTSIM_DCQCN_KMIN_KB` / `KMAX_KB`. Auto-selects `ASTRASIM_HTSIM_QUEUE_TYPE=composite` if unset. RoCE AIMD rate-control on CNP is deferred to a future upstream patch on `roce.cpp` (requires extending `RoceAck` with an ECN-echo bit + AIMD state in `RoceSrc`). |
| `hpcc` | Phase 3.1c **native HPCC** | Runs htsim's `HPCCSrc`/`HPCCSink` with INT telemetry injected by `LosslessOutputQueue` at each switch. Ctor force-selects `ASTRASIM_HTSIM_QUEUE_TYPE=lossless` because only LosslessOutputQueue injects INT. HPCC's AIMD-based `_cwnd` adaptation is live on INT-marked acks. |

PFC is an orthogonal switch (`ASTRASIM_HTSIM_PFC=1`, planned §11.2 P3.1d).

## Typical sims & timings (reference hardware: 32-core / 31 GiB RAM box)

| Experiment | NPUs | Wall time (RoCE) | Peak RSS |
|---|---:|---:|---:|
| qwen/ring_ag | 16 | < 0.1s | < 150 MB |
| llama3_70b/in_dc | 1024 | ~20 min | ~20 GB |
| megatron_gpt/gpt_39b_512 | 512 | ~10 min | ~15 GB |
| megatron_gpt/gpt_76b_1024 | 1024 | ~45 min (can OOM on ≤32GB) | ~28 GB |

The 1024-NPU runs are memory-bound on commodity boxes. Phase 4 defers a
sharded-parallel runner (see §11.3 lever #5) for when wall time matters more.

## Adding a new experiment

```bash
cp -r astra-sim/llama_experiment/in_dc astra-sim/llama_experiment/in_dc_htsim
cat >> astra-sim/llama_experiment/in_dc_htsim/run_htsim.sh  # see neighbour for template
chmod +x astra-sim/llama_experiment/in_dc_htsim/run_htsim.sh
bash astra-sim/llama_experiment/in_dc_htsim/run_htsim.sh
```

The CI smoke `utils/htsim_smoke.sh` is the first check on any rebuild.

## Porting an ns-3 experiment (U9)

If you are migrating an experiment that already has an `ns3_config.txt`
(CC_MODE / ENABLE_QCN / KMAX_MAP / LINK_DOWN / etc.), use the helper parser
to translate those settings into the ASTRASIM_HTSIM_* env vars htsim reads:

```bash
# Preview what the parser will export:
python3 htsim_experiment/tools/ns3_config_to_htsim.py \
    llama_experiment/inter_dc_mesh/ns3_config.txt

# Apply them to the current shell, then run htsim:
eval "$(python3 htsim_experiment/tools/ns3_config_to_htsim.py \
    llama_experiment/inter_dc_mesh/ns3_config.txt)"
bash llama_experiment/inter_dc_mesh_htsim/run_htsim.sh
```

The parser handles:
- `CC_MODE` → `HTSIM_PROTO` (1→dcqcn, 3/4→hpcc, 7/8→tcp)
- `ENABLE_QCN=1` → `ASTRASIM_HTSIM_QUEUE_TYPE=lossless` (PFC)
- `PACKET_PAYLOAD_SIZE` → `ASTRASIM_HTSIM_PACKET_BYTES`
- `BUFFER_SIZE` (MB) → `ASTRASIM_HTSIM_QUEUE_BYTES` (divided by 16 ports)
- `KMAX_MAP` / `KMIN_MAP` / `PMAX_MAP` → passthrough (consumed by U3)
- `LINK_DOWN` events → `ASTRASIM_HTSIM_OCS_SCHEDULE`
- `ENABLE_TRACE=1` → `ASTRASIM_HTSIM_LOGGERS=1`
- `ACK_HIGH_PRIO=1` → `ASTRASIM_HTSIM_ACK_HIGH_PRIO=1` (passthrough for U5)

Run `bash htsim_experiment/tools/test_ns3_config_parse.sh` to verify the
parser after any changes.
