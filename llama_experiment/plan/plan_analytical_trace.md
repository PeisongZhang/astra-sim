# Analytical Backend 流量 Trace / 时间轴流量矩阵 方案

## 0. 目的

给 ASTRA-sim 的 analytical backend（congestion-aware 与 congestion-unaware 两个变体）加上类似 ns-3 `ENABLE_TRACE` 的能力：在仿真过程中记录训练产生的每一条网络通信，仿真结束后可以聚合出**时间轴上的流量矩阵**（`traffic_matrix_<window>.npy`），用于与 ns-3 对照、以及跨 DC 拓扑的流量可视化。

参考对照：
- ns-3 侧：`astra-sim/traffic_matrix.md`、`astra-sim/llama_experiment/traffic_analysis/`（`extract_traffic_matrix.py` → `validate_matrix.py` → `visualize_traffic.py`）。
- 目标实验入口：`astra-sim/llama_experiment/in_dc/run_analytical.sh`（当前已能跑 analytical，缺 trace 输出）。

## 1. ns-3 vs analytical 的建模粒度差异

| 维度 | ns-3 backend | analytical backend |
| --- | --- | --- |
| 仿真粒度 | packet-level | flow / chunk-level |
| trace 单位 | 每个 packet `<src, dst, start, end, size>` | 每个 chunk（一次 `AstraNetworkAPI::sim_send`） |
| 对流量矩阵的影响 | 天然逐 packet 累加 | 一个 chunk 作为一条整记录，按时间窗口聚合 bytes 即可 |

**结论**：analytical 的 trace 单位直接取 chunk 即可，不必模拟出"包"。时间轴流量矩阵只需要按窗口聚合 bytes，chunk 级别信息已经足够。

## 2. 核心 Hook 点（单点覆盖两个变体）

congestion-aware 与 congestion-unaware 的 API 入口分离，但两者都汇聚到 `common/CommonNetworkApi`。因此 trace hook 放在 common 层即可覆盖两者。

| 动作 | 位置 | 作用 |
| --- | --- | --- |
| 记录 `send_time` | `congestion_aware/CongestionAwareNetworkApi.cc::sim_send`（~L59）<br>`congestion_unaware/CongestionUnawareNetworkApi.cc::sim_send`（~L36） | chunk 发起时取 `event_queue->get_current_time()` |
| 记录 `finish_time` + 写 trace | `common/CommonNetworkApi.cc::process_chunk_arrival`（~L139） | 两个 backend 的 chunk 到达都会回到这里，天然汇聚点 |
| 时间戳在 send/arrival 之间的传递 | `include/common/CallbackTrackerEntry.hh` 增加 `send_time` 字段 | chunk key 已经是 `(tag, src, dst, size, chunk_id)`，直接挂在这个 entry 上 |

hop-by-hop 级别（只 congestion-aware 有意义）的 hook 点在 `extern/network_backend/analytical/congestion_aware/network/Link.cpp::schedule_chunk_transmission`，用来分析链路拥塞与排队延迟。作为 **Phase 3** 独立开关实现，详见 §4.3。

## 3. 设计决策：仿真只写 trace，统计完全离线

**不做仿真内在线聚合。** 理由：
- analytical 仿真本身运行时间很长（跨 DC 大模型一次 iteration 动辄几十分钟到数小时）。
- 时间窗口（50us / 10ms / 50ms / 100ms …）、起止时间范围、是否按 logical comm group 切分、是否区分 src→dst 方向等统计维度，都只在分析阶段才能定下来。
- 如果把窗口固化到仿真内，调一次窗口就得重仿一次，不可接受。
- **结论**：仿真阶段只写一份"足够详细的原始 trace"，所有聚合/矩阵化/可视化都放到离线 Python 脚本里。窗口大小、时间段、过滤条件均在分析阶段参数化。

## 4. 分阶段落地

### Phase 1：chunk-level trace 输出（本方案主体）

仿真结束后产生一份与 ns-3 `mix.tr` 语义对齐的文本 trace，字段：

```
src dst size send_time_ns finish_time_ns chunk_id tag
```

实现要点：
- 新增 `common/TraceManager.{hh,cc}`，单例形式，负责文件打开/写入/关闭。
- 开关走环境变量，与现有 `ASTRA_ANALYTICAL_DEBUG_TAGS` 风格保持一致：
  - `ASTRA_ANALYTICAL_ENABLE_TRACE=1` 打开 trace
  - `ASTRA_ANALYTICAL_TRACE_FILE=<path>` 指定输出路径
