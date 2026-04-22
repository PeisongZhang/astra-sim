# ASTRA-sim × htsim 后端 —— 完整使用说明书

> 面向从零开始的使用者。读完这一篇就能独立构建、跑实验、做 §11.6 验收、扩展新实验。
> 深度背景、决策历史、未完成项见 `../../htsim_migration_plan.md`（§22 是权威快照）。
> 细节对照：`htsim_user_guide.md`（环境变量表）、`cross_dc_topology.md`（跨 DC 拓扑扩展）、`sharded_parallel_design.md`（U2 分片并行设计）。

---

## 1. 迁移计划完成了什么

### 1.1 覆盖范围

| 类别 | 已交付 |
|---|---|
| 后端前端代码 | `astra-sim/network_frontend/htsim/` 下 TCP / RoCE / DCQCN / HPCC 四种协议 + `GenericCustomTopology` 通用拓扑 + 跨 DC / WAN 不对称 / GatewayQueue 扩展 |
| 上游适配 | submodule pin 在 `841d9e7`；`build/astra_htsim/htsim_astrasim.patch`（826 行 / 14 文件）加 flow-finish 回调 / 确定性 seed / OCS setter / 向量化 INT / AIMD CC |
| 构建系统 | `build/astra_htsim/build.sh`（幂等 patch + cmake + make，< 2 min 全量） |
| 实验目录 | 18 个 `*_htsim/`，与原 analytical / ns-3 实验并排放（见 §3.3） |
| 批量 runner | `htsim_experiment/run_all_htsim.sh`（产出 3-backend CSV 对比） |
| 分片并行 | `htsim_experiment/tools/shard_workload_pp.py` + `run_pp_sharded.sh` + 若干一键验收脚本 |
| 回归与 CI | `utils/htsim_smoke.sh` + `htsim_experiment/tools/test_*.sh` 共 10+ 个集成测试 |
| 文档 | `htsim_experiment/docs/` 下 5 份文档（基线、用户手册、跨 DC、分片设计、本说明书） + 顶层 `htsim_migration_plan.md`（计划 + 全部 session 交班记录） |

### 1.2 §11.6 验收现状

| Test | NPU | 协议 | Ratio (htsim / baseline) | 门槛 [0.9, 1.5] |
|---|---|---|---|---|
| qwen/ring_ag (smoke) | 16 | RoCE | — | ✅ |
| llama/in_dc | 16 | RoCE / DCQCN / HPCC | 1.004 / 1.004 / 0.996 | ✅ |
| llama/in_dc_dp | 16 | RoCE | 0.974 | ✅ |
| llama/inter_dc | 16 | RoCE | 1.004 | ✅ |
| llama/inter_dc_dp | 16 | RoCE | 0.985 | ✅ |
| llama/inter_dc_dp_localsgd | 16 | RoCE | 0.999 | ✅ |
| llama/inter_dc_mesh (vs ns-3) | 16 | RoCE | 1.008 | ✅ |
| llama/inter_dc_ocs_mesh (vs ns-3) | 16 | RoCE | 1.008 | ✅ |
| llama/inter_dc_ocs_ring (vs ns-3) | 16 | RoCE | 1.008 | ✅ |
| **megatron_gpt_39b @ 512（产线 LAYER=48）** | **512** | **RoCE 分片 PP=2** | **0.946** | **✅（金标准）** |
| megatron_gpt_39b 家族 scale ladder @ {32,64,128,256,512,L48-32} | — | RoCE 分片 | 0.91–0.95 | ✅ |

**阻塞点（与本工程正确性无关）**：

- `gpt_39b @ BATCH=1536`（arxiv 原始口径 24 个 microbatch）需要 ≥ 64 GiB RAM，当前 30 GiB 机器 OOM。
- `gpt_76b_1024` / `llama3_70b` 1024 NPU 实验同样受 RAM 限制（U12）。
- `qwen/in_dc (128)` 在原始 Clos 拓扑下事件吞吐仍有压力，可按 §3.5 的"flat-star 降压"思路重跑。

