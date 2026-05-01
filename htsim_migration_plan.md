# ASTRA-sim 迁移到 htsim 后端 —— 现状与维护手册

> **当前权威文档（关账于 2026-04-23 夜）**。原 3300 行的逐 session 演化记录已归档到 `htsim_migration_plan.md.bak`，按需查阅。
> **新接手第一步**：跑 §4 三件套自检，PASS 即可继续工作。

**目标**：把 `astra-sim/{llama,llama3_70b,qwen,megatron_gpt}_experiment/` 下的实验全部迁到 htsim 后端，建立可回归的 htsim 实验流水线。下游动机是为 MoE + OCS 研究（MixNet SIGCOMM'25 用的就是 htsim）打基座。

**用户定的验收口径**（金标准从 76b 降档到 39b 之后）：
- `gpt_39b_512 × LAYER=48 × BATCH=256 × MICROBATCH=2 × ar=1` 通过 §6 cycle 窗口 [0.9, 1.5]。
- **已 3 次字节一致重现 ratio = 0.9462**，PASS。

---

## 1. 背景

### 1.1 为什么换 htsim

| 后端 | 模型 | 速度 | OCS 重构能力 | 结论 |
|---|---|---|---|---|
| analytical | 闭式公式 + 静态 BFS 路由 | 最快 | ❌ ctor 期固化路由 | 适合大规模快速 sweep |
| ns-3 | 包级 | 慢 5-10× htsim | 仅 `TakeDownLink`，模块耦合重 | 现有 baseline 用 |
| **htsim** | 包级 + DES `eventlist` | 中等 | ✅ DES 调度器干净，原生支持拓扑 mutation | **唯一适合 MoE-OCS 研究** |

### 1.2 集成架构

- **frontend**：`astra-sim/network_frontend/htsim/`，5 个 C++ 文件 + topology adapter + 4 个 protocol 实现。
- **backend**：`extern/network_backend/csg-htsim/`（git submodule，pin = `841d9e7`），自带 Makefile 编译成 `libhtsim.a`，由 CMake `add_custom_target(htsim)` 拉进来。
- **patch**：3 个文件，由 `build/astra_htsim/build.sh` 幂等 apply：
  - `htsim_astrasim.patch` (~826 行) — flow-finish hook、verbose guards、queue config
  - `htsim_eventlist.patch` (~500 行) — `EventList` multimap → vector binary heap + `ASTRASIM_HTSIM_EVENT_RESERVE`
  - `chakra_perf.patch` (~362 行) — Chakra dep_solver 紧凑邻接 + 冗余层丢弃 + `NodeId` u32

### 1.3 当前协议 / 拓扑覆盖

- **协议**：TCP（参考用）/ RoCE（默认）/ DCQCN / HPCC，4 种均通过 cycle 一致性回归。
- **拓扑**：htsim 原生 fat-tree/BCube/VL2/Star/Multihomed + 自研 `GenericCustomTopology`（吃 ASTRA-sim 的 `topology.txt`，支持 `#REGIONS` 跨 DC + 链路类型 `intra/inter_leaf/inter_spine/wan` + 不对称带宽后缀 `@<rev_bw>/<rev_lat>`）。
- **Queue discipline**：`random`（默认）/ `composite` / `lossless`（含 paired LosslessInputQueue + 单优先级 PFC）。
- **OCS**：`schedule_link_change(t, src, dst, bw, up)` 真正调 `Pipe::setDelay` / `BaseQueue::setBitrate`；可选 Dijkstra 重路由。

---

## 2. 实验清单

| 实验族 | 子目录 | NPU | 拓扑 | acceptance 状态 |
|---|---|---|---|---|
| **llama_experiment** (8) | in_dc / in_dc_dp / inter_dc / inter_dc_dp / inter_dc_dp_localsgd / inter_dc_mesh / inter_dc_ocs_mesh / inter_dc_ocs_ring | 32 | topology.txt + #REGIONS | ✅ 8/8 ratio ∈ [0.974, 1.008] |
| **qwen_experiment** (2) | in_dc / ring_ag | 16-128 | Ring YAML | ring_ag ✅；in_dc 128 跑通但 ratio 0.506（D5）|
| **megatron_gpt** (4) | gpt_39b_512(_noar) / gpt_76b_1024(_noar) | 512-1024 | YAML | gpt_39b ✅ (sharded)；gpt_76b 待硬件 |
| **llama3_70b** (4) | in_dc / inter_dc_dp / inter_dc_dp_localsgd / inter_dc_pp | 1024 | topology.txt | 待硬件（同 76b）|

