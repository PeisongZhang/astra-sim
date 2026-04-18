# ASTRA-sim Analytical 后端使用说明

本文档面向 `astra-sim/qwen_experiment/in_dc/` 实验目录，系统性地介绍 Analytical（congestion-aware）后端的构建、配置、运行、调优与诊断方法，并覆盖本仓库近期针对 Plan C（同时戳批事件并行）所做的优化和新增环境变量。

---

## 1. 后端简介

ASTRA-sim 的 Analytical 后端是一个**离散事件仿真器**（DES），以解析模型替代 ns-3 等包级仿真器，用于快速评估集合通信在给定拓扑和工作负载下的完成时间。仓库中提供两种变体：

| 变体 | 可执行文件 | 说明 |
|------|------------|------|
| Congestion-Aware | `AstraSim_Analytical_Congestion_Aware` | 考虑链路占用、排队、序列化延迟；本实验使用 |
| Congestion-Unaware | `AstraSim_Analytical_Congestion_Unaware` | 仅按理想带宽/延迟计算，不建模拥塞 |

核心执行循环位于 `astra-sim/network_frontend/analytical/congestion_aware/main.cc`：

1. `EventQueue::proceed()`：取出最早时间戳上的所有事件并执行；
2. 执行期间事件可能向队列写入新事件（回调链）；
3. 所有事件消费完后，主循环尝试推进 ready list 上"卡住"的 stream，直到无新的进展产生则结束。

事件队列实现位于 `extern/network_backend/analytical/common/event-queue/EventQueue.cpp`，对应头文件在 `extern/network_backend/analytical/include/astra-network-analytical/common/EventQueue.h`。

---

## 2. 目录结构速览

```
astra-sim/
├── build/astra_analytical/
│   ├── build.sh                       # 构建脚本
│   ├── CMakeLists.txt                 # 顶层 CMake
│   └── build/                         # 构建产物（make 输出）
│       └── bin/
│           └── AstraSim_Analytical_Congestion_Aware
├── astra-sim/
│   └── network_frontend/analytical/
│       └── congestion_aware/main.cc   # 仿真主入口
├── extern/network_backend/analytical/
│   ├── common/event-queue/            # EventQueue / EventList / Event
│   ├── congestion_aware/network/      # Device / Link / Chunk
│   └── include/astra-network-analytical/  # 公共头文件
└── qwen_experiment/in_dc/
    ├── run_analytical.sh              # 推荐的运行脚本
    ├── analytical_network.yml         # 网络后端入口
    ├── topology.txt                   # 自定义拓扑（具体链路）
    ├── astra_system.json              # 系统行为配置
    ├── no_memory_expansion.json       # 远端内存配置
    ├── workload/                      # Chakra ET 负载 trace
    │   ├── workload.json              # 通信组（comm-group）映射
    │   └── workload.<rank>.et         # 每个 NPU 的 ET trace（128 份）
    └── parallelization_exploration.md # 并行化改进方案
```

---

## 3. 构建

### 3.1 一键构建

```bash
cd astra-sim
./build/astra_analytical/build.sh -t congestion_aware
```

`-t` 的可选值：`all` / `congestion_aware` / `congestion_unaware`；默认 `all`。

### 3.2 构建标志

| 参数 | 作用 |
|------|------|
| `-t <target>` | 选择构建目标 |
| `-d` | 切换 `CMAKE_BUILD_TYPE=Debug` |
| `-l` | 清理构建目录（删除 `build/` 与 Chakra protobuf 生成物） |

环境变量 `ASTRA_ANALYTICAL_BUILD_TYPE`（默认 `Release`）可覆盖 CMake 构建类型。注意 CMake 中 `COMPILE_WARNING_AS_ERROR ON`，任何警告都会中断构建。

### 3.3 构建产物

- 可执行文件：`build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware`
- 静态库：`build/astra_analytical/build/lib/libAnalytical_Congestion_Aware.a`
- 兼容符号链接：`build/astra_analytical/build/AstraCongestion/bin/AstraCongestion`

---

## 4. 命令行参数

以下参数由 `CmdLineParser` 解析（定义于 `network_frontend/analytical/common/CmdLineParser.cc`）：