### 1.3 仍未完成的事项

- **U2 full**：分片并行 runner 目前依赖 PP 切分；若需沿 DP / TP 切还要扩 STG。
- **U5 multi**：PFC 多优先级（`EthPausePacket::_pausedClass`）。单优先级已就绪。
- **U9 map 消费**：`KMAX_MAP` / `KMIN_MAP` 目前仅 passthrough，CompositeQueue 用单值阈值。
- **OCS 调度器本体**：mutator + reroute API 就位，具体 OCS 策略留给下游 MoE-OCS。
- **U12**：≥64 GiB RAM 硬件（外部依赖）。

---

## 2. 环境准备

### 2.1 依赖

- Linux（本工程在 Ubuntu 22.04 / kernel 5.15 上测过）。
- C++17 工具链（g++ ≥ 11，make，cmake ≥ 3.15）。
- Python 3.10 + venv（分片并行 runner 读写 Chakra protobuf 用）。
- ≥ 30 GiB RAM（小规模实验）；≥ 64 GiB RAM（1024-NPU / BATCH=1536 实验）。

### 2.2 Python venv

仓库统一使用 `/home/ps/sow/part2/astra-sim/.venv`。分片并行脚本里已写成绝对路径，无需提前 activate。如需单独跑辅助脚本：

```bash
source /home/ps/sow/part2/astra-sim/.venv/bin/activate
# 或者直接用解释器
/home/ps/sow/part2/astra-sim/.venv/bin/python <script.py>
```

### 2.3 submodule pin

```bash
cd /home/ps/sow/part2/astra-sim/extern/network_backend/csg-htsim
git rev-parse HEAD | head -c 7     # 预期 841d9e7
git status --short | wc -l         # 预期 14（build.sh 幂等 apply 的 patch 改动）
```

> **切勿**裸升级 submodule。14 个文件的 patch 与 pin 强绑定，升级须按 `build/astra_htsim/UPSTREAM_NOTES.md` 的流程走。

---

## 3. 构建与快速验证

### 3.1 构建

```bash
cd /home/ps/sow/part2/astra-sim
bash build/astra_htsim/build.sh          # 幂等 apply patch → cmake → make（< 2 min）
bash build/astra_htsim/build.sh -d       # debug build（-O0 -g）
bash build/astra_htsim/build.sh -l       # clean：删 build/ + 生成的 et_def.pb.*
```

产物：`build/astra_htsim/build/bin/AstraSim_HTSim`。

若 patch re-apply 失败（"previously applied / hunk failed"），先恢复 submodule 再重跑：

```bash
cd extern/network_backend/csg-htsim
git checkout -- sim/
cd ../../..
bash build/astra_htsim/build.sh
```

### 3.2 自检三件套（< 10 秒）

```bash
bash utils/htsim_smoke.sh                              # 16 NPU ring all-gather，<1s，16/16 PASS
bash htsim_experiment/tools/test_generic_topology.sh   # Generic topology + Custom topology.txt，<3s
bash htsim_experiment/tools/test_pp_sharded_runner.sh  # 8 NPU PP=2 分片并行骨架，<10s
```

### 3.3 §11.6 完整回归（~20 分钟）

9 个 16-NPU 实验串行跑，验证 cycle ratio 稳定在历史基线附近：

```bash
cd /home/ps/sow/part2/astra-sim
for v in in_dc in_dc_dp inter_dc inter_dc_dp inter_dc_dp_localsgd \
         inter_dc_mesh inter_dc_ocs_mesh inter_dc_ocs_ring; do
  rm -rf llama_experiment/${v}_htsim/log llama_experiment/${v}_htsim/run_htsim.log
  ASTRASIM_HTSIM_QUEUE_TYPE=lossless \
  ASTRASIM_HTSIM_ENDTIME_SEC=400 \
    timeout 600 bash llama_experiment/${v}_htsim/run_htsim.sh > /dev/null 2>&1
  echo "$v: $(grep -cE 'sys\[[0-9]+\] finished' llama_experiment/${v}_htsim/run_htsim.log)/16"
done
# 每行预期 16/16
```