每个 `_htsim/` 目录与原 `_analytical` / ns-3 实验**并列存在**，不覆盖原结果，三方对比写到 `report.md`。

---

## 3. 关键文件索引

**Frontend**
- `astra-sim/network_frontend/htsim/HTSimMain.cc` — 入口；从 `NetworkParser` 读 dims/bandwidth/topology。Custom YAML 没写 `npus_count` 时从 `topology.txt` 第一行推算。
- `HTSimSession.{cc,hh}` — `HTSimProto` 枚举分发；env var 解析。
- `HTSimNetworkApi.{cc,hh}` — 实现 `AstraNetworkAPI`。
- `topology/GenericCustomTopology.{cc,hh}` — 吃 ASTRA-sim Custom topology；BFS / Dijkstra 路由；`#REGIONS` + `link_type` + 不对称带宽；`schedule_link_change` 真正调 `setBitrate`。`max_host_linkspeed_bps()` 给 RoCE NIC 做 pacing。
- `proto/HTSimProtoTcp.{cc,hh}` — TCP（基础参考）。
- `proto/HTSimProtoRoCE.{cc,hh}` — RoCE/DCQCN/HPCC 共用入口。**routein 必须是完整反向 BFS 路径**（不是单元素 shortcut，否则 ACK 错路由）。

**Backend / patch**
- `extern/network_backend/csg-htsim/sim/eventlist.{h,cpp}` — vector binary heap + `ASTRASIM_HTSIM_EVENT_RESERVE`。
- `extern/network_backend/csg-htsim/sim/{tcp,roce,hpcc}.{cpp,h}` — flow-finish hook + verbose guards。
- `extern/graph_frontend/chakra/src/feeder_v3/dependancy_solver.{h,cpp}` — vector adjacency + `_alias_enabled_to_data`。
- `extern/graph_frontend/chakra/src/feeder_v3/common.h:8` — `using NodeId = uint32_t`。
- `astra-sim/common/Logging.cc` — `ASTRASIM_LOG_LEVEL` / `ASTRASIM_FLUSH_ON` env。

**U2 分片并行 runner**（解决单进程事件吞吐墙）
- `htsim_experiment/tools/shard_workload_pp.py` — STG `.et` PP splitter（multiprocessing）+ `--calibrate-from-analytical` 模式（§7.1）。写 `shard_stats.json`（per-shard boundary count）。
- `htsim_experiment/tools/extract_sub_topology.py` — Clos 子拓扑 BFS 抽取。
- `htsim_experiment/tools/make_pp_shard_exp.sh` — per-shard exp 目录生成（写绝对 PROJECT_DIR + 显式 `npus_count`）。
- `htsim_experiment/tools/run_pp_sharded.sh` — 通用 N-shard orchestrator。
- `htsim_experiment/tools/run_gpt_39b_512_L48_sharded.sh` — **金标准**（star + L48 + B256，~55 min parallel / ~140 min sequential）。
- `htsim_experiment/tools/run_gpt_39b_{32,64,128,256,512_star}_sharded.sh` — scale ladder。
- `htsim_experiment/tools/test_pp_sharded_runner.sh` — 8-NPU CI smoke（≤ 10s）。

**用户文档**：`htsim_experiment/docs/{htsim_user_guide.md, cross_dc_topology.md, htsim_baseline.md, status_report.md}`。

---

## 4. 构建与自检（每次接手必跑）

```bash
cd /home/ps/sow/part2/astra-sim

# (a) submodule pin + build (~2 min)
(cd extern/network_backend/csg-htsim && git rev-parse HEAD | cut -c1-7)  # 预期 841d9e7
bash build/astra_htsim/build.sh                                          # 预期 Built target AstraSim_HTSim

# (b) 三件套 smoke (~3 min)
bash utils/htsim_smoke.sh                                  # PASS 16/16, max_cycle 380204
bash htsim_experiment/tools/test_generic_topology.sh       # PASS, max_cycle 11,890,010,036
bash htsim_experiment/tools/test_pp_sharded_runner.sh      # PASS, 2 shards 4/4

# (c) llama/in_dc anchor (~70s) — 最敏感的 cycle 基准
cd llama_experiment/in_dc && bash run_htsim.sh && cd ../..
# 预期 max=136,719,260,632 ratio=1.0041（或 1.0043，byte-exact 二选一）

# (d) gpt_39b 金标准 smoke (~12s)
bash htsim_experiment/tools/run_gpt_39b_32_sharded.sh      # PASS ratio 0.9135

# (e) 完整金标准（可选，~55–140 min）
bash htsim_experiment/tools/run_gpt_39b_512_L48_sharded.sh # PASS ratio 0.9462
```

