# inter_dc_dp_localsgd htsim 跑不通 —— 调试 handoff

> 日期：2026-04-29  
> 仓库路径：`/data/ps/sow/astra-sim`  
> 实验目录：`llama_experiment/inter_dc_dp_localsgd/`

## 0. 一句话现状

- **Bug A（uint64 wrap → assert(when>=now())）已修复**：补丁打在 `astra-sim/network_frontend/htsim/proto/HTSimProto{RoCE,Tcp,HPCC}.cc`，未提交。  
- **Bug B（仿真跑不到 all-finished，rank 全部卡住）未修复**：跟 inter-DC WAN BDP × 当前 GatewayQueue 大小有关，是接下来要解决的。

跑命令：
```bash
cd /data/ps/sow/astra-sim/llama_experiment/inter_dc_dp_localsgd
ASTRASIM_HTSIM_ENDTIME_SEC=0 bash run_htsim.sh
```
当前结果：进程正常 `exit 0`，但 stderr 末尾 `Warning: Simulation timed out.`，`log/log.log` 里没有任何 `sys[*] finished, * cycles`。

## 1. 实验配置一览

- 工作负载：`/data/ps/sow/dnn_workload/llama3_8b/attstandard_sgdlocal_layer32_iter8_batch128_micro2_seq8192_dp4_tp1_pp4_sp1_ep1`，16 个 `workload.{0..15}.et` + `workload.json`（36 个 comm group）。
- 拓扑（`topology.txt`）：41 节点 / 25 交换机 / 52 链路。NPU 0–15，跨 4 个 DC（每个 DC 4 个 NPU）。WAN 链路：
  ```
  40 21 800Gbps 0.562ms 0
  40 27 800Gbps 0.501ms 0
  40 33 800Gbps 0.402ms 0
  40 39 800Gbps 0.317ms 0
  ```
- 分子：4-tier 树（host NIC `4800Gbps`，到中转 ToR `200Gbps`，到 DC 网关 `200Gbps`，到 WAN 中心 800Gbps）。
- `ASTRASIM_HTSIM_NIC_GBPS` 没设；`recommended_nic_linkspeed_bps()` 返回 backbone min = **200 Gbps**（log 头：`[roce] host NIC pacing = 200 Gbps`）。
- `analytical_network.yml`：`topology: [Custom]`，`topology_file: "topology.txt"`。

参考的对照实验（同 topology 但 WAN 退化为 0.0006ms）：`llama_experiment/inter_dc_dp/`，run_htsim.sh 把 `ASTRASIM_HTSIM_ENDTIME_SEC` 默认设为 1000。

## 2. Bug A —— uint64 时间溢出炸 assert