### 3.4 金标准一键（~55 分钟）

```bash
bash htsim_experiment/tools/run_gpt_39b_512_L48_sharded.sh
# 预期：PASS，ratio ≈ 0.946（analytical 1,766,050,780 vs htsim 1,670,989,399）
```

### 3.5 金标准 smoke（~10 秒）

```bash
bash htsim_experiment/tools/run_gpt_39b_32_sharded.sh
# 预期：PASS，ratio ≈ 0.914
```

---

## 4. 一次 htsim 仿真的命令行

htsim 后端复用 ASTRA-sim 统一 CLI，**不需要为 htsim 单独写配置文件**：

```bash
/home/ps/sow/part2/astra-sim/build/astra_htsim/build/bin/AstraSim_HTSim \
  --workload-configuration=<workload dir>/workload \
  --comm-group-configuration=<workload dir>/workload.json \
  --system-configuration=<exp>/astra_system.json \
  --remote-memory-configuration=<exp>/no_memory_expansion.json \
  --network-configuration=<exp>/analytical_network.yml \
  --htsim-proto=roce
```

参数说明：

| 参数 | 作用 |
|---|---|
| `--workload-configuration` | STG 产出的 `workload.%d.et` 文件的路径前缀（**不带 .et 后缀**）。 |
| `--comm-group-configuration` | 同目录下 `workload.json`，或字符串 `empty`。 |
| `--system-configuration` | `astra_system.json`，和 analytical / ns-3 后端**完全相同**。 |
| `--remote-memory-configuration` | `no_memory_expansion.json`，通常照搬模板。 |
| `--network-configuration` | `analytical_network.yml`。若 `topology: [Custom]`，htsim 会走 `GenericCustomTopology` 吃 `topology.txt`；若写死 FatTree / Ring，则走 htsim 原生对等拓扑。 |
| `--htsim-proto` | `tcp` / `roce` / `dcqcn` / `hpcc`。**推荐默认 `roce`**（§11.6 全部基于 RoCE 达标）。 |

**运行时协议 / 队列 / 拓扑行为由环境变量微调**，见 §7 和 `htsim_user_guide.md`。

---

## 5. 用现成的 `*_htsim/` 实验

每个 `*_htsim/` 目录都是一个自包含实验：

```
<family>_experiment/<subexp>_htsim/
├── analytical_network.yml   # Custom topology，指向下一行
├── topology.txt             # 拓扑定义（ASTRA-sim Custom 格式，可含 #REGIONS 跨 DC 扩展）
├── astra_system.json        # 与原 analytical 实验一致
├── logical_topo.json        # logical dim 定义
├── no_memory_expansion.json # 远端内存禁用
└── run_htsim.sh             # 一键脚本
```

典型运行：

```bash
cd /home/ps/sow/part2/astra-sim
# (可选) 环境变量微调
export ASTRASIM_HTSIM_QUEUE_TYPE=lossless   # 推荐：N-way incast 必开
export ASTRASIM_HTSIM_ENDTIME_SEC=400

# 直接运行（run_htsim.sh 内含绝对路径，可从任意 cwd 启）
bash llama_experiment/in_dc_htsim/run_htsim.sh

# 结果落在 run_htsim.log
grep -E "sys\[[0-9]+\] finished" llama_experiment/in_dc_htsim/run_htsim.log | tail
```

每个 `run_htsim.sh` 都接受以下环境变量覆盖：

- `WORKLOAD_DIR`：替换默认 workload（默认指向 `dnn_workload/<model>/<flavor>`）。
- `HTSIM_PROTO`：默认 `roce`，可设 `tcp` / `dcqcn` / `hpcc`。
- `ASTRASIM_HTSIM_ENDTIME_SEC`：默认 1000 秒 simtime。

### 5.1 18 个实验清单