任何一步红 → 先恢复 (`git checkout -- extern/network_backend/csg-htsim/sim/` + 重 build)，**不要在红状态下加新功能**。

---

## 5. 环境变量参考

所有对外配置都通过 env var，运行期生效，无需重 build。

| 变量 | 默认 | 作用 |
|---|---|---|
| `ASTRASIM_HTSIM_QUEUE_TYPE` | `random` | `random` / `composite` / `lossless` |
| `ASTRASIM_HTSIM_PFC_HIGH_KB` / `LOW_KB` | 200 / 50 | lossless PAUSE 阈值（多向 incast 调到 50/20） |
| `ASTRASIM_HTSIM_QUEUE_BYTES` | 1 MB | 每端口 queue 大小（256 NPU 大并发改 16 MB） |
| `ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES` | 4 MB | 跨 region queue 大小 |
| `ASTRASIM_HTSIM_PACKET_BYTES` | 4096 | MTU |
| `ASTRASIM_HTSIM_NIC_GBPS` | auto | NIC pacing；用 topology max linkspeed 自动 |
| `ASTRASIM_HTSIM_NIC_WIRE_SPEED` | unset | 强制 wire-speed pacing |
| `ASTRASIM_HTSIM_ENDTIME_SEC` | 1000 | simtime 上限 |
| `ASTRASIM_HTSIM_RANDOM_SEED` | `0xA571A517` | 固定 seed（确定性回归） |
| `ASTRASIM_HTSIM_ROUTE` | `dijkstra` | 可回退 `bfs` |
| `ASTRASIM_HTSIM_OCS_SCHEDULE` | unset | `<us>:<src>:<dst>:<gbps>:<up>[,...]` |
| `ASTRASIM_HTSIM_OCS_REROUTE` | unset | OCS 事件触发 Dijkstra 重算 |
| `ASTRASIM_HTSIM_DCQCN_KMIN_KB` / `KMAX_KB` | unset | ECN 阈值 |
| `ASTRASIM_HTSIM_DCQCN_AIMD` | auto(dcqcn=1) | 启用 AIMD CC |
| `ASTRASIM_HTSIM_DCQCN_{AI_MBPS,MIN_MBPS,BYTES,G_RECIP}` | auto | DCQCN 细节 |
| `ASTRASIM_HTSIM_KMAX_MAP` / `KMIN_MAP` / `PMAX_MAP` | unset | ns-3 passthrough |
| `ASTRASIM_HTSIM_ACK_HIGH_PRIO` | unset | ns-3 passthrough |
| `ASTRASIM_HTSIM_VERBOSE` | 0 | per-flow / PFC / OCS / Clock 进度 stdout（默认关；调试设 1）|
| `ASTRASIM_HTSIM_LOGGERS` | unset | htsim sampling loggers → logout.dat |
| `ASTRASIM_HTSIM_EVENT_RESERVE` | 65536 | EventList 预分配条目数（每条 24 bytes）。**大规模必设**：50M (L48 B256)，500M (B1536) |
| `ASTRASIM_LOG_LEVEL` | `info` | spdlog 文件 sink 级别。256+ NPU 长跑设 `warn` 或 `info`，**不要设 `debug`** |
| `ASTRASIM_FLUSH_ON` | `err` | spdlog async flush 级别。**长跑必设 `info`**，否则 sys finished 全 buffer 到 shutdown 才落盘 |

---

## 6. 验收标准 (§11.6)

每个迁移成功的实验要满足：

| 指标 | 门槛 |
|---|---|
| `htsim max cycle / analytical max cycle` | ∈ [0.9, 1.5] |
| `htsim wall time / analytical wall time` | ≤ 3× |
| `exposed comm %` 差异 | < 15 percentage points |
| `TFLOPS/GPU` 推导差异 | < 10% |
| flow-finish 回调计数 | 等于 workload 声明的 send 数 |