### 用户最初的失败日志
```
[roce] host NIC pacing = 200 Gbps
[roce] actual nodes 41
AstraSim_HTSim: eventlist.cpp:115: static void EventList::sourceIsPending(...): Assertion `when>=now()' failed.
```

### 根因
1. `HTSimProtoRoCE::HTSimProtoRoCE` 里 `c = std::make_unique<Clock>(timeFromSec(0.5), eventlist)` —— 这个 `Clock` 只是个进度指示器（verbose 时打 `.|`），无限自重排，每 0.5 s simtime 一次。
2. 用户改了同一文件：把默认 endtime 由 `1000.0` 改成 `0.0` (= 「unlimited」)，并在 `setEndtime` 外面包了 `if (endtime_sec > 0)`。run_htsim.sh 默认也改成 `ASTRASIM_HTSIM_ENDTIME_SEC=0`。
3. 这下 unlimited 模式下，`_endtime` 永远是 0，`sourceIsPending` 的 `if (_endtime==0 || when<_endtime)` 不再过滤任何 `when`。
4. inter-DC 的 flow 跑不完（见 §3） → `CompletionTracker` 不触发 `stop_simulation()` → heap 里只剩 Clock，事件循环以 0.5 s/格疯狂前推 `_lasteventtime`。
5. `simtime_picosec` 是 `uint64_t`（`extern/network_backend/csg-htsim/sim/config.h:26`）。当 `now() ≈ UINT64_MAX − 73 ns`（即约 5848 simulated 年），`Clock::doNextEvent` 调 `sourceIsPendingRel(*this, _period)` 即 `sourceIsPending(now() + 5e11 ps)` → uint64 溢出 wrap 到 `~426 GS` → `when < now()` → assert 炸。

### 用过的诊断手段
往 `extern/network_backend/csg-htsim/sim/eventlist.cpp::sourceIsPending` 注入 `backtrace()`/`backtrace_symbols_fd`（需要 `<execinfo.h>`），重建后再跑，通过 `addr2line -f -i -C -e .../AstraSim_HTSim <addr>` 把堆栈解到源码行。完整链：
```
EventList::sourceIsPending  (eventlist.cpp:115)
Clock::doNextEvent          (clock.cpp:15)
EventList::doNextEvent      (eventlist.cpp:107)
HTSim::HTSimProtoRoCE::run
main
_start
```
这个机器装不了 `gdb`（`apt-get install gdb` 被沙盒拒了），用 `backtrace()` 替代是当前会话验证可行的姿势。下次需要可以直接抄。

### 当前补丁（未 commit）
三处协议构造里把 unlimited 兜底成 1e6 s simtime（≈11.5 天，远小于 `UINT64_MAX/timeFromSec ≈ 5848 年`）：

```cpp
// HTSimProto{RoCE,Tcp,HPCC}.cc 同处
if (endtime_sec > 0) {
    eventlist.setEndtime(timeFromSec(endtime_sec));
} else {
    // 0 = "unlimited" 兜底：避免 Clock 自循环把 simtime 推到 uint64 溢出区域。
    eventlist.setEndtime(timeFromSec(1.0e6));
}
```

效果：`exit 134` → `exit 0`。

### 备选/更彻底的方案（没采纳，留作参考）
- 在 `endtime_sec=0` 时**根本不创建 Clock**（它只是 verbose 时打点）。
- 让 Clock 在 verbose 关闭时不自重排（patch `clock.cpp::doNextEvent`，外面有 `_astrasim_verbose` 分支）。
- 任何上层在 heap 即将 wrap 时主动 `setEndtime(now())` 优雅停机。

如果接下来打算让 unlimited 真的语义无界，建议改 Clock；当前补丁是快速止血。

## 3. Bug B —— rank 卡住，never finished（这是接下来要解的）

### 现象
- 修完 Bug A 之后 ENDTIME=0 跑下来 11.5 天 simtime 还是 0/16 finished。
- ENDTIME=10s 之内已经完成约 240 个 flow（参考 verbose run），simtime ~135 ms 时 flow 频次明显下来。
- ENDTIME=300s 跑满 600 s wallclock 仍未结束，flow 一直在 `Send flow … to {12,14,...}` 这种节奏出现，看上去 inter-DC 那批跨 region 的 allreduce 在重传循环里走不动。

### 大概率根因（待验证）
- 一条 WAN 链路：800 Gbps × 0.5 ms = **BDP ≈ 50 MB**；RTT ~1 ms 算下来更大。
- 当前 `GenericCustomTopology` 的 GatewayQueue 默认是 `4 × kDefaultQueueBytes = 4 MB`（见 `astra-sim/network_frontend/htsim/topology/GenericCustomTopology.cc::gateway_queue_size_bytes_default`）。
- BDP ≫ 4 MB → 大量丢包 → RoCE go-back-N（`_rto = 20 ms` 起步，`roce.cpp:59`）→ 实际有效带宽塌方，long flow 永远完不了。

### 推荐先尝试
1. 直接把 GatewayQueue 顶大：
   ```bash
   ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES=$((128 * 1024 * 1024)) \
   ASTRASIM_HTSIM_ENDTIME_SEC=300 \
       bash run_htsim.sh
   ```
   如果仍然 timeout，把队列再翻倍 / 256 MB；实在不行考虑改用 `lossless` queue（`ASTRASIM_HTSIM_QUEUE_TYPE=lossless`）+ PFC 阈值放宽。
2. 跑 `dcqcn` 协议（`HTSIM_PROTO=dcqcn bash run_htsim.sh`），自带 ECN+AIMD，能压住带宽不让队列爆掉。可一并 `ASTRASIM_HTSIM_DCQCN_KMIN_KB=4096 KMAX_KB=32768`（数字对 50 MB BDP 取个合理百分比）。
3. 验收信号：`grep -c 'sys\[.*\] finished, .* cycles' log/log.log` == 16，并且 `run_htsim.log` 末尾不再有 `Warning: Simulation timed out.`。

### 不要先做的事
- **不要**拿 `inter_dc_dp/topology.txt`（WAN 退化成 0.0006 ms）当锚 —— 那是个调试用的退化拓扑，跑得通对当前 inter-DC 模拟没参考价值。
- **不要**简单地在 run_htsim.sh 把 ENDTIME 调小再说"跑通了"—— 16/16 finished 是真接受标准，timeout 退出不是。

## 4. 关键文件 & 函数地图

| 文件 | 作用 |
| ---- | ---- |
| `astra-sim/network_frontend/htsim/HTSimMain.cc` | 入口；构造 16 个 `Sys`，`workload->fire()` 后调 `ht.run()`。 |
| `astra-sim/network_frontend/htsim/HTSimSession.cc` | session 静态 map（send_waiting / recv_waiting / msg_standby / flow_id_to_tag），`schedule_astra_event` 把 AstraSim 调度桥到 htsim eventlist。 |
| `astra-sim/network_frontend/htsim/HTSimNetworkApi.cc` | `sim_send` / `sim_schedule` / `sim_recv`；`CompletionTracker::mark_rank_as_finished` → `htsim_session.stop_simulation()`。 |
| `astra-sim/network_frontend/htsim/proto/HTSimProtoRoCE.cc` | RoCE 协议端构造（**Bug A 补丁就在这里 §11.3 速度杠杆下面**），`schedule_htsim_event` 给每条 flow 建 `RoceSrc`/`RoceSink`，`run()` 跑 eventlist 主循环。 |
| `astra-sim/network_frontend/htsim/topology/GenericCustomTopology.cc` | 解析 `topology.txt`、建 Queue/Pipe、Dijkstra 路由。GatewayQueue 大小默认值在 `gateway_queue_size_bytes_default()`（`ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES` 覆盖）。 |
| `extern/network_backend/csg-htsim/sim/eventlist.{h,cpp}` | EventList 全局单例，`_lasteventtime` 单调递增，`sourceIsPending` 那条 assert 是 Bug A 的爆点。 |
| `extern/network_backend/csg-htsim/sim/clock.cpp` | `Clock::doNextEvent` —— 进度 ticker，无限自重排。 |
| `extern/network_backend/csg-htsim/sim/roce.cpp` | RoceSrc/RoceSink；`_rto = 20ms` 起步；DCQCN AIMD 在 `processAck` 里。 |

## 5. 复现脚本（手抄即可）

```bash
# 0. 仓库根
cd /data/ps/sow/astra-sim