- 改动文件：
  - `include/common/CallbackTrackerEntry.hh` —— 加 `send_time` 字段 + getter/setter
  - `congestion_aware/CongestionAwareNetworkApi.cc::sim_send` —— 写 `send_time`
  - `congestion_unaware/CongestionUnawareNetworkApi.cc::sim_send` —— 同上
  - `common/CommonNetworkApi.cc::process_chunk_arrival` —— 读 `send_time`、写 trace 一行
  - `common/TraceManager.{hh,cc}` —— 新建
  - `congestion_aware/main.cc`、`congestion_unaware/main.cc` —— 启动时 init、退出前 finalize

**I/O 开销控制**：
- 写入走带缓冲的 `FILE*`（`setvbuf` 设 1–4 MB 缓冲），避免高频小写拖慢仿真。
- 格式先用文本，足够快且便于 `awk/pandas` 直接处理；若文件过大再考虑二进制或 `gzip` 流式写入。
- 单机 llama3-8B/70B 级别，chunk 数量预估 10^5 – 10^6 量级，文本 trace 在百 MB 以内，可接受。

工作量估计：1–2 天。

### Phase 2：离线分析脚本（Python）

放到 `astra-sim/llama_experiment/traffic_analysis/` 下，与现有 ns-3 脚本并列：

- `extract_traffic_matrix_analytical.py`：读 Phase 1 的 trace，按 `--window <ns>` 聚合成 `N×N×T` 矩阵，输出 `.npy`。
- **时间归属策略（CLI 参数，默认 B）**：
  - `--attribution finish`（方案 A）：chunk 在 `finish_time` 所在窗口整块计入。实现最简单，但窗口边界带宽会抖。
  - `--attribution spread`（方案 B）：按 `[send_time, finish_time]` 区间把 bytes 线性摊分到所覆盖窗口。更平滑，更接近 ns-3 packet 级聚合。推荐默认。
- 其他有用的 CLI 参数：`--start_ns / --end_ns`（只统计某段时间）、`--src_filter / --dst_filter`（按节点过滤）、`--output <path>`。
- 可视化复用：`visualize_traffic.py`、`animate_traffic.py`、`export_interactive_heatmap.py` 读的是 `.npy`，只要布局对齐就能零改动复用。

工作量估计：1 天。

### Phase 3：hop-by-hop 链路级 trace（独立开关，默认 off）

**仅 congestion-aware 有效**（congestion-unaware 没有 Link 模型）。后续要分析 inter-DC 链路拥塞、排队延迟、链路利用率时会用到。

#### 开关设计

与 Phase 1 的 chunk-level trace **完全独立**，用户可以任意组合（只 chunk / 只 hop / 两者都开 / 都不开）：

| 开关 | 作用 |
| --- | --- |
| `ASTRA_ANALYTICAL_ENABLE_TRACE=1` | chunk-level trace（Phase 1） |
| `ASTRA_ANALYTICAL_ENABLE_HOP_TRACE=1` | hop-by-hop trace（Phase 3） |
| `ASTRA_ANALYTICAL_HOP_TRACE_FILE=<path>` | hop trace 输出路径 |

congestion-unaware 下若设置了 `ASTRA_ANALYTICAL_ENABLE_HOP_TRACE=1`，启动时打印一条 warning 并忽略（不报错，保持配置可复用）。

#### 记录字段

每 hop 一行，字段：

```
chunk_id hop_idx link_src link_dst size enqueue_ns tx_start_ns arrival_ns
```

- `enqueue_ns`：chunk 进入该 link 队列的时间（`Link::send` 被调用、link busy 时）。
- `tx_start_ns`：该 chunk 开始占用该 link 的时间（busy 时等于前一 chunk 的 `tx_end`；idle 时等于 `enqueue_ns`）。
- `arrival_ns`：chunk 到达 link 下一端 device 的时间（`tx_start_ns + latency + size/bandwidth`）。
- `hop_idx`：chunk 在 route 中的第几跳（0 起），便于拼出 chunk 的完整路径。

有这三个时间戳就能同时算出"排队时延 = tx_start - enqueue"、"传输时延 = arrival - tx_start"、"link 利用率"。

#### Hook 位置

主 hook：`extern/network_backend/analytical/congestion_aware/network/Link.cpp::schedule_chunk_transmission`（~L112）。这是 chunk 真正被调度上 link 的函数，能同时拿到三个时间戳。

辅助：`Link::send`（~L53）入队时记 `enqueue_ns`（busy 走队列分支的情况）。idle 分支里 `enqueue_ns == tx_start_ns`，不用单独记。