差异主要来源（在窗口内是预期）：
- analytical congestion-aware 的流体 / 串行 chunk 模型对 ring collective 略保守 → htsim 通常偏低 5-10%。
- TCP slow start、htsim 默认 `memFromPkt(8)` buffer。

### 6.1 Acceptance 总览（关账时）

| Test | NPU | Ratio | 说明 |
|---|---|---:|---|
| utils/htsim_smoke.sh | 16 | — | ring_ag micro，cycle 380,204 |
| llama/in_dc | 16 | 1.0041 | 最敏感 anchor |
| llama/in_dc_dp | 16 | 0.974 | |
| llama/inter_dc | 16 | 1.004 | |
| llama/inter_dc_dp | 16 | 0.985 | |
| llama/inter_dc_dp_localsgd | 16 | 0.999 | |
| llama/inter_dc_mesh | 16 | 1.008 | vs ns-3 |
| llama/inter_dc_ocs_mesh | 16 | 1.008 | vs ns-3 |
| llama/inter_dc_ocs_ring | 16 | 1.008 | vs ns-3 |
| gpt_39b_32 (PP=2) | 32 | **0.9135** | sharded smoke |
| gpt_39b_64 / 128 / 256 / 512_star (L4) | 64-512 | 0.92-0.93 | scale ladder，PASS |
| **🏆 gpt_39b_512_L48 B256 ar=1** | **512** | **0.9462** | **金标准，3 次 byte-exact 重现** |
| gpt_39b_512_L48 B256 ar=0 | 512 | 0.4851 | infra PASS，ratio 不达（D2）|
| qwen/in_dc | 128 | **0.9043** | ✅ PASS（M1 幽灵 bug：旧 0.506 用了失败 analytical run 当分母）|
| gpt_39b_512_L48 B1536 (arxiv) | 512 | DNF | OOM @ 30 GiB（U12/D1）|
| gpt_76b_1024 / llama3_70b 四变体 | 1024 | DNF | OOM @ 30 GiB（U12）|

**所有 cycle 数字 byte-exact 跨 §22 / §23 / §24 / 三次重现**——`ASTRASIM_HTSIM_RANDOM_SEED` 固定，所有优化都通过了 zero-regression 验证。

---

## 7. U2 分片并行 runner（核心机制说明）

**问题**：htsim 单线程 DES ~10⁶ event/s wall；Megatron 一次 iteration 10⁷⁺ event。1024 NPU 单进程吞吐墙。

**解法**：按 PP stage 切 workload。`gpt_39b_512` PP=2 分两 shard，`gpt_76b_1024` 同理 PP=2。

**实现要点**：
1. **`shard_workload_pp.py`**：读 STG `.et`，按 `rank // (DP*TP)` 切 PP 片，shard 内 rank ID renumber 到 `[0..stage_size)`。
2. **跨 shard 边界处理**：每条 `COMM_SEND/COMM_RECV_NODE` 若对端在 shard 外，转 `COMP_NODE`，`num_ops = boundary_latency_us × peak_tflops`（默认 25 µs × 312 TFLOPS = 7.8 G ops）。
3. **关键坑（T4 / D2）**：boundary `COMP_NODE` 的 `tensor_size` 必须 > 0。Workload.cc::issue_comp 对 `tensor_size==0` 走 `skip_invalid` 分支，不触发 `issue_dep_free_nodes()`，shard stage > 0（一上来就 RECV）整个 DAG 挂死 tick=0。splitter 写 `tensor_size = max(1, num_ops/1024)`。**不要改回 0**。
4. **`workload.json`** 只保留 ranks 全在 shard 内的 comm_groups。
5. **拓扑**：`extract_sub_topology.py` 做 reachability BFS 抽 sub-Clos；金标准实测改用 **flat star（N-host + 1 switch）**，因为 Clos 97-switch 在 256 rank 下 DES 推不动（T7 / O2）。
6. **合并**：`combined_max_cycle = max_over_shards(max_cycle)`。对纯 PP pipeline + microbatches >> PP 时 bubble < 5%，落在 [0.9, 1.5] 窗口内可接受（gpt_39b 24 MBatches / PP=2 → bubble ~8%）。

**8-NPU smoke** (`test_pp_sharded_runner.sh`) 必须每次改 splitter/runner 后 PASS（≤ 10s）。

