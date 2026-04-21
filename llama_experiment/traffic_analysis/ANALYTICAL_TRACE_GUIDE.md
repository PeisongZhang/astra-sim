# Analytical 后端流量矩阵使用指南

与 `TRAFFIC_ANALYSIS_GUIDE.md` 配套的 analytical 版本。ns-3 那套工具处理 `mix.tr`；这份文档处理 analytical 后端导出的 chunk 级文本 trace。

设计细节见 `../plan/plan_analytical_trace.md`。

---

## 1. 仿真阶段：产生 trace

Analytical 后端（congestion_aware 与 congestion_unaware 都支持）通过两个环境变量打开 trace：

| 环境变量 | 作用 |
| --- | --- |
| `ASTRA_ANALYTICAL_ENABLE_TRACE=1` | 打开 chunk 级 trace |
| `ASTRA_ANALYTICAL_TRACE_FILE=<path>` | trace 文件输出路径（默认为当前工作目录下 `analytical_trace.txt`） |

### 1.1 通过 `in_dc/run_analytical.sh`

脚本已集成快捷开关 `ENABLE_TRACE`：

```bash
cd astra-sim/llama_experiment/in_dc
ENABLE_TRACE=1 bash run_analytical.sh
# → analytical_trace.txt 写入 in_dc/ 目录
```

如果要覆盖路径：

```bash
ENABLE_TRACE=1 ASTRA_ANALYTICAL_TRACE_FILE=/tmp/my_trace.txt bash run_analytical.sh
```

### 1.2 直接运行可执行文件

```bash
ASTRA_ANALYTICAL_ENABLE_TRACE=1 \
ASTRA_ANALYTICAL_TRACE_FILE=analytical_trace.txt \
./build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware \
    --workload-configuration=<...> \
    --system-configuration=<...> \
    --remote-memory-configuration=<...> \
    --network-configuration=<...>
```

关闭时（不设或 `=0`）不会产生任何 trace 文件，也没有 I/O 开销。

### 1.3 输出格式

文本格式，每行一个 chunk 到达事件：

```
# src dst size send_time_ns finish_time_ns chunk_id tag
0 1 262144 10 5392 0 500000000
1 2 262144 10 5392 0 500000000
...
```

- `src / dst`：NPU 编号
- `size`：chunk 字节数（一次 `sim_send` 的 `count`）
- `send_time_ns`：`sim_send` 被调用时的仿真时间（ns）
- `finish_time_ns`：chunk 到达目的地时的仿真时间（ns）
- `chunk_id`：同一 `(tag, src, dst, size)` 下分配的递增序号
- `tag`：collective 算法使用的 tag

---

## 2. 离线分析：`extract_traffic_matrix_analytical.py`

把 chunk trace 聚合成 `N×N×T` 的 `.npy` 矩阵，和 ns-3 侧的 `extract_traffic_matrix.py` 产物结构一致，可以直接喂给现有的 `visualize_traffic.py` / `animate_traffic.py` / `export_interactive_heatmap.py`。

```bash
source /home/ps/sow/part2/astra-sim/.venv/bin/activate

python3 extract_traffic_matrix_analytical.py \
    --trace ../in_dc/analytical_trace.txt \
    --window 50000000 \
    --attribution spread \
    --output ../in_dc/analytical_traffic_matrix_50ms.npy
```

### 2.1 CLI 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--trace` | 必填 | 输入 chunk trace 路径 |
| `--output` | 必填 | 输出 `.npy` 路径 |
| `--window` | `50_000_000`（50 ms） | 时间窗口，单位 ns |
| `--attribution` | `spread` | `finish`：整个 chunk 计入 `finish_time` 所在窗口。`spread`：按 `[send_time, finish_time]` 线性摊分 bytes（更平滑，接近 ns-3 包级聚合） |
| `--start_ns` | — | 只统计 `finish_time >= start_ns` 的 chunk |
| `--end_ns` | — | 只统计 `send_time < end_ns` 的 chunk |
| `--src_filter` | — | 逗号分隔的 src NPU 白名单，如 `0,1,2,3` |
| `--dst_filter` | — | 逗号分隔的 dst NPU 白名单 |
| `--num_nodes` | 自动推断 | 强制矩阵边长 N |

