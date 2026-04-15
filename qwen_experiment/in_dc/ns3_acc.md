# ns-3 / Astra-Sim 仿真加速分析

## 结论摘要

本次实验路径下，仿真慢的原因主要分成两个阶段：

1. **启动阶段热点**在 `AstraSim::Workload::Workload -> Chakra::FeederV3::ETFeeder::build_index_dependancy_cache`，CPU 时间大量消耗在 `std::unordered_map/std::unordered_set` 的 `rehash/find/allocate` 与 `malloc` 上。也就是说，**workload 依赖索引构建本身就很重**。
2. **steady-state 仿真阶段热点**主要在 ns-3 事件循环本身，包括：
   - `ns3::QbbNetDevice::{TransmitStart, TransmitComplete, DequeueAndTransmit}`
   - `ns3::int64x64_t::Udiv`
   - `ns3::DataRate::Calculate*TxTime`
   - `ns3::HeapScheduler::{IsLessStrictly, TopDown, Exch}`
   - `ns3::Packet` / `ns3::Object` 的引用计数与析构

因此，当前瓶颈更像是：

- **前期 workload 解析/建图开销大**
- **后期离散事件数量过多，事件调度与包对象处理开销高**

而不是简单的“磁盘写 trace”单点瓶颈。

## perf 分析结果

### 1. perf 权限与环境

- `sudo -n true` 已可用
- `/proc/sys/kernel/perf_event_paranoid = 1`
- `perf version 5.15.198`

### 2. perf stat（20s）

对 `./ns3 ...` 直接采样得到：

- `task-clock`: 20019 ms
- `CPUs utilized`: `0.994`
- `cycles`: `91,441,159,547`
- `instructions`: `167,009,751,024`
- `IPC`: `1.83`
- `user`: `18.96s`
- `sys`: `1.18s`

说明该进程在采样窗口内基本是 **单核 CPU 打满**，更偏向 **CPU-bound**，不是主要卡在内核态 I/O。

### 3. 启动阶段热点（启动后立即采样）

调用路径集中在：

`main -> AstraSim::Sys::Sys -> AstraSim::Workload::Workload -> Chakra::FeederV3::ETFeeder::ETFeeder -> build_index_dependancy_cache`

flat hotspot 典型项包括：

- `std::__detail::_Hash_node...::_M_next`
- `std::_Hashtable...::_M_find_before_node`
- `malloc`
- `operator new`
- `unordered_map::operator[]`
- `unordered_set::insert`

结论：**启动慢的重要原因是 Chakra ET workload 的依赖关系索引构建。**

### 4. steady-state 热点（先运行 60s，再 attach perf 20s）

主要热点如下：

- `ns3::Ptr<ns3::Packet>::~Ptr`
- `ns3::SimpleRefCount<...>::Ref / Unref`
- `ns3::QbbNetDevice::TransmitComplete`
- `ns3::QbbNetDevice::TransmitStart`
- `ns3::QbbNetDevice::DequeueAndTransmit`
- `ns3::int64x64_t::Udiv`
- `ns3::DataRate::CalculateBitsTxTime / CalculateBytesTxTime`
- `ns3::HeapScheduler::IsLessStrictly`
- `ns3::HeapScheduler::TopDown`
- `ns3::HeapScheduler::Exch`

结论：**steady-state 慢的核心是大量离散事件处理、调度器比较/堆维护，以及 packet 对象生命周期成本。**

## 对“能否改成并行程序”的判断

当前这条 Astra-Sim + ns-3 前端路径，本质上仍是：

- 单进程
- 单个 ns-3 事件队列
- 一次 `Simulator::Run()`

虽然仓库里的 ns-3 是带 MPI 编译支持的，但当前实验前端没有真正走 distributed ns-3 的运行路径。因此：

- **不能简单通过加线程就获得明显收益**
- 想做真正并行，需要较大改造：把 NPU / node / event queue 分区，并切换到 distributed ns-3 / MPI 运行模型

这不是一个“小改动调参”问题，而是一个 **架构级重构**。

## 哪些方法最有希望明显提速

### 优先级 1：减少 workload 初始化开销