### 7.1 Boundary-latency 自动校准（D2 解决方案）

splitter 写入 `shard_stats.json`（per-shard boundary count + 当前 `boundary_latency_us`）。
事后拿 analytical 参考 run 和 htsim run.csv 反推下一轮的 boundary_us：

```bash
# Step 1: 首轮分片 + 跑
python htsim_experiment/tools/shard_workload_pp.py \
    --workload-dir <stg> --out-dir <shards> --pp 2 --dp 4 --tp 2 \
    --boundary-latency-us 25
bash htsim_experiment/tools/run_pp_sharded.sh ...  # 产 run.csv

# Step 2: 拿同 workload 的 analytical 参考日志，反推建议值
python htsim_experiment/tools/shard_workload_pp.py \
    --calibrate-from-analytical <analytical.log> \
    --htsim-run-csv <shards>/run.csv \
    --stats-in <shards>/shard_stats.json
# → "suggested --boundary-latency-us = XXX.XXX"

# Step 3: 用建议值重跑
```

模型：`htsim = static + N_boundary × boundary_ns`；`static = htsim_cycle - N_boundary × current_ns`；
`suggested_ns = (analytical - static) / N_boundary`。如 ratio 已在 [0.9, 1.5]，脚本会告知无需重跑。

---

## 8. 性能与内存优化总结

### 8.1 已落地（patch 自动 apply）

| 优化 | Patch | 对小规模收益 | 对大规模收益 |
|---|---|---|---|
| EventList multimap → vector binary heap | `htsim_eventlist.patch` | wall -5–30% | -19% wall（D8 修复后）|
| EventList 预分配 capacity (`EVENT_RESERVE`) | 同上 | 默认 65k 不变 | 避免 2× doubling 的 reallocation transient peak |
| Chakra dep_solver `unordered_set` → `vector` 邻接 | `chakra_perf.patch` | RSS -46% | -1–1.5 GB（dep_graph 部分）|
| Chakra ctrl/enabled 冗余层丢弃（STG 无 ctrl_edges 时 alias enabled→data） | 同上 | RSS 累计 -57% | 同上 |
| `NodeId` uint64 → uint32 | 同上 | 中性 / 轻微 cache 改善 | parallel peak RSS 几乎无变化（实测，D8 后内存主导项是 event queue + RoCE per-flow state） |

**实测**：llama/in_dc 16-NPU **980 MB → 418 MB (-57%)**，wall 98s → 70s。

### 8.2 大规模内存模型（§24.4）

每 packet 在 htsim 产生 4+ events（NIC pace / pipe / queue dequeue / ack），加 PFC 重传 / pause。

```
pending_events ≈ N_hosts × N_microbatches × N_concurrent_flows × N_packets_per_flow × 4
```

| Workload | events 估算 | queue mem | + per-flow state | 总 RSS 实测 |
|---|---|---|---|---|
| llama/in_dc 16-NPU | ~100K | 2 MB | ~200 MB | **418 MB** ✓ |
| gpt_39b L48 B256 / shard | ~8 M | 200 MB | ~2 GB | **~14 GB / shard** ✓ |
| gpt_39b L48 **B1536** / shard | ~50 M | 1.2 GB | ~12 GB | **~25 GB ❌ OOM** |

**结论**：现行优化解决了 init-time dep_graph 内存（小规模 -57%），但 **runtime DES event queue 是大规模主要内存来源**——这只能靠 packet coalescing / multi-thread eventlist（研究级）或更大 RAM 解决。

### 8.3 tcmalloc（已链入 build）

`AstraSim_HTSim` 默认在 link 时吃 `libtcmalloc_minimal.so.4`（通过
`astra-sim/network_frontend/htsim/CMakeLists.txt` 的 `find_file` 自动定位，
不存在时 fallback glibc malloc）。预期 wall +5–15%，对 RSS 无收益。
`-DASTRASIM_HTSIM_TCMALLOC=OFF` 可关闭。

```bash
# 验证
ldd build/astra_htsim/build/bin/AstraSim_HTSim | grep tcmalloc
# → libtcmalloc_minimal.so.4 => /lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4
```

---

## 9. 已知问题与陷阱清单