# 1. 重建 htsim 后端（如有改动）
bash build/astra_htsim/build.sh

# 2. 当前实验目录跑 RoCE
cd llama_experiment/inter_dc_dp_localsgd

# 2.a. 验 Bug A 修复有效（ENDTIME=0 不再炸）
ASTRASIM_HTSIM_ENDTIME_SEC=0 bash run_htsim.sh; echo "rc=$?"

# 2.b. 加上 verbose 看 flow 进度（注意会刷屏 + 大幅减速）
ASTRASIM_HTSIM_VERBOSE=1 ASTRASIM_HTSIM_ENDTIME_SEC=30 bash run_htsim.sh \
    2>&1 | grep -E 'startflow|finished at|finished,' | tail -50

# 2.c. 验收：是否 16/16 finished
grep -c 'sys\[.*\] finished, .* cycles' log/log.log
```

## 6. 待办

- [x] 调 GatewayQueue / 协议参数让 Bug B 能跑到 16/16 finished（建议从 §3 推荐 1 开始）。**已解，根因不是 GatewayQueue，见 §7。**
- [ ] 跑通后把 §3 的最终参数写回 `htsim_user_guide.md` 「inter-DC LocalSGD」一节，作为长跑配置。
- [ ] 确认 Bug A 的兜底补丁是否要落 commit；如要，建议同时把 Clock 改成 verbose-only 自重排，避免兜底值（1e6 s）成为新的"魔法常数"。
- [ ] 顺便核一下 `inter_dc_dp/topology.txt` 那个 `0.0006ms` WAN 是不是历史遗留的退化值 —— 如果是，要么删掉这个实验，要么把它跟 inter_dc_dp_localsgd 拉齐到真实 WAN latency。

## 7. Bug B 实际根因 & 修复（2026-04-29 接力会话补记）

§3 的诊断方向（GatewayQueue 太小）走偏了。实际根因是 **csg-htsim 的 RoCE 协议没有 RTO timer，重传完全靠 sink 端的 NACK 触发；一旦 NACK 在反向路径被 drop，sender 永远不重传，那条 flow 永远 stuck**。跨 DC 1.1 ms RTT × 默认 1 MB 队列下，drop 大概率在 ring AllReduce 的最后一两个 hop 命中，受害 flow 的 rank 永远完不成 collective → CompletionTracker 永远不到 16/16。

### 诊断步骤（可复用）
1. **GatewayQueue 顶到 128 MB 仍然 0/16 finished** —— 排除"BDP 不够缓冲"。stdout 里看 `[generic] GatewayQueue: 4 inter-region links at 131072 KB buffer` 才说明设置确实生效。注意 `topology.txt` 的 4 条 WAN 链路必须显式写 `wan` 第 6 列 token（或用 `#REGIONS` 段），否则 `is_gateway=false`，env 设了也没用。这是 §3 的 handoff 没意识到的隐藏前提。
2. **加诊断 dump**（已落到 `astra-sim/network_frontend/htsim/HTSimMain.cc` 末尾，`Warning: Simulation timed out` 后）：dump `send_waiting / recv_waiting / msg_standby` 的 size + 头几条 entry。0 RTO + 0 NACK 是误导（`go back n` 串只在 `_log_me==true` 时打），dump 才是 ground truth。
3. dump 显示卡住的 4 个 flow 全是 **每个 DC 内部 ring AllReduce 的最后一个 chunk**（DC0: 3→0; DC1: 6→7 等）。这些 flow 在 verbose log 里有 `Send flow N` + `startflow roce_X_Y at T`，但**没有** `Flow … finished` —— 协议层认为 send 已完成但 ack 没回来。
4. 看 `extern/network_backend/csg-htsim/sim/roce.cpp` 的 `processNack` / `doNextEvent`：sender 只在收 NACK 时才 `_highest_sent = _last_acked` 并重新 schedule send；没有定时器兜底。NACK loss = forever stuck。