| Family | 子目录 | NPU | 状态 |
|---|---|---|---|
| qwen | `qwen_experiment/ring_ag_htsim` | 16 | ✅ smoke |
| | `qwen_experiment/in_dc_htsim` | 128 | ⏸ U2（单线程 DES 吞吐） |
| llama | `llama_experiment/in_dc_htsim` | 16 | ✅ 1.004 |
| | `llama_experiment/in_dc_dp_htsim` | 16 | ✅ 0.974 |
| | `llama_experiment/inter_dc_htsim` | 16 | ✅ 1.004 |
| | `llama_experiment/inter_dc_dp_htsim` | 16 | ✅ 0.985 |
| | `llama_experiment/inter_dc_dp_localsgd_htsim` | 16 | ✅ 0.999 |
| | `llama_experiment/inter_dc_mesh_htsim` | 16 | ✅ 1.008 vs ns-3 |
| | `llama_experiment/inter_dc_ocs_mesh_htsim` | 16 | ✅ 1.008 vs ns-3 |
| | `llama_experiment/inter_dc_ocs_ring_htsim` | 16 | ✅ 1.008 vs ns-3 |
| megatron_gpt | `gpt_39b_512_htsim` | 512 | ⏸ 直跑 U2 阻塞；分片 PASS |
| | `gpt_39b_512_noar_htsim` | 512 | ⏸ 同上 |
| | `gpt_76b_1024_htsim` | 1024 | ⏸ U2 + U12 |
| | `gpt_76b_1024_noar_htsim` | 1024 | ⏸ U2 + U12 |
| llama3_70b | `in_dc_htsim` / `inter_dc_dp_htsim` / `inter_dc_dp_localsgd_htsim` / `inter_dc_pp_htsim` | 1024 | ⏸ U2 + U12 |

---

## 6. 协议与拓扑特性

### 6.1 协议选项（`--htsim-proto=`）

| 值 | 说明 | 推荐用途 |
|---|---|---|
| `tcp` | htsim `TcpSrc` / `TcpSink`，Reno + slow start。Multipath 已 bypass（固定 1 subflow）。 | 对照组 / 历史兼容 |
| `roce` | Minimal RoCE v2（默认）。auto NIC pacing、固定 seed、flow-finish 回调。 | **§11.6 默认** |
| `dcqcn` | RoCE + CompositeQueue ECN 标记 + AIMD CWND（真 DCQCN，SIGCOMM'15 简化版）。自动把 queue type 切到 `composite`。 | 拥塞控制研究 |
| `hpcc` | 原生 HPCC（INT 由 `LosslessOutputQueue` 注入）；强制 `queue_type=lossless`。 | 论文复现 / HPCC 对比 |

DCQCN 可细调：`ASTRASIM_HTSIM_DCQCN_{KMIN_KB,KMAX_KB,AI_MBPS,MIN_MBPS,BYTES,G_RECIP}`。

### 6.2 Queue 规则（`ASTRASIM_HTSIM_QUEUE_TYPE=`）

| 值 | 说明 | 场景 |
|---|---|---|
| `random`（默认） | `RandomQueue`，丢包 + RoCE RTO 重传。**大规模多并发场景下易退化**，仅做兼容基线。 | 向后兼容 |
| `composite` | `CompositeQueue`，ECN + 公平丢包。 | DCQCN 研究（通常 `--htsim-proto=dcqcn` 会自动切过来） |
| `lossless` | `LosslessOutputQueue` + 配对 `LosslessInputQueue`，**PFC 单优先级无损**。 | **推荐生产**：N-way incast、跨 DC、1024 NPU 必开 |

PFC 阈值：`ASTRASIM_HTSIM_PFC_HIGH_KB` / `LOW_KB`（默认 200 / 50 KB）。对 N > 5 并发 incast 把 `HIGH_KB` 降到 50 避免 "LOSSLESS not working"。

### 6.3 拓扑输入格式

#### 6.3.1 ASTRA-sim Custom `topology.txt`

```
<num_nodes> <num_switches> <num_links>
<switch_id_0> <switch_id_1> ...

<src> <dst> <bw> <lat> <err> [link_type] [@<rev_bw>/<rev_lat>]
```