| # | 问题 | Workaround / Fix |
|---|---|---|
| **D1** | htsim DES event queue 无上限增长 | 大规模需更大 RAM 或 packet coalescing（研究级）|
| **D2** | PP splitter `boundary_latency_us` 固定 25 µs | ✅ `shard_workload_pp.py --calibrate-from-analytical` 已落地（§7.1）|
| **D3** | `timeout N bash ...` SIGHUP 连锁杀子 | 用 `setsid nohup ... </dev/null &` 隔离进程组 |
| **D4** | Monitor 的 `pgrep -f pattern` 误匹配旧进程 | 仓库内无此代码（仅指未来 Claude Monitor 调用指南）；用 `kill -0 $PID` |
| **D5** | ~~qwen/in_dc 128 ratio 0.506~~ | ✅ **幽灵 bug**：旧分母取自 failed analytical (exit 2, 64/128)；128/128 完整 baseline 13.45G → 真实 ratio 0.9043 PASS |
| **D6** | `tee` buffer 满时 stdout block | `stdbuf -oL` 或 `--output-buffer=line` |
| **D7** | OOM-borderline 时手动 kill shard 浪费 wall | 待写 memory-aware auto-sequential runner |
| **D8** | event-list vector capacity 2× doubling 大规模 RSS 峰 | ✅ 已修（`ASTRASIM_HTSIM_EVENT_RESERVE`）|
| **T1** | 长跑 `run_htsim.log` 字节不动看似挂了 | 必设 `ASTRASIM_FLUSH_ON=info` |
| **T2** | `rotating_file_sink` debug 级日志拖死 DES | 必设 `ASTRASIM_LOG_LEVEL=info`（或 warn）|
| **T3** | "LOSSLESS not working" 2M 行/10s | `QUEUE_BYTES=16777216` + `PFC_HIGH_KB=50`，或拓扑选 star |
| **T4** | splitter boundary `tensor_size=0` → DAG tick=0 挂死 | 已修：`tensor_size = max(1, num_ops/1024)`，**勿改回**|
| **T5** | `HTSimProtoRoCE.cc:74` 断言 `npus_count == topology.host_count` | `make_pp_shard_exp.sh` 写显式 `npus_count: [<shard_size>]` |
| **T6** | shard `run_htsim.sh` 用 `SCRIPT_DIR/../..` 解析 PROJECT_DIR | 已修：烧死绝对路径 |
| **T7** | Clos 97-switch 在 256 rank DES 推不动 | star 拓扑替代；Clos 留待 GPU DES |
| **T8** | STG `OUTPUT_DIR` 命名不含 DP/TP/PP | 切 rank 数前手动 `rm -r <old dir>` |
| **T9** | `/tmp/shard_*` 缓存污染新 run | 切 workload 时先 `rm -r /tmp/shard_*` |
| **T11** | L48 ratio 0.94 vs L4 0.92-0.93 偏高（boundary 估低） | 研究级，同 D2 校准方案 |
| **T12** | `pgrep -f AstraSim_HTSim` self-match | 用 `pgrep -x AstraSim_HTSim` |

**硬约束**：
- **不要** parallel 跑 L48 B256 两 shard（30 GiB 机器 combined RSS 26 GB，90% OOM）。默认 sequential。
- **不要** 在 30 GiB RAM 跑 B1536 / gpt_76b_1024 / llama3_70b 1024。需 ≥ 64 GiB RAM。
- **不要** 裸升 htsim submodule（pin = `841d9e7`）。升级走 `build/astra_htsim/UPSTREAM_NOTES.md` 流程。
- **不要** 改 patch 以外的 htsim 源文件（build.sh 会重 apply 覆盖）。改源就同步更新对应 patch。
- **不要** 假设 analytical = ground truth：两者内在差 5-10%（htsim 偏低），§11.6 [0.9, 1.5] 窗口正基于此。

---

## 10. 未完成工作（按 ROI 排）

**P0 — 验收已过，无 P0**。`gpt_39b` 金标准 3 次 byte-exact 重现。

**P1 — 1 小时级快胜**

| # | 任务 | 状态 |
|---|---|---|
| M1 | ~~qwen/in_dc 128 ratio 0.506~~ | ✅ 关闭：真实 ratio 0.9043（D5 幽灵 bug）|
| D4 | Monitor PID 精确匹配 | ✅ 关闭：仓库无 `pgrep -f` 代码，只是给 Claude Monitor 调用指南 |

**P2 — 0.5 天级**