### 2.2 换窗口不用重仿

窗口大小完全在分析阶段决定，想换 10 ms / 100 us 直接改 `--window`：

```bash
# 10 ms
python3 extract_traffic_matrix_analytical.py --trace ... --window 10000000 --output tm_10ms.npy
# 100 us
python3 extract_traffic_matrix_analytical.py --trace ... --window 100000 --output tm_100us.npy
```

### 2.3 两种时间归属策略的差异

- `finish`：实现最简单，但窗口边界会出现明显抖动 —— 一个跨 5 个窗口的大 chunk 会把全部 bytes 压到它落地的那个窗口。
- `spread`（默认）：把 chunk 的 bytes 按时长线性摊分到它穿过的每个窗口。总量不变；**边界效应被抹平**，更接近 ns-3 packet 级聚合后的形态，跨后端对比时用这个。

整数字节精确配账：每个窗口取 `floor(size * overlap / duration)`，最后一个窗口拿余数，保证 `sum == size`。

---

## 3. 与 ns-3 流量矩阵对照

两套工具产生的 `.npy` shape 都是 `(T, N, N)`、dtype 都是 `int64`，可以共用可视化脚本：

```bash
python3 visualize_traffic.py --input analytical_traffic_matrix_50ms.npy
python3 animate_traffic.py --input analytical_traffic_matrix_50ms.npy --output analytical.gif
python3 export_interactive_heatmap.py --input analytical_traffic_matrix_50ms.npy --output analytical.html
```

对照建议：

1. 用相同 `--window` 提取两份矩阵（analytical vs. ns-3）。
2. 比 `matrix.sum()`（总 bytes，应该吻合）。
3. 比每行 / 每列的时间序列 —— analytical 没有排队和丢包，所以边界会更"方"，整体形态应该对齐。

---

## 4. 规模与性能

- **trace 文件体积**：chunk 数量 × 每行 ≈ 60 字节。Llama3-8B 一个 iteration 大概 10⁵–10⁶ chunk，文本 trace 在 10 MB – 100 MB 量级。
- **仿真 I/O 开销**：`FILE*` 带 4 MB 缓冲，高频短写基本被吸收，仿真时长不受影响。
- **默认关闭**：不设 `ASTRA_ANALYTICAL_ENABLE_TRACE` 时 `write_chunk` 是一个指针判 null + early return，开销可忽略。

如果 trace 超过 1 GB 需要考虑切换到二进制或流式 `gzip`，目前先用文本观察实际规模。

---

## 5. 常见问题

**Q: 开了 trace 为什么文件为空（只有 header）？**
A: 检查 simulator 是否真的跑到了 `sim_send`。如果 workload 加载失败（比如 `workload.0.et` 不存在），初始化阶段就返回了，自然没有流量。

**Q: `send_time == finish_time == 0` 是什么意思？**
A: analytical 时间从 0 开始，第一个 chunk 从一个 NPU 发出、另一个 NPU 几乎同时 ready 时，可能落在同一个 ns。正常现象。

**Q: `spread` 模式每个窗口的字节数不是整数倍 chunk size，是不是有 bug？**
A: 不是。`spread` 模式按 `[send_time, finish_time]` 比例把 chunk 拆到多个窗口，每个窗口拿到的是这个 chunk 的一部分字节，自然不是 chunk size 的整数倍。总量 `matrix.sum()` 仍然 `== Σ chunk size`。

**Q: hop-by-hop 链路级 trace 呢？**
A: 方案里是 Phase 3，独立开关 `ASTRA_ANALYTICAL_ENABLE_HOP_TRACE`，目前未实现。需要跨 DC 链路利用率 / 排队延迟分析时再加。
