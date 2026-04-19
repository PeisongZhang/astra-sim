# Qwen-32B LAYER=64 Analytical 仿真死锁修复

## 1. 问题现象

- 运行脚本：`astra-sim/qwen_experiment/in_dc/analytical.sh`
- 复现条件：`LAYER=64` 的 workload（`dnn_workload/qwen_32b/standard_standard_64_1_128_2_4096/`）
- 配置：`DP=4 TP=8 PP=4 SP=1`（共 128 NPU）
- 其他规模（`LAYER=4/8/16/32`）均能正常完成
- 失败日志：`log/analytical_20260419_114926.log`

失败日志中可以看到：

```
[analytical] Pending callbacks before cleanup: 432
[analytical]   tag=559799 src=32 dst=0 size=5335040 chunk_id=0 send=0 recv=1 finished=0
...
[HardwareResource] [critical] !!!Hardware Resource sys.id=2 has unreleased nodes!!!
...
+ SIM_EXIT=2
```

- 只有 `sys[64]..sys[127]`（PP stage 2 & 3）顺利完成；
- `sys[0]..sys[63]`（PP stage 0 & 1）全部卡死；
- 432 个未完成的 recv 全部是 `src ∈ [32,63] → dst ∈ [0,31]`，即 PP stage 1 → stage 0 的反向梯度通道从未发出。

## 2. 定位过程

### 2.1 确认是否为 STG 侧问题

对比 `LAYER=32` 与 `LAYER=64` 的 .et 文件结构：

| 量 | LAYER=32 | LAYER=64 |
|---|---|---|
| rank 0 总节点 | 6764 | 13444 |
| rank 0 COMP(type=4) | 5442 | 10834 |
| rank 0 COMM_COLL(type=7) | 1290 | 2578 |
| rank 0 SEND(type=5) | 16 | 16 |
| rank 0 RECV(type=6) | 16 | 16 |
| rank 32 SEND | 32 | 32 |
| rank 32 RECV | 32 | 32 |

**结论**：SEND / RECV 数量完全相同，只是中间 COMP / COLL 数量翻倍。STG 生成的 graph 结构是对齐的，不是 STG 的 bug。

### 2.2 ASTRA_ANALYTICAL_DEBUG_STUCK 抓卡死现场

开启 `ASTRA_ANALYTICAL_DEBUG_STUCK=1` 后，每个未结束的 sys 会在仿真循环退出前打印其 ready_list：

```
[analytical-stuck] sys=32 front_stream=20023616 ready_streams=[20023616,...,20023619]  (4个)
[analytical-stuck] sys=40 front_stream=8896     ready_streams=[8896,8897,...,8900]     (5个)
[analytical-stuck] sys=44 front_stream=20023616 (4个)
...
```

TP group 37 = `[32, 36, 40, 44, 48, 52, 56, 60]`。
同一 TP 组中：`sys=32/36/44/48/52/56/60` 都卡在 stream **20023616**，而 `sys=40` 却卡在 stream **8896**。
collective 需要组内所有 rank 到达同一个 stream 才能推进，出现跨组环形等待 → 死锁。

### 2.3 两条独立的根因

#### 根因 A（潜在）：`kMaxCommGroups=128` 导致 stream_id 碰撞

`astra-sim/astra-sim/system/Sys.cc` 中 collective 的 stream_id 编码：

```cpp
constexpr int kMaxCommGroups = 128;
constexpr int kMaxStreamsPerCollective = 64;
assert(0 <= comm_group_id && comm_group_id < kMaxCommGroups);  // Release 构建会被 NDEBUG 消掉
return collective_instance_id * kMaxCommGroups * kMaxStreamsPerCollective
     + comm_group_id        * kMaxStreamsPerCollective
     + stream_index;        // 返回 int (32-bit)
```

当前 qwen workload 的 `workload.json` 中共有 **176** 个 comm group（48 个 DP/TP 组 + 128 个 SP=1 singleton 组）。

- `comm_group_id ∈ [129, 176]` 超过了 128，assert 在 Release 编译下被消除；
- 由于 `(inst, group_id)` 在 `kMaxCommGroups=128` 的模下不唯一，
  `(inst, g)` 与 `(inst-1, g+128)` 会映射到同一个 `stream_id`：
  - 例：`(2443, 165)` 与 `(2444, 37)` 都解码为 `20023616`。
