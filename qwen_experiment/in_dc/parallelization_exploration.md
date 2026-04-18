# ASTRA-sim 多线程并行化可行性探索报告

## 1. 当前仿真架构分析

### 1.1 仿真规模

当前模拟的 Qwen-32B 数据中心拓扑包含：

| 资源 | 数量 |
|------|------|
| NPU（GPU） | 128 |
| 交换机（Switch） | 149 |
| 链路（双向） | 388 |
| 总设备节点 | 277 |
| 工作负载文件 | 128 个 `.et` 文件（每 GPU 一个，每个 ~17MB） |

拓扑结构为 3 层树形网络：
- **第 1 层**：GPU → ToR Switch（4800Gbps NVLink，0.15ns 延迟）
- **第 2 层**：GPU → Leaf Switch（200Gbps RDMA，1ns 延迟）
- **第 3 层**：Leaf Switch → Spine Switch（200Gbps，500ns 延迟）
- **第 4 层**：Spine Switch → Core Switch（6400Gbps，600ns 延迟）

### 1.2 核心仿真循环

```
main.cc
│
├── EventQueue (单一全局事件队列，std::list<EventList> 按时间排序)
│
├── 主循环:
│   while (true) {
│       while (!event_queue->finished()) {
│           event_queue->proceed();   // 取出最近的时间点，执行所有回调
│       }
│       // 尝试唤醒搁浅的流
│       issue_stranded_dependency_free_nodes();
│       schedule_stranded_ready_streams();
│   }
```

`EventQueue::proceed()` 的工作流程：
1. 从队列头部取出时间最小的 `EventList`
2. 更新 `current_time` 为该时间
3. 依次调用该 `EventList` 中的所有回调函数
4. 弹出已处理的 `EventList`

**关键特征：严格按时间顺序推进，同一时间点的事件按 FIFO 顺序执行。**

### 1.3 事件调度入口

仿真中只有两个地方产生新事件到 `EventQueue`：

| 调度入口 | 位置 | 作用 |
|----------|------|------|
| `Link::schedule_chunk_transmission()` | Link.cpp:111-135 | 调度 (1) chunk 到达下一设备 (2) link 变空闲 |
| `CommonNetworkApi::sim_schedule()` | CommonNetworkApi.cc:192-206 | 调度系统层定时回调（compute 延迟、内存延迟等） |

### 1.4 数据流：从集合通信到网络事件

```
Workload → Sys::generate_all_reduce() → 创建 Ring 集合通信
    → front_end_sim_send() → CommonNetworkApi::sim_send()
        → CongestionAwareNetworkApi::sim_send()
            → Topology::route(src, dst)     // BFS 路由
            → Chunk 创建 (带回调)
            → Topology::send(chunk)
                → Device::send(chunk)       // 源设备发送
                    → Link::send(chunk)     // 入链路
                        → Link::schedule_chunk_transmission()
                            → EventQueue::schedule_event(到达时间, chunk_arrived_next_device)
                            → EventQueue::schedule_event(空闲时间, link_become_free)

事件触发链:
chunk_arrived_next_device → 中间设备 → Device::send() → Link::send() → ... (逐跳)
chunk_arrived_dest → invoke_callback → process_chunk_arrival → trigger send/recv handler
link_become_free → 处理排队中的 pending chunk
```

### 1.5 关键全局共享状态

| 共享状态 | 类型 | 访问方式 |
|----------|------|----------|
| `EventQueue` | `shared_ptr`，单例 | 所有 Link、CommonNetworkApi 共享 |
| `CallbackTracker` | `static`，单例 | 所有 CongestionAwareNetworkApi 实例共享 |
| `ChunkIdGenerator` | `static`，单例 | 所有网络 API 共享 |
| `Sys::all_sys` | `static vector` | 全局 Sys 列表 |
| `Link::event_queue` | `static shared_ptr` | 所有 Link 共享 |
| `Topology::devices` | `vector<shared_ptr<Device>>` | 路由和发送共享 |
| 每个 `Device` 的 `links` map | per-device | `Device::send()` 中访问 |
| 每个 `Link` 的 `pending_chunks` | per-link | 链路排队 |