| # | 任务 | 状态 |
|---|---|---|
| D2 | PP boundary-latency 自动校准 | ✅ `shard_workload_pp.py --calibrate-from-analytical` 已落地 |
| S2 | tcmalloc 链入 build | ✅ CMake 自动链 `libtcmalloc_minimal.so.4`（§8.3）|
| S1 | LTO 修复 | ⚠️ 根因锁定：`CMakeLists.txt:27` 的 `option(SPDLOG_FMT_EXTERNAL ON)` 是 no-op (option 第二参是 help_text)；但强打开 SPDLOG_FMT_EXTERNAL 后发现 `extern/helper/fmt` 与 `spdlog/fmt/bundled` 头文件点版本不一致（base.h 2932 vs 3077 行），外部 fmt 缺 `basic_format_string`。真修需重做 vendoring（复制 bundled 到外部 + 适配 format-inl），1+ 天；降级 P3 |

**P3 — 1-2 周研究级**

| # | 任务 | 动机 |
|---|---|---|
| S1 | 统一 fmt vendoring 以解锁 LTO | 复制 `spdlog/fmt/bundled` 到 `extern/helper/fmt` + 重做 format-inl 源文件，让一处 fmt 同时服务静态库 / spdlog；完成后可开 -flto 赢 +10–15% wall |
| S3 | htsim packet coalescing | 解锁 B1536 / gpt_76b_1024 内存（D1 根因）|
| S4 | Multi-thread eventlist | 根除单线程 DES 吞吐墙 |
| S5 | OpenMP per-NPU workload replay | system 层并行，network 仍单线程，预期 1.2-1.5× |
| O3 | gpt_76b_1024 真 1024 NPU acceptance | 需 ≥ 64 GB RAM + S3 |

**P4 — 硬件阻塞（无代码出路）**
- O1 `gpt_39b_512 B1536`（arxiv exact）：30 GB 不够，需 ≥ 64 GB。
- O3 `gpt_76b_1024` / O4 `llama3_70b` 1024：同上 + S3。
- O7 多优先级 PFC（htsim 核心需 per-class queue state 重构，不阻塞 acceptance）。
- O9 OCS 调度器策略本体（mutator + reroute API 已备）。

---

## 11. 历史 session 时间线（详见 `*.md.bak`）

| Session | 关键产出 |
|---|---|
| 2026-04-22 | Phase 0/0.5/1/1.5/4 拉起；submodule 升 → `841d9e7`；`GenericCustomTopology`；ring_ag smoke PASS |
| 2026-04-22 下午 | QueueLoggerEmpty 无限循环修复；`srand(time(NULL))` 非确定性消除；NIC pacing；llama/in_dc 16-NPU 首过 §11.6 (1.004×) |
| 2026-04-22 evening | LosslessOutputQueue + PFC + WAN 不对称 → 8 个 inter_dc 实验解锁；§11.6 PASS 数 1 → 9 |
| 2026-04-22 late-evening | DCQCN/HPCC/OCS mutator + reroute；ns-3 config 转换工具 |
| 2026-04-22 night | DCQCN AIMD；OCS route recalc；P4/P5/U3 技术债清算 |
| 2026-04-22 night-2 | **U2 分片并行 runner** 落地（4h，绕开 STG splitter 1-2 周）|
| 2026-04-22/23 night-3 | gpt_39b 完整 scale ladder 7/7 PASS；金标准 L48 B256 ratio 0.9462 |
| 2026-04-23 | EventList binary heap + Chakra 紧凑邻接 → RSS -57%；9 × 16-NPU 字节一致 |
| 2026-04-23 下午 | O1 (B1536) 内存根因；O5 (qwen 128) infra PASS；O6 (noar) infra PASS / ratio 不达 |
| 2026-04-23 晚 | D8 (`EVENT_RESERVE`) + M2 (`NodeId u32`)；金标准 3 次 byte-exact re-verify |

完整逐 session 演化记录见 `htsim_migration_plan.md.bak`（3304 行）。

---

## 12. 一句话总结

> 用户要求的 `gpt_39b` 已 PASS（ratio 0.9462，3 次 byte-exact 重现）。所有剩余项要么硬件阻塞（B1536 / 76b_1024 需 ≥ 64 GiB RAM），要么研究级（packet coalescing / multi-thread DES），要么 0.5–2 天级小任务可下次单独推进。当前代码 base 健康，从 §4 三件套自检即可接手。