因为启动阶段大量时间花在 `ETFeeder::build_index_dependancy_cache`：

- 优先检查 Chakra ETFeeder 是否能：
  - 复用依赖索引缓存
  - 预构建并序列化缓存
  - 减少 `unordered_map/unordered_set` 的反复扩容
  - 在建图前 `reserve`
- 如果同一 workload 会重复跑多次，**最值得做的是把依赖索引离线化/缓存化**

这类优化通常**不影响仿真精度**，但对启动时间很敏感。

### 优先级 2：减少 steady-state 事件数

当前 steady-state 热点说明包级事件很多。可优先考虑：

1. **尽量维持较大的包载荷**
   - 当前 `PACKET_PAYLOAD_SIZE 9000` 已经是较友好的 jumbo 配置
   - 不建议再调小，否则事件数通常会更多

2. **减少不必要的 packet/subflow 切分**
   - 若上层或前端有额外 subflow 拆分，事件数会放大
   - 这类优化通常对速度帮助大，但要评估是否影响通信细节保真度

3. **检查是否可以降低对每个包的细粒度模拟**
   - 若实验目标更偏算法级吞吐/时延趋势，而非交换机细节，可考虑更粗粒度建模
   - 但这会涉及模型抽象层面的取舍

### 优先级 3：调度器 A/B 测试

当前配置使用：

- `NS3_SCHEDULER ns3::HeapScheduler`

steady-state 热点中，`HeapScheduler` 相关函数占比明显，因此建议做 A/B 测试：

- `ns3::HeapScheduler`
- `ns3::CalendarScheduler`
- `ns3::MapScheduler`

这个方向的优点是：

- **不改仿真逻辑**
- **不影响精度**
- 实现成本低

建议直接用同一 workload 做三组短跑对比 wall time。

### 优先级 4：继续控制 tracing，但它不是本次 perf 的头号热点

之前静态分析里发现：

- `mix.tr` 体积很大
- `trace.txt` 覆盖 64 个节点
- `ENABLE_TRACE 1` 可能隐含开启多类 trace

虽然这次 perf 没显示 `write/fprintf` 是前排 CPU 热点，但 trace 仍可能：

- 增加总运行时间
- 放大磁盘占用
- 拉高尾部阶段开销

因此仍建议：

- 非必要时关闭 `ENABLE_TRACE`
- 显式关闭 `ENABLE_PFC_TRACE`
- 显式关闭 `ENABLE_FCT_TRACE`
- 显式关闭 `ENABLE_QLEN_MONITOR`
- 若必须保留 trace，只跟踪少量代表性节点

这是一个**低风险、易实施**的优化项。

## 建议的实际优化顺序

### 方案 A：低风险、优先尝试

1. 关闭不必要 trace
2. 对比不同 `NS3_SCHEDULER`
3. 保持 `PACKET_PAYLOAD_SIZE 9000`
4. 缩小 `trace.txt` 节点范围

特点：

- 改动小
- 基本不影响精度
- 可快速得到收益

### 方案 B：中收益方向

1. 优化 Chakra `ETFeeder::build_index_dependancy_cache`
2. 减少 `unordered_map/unordered_set` 重哈希与动态分配
3. 对 workload 依赖图做缓存/离线索引

特点：

- 对启动耗时帮助会非常明显
- 通常不改变仿真结果
- 需要改源码

### 方案 C：高投入方向

1. 研究 distributed ns-3 / MPI 运行
2. 把当前 Astra 前端改造成多进程分区仿真
3. 重新梳理跨分区事件同步

特点：

- 潜在收益大
- 实现复杂
- 风险高，不适合作为第一步优化

## 当前最重要的结论

如果目标是“**尽量不影响精度，但明显加速**”，建议优先顺序是：

1. **先做配置层优化**：trace 精简 + scheduler A/B
2. **再做源码层优化**：重点攻 `ETFeeder::build_index_dependancy_cache`
3. **最后才考虑并行化重构**

换句话说，当前最值得投入的不是“把单线程直接改并行”，而是：

- **减少初始化建图成本**
- **减少 steady-state 事件调度成本**

这两项更贴合 perf 采到的真实热点。