## 2. "GPU/Switch 作为线程，Link 作为 Channel" 方案分析

### 2.1 方案描述

```
构想: 每个 Device (GPU/Switch) 运行一个独立线程
      Link 作为线程间的通信 channel
      Chunk 通过 channel 在设备线程间传递

Device Thread 0 ──Link(channel)──→ Device Thread 128 (Switch)
Device Thread 1 ──Link(channel)──→ Device Thread 128 (Switch)
...
Device Thread 128 ──Link(channel)──→ Device Thread 164 (Spine)
```

### 2.2 根本困难：全局事件队列的因果一致性

**核心问题：这是一个离散事件仿真（DES），不是真实的并发系统。**

在当前仿真模型中：
- 全局虚拟时钟 (`current_time`) 是整个仿真的核心
- 每个事件在特定虚拟时间触发，而非挂钟时间
- 同一虚拟时间的事件执行顺序会影响结果（例如：Link 空闲事件和 Chunk 到达事件如果恰好同一时间触发，执行顺序决定了是否会排队）
- 事件回调会**同步产生新事件**：一个 `chunk_arrived_next_device` 回调会立即触发 `Device::send()` → `Link::send()` → 可能立即 `schedule_chunk_transmission()`

如果将 Device 放在不同线程：
1. **时间同步问题**：线程 A 在虚拟时间 T=100 处理事件时，产生了 T=150 的新事件；线程 B 可能已经推进到 T=200，漏掉了 T=150 的事件。
2. **事件插入竞争**：多个线程同时向 `EventQueue` 插入事件，`std::list` 非线程安全。
3. **回调中的同步调用链**：`chunk_arrived_next_device` → `Device::send()` → `Link::send()` 是同步调用链，涉及当前设备的 Link 状态查询和修改。

### 2.3 对该方案的结论

> **直接将 GPU/Switch 作为独立线程并使用 Channel 传递消息，无法在不改变仿真结果的前提下正确工作。**

原因：
1. DES 的语义要求全局时间单调推进，同一时间的事件必须全部处理完才能推进到下一时刻
2. 事件回调会同步产生新的同时刻或未来时刻的事件
3. 简单的消息传递模型无法表达"虚拟时间中的因果依赖"

## 3. 可行的并行化方案

### 3.1 方案 A：保守时间同步 PDES（Chandy-Misra-Bryant）

**原理**：将全局事件队列分割为每个 LP（Logical Process）一个本地事件队列，LP 之间通过带时间戳的消息通信，使用 Null Message 协议避免死锁。

```
┌──────────┐    timestamped msg    ┌──────────┐
│  LP_0    │ ──────────────────→   │  LP_128  │
│ (GPU 0)  │ ←────────────────── │ (Switch)  │
│ local EQ │    null messages      │ local EQ │
└──────────┘                       └──────────┘
     │                                  │
     │   barrier: min(next_event)       │
     └──────────────────────────────────┘
```

**映射到 ASTRA-sim**：

| 概念 | 映射 |
|------|------|
| LP (Logical Process) | 每个 Device (GPU / Switch) |
| 本地事件队列 | 每个 LP 自己的 EventQueue |
| Link 传输 | LP 间的带时间戳消息（替代全局 schedule_event） |
| Lookahead | Link 的 communication_delay（latency + serialization） |

**优点**：
- 保证仿真结果完全一致（时间戳排序 + 因果一致）
- 充分利用网络的物理延迟作为 lookahead

**缺点**：
- 实现复杂度极高，需要重写整个事件引擎
- Null Message 开销大，尤其当拓扑连接密集时
- Lookahead 值小（NVLink 延迟 0.15ns）时并行度很低
- 需要将 `CallbackTracker`、`Sys` 层也做 LP 化改造

**改造量估计**：~3000-5000 行核心代码改动，涉及 EventQueue、Link、Device、CommonNetworkApi、Sys 等几乎所有核心类。

**预期加速**：由于 NVLink 层的 lookahead 很小（0.15ns），在该层的并行度受限。跨 Spine 层（600ns lookahead）可获得更好的并行度。总体预计 **2-5x 加速**。

### 3.2 方案 B：乐观时间同步 PDES（Time Warp）