- 当两个不同的 collective 用同一个 stream_id 时，`BaseStream::synchronizer` /
  `synchronizer_target` 全局表会被互相污染，导致 `ask_for_schedule()` 中
  `participants.size() == synchronization_target` 的判定永远失败。

但实测即使把 `kMaxCommGroups` 改为 1024（消除所有碰撞），死锁依旧，说明这并**不是本次的直接原因**——
`qwen_experiment` 的 singleton 组（129-176）实际上没有被任何 rank 用作 collective 的 pg（rank 114 只用 pg=47/pg=29），
所以"碰撞的另一半" `(inst-1, g+128)` 不会被实例化，不会触发真实的同步污染。
但这确实是一个**潜伏 bug**：当未来有 workload 让 `comm_group_id >= 128` 的组真的发起 collective 时，会静默碰撞进入死锁。

#### 根因 B（本次直接原因）：`active-chunks-per-dimension: 1` 在 LAYER=64 下触发调度死锁

`astra_system.json`:

```json
"active-chunks-per-dimension": 1
```

含义：每个网络维度（TP / DP / …）同一时刻最多只有 **1** 个 collective chunk 处于激活状态，其余 ready 的 collective 串行等待。

在 LAYER=64 场景：

- 每个 rank 在 TP 组中产生 2560 个 collective 实例（LAYER=32 是 1280，LAYER=16 是 640）；
- 以 `kMaxCommGroups=1024` 编码后可确认，卡住时：
  - `sys=33/37/41/57` 停在 **TP group 38 的 instance 2442**（`stream_id = 160041344`）；
  - `sys=45/46/47` 停在 **DP group 12 的 instance 1**（`stream_id = 66304`）；
  - `sys=40/42/43` 停在 **DP group 11 的 instance 1**（`stream_id = 66240`）；
  - `sys=44/48/52/56/60/32/36` 停在 **TP group 37 的 instance 2444**（`stream_id = 160172352`）；
- 形成环形依赖：
  - TP 37 需要 `sys=40` 到达，但 `sys=40` 正在等 DP 11；
  - DP 11 需要 `sys=41` 到达，但 `sys=41` 正在等 TP 38；
  - TP 38 需要 `sys=45` 到达，但 `sys=45` 正在等 DP 12；
  - DP 12 需要 `sys=44` 到达，但 `sys=44` 正在等 TP 37 → 回到起点。

当每个 dim 只允许 1 个 active chunk 时，调度器没有任何自由度去打破这个环——
所有 rank 都已经把"前序的那一个"chunk 占满，换不出空位来匹配对方期望的那一条 stream。
LAYER ≤ 32 时 collective 实例少，不同 rank 之间的进度差较小，运气足以使这个环始终不闭合；
LAYER=64 把实例数翻倍后，环必然在某一点合上。

增大 `active-chunks-per-dimension` 后，每个维度可以同时持有多个 chunk，调度器有回旋余地去同时推进 TP 和 DP 两个方向的 collective，环不再闭合。

## 3. 修复

### 3.1 直接修复：提高并发 chunk 数

`astra-sim/qwen_experiment/in_dc/astra_system.json`：

```diff
-    "active-chunks-per-dimension": 1,
+    "active-chunks-per-dimension": 8,
```

### 3.2 防御性修复：扩大 kMaxCommGroups，把 assert 换成运行时 panic

`astra-sim/astra-sim/system/Sys.cc` `Sys::generate_collective` 内的 `allocate_stream_id`：

- `kMaxCommGroups`：`128` → `1024`（当前 workload 最大 176，留足余量；`int stream_id` 可承载 `inst_id` 上限约 32K，足够 LAYER=128 级别 workload）；
- 将两条 `assert` 替换为 `sys_panic(...)`，Release 下也会真正报错，避免再次静默走进 stream_id 碰撞；
- 在顶部补上一段注释说明编码规则与死锁后果。

核心 diff：