### 修复（已写到 `llama_experiment/inter_dc_dp_localsgd/run_htsim.sh` 默认）
```bash
export ASTRASIM_HTSIM_QUEUE_TYPE=lossless          # PFC 反压，根除 drop
export ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES=$((128 * 1024 * 1024))  # 容纳 WAN BDP
export ASTRASIM_HTSIM_ENDTIME_SEC=0                # unlimited（兜底见 Bug A）
```
配套 `topology.txt` 的 4 条 WAN 链路尾巴加 `wan` token：
```
40 21 800Gbps 0.562ms 0 wan
40 27 800Gbps 0.501ms 0 wan
40 33 800Gbps 0.402ms 0 wan
40 39 800Gbps 0.317ms 0 wan
```

### 验收（已通过）
- `bash run_htsim.sh` zero-config，~50 s wallclock 跑完。
- `grep -c 'sys\[.*\] finished, .* cycles' log/log.log` = **16**
- `run_htsim.log` 末尾无 `Warning: Simulation timed out.`
- htsim 报 ~136.5 B cycles，跟 analytical 的 136.35 B 差 < 0.1%，packet-level 与 fluid 几乎重合。

### 留给后人
- **不要**只调 GatewayQueue 然后看到 0 finished 就以为是 buffer 不够 —— 顺手 dump 一下 pending maps，几行就能定位到底是 send-side 卡（队列爆 / RTO storm）还是 recv-side 卡（NACK drop 死锁 / chunk mismatch）。
- 长期方案是给 csg-htsim 的 RoCE 加 RTO timer 兜底；短期就用 lossless。dcqcn 协议其实 underlying 还是同一个 RoCE，没有补这个 timer，所以 dcqcn 也不能替代 lossless。
- §3 的 handoff 推荐里 plan B（dcqcn）和 plan C（lossless）相比，**应该把 lossless 摆到 plan A**：因为 lossless 直接消除丢包，是当前实现下唯一能保证 cross-DC long-RTT 完成的姿势。