**原理**：每个 LP 自由推进时间，当收到过去时间的消息时执行回滚（rollback）。

**优点**：
- 不需要 Null Message，理论并行度更高
- Lookahead 小时也能工作

**缺点**：
- 需要实现状态快照和回滚机制
- ASTRA-sim 中大量使用 raw pointer 和 `unique_ptr`，状态快照极为困难
- `Link::pending_chunks` 是 `std::list<unique_ptr<Chunk>>`，回滚需要克隆
- `CallbackTracker` 的状态回滚非常复杂
- 反消息（anti-message）机制实现困难

**改造量估计**：~5000-8000 行，且需要为所有核心数据结构添加快照/恢复能力。

**预期加速**：理论上可达 **5-10x**，但实际中由于频繁回滚，可能退化到 3-5x。

### 3.3 方案 C：批量事件并行化（同时刻事件并行处理）

**原理**：保留全局事件队列，但对同一虚拟时间点的多个事件进行并行处理。

```
EventQueue::proceed() {
    // 取出当前时间点的所有事件
    auto& events = event_queue.front();

    // 分析事件间的依赖关系
    // 对独立事件并行执行（OpenMP / thread pool）
    parallel_for(independent_events) {
        event.invoke();
    }
}
```

**映射到 ASTRA-sim**：

当前仿真中，同一时刻的典型事件组合：
- 多个 `link_become_free` 事件（不同 Link 变空闲 → 独立）
- 多个 `chunk_arrived_next_device` 事件（不同 Chunk 到达不同设备 → 可能独立）
- 混合的 `link_become_free` + `chunk_arrived` 事件（如果涉及同一 Link → 有依赖）

**关键挑战**：
- `chunk_arrived_next_device` 回调会调用 `Device::send()` → `Link::send()`，可能修改 Link 的 `busy` 状态和 `pending_chunks`
- 两个事件如果操作同一个 Link，必须串行
- 事件回调可能**产生新的当前时刻事件**（如 `link_free_time == current_time` 当 serialization_delay 为 0 时）

**实现方案**：
1. 按 Link 或 Device 分组：将同一时刻的事件按涉及的 Device/Link 分组
2. 不同组的事件可以并行
3. 同组内的事件串行
4. 新产生的事件如果是当前时刻的，放入下一轮迭代

**改造量估计**：~500-1000 行，主要修改 EventQueue 和 EventList。

**预期加速**：取决于同一时刻的事件数量和独立程度。估计 **1.5-3x**。对于 128 GPU 的大规模集合通信，同一时刻可能有几十到上百个独立事件。

### 3.4 方案 D：EventQueue 性能优化（非并行化，但高收益）

**分析当前瓶颈**：

`EventQueue::schedule_event()` 使用 **线性扫描** 插入事件：

```cpp
// EventQueue.cpp:50-51 -- O(N) 线性扫描！
auto event_list_it = event_queue.begin();
while (event_list_it != event_queue.end() && event_list_it->get_event_time() < event_time) {
    event_list_it++;
}
```

这在事件数量大时是 **O(N)** 的。对于 128 GPU × 大量集合通信，事件队列可能有数万到数十万个时间点。

**优化方案**：
1. **替换为优先队列**（`std::priority_queue` 或 `std::map<EventTime, EventList>`）：O(log N) 插入
2. **使用 Calendar Queue**：O(1) 平均插入，适合 DES
3. **使用 Ladder Queue**：另一种 O(1) 平均的 DES 专用队列

**改造量估计**：~100-200 行，仅修改 EventQueue 实现。

**预期加速**：如果事件插入是主要瓶颈，可获得 **2-10x 加速**，几乎无风险。

### 3.5 方案 E：分层仿真 + 子拓扑并行

**原理**：利用拓扑的层次结构，将仿真分为可独立执行的子仿真。

```
   ┌─── 子拓扑 1: GPU 0-31 + Switch 128-131,132-163,164 ───┐
   │                                                          │
   │  ┌─── 子拓扑 2: GPU 32-63 + Switch 165-168,... ───┐    │
   │  │                                                   │    │
   │  │  ┌─── 子拓扑 3: GPU 64-95 + ... ───┐            │    │
   │  │  │                                    │            │    │
   │  │  │  ┌─── 子拓扑 4: GPU 96-127 ───┐  │            │    │
   │  │  │  │                               │  │            │    │
   ├──┼──┼──┼─── Spine Switch 276 ─────────┤──┤────────────┤────┤
   └──┴──┴──┴───────────────────────────────┴──┴────────────┴────┘
```