| 参数 | 含义 |
|------|------|
| `--workload-configuration=<前缀>` | Chakra ET 文件前缀，实际读取 `<前缀>.<rank>.et` |
| `--comm-group-configuration=<path>` | 通信组 JSON（定义每个 comm-group 包含哪些 rank） |
| `--system-configuration=<path>` | 系统 JSON（调度策略、collective 实现等） |
| `--remote-memory-configuration=<path>` | 内存后端 JSON |
| `--network-configuration=<path>` | 网络后端 YAML，指向拓扑 |
| `--num-queues-per-dim=<int>` | 每维度的 send/recv 队列数（默认 `1`） |
| `--comm-scale=<double>` | 通信量缩放（默认 `1`） |
| `--injection-scale=<double>` | 注入速率缩放（默认 `1`） |
| `--rendezvous-protocol=<bool>` | 是否启用 rendezvous 协议 |
| `--logging-configuration=<path>` | spdlog 日志配置 |
| `--logging-folder=<path>` | 日志输出目录 |

---

## 5. 配置文件

### 5.1 网络 YAML（`analytical_network.yml`）

```yaml
topology: [ Custom ]
topology_file: "topology.txt"
```

- `topology`：可取 `Ring`、`FullyConnected`、`Switch`、`Custom` 或多维组合（如 `[Ring, Switch]`）。
- `topology_file`：当 `Custom` 时指向拓扑文件，路径相对于 YAML 目录。

### 5.2 自定义拓扑文件（`topology.txt`）

三段结构（Qwen 实验为例）：

```
<npus_count> <switches_count> <links_count>
<switch_id_1> <switch_id_2> ... <switch_id_K>
<src> <dst> <bandwidth> <latency> <weight>
...
```

本实验为 `277 149 388`：128 个 GPU + 149 台交换机，共 388 条链路；后续每行定义一条有向链路：

- `src`/`dst`：节点 ID（0..npus-1 为 GPU，后续为交换机）
- `bandwidth`：形如 `4800Gbps`、`400GBps`、`1.6Tbps`
- `latency`：形如 `0.00015ms`、`100ns`
- `weight`：多链路分流权重，0 表示等权

### 5.3 系统 JSON（`astra_system.json`）

```json
{
    "scheduling-policy": "LIFO",
    "endpoint-delay": 10,
    "active-chunks-per-dimension": 1,
    "preferred-dataset-splits": 4,
    "all-reduce-implementation": ["ring"],
    "all-gather-implementation": ["ring"],
    "reduce-scatter-implementation": ["ring"],
    "all-to-all-implementation": ["direct"],
    "collective-optimization": "localBWAware",
    "local-mem-bw": 1560,
    "boost-mode": 0,
    "roofline-enabled": 1,
    "peak-perf": 312,
    "hardware-resource-capacity": {
        "cpu": 1,
        "gpu-comp": 1,
        "gpu-comm": 1,
        "gpu-recv": 64
    }
}
```

常用字段：

- `scheduling-policy`：`LIFO` / `FIFO`；本实验用 LIFO。
- `all-reduce-implementation` 等：可取 `ring` / `direct` / `doubleBinaryTree` / `halvingDoubling` 等，列表长度应等于维度数。
- `collective-optimization`：`baseline` / `localBWAware`。
- `roofline-enabled` / `peak-perf` / `local-mem-bw`：计算 roof-line 上限（TFLOPS / GB/s）。
- `hardware-resource-capacity`：单卡并发 CPU / 计算 / 发送 / 接收并行度。

### 5.4 远端内存 JSON（`no_memory_expansion.json`）

```json
{ "memory-type": "NO_MEMORY_EXPANSION" }
```

另一可选值：`ANALYTICAL_REMOTE_MEMORY`（需额外带宽/延迟字段）。

### 5.5 通信组 JSON（`workload/workload.json`）

形如 `{ "1": [0,1,2,3], "2": [4,5,6,7], ...}`，键是 comm-group id（字符串），值是该组包含的 rank 列表。Chakra ET 中的 `comm_group` 字段引用这些 id。

### 5.6 Chakra ET（`workload/workload.<rank>.et`）

每个 rank 一个二进制 ET 文件，内容为 Chakra protobuf（定义见 `extern/graph_frontend/chakra/schema/protobuf/et_def.proto`）。通过 `generate_topology.sh` 及外部工具（如 `chakra_converter`）生成。

---

## 6. 运行

### 6.1 推荐流程

```bash
cd astra-sim/qwen_experiment/in_dc
./run_analytical.sh
```

脚本会：

1. 调用 `build.sh -t congestion_aware` 触发增量构建；
2. 导出 Plan C 调优环境变量（见下）；
3. 以预设配置启动仿真；
4. 日志同步落盘到 `run_analytical.log`，并保留管道起始端的退出码。

退出码含义：