```cpp
auto allocate_stream_id = [&](int stream_index) {
    if (collective_instance_id != uint64_t(-1)) {
        // stream_id 把 (collective_instance_id, comm_group_id, stream_index)
        // 编码成一个 int，必须对所有"同时存活"的三元组保持无碰撞，否则不同
        // collective 会混用同一个 stream_id，污染 BaseStream::synchronizer /
        // synchronizer_target，使 ask_for_schedule 中
        // participants.size() == synchronization_target 的校验永久失败→死锁。
        // kMaxCommGroups 必须严格大于 workload.json 里最大的 comm_group_id，
        // 否则高编号 group 会在 128 模下与低编号 group 发生环绕碰撞。
        constexpr int kMaxCommGroups = 1024;
        constexpr int kMaxStreamsPerCollective = 64;
        const int comm_group_id =
            communicator_group != nullptr ? communicator_group->get_id() : 0;
        if (comm_group_id < 0 || comm_group_id >= kMaxCommGroups) {
            sys_panic("comm_group_id=" + std::to_string(comm_group_id) +
                      " exceeds kMaxCommGroups=" +
                      std::to_string(kMaxCommGroups) +
                      "; raise kMaxCommGroups in Sys.cc");
        }
        if (stream_index < 0 || stream_index >= kMaxStreamsPerCollective) {
            sys_panic("stream_index=" + std::to_string(stream_index) +
                      " exceeds kMaxStreamsPerCollective=" +
                      std::to_string(kMaxStreamsPerCollective));
        }
        return static_cast<int>(
            collective_instance_id * kMaxCommGroups * kMaxStreamsPerCollective
            + comm_group_id * kMaxStreamsPerCollective + stream_index);
    }
    ...
};
```

## 4. 验证

### 4.1 LAYER=64 端到端通过

直接跑 `bash astra-sim/qwen_experiment/in_dc/analytical.sh` 得到：

```
exit=0
Pending callbacks: 0
unreleased nodes: 0
```

主仿真 cycles（chunks=8，kMaxCommGroups=1024）：

| sys | cycles | exposed_comm |
|---|---|---|
| sys[127] | 11,909,684,194 | 8,838,301,130 |
| sys[96]  | 11,909,923,618 | 8,838,540,554 |
| sys[64]  | 12,242,687,485 | 9,424,191,133 |
| sys[32]  | 12,771,097,482 | 9,952,601,130 |
| sys[0]   | **13,447,949,494** | 10,376,785,278 |

最后完成的 GPU 是 `sys[0]`（PP stage 0 首 rank），符合 1F1B pipeline 的预期：stage 0 最早启动、最晚结束。

### 4.2 LAYER=32 无回归

`kMaxCommGroups=1024` 配合原 `chunks=1` 的 `astra_system.json`：

```
exit=0
Pending callbacks: 0
sys[0] finished, 15,405,618,897 cycles
```

仍能正常通过。

`chunks=8` 下：

```
sys[0] finished, 6,948,266,904 cycles
```

规模 ≈ LAYER=64 的一半，符合层数翻倍的预期。

### 4.3 `kMaxCommGroups=128` + `chunks=8`（对照实验）

用来隔离两个修复的相对作用：

```
exit=0
Pending callbacks: 0
```

说明在 `qwen_experiment/in_dc` 这份 workload 上，B 是充分条件；A 仅为防御性修复。
但保留 A 可以避免未来出现让 singleton 组也发 collective 的 workload 时再踩坑。

## 5. 影响面与后续建议

- 所有现存 `astra_system.json` 都使用 `"active-chunks-per-dimension": 1`（包括整个
  `llama_experiment/*`）。本次只修改了 `qwen_experiment/in_dc/astra_system.json`，
  其他实验（llama 系列、qwen 其它 variant）目前没有复现死锁，暂不改动。
  如果后续把 llama 层数也加到 64/80 以上，建议把它们也改成 8。

- `active-chunks-per-dimension` 并不是一个"精度/物理含义"开关，而是调度器的
  并发度配置。提高它只会让同维度多个 chunk 并行调度，理论上不会恶化精度
  （模型/网络带宽计算仍以单 chunk 为粒度）。本次实验的 LAYER=32 在
  `chunks=1` 与 `chunks=8` 之间 `sys[0]` cycles 由 15.4 B → 6.95 B，
  是 compute/comm overlap 被放开的正常结果，不是精度漂移。

- 如果担心与历史 LAYER=4/8/16/32 的 baseline 结果不可比，可以：
  1. 保留 `chunks=8` 作为 LAYER ≥ 64 的新 baseline；
  2. 重新跑 LAYER=4/8/16/32 的 `chunks=8` 版本更新 `report.md` / `report.csv`。

- `Sys.cc` 里两条 `sys_panic` 是为了**未来**避免这类静默死锁。如果将来有
  workload 的 `comm_group_id` 真的 > 1024，会立刻在仿真启动阶段报错，而不是
  跑到一半卡住。