- 第一行：节点总数 / 交换机数 / 链路数。
- 第二行：交换机 node IDs。
- 其余行：每条双向链路的带宽 / 时延 / 误码率，最后两个可选字段：
  - `link_type ∈ {intra, inter_leaf, inter_spine, wan}`（默认 `intra`）。
  - `@<rev_bw>/<rev_lat>`：显式不对称反向带宽 / 时延（WAN 专用）。

#### 6.3.2 跨 DC 扩展（`#REGIONS`）

```
#REGIONS <num_regions>
<node_id> <region_id> <node_id> <region_id> ...
```

- 空格分隔的 (node_id, region_id) 对，可跨多行。
- 未列出的节点默认 region 0。
- 跨 region 链路自动走 `GatewayQueue`（buffer 大小由 `ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES` 控制，默认 4× `QUEUE_BYTES`）。

完整示例见 `cross_dc_topology.md`。

#### 6.3.3 路由

默认 Dijkstra（边权 = 1 / bw_Gbps，偏好高带宽路径）。回退：`ASTRASIM_HTSIM_ROUTE=bfs`（纯跳数）。

### 6.4 OCS 运行期拓扑重构

```bash
# 在 10 ms 时把 src=0 ↔ dst=1 的带宽切到 100 Gbps，开启状态
export ASTRASIM_HTSIM_OCS_SCHEDULE="10000:0:1:100:1"

# 多条事件用逗号分隔
export ASTRASIM_HTSIM_OCS_SCHEDULE="10000:0:1:100:1,20000:0:1:0:0"

# 叠加：带宽变化时重算 Dijkstra（新 flow 会避开低带宽链路，旧 Route 保活到完成）
export ASTRASIM_HTSIM_OCS_REROUTE=1
```

格式 `<at_us>:<src>:<dst>:<bw_gbps>:<up>`，`up=1` 表上线、`0` 表下线。底层调用 `GenericCustomTopology::schedule_link_change`，在事件时刻真正改写 htsim `Queue::_bitrate` + `Pipe::_delay`。

---

## 7. 完整环境变量表

详表在 `htsim_user_guide.md`。速查：

| 变量 | 默认 | 何时改 |
|---|---|---|
| `ASTRASIM_HTSIM_QUEUE_TYPE` | `random` | **生产必设 `lossless`** |
| `ASTRASIM_HTSIM_QUEUE_BYTES` | 1 MB | N>5 incast 时扩到 16 MB |
| `ASTRASIM_HTSIM_PFC_HIGH_KB` / `LOW_KB` | 200 / 50 | N-way 大 incast 降到 50 / 20 |
| `ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES` | 4 MB | 跨 region / WAN burst 大的场景放大 |
| `ASTRASIM_HTSIM_ENDTIME_SEC` | 1000 | 长 workload 扩到 5000；smoke 压到 200 |
| `ASTRASIM_HTSIM_PACKET_BYTES` | 4096 | 一般不动 |
| `ASTRASIM_HTSIM_NIC_GBPS` | auto | 手工压低注入速率时用 |
| `ASTRASIM_HTSIM_NIC_WIRE_SPEED` | unset | **仅 debug**；异构 fabric 开了会炸 |
| `ASTRASIM_HTSIM_ROUTE` | `dijkstra` | 回退跳数路由 |
| `ASTRASIM_HTSIM_RANDOM_SEED` | `0xA571A517` | 排查 seed 敏感性 |
| `ASTRASIM_HTSIM_OCS_SCHEDULE` | unset | OCS / 链路故障注入 |
| `ASTRASIM_HTSIM_OCS_REROUTE` | unset | OCS 事件后需要路由重选 |
| `ASTRASIM_HTSIM_DCQCN_KMIN_KB` / `KMAX_KB` | unset | DCQCN ECN 阈值 |
| `ASTRASIM_HTSIM_DCQCN_AIMD` | auto | `--htsim-proto=dcqcn` 时自动开 |
| `ASTRASIM_HTSIM_VERBOSE` | unset | 调试时 per-flow 日志 |
| `ASTRASIM_HTSIM_LOGGERS` | unset | 打开 htsim sampling loggers（`logout.dat`） |
| **`ASTRASIM_LOG_LEVEL`** | `debug` | **长跑必设 `info` 或 `off`**，否则 debug 日志压死 DES |
| **`ASTRASIM_FLUSH_ON`** | `err` | **长跑必设 `info`**，否则 spdlog buffer 到退出才落盘（像挂了） |