- `0`：仿真正常结束，所有待处理回调已清空。
- `2`：存在遗留 pending callback（通常是死锁/stuck 状态，会同时打印 `[analytical] Pending callbacks before cleanup`）。
- 其他非零：参数错误或运行期异常。

### 6.2 直接调用二进制

```bash
build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware \
    --workload-configuration=<workload_prefix> \
    --comm-group-configuration=<comm_group_json> \
    --system-configuration=<system_json> \
    --remote-memory-configuration=<memory_json> \
    --network-configuration=<network_yaml> \
    --num-queues-per-dim=1
```

---

## 7. 环境变量

### 7.1 Plan C 并行调优（新增）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ASTRA_EVENT_PARALLEL_THREADS` | `nproc` | 同时戳并行运行允许的最大线程数；设为 `1` 可完全退回串行 |
| `ASTRA_EVENT_PARALLEL_MIN_EVENTS` | `8` | 单次并行安全批的事件数阈值，低于此值走串行 |
| `ASTRA_EVENT_QUEUE_STATS` | `0` | 非 `0` 时，进程退出时打印事件队列累计计数 |

并行核心位于 `EventQueue::invoke_parallel_safe_run`。目前被注册为 "parallel-safe" 的回调只有 `Link::link_become_free`，按 `callback_arg=link_ptr` 分组后同一链路的事件串行、不同链路的事件可跨线程并行。`Chunk::chunk_arrived_next_device` 不能在当前分组语义下安全并行（会触碰共享 `Link::pending_chunks` 与 `CompletionState`，参见 `parallelization_exploration.md`）。

实现要点（已修复）：

- **持久线程池**：`EventQueue` 在首次并行运行时懒加载线程池，线程生命周期等于仿真整段运行，避免原版逐批 `std::thread` 的创建/销毁开销。
- **无锁白名单**：`parallel_safe_callbacks` 改为 `std::array<std::atomic<Callback>, 16>`；读路径 (`is_parallel_safe_callback`) 不再获取互斥锁。
- **主线程参与**：派发 `thread_count-1` 个 worker 后，主线程一并参与 work-stealing（共享原子 group 索引），最大化 CPU 利用率。
- **去锁化主循环**：`proceed()`、`finished()`、以及 `invoke_event_batch` 的回写阶段均不再进入互斥锁；仅 `schedule_event` 的异常兜底路径保留 `schedule_mutex`。

### 7.2 计时与诊断

| 变量 | 作用 |
|------|------|
| `ASTRA_ANALYTICAL_TIMING` | 非 `0` 时，主函数各阶段（topology 构造、system 构造、workload fire、simulation_loop、total）逐个打印 `[analytical-timing] ...`，并在主循环结束时输出 `simulation_loop_breakdown`（包含 `outer_iterations` / `proceed_calls` / `proceed_ms` / `issue_dep_free_ms` / `schedule_stranded_ms`） |
| `ASTRA_ANALYTICAL_DEBUG_STUCK` | 非 `0` 时，若仿真在未完成全部 workload 的情况下 stuck，会转储每个 Sys 的 ready-list / 运行中 stream 数 |
| `ASTRA_EVENT_QUEUE_STATS` | 见 7.1，用于定位热点批大小（`max_batch_size`）、并行运行次数（`parallel_runs`）、被并行化的事件数占比（`parallel_events / drained_events`） |
| `ASTRA_ANALYTICAL_BUILD_TYPE` | 构建阶段使用，`Release` / `Debug` |

---

## 8. 输出说明

### 8.1 主要 stderr/stdout

| 前缀 | 含义 |
|------|------|
| `[ASTRA-sim] ...` | 运行脚本自身日志 |
| `[analytical-timing] ...` | `ASTRA_ANALYTICAL_TIMING` 打开时的阶段计时 |
| `[analytical-stuck] sys=... ready_list=... ...` | `ASTRA_ANALYTICAL_DEBUG_STUCK` 下的死锁转储 |
| `[event-queue-stats] schedule_calls=... parallel_events=...` | `ASTRA_EVENT_QUEUE_STATS` 汇总 |
| `[analytical] Pending callbacks before cleanup: ...` | 退出时还有 pending 回调（异常完成） |
| 其他 `sys[i]` / `workload` / `system` | ASTRA-sim 核心的业务日志，通过 spdlog 输出，格式由 `logging-configuration` 控制 |

### 8.2 日志文件

`run_analytical.sh` 通过 `tee` 将 stdout/stderr 重定向到 `run_analytical.log`（文件会被覆盖）。日志末尾一般包含 Chakra workload 的完成摘要以及 spdlog 输出。