当集合通信被分解为子拓扑内的通信时（如 8-GPU ring within one rack），这些子通信可以并行仿真。跨子拓扑的通信需要同步。

**改造量估计**：~1000-2000 行。

**预期加速**：对于 rack-local 通信主导的场景可达 **2-4x**。

## 4. 综合建议

### 4.1 推荐实施路径（按性价比排序）

| 优先级 | 方案 | 改动量 | 风险 | 预期加速 | 推荐度 |
|--------|------|--------|------|----------|--------|
| **P0** | **D: EventQueue 优化** | 100-200 行 | 极低 | 2-10x | ★★★★★ |
| **P1** | **C: 同时刻事件并行** | 500-1000 行 | 低 | 1.5-3x | ★★★★ |
| P2 | E: 分层子拓扑并行 | 1000-2000 行 | 中 | 2-4x | ★★★ |
| P3 | A: 保守 PDES | 3000-5000 行 | 高 | 2-5x | ★★ |
| P4 | B: 乐观 PDES | 5000-8000 行 | 极高 | 5-10x | ★ |

### 4.2 具体实施建议

#### 第一步（立即可做）：EventQueue 优化

将 `EventQueue` 的底层数据结构从 `std::list<EventList>` 替换为 `std::map<EventTime, EventList>` 或自定义 Calendar Queue。这是纯粹的数据结构优化，不改变任何仿真语义。

需要修改的文件：
- `extern/network_backend/analytical/common/event-queue/EventQueue.cpp`
- `extern/network_backend/analytical/include/astra-network-analytical/common/EventQueue.h`

验证方法：运行同一 workload，对比输出日志是否 bit-identical。

#### 第二步（中等工作量）：同时刻事件并行

在 `EventList::invoke_events()` 中：
1. 预扫描事件列表，提取每个回调的"目标对象"（Link 或 Device）
2. 按目标对象分组
3. 使用线程池并行执行不同组
4. 同步所有组完成后，处理新产生的事件

需要额外保护的共享状态：
- `CallbackTracker` → 加 mutex 或改为 per-NPU tracker
- `ChunkIdGenerator` → 加 atomic counter
- `EventQueue::schedule_event()` → 加 mutex（新事件暂存到 thread-local buffer，批量合并）

### 4.3 不建议的方案

**直接的 "GPU/Switch 作为线程 + Link 作为 Channel" 方案不可行**，原因总结：

1. DES 仿真的虚拟时间语义无法直接映射到真实线程并发
2. 因果一致性要求全局时间同步，而简单的 channel 模型没有时间概念
3. 事件回调的同步调用链（`chunk_arrived` → `Device::send` → `Link::send` → `schedule_event`）跨越多个"线程"边界
4. 全局共享状态（`EventQueue`、`CallbackTracker`、`Sys::all_sys`）过于密集
5. 即使加锁保护，锁竞争也会严重降低性能

## 5. 补充：Profile 分析建议

在实施任何优化前，建议先 profile 确认性能瓶颈：

```bash
# 使用 perf 采样
perf record -g ./AstraSim_Analytical_Congestion_Aware [参数...]
perf report

# 使用 callgrind（更详细但更慢）
valgrind --tool=callgrind ./AstraSim_Analytical_Congestion_Aware [参数...]
kcachegrind callgrind.out.*
```

重点关注：
- `EventQueue::schedule_event()` 的耗时占比（验证 O(N) 线性扫描瓶颈）
- `EventQueue::proceed()` vs `EventList::invoke_events()` 的耗时比例
- `Chunk::chunk_arrived_next_device()` 和 `Link::link_become_free()` 的调用频率
- `CallbackTracker::search_entry()` 的查找开销

如果 `schedule_event` 确实占大比例时间（预期 >30%），那么单纯的 EventQueue 数据结构优化就能获得显著加速。