---

## 8. 分片并行 runner（U2）

### 8.1 什么时候需要

- 单机 htsim 是**单线程** DES，事件吞吐约 10⁶ / 秒；
- ≥ 128 NPU 的 Megatron 级 workload 一次 iteration 即 10⁷⁺ events；
- 直接跑会数小时不出结果。

解法：按 PP 维度把 workload 切成 N 份，起 N 个 htsim 子进程并行，合并 max cycle。

### 8.2 一键接口

每个 `run_gpt_39b_*_sharded.sh` 都烧死了一组 (LAYER, DP, TP, PP, BATCH, MICROBATCH) 并选好了拓扑和协议：

```bash
# 10 秒 smoke
bash htsim_experiment/tools/run_gpt_39b_32_sharded.sh

# 产线 L48 @ 512 NPU 金标准（~55 分钟）
bash htsim_experiment/tools/run_gpt_39b_512_L48_sharded.sh

# Scale ladder
bash htsim_experiment/tools/run_gpt_39b_512_star_sharded.sh   # L4 @ 512
```

产物写到 `htsim_experiment/<name>_sharded/`：

```
<name>_sharded/
├── shard_0_exp/          # 子进程工作目录
│   ├── analytical_network.yml
│   ├── astra_system.json
│   ├── topology.txt
│   ├── run_htsim.sh
│   ├── run_htsim.log
│   └── runner.log
├── shard_1_exp/
└── run.csv               # shard_id,max_cycle,finished,wall_sec,rc
```

> `*_sharded/` 目录整个都是运行产物（已在 `.gitignore`），可随时删除重跑。

### 8.3 通用接口（任意 workload）

```bash
bash htsim_experiment/tools/run_pp_sharded.sh \
  --base-exp  llama_experiment/in_dc_htsim \
  --workload-dir /path/to/stg_output_dir \
  --pp 2 --dp 32 --tp 8 \
  --out-dir htsim_experiment/my_sharded \
  --queue lossless --proto roce --endtime 300
```

内部流程：

1. `shard_workload_pp.py` 读原始 `workload.*.et`，按 `rank // (DP*TP)` 分 PP 片；跨片 `COMM_SEND/RECV` 改写为等价 `COMP_NODE`（保持 DAG 依赖，等价延迟默认 25 µs × peak TFLOPS）。
2. `extract_sub_topology.py`（可选，Clos 分片时用）从原 topology.txt 抽 N 个 host 的子拓扑。
3. `make_pp_shard_exp.sh` 为每个 shard 生成独立 `astra_system.json` / `analytical_network.yml` / `topology.txt` / `run_htsim.sh`。关键点：`npus_count` 显式写成 shard 大小；`PROJECT_DIR` 烧死绝对路径。
4. 并行起 N 个 `AstraSim_HTSim`，汇总 `run.csv`。
5. 合并 `combined_max_cycle = max(shard_cycle)`（纯 PP pipeline 等价模型；忽略 pipeline warm-up bubble，< 5% 误差在 §11.6 容忍内）。

设计细节 / 开放问题见 `sharded_parallel_design.md`。

### 8.4 长跑硬建议

```bash
export ASTRASIM_LOG_LEVEL=info      # 否则 debug 日志能打挂 DES
export ASTRASIM_FLUSH_ON=info       # 否则看不到进度，像挂了
export ASTRASIM_HTSIM_QUEUE_TYPE=lossless
export ASTRASIM_HTSIM_QUEUE_BYTES=16777216  # 16 MB，多并发 incast
export ASTRASIM_HTSIM_PFC_HIGH_KB=50
```

---

## 9. 新增一个 htsim 实验

### 9.1 从现有 analytical 实验迁移（推荐）