### 8.3 Stats 解读要点

- **`drained_events / drained_batches`**：单次 `proceed()` 内平均批大小。数值大于 `ASTRA_EVENT_PARALLEL_MIN_EVENTS` 才有被并行的可能。
- **`parallel_events / drained_events`**：被并行安全处理的事件占比；取决于白名单覆盖与回调分布。
- **`parallel_groups / parallel_runs`**：平均每次并行运行的 group 数，接近 `ASTRA_EVENT_PARALLEL_THREADS` 时线程才被充分利用。
- **`max_parallel_groups`**：历史最高并行 group 数，是决定线程数下限的参考。

---

## 9. 典型调优策略

1. **先测基线**：`ASTRA_EVENT_PARALLEL_THREADS=1 ASTRA_ANALYTICAL_TIMING=1 ./run_analytical.sh`，记录 `simulation_loop_breakdown` 中的 `proceed_ms`。
2. **观察批大小**：加开 `ASTRA_EVENT_QUEUE_STATS=1`，若 `max_batch_size` 远小于 `ASTRA_EVENT_PARALLEL_MIN_EVENTS`，说明并行无用武之地，应优先优化算法结构，而非加线程。
3. **分档测试线程数**：依次 `ASTRA_EVENT_PARALLEL_THREADS=2,4,8,16,...` 对比 `proceed_ms`。超过物理核后通常收益为负（线程切换与 cache 抖动）。
4. **降低阈值**：对于大批量、小事件的场景，`ASTRA_EVENT_PARALLEL_MIN_EVENTS=4` 或 `2` 可能提升并行命中率；但阈值过低反而让 cv 唤醒开销占主导。
5. **诊断 stuck**：`ASTRA_ANALYTICAL_DEBUG_STUCK=1` 有利于定位 workload/ET 依赖异常。

---

## 10. 扩展与后续

- `parallelization_exploration.md` 列出了方案 A（Chandy-Misra 保守并行）、B（Time Warp 乐观并行）、C（同时戳批并行）、D（数据结构优化）、E（子拓扑划分）的对比；当前仓库实现了 D 与 C。
- 要进一步扩大 Plan C 的覆盖，可考虑：
  1. 为 `Chunk::chunk_arrived_next_device` 引入"按目标 Link 分组"的 grouping-key 钩子；
  2. 将 `CompletionState::pending_chunks` 改为 `std::atomic<...>` 以消除 split-chunk 的 decrement race；
  3. 为 Link 增加细粒度互斥或将 `Device::send` 改写为 lock-free。
- Plan E（子拓扑划分）需要在 `Topology` / `Device` 层做切片，属于结构性改动，推荐在 Plan C 榨干收益后再评估。

---

## 11. 常见问题

| 现象 | 排查建议 |
|------|----------|
| 构建失败：`-Werror` 类警告 | 查看出错文件与行号，Analytical 项目默认将警告视为错误 |
| 运行极慢且 `proceed_ms` 占比 >80% | 开启 `ASTRA_EVENT_QUEUE_STATS`，确认批大小与并行率；调整线程数 |
| 退出码 `2` + Pending callbacks | 某些 stream 未推进完毕，尝试 `ASTRA_ANALYTICAL_DEBUG_STUCK=1` 查看 ready_list，检查 ET 依赖是否完备 |
| 同一链路事件仍串行 | 符合预期：同 `callback_arg` 的事件必须串行以保证正确性 |
| 设置 `ASTRA_EVENT_PARALLEL_THREADS=0` 未生效 | `0` 会被当作"未设置"，走默认 `hardware_concurrency`；需显式给 `1` 才是串行 |
| Topology 解析报错 | 检查 `topology.txt` 首行三数与后续节点数/链路数是否一致，带宽/延迟单位是否被识别 |

---

## 12. 快速命令备忘

```bash
# 基线（串行）
ASTRA_EVENT_PARALLEL_THREADS=1 ASTRA_ANALYTICAL_TIMING=1 \
    ./run_analytical.sh

# 并行 + 统计
ASTRA_EVENT_PARALLEL_THREADS=$(nproc) \
ASTRA_ANALYTICAL_TIMING=1 \
ASTRA_EVENT_QUEUE_STATS=1 \
    ./run_analytical.sh

# Debug 构建 + stuck 诊断
./build/astra_analytical/build.sh -t congestion_aware -d
ASTRA_ANALYTICAL_DEBUG_STUCK=1 ./run_analytical.sh

# 纯清理
./build/astra_analytical/build.sh -l
```