`hop_idx` 和 `chunk_id` 需要随 `Chunk` 对象透传。`chunk_id` 已经在 chunk key 里（Phase 1 已落地），`hop_idx` 可以由 `Chunk::route` 剩余长度推出，也可以在 `Chunk` 类里加一个 counter。

#### 关联到 chunk-level trace

通过 `chunk_id` 关联：Phase 1 trace 的 `chunk_id` 和 Phase 3 hop trace 的 `chunk_id` 是同一个，离线脚本可以 join 两份 trace 拼出完整的"chunk 级 + 每 hop"视图。

#### 改动文件

- `extern/network_backend/analytical/congestion_aware/network/Link.cpp` —— `schedule_chunk_transmission` / `send` 加 hop trace 写入
- `extern/network_backend/analytical/congestion_aware/network/Chunk.{h,cpp}` —— 如需 `hop_idx` counter
- `common/TraceManager.{hh,cc}` —— 复用（新增 `write_hop(...)` 方法和独立的 `FILE*`）
- `congestion_aware/main.cc` —— init/finalize 处多打开一个 file handle

#### I/O 开销

hop trace 行数 ≈ chunk 数 × 平均路径 hop 数。跨 DC 场景路径通常 3–6 hops，文件体积大约是 chunk trace 的 3–6 倍。`setvbuf` 缓冲 + 默认 off，只在需要时开。

#### 离线分析（Phase 2 同时扩展）

- `extract_link_utilization.py`：读 hop trace，按 `--window` 聚合每条 link 的 bytes / 占用率。
- `extract_queue_delay.py`：统计每条 link 的 `tx_start - enqueue` 分布，看拥塞严重程度。

工作量估计：2–3 天（含离线脚本）。

## 5. 与 in_dc 实验脚本的集成

`astra-sim/llama_experiment/in_dc/run_analytical.sh` 结构不用变，按需追加环境变量：

```bash
# 只开 chunk-level trace（Phase 1）
export ASTRA_ANALYTICAL_ENABLE_TRACE=1
export ASTRA_ANALYTICAL_TRACE_FILE="${SCRIPT_DIR}/analytical_trace.txt"

# 同时开 hop-by-hop trace（Phase 3，仅 congestion-aware）
export ASTRA_ANALYTICAL_ENABLE_HOP_TRACE=1
export ASTRA_ANALYTICAL_HOP_TRACE_FILE="${SCRIPT_DIR}/analytical_hop_trace.txt"
```

离线分析示例：

```bash
# 流量矩阵（chunk-level trace → N×N×T）
python extract_traffic_matrix_analytical.py \
    --trace in_dc/analytical_trace.txt \
    --window 50000000 \
    --attribution spread \
    --output in_dc/analytical_traffic_matrix_50ms.npy

# 链路利用率（hop trace → per-link 时间序列）
python extract_link_utilization.py \
    --hop-trace in_dc/analytical_hop_trace.txt \
    --window 50000000 \
    --output in_dc/analytical_link_util_50ms.npy
```

窗口想换成 10ms / 100us，只需换 `--window`，不需重仿真。

## 6. 风险与待确认项

1. **时间归属策略**：A 还是 B？（倾向：B，跟 ns-3 对齐）
2. **输出格式对齐**：是否严格对齐 ns-3 `mix.tr` 字段顺序，以便 `traffic_analysis/` 现有脚本零改动复用？（倾向：对齐）
3. **trace 文件体积**：若文本 trace 过大（> 1 GB），切到二进制或 `gzip` 流式写；先做文本版看实际规模再说。hop trace 体积是 chunk trace 的 3–6 倍，同样处理。
4. **Phase 3 优先级**：chunk-level + 流量矩阵是当前 in_dc 实验急需的；hop-by-hop 是后续跨 DC 链路分析才会用。建议按 Phase 1 → Phase 2 → Phase 3 顺序实现，Phase 3 独立开关不影响 Phase 1/2 的日常使用。

## 7. 下一步

- 方案 review 通过后按 Phase 1 → Phase 2 → Phase 3 顺序实现，每个 Phase 独立开关可单独启用。
- Phase 1/2 先在 `in_dc/run_analytical.sh` 上跑通，与 ns-3 的 `traffic_matrix_50ms.npy` 对照，验证时间轴形态一致、总量一致。
- 之后扩展到 `inter_dc*/` 各个拓扑，作为 analytical/ns-3 精度对照的标准工件。
- Phase 3 用于跨 DC 链路级分析（链路利用率、排队延迟、拥塞热点），等有具体实验需求时启用。