```bash
cd /home/ps/sow/part2/astra-sim
cp -r llama_experiment/in_dc llama_experiment/in_dc_htsim
# 仅保留 htsim 需要的文件；如有必要清理 analytical/ns-3 特有产物
```

按模板写 `run_htsim.sh`（参考 `llama_experiment/in_dc_htsim/run_htsim.sh`）：

```bash
#!/bin/bash
set -o pipefail
set -x
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
if [ ! -x "${ASTRA_SIM}" ]; then
    bash "${PROJECT_DIR:?}/build/astra_htsim/build.sh" || exit 1
fi
WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/llama3_8b/<flavor>"
WORKLOAD_DIR="${WORKLOAD_DIR:-${WORKLOAD_DIR_DEFAULT}}"
"${ASTRA_SIM}" \
  --workload-configuration="${WORKLOAD_DIR}/workload" \
  --comm-group-configuration="${WORKLOAD_DIR}/workload.json" \
  --system-configuration="${SCRIPT_DIR}/astra_system.json" \
  --remote-memory-configuration="${SCRIPT_DIR}/no_memory_expansion.json" \
  --network-configuration="${SCRIPT_DIR}/analytical_network.yml" \
  --htsim-proto="${HTSIM_PROTO:-roce}" \
  2>&1 | tee "${SCRIPT_DIR}/run_htsim.log"
```

`analytical_network.yml` 保持 `topology: [Custom]` + `topology_file: topology.txt`。htsim frontend 会自动走 `GenericCustomTopology`。

### 9.2 从 ns-3 实验迁移（自动字段映射）

```bash
# 预览 ns-3 字段会映射到哪些 ASTRASIM_HTSIM_* 变量
python3 htsim_experiment/tools/ns3_config_to_htsim.py \
    llama_experiment/inter_dc_mesh/ns3_config.txt

# 应用到当前 shell，然后跑 htsim
eval "$(python3 htsim_experiment/tools/ns3_config_to_htsim.py \
    llama_experiment/inter_dc_mesh/ns3_config.txt)"
bash llama_experiment/inter_dc_mesh_htsim/run_htsim.sh
```

已处理字段：`CC_MODE` → `HTSIM_PROTO`、`ENABLE_QCN` → `QUEUE_TYPE=lossless`、`PACKET_PAYLOAD_SIZE`、`BUFFER_SIZE`、`KMAX_MAP` / `KMIN_MAP` / `PMAX_MAP`、`LINK_DOWN` → `OCS_SCHEDULE`、`ENABLE_TRACE`、`ACK_HIGH_PRIO`。

### 9.3 纳入批量 runner

编辑 `htsim_experiment/run_all_htsim.sh` 的 `EXPS=(...)` 数组加一行路径，下次 `bash htsim_experiment/run_all_htsim.sh` 即可带出并写入 `run_all_report.csv`。

---

## 10. 常见问题与排查

### 10.1 跑了很久 `run_htsim.log` 一直是 125 bytes

spdlog async 默认只在 error 时 flush。加：

```bash
export ASTRASIM_FLUSH_ON=info
```

### 10.2 `[LOSSLESS not working]` 刷屏 / 事件推不动

PFC 阈值 × 并发度超过 queue 容量。调整：

```bash
export ASTRASIM_HTSIM_QUEUE_BYTES=16777216   # 16 MB
export ASTRASIM_HTSIM_PFC_HIGH_KB=50
```

### 10.3 128/512/1024 NPU 实验跑不动（0 sys finished）

单线程事件吞吐上限。用分片并行 runner（§8），或把实验降到 ≤ 64 NPU 验证正确性。

### 10.4 1024 NPU 实验 OOM kill 137

30 GiB RAM 不够。换机器到 ≥ 64 GiB 或扩 swap 到 32 GiB。

### 10.5 clean build 后数字跳变

增量构建残留过 stale object。彻底重建：

```bash
bash build/astra_htsim/build.sh -l
bash build/astra_htsim/build.sh
```

### 10.6 跨 DC / 不对称 WAN 实验 ratio 异常

- 确认 `topology.txt` 的 `@<rev_bw>/<rev_lat>` 写法正确（空白分隔，和 link_type 顺序不敏感）。
- `ASTRASIM_HTSIM_NIC_WIRE_SPEED` 若开了会按 host 最大带宽发包，backbone 瓶颈场景下会炸；解除该变量。

### 10.7 修改了 htsim 源代码（`extern/.../sim/*`）

**必须同步更新 patch**，否则下次 clean build 会丢改动：

```bash
cd extern/network_backend/csg-htsim
git diff sim/ > ../../../build/astra_htsim/htsim_astrasim.patch
rm -f sim/*.orig
```

---

## 11. 关键文件与目录

```
astra-sim/
├── CLAUDE.md                       # Claude 工作指南（含项目惯例）
├── htsim_migration_plan.md         # 迁移计划 + 全部 session 交班记录（§22 是权威快照）
├── build/astra_htsim/
│   ├── build.sh                    # 幂等构建入口
│   ├── CMakeLists.txt              # Release + -march=native（LTO 故意关）
│   ├── htsim_astrasim.patch        # htsim 源 patch（826 行 / 14 文件）
│   └── UPSTREAM_NOTES.md           # submodule pin & 升级评估
├── astra-sim/network_frontend/htsim/
│   ├── HTSimMain.cc                # 入口
│   ├── HTSimSession.{cc,hh}        # 协议 dispatch
│   ├── HTSimNetworkApi.{cc,hh}     # AstraNetworkAPI 实现
│   ├── proto/HTSimProtoTcp.{cc,hh}
│   ├── proto/HTSimProtoRoCE.{cc,hh}
│   ├── proto/HTSimProtoHPCC.{cc,hh}
│   └── topology/GenericCustomTopology.{cc,hh}   # Custom topo + 跨 DC + OCS
├── utils/htsim_smoke.sh            # CI smoke（<1s）
├── htsim_experiment/
│   ├── docs/
│   │   ├── htsim_user_guide.md     # 环境变量详表
│   │   ├── cross_dc_topology.md    # #REGIONS 扩展
│   │   ├── htsim_baseline.md       # Phase 0 基线记录
│   │   ├── sharded_parallel_design.md
│   │   └── htsim_usage_manual.md   # 本文件
│   ├── tools/                      # 测试 + 分片 runner + ns-3 转换
│   ├── smoke/run_htsim.sh          # 手动 smoke（替代 utils/htsim_smoke.sh 的长命令版本）
│   └── run_all_htsim.sh            # 批量 runner
├── extern/network_backend/csg-htsim  # submodule, pin 841d9e7
└── {llama,llama3_70b,qwen,megatron_gpt}_experiment/*_htsim/   # 18 个实验目录
```

---

## 12. 速查命令卡

| 场景 | 命令 |
|---|---|
| 构建 | `bash build/astra_htsim/build.sh` |
| 清洁重建 | `bash build/astra_htsim/build.sh -l && bash build/astra_htsim/build.sh` |
| CI smoke | `bash utils/htsim_smoke.sh` |
| 集成测试全套 | `for t in htsim_experiment/tools/test_*.sh; do bash "$t"; done` |
| 跑单实验 | `bash llama_experiment/in_dc_htsim/run_htsim.sh` |
| 跑所有实验 + CSV | `bash htsim_experiment/run_all_htsim.sh` |
| 金标准 smoke | `bash htsim_experiment/tools/run_gpt_39b_32_sharded.sh` |
| 金标准 production | `bash htsim_experiment/tools/run_gpt_39b_512_L48_sharded.sh` |
| 恢复 submodule | `cd extern/network_backend/csg-htsim && git checkout -- sim/` |
| 同步 patch | `cd extern/network_backend/csg-htsim && git diff sim/ > ../../../build/astra_htsim/htsim_astrasim.patch` |
| 清理所有运行产物 | `rm -rf htsim_experiment/*_sharded/ **/log/ **/run_htsim.log **/logout.dat **/idmap.txt **/sharded_runner.log` |
