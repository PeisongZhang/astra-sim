# Llama3-70B 跨 DC 训练 analytical 仿真结果

生成时间：2026-04-21
仿真器：`AstraSim_Analytical_Congestion_Aware`（`astra-sim/build/astra_analytical/build/bin/`）
Workload 生成：`dnn_workload/llama3_70b/llama3_70b.sh`

---

## 1. 实验配置

### 1.1 模型 & 并行

| 字段        | 值                        |
| ----------- | ------------------------- |
| 模型         | Llama3-70B（`llama3_70b.json`）|
| `hidden_size` / `dff` / layers | 8192 / 28672 / 80 |
| heads / kv-heads (GQA) | 64 / 8           |
| vocab_size  | 128256                    |
| 并行         | DP=32, TP=8, PP=4, SP=1 → 1024 NPUs (= 128 DGX × 8 A100) |
| PP schedule | 1f1b                     |
| SGO / AR / Mixed-precision | ✔ / ✔ / ✔   |

### 1.2 超参 deviation

相较 `megatron_gpt_76b.sh` 默认（= paper arXiv:2104.04473 Table 1 row 6）：

| 字段        | paper  | 本实验   | 原因                                                          |
| ----------- | ------ | -------- | ------------------------------------------------------------- |
| `BATCH`     | 1792   | **512**  | 本机 30 GB 内存不足以承载 BATCH=1792 × ITER=2 的 ETFeeder dep graph（每 rank ~300K nodes × 3 层 dep map），实测 OOM（exit 137）。缩到 BATCH=512 后规模 ≈ `gpt_76b_1024` 参考实验的 0.76× |
| `MICROBATCH`| 2      | 2        | 保持                                                          |
| `SEQUENCE`  | 2048   | 2048     | 保持                                                          |
| `ITERATION` | 1      | **2**    | 按用户要求                                                    |
| 其余        | —      | 对齐     | `fused` attention / `1f1b` / `PP_VIRTUAL=1` / `SGO=1` / `AR=1` / `weight_sharded=0` |

每 rank 一个 iter 的微批数 = `BATCH / (MICROBATCH × DP) = 512 / (2 × 32) = 8`。

### 1.3 Workload 规模

| 版本          | 目录                                                 | 单 rank `.et` | 总计      |
| ------------- | ---------------------------------------------------- | -------------- | --------- |
| W-std (E1–E3) | `fused_standard_80_2_512_2_2048_1f1b_v1_sgo1_ar1/`   | ~5.0 MB        | 4.9 GB    |
| W-lsgd (E4)   | `fused_localsgd_80_2_512_2_2048_1f1b_v1_sgo1_ar1/`   | ~5.0 MB        | 4.9 GB    |

### 1.4 拓扑

每个 DC 内结构：NVSwitch(4800G/0.15μs) + Leaf/NIC(200G/0.5μs) + DC-spine(1600G/0.5μs)；
4 个 DC-spine 通过单个 global core 互连，WAN 链路 800G，单向时延
`{0.562, 0.501, 0.402, 0.317}` ms（= `llama_experiment/inter_dc`，上海/苏州/杭州/宁波 ↔ 嘉兴）。

| 实验                       | 拓扑文件                                            | 实体/交换机/链路 | DC 划分 |
| -------------------------- | --------------------------------------------------- | ---------------- | ------- |
| E1 `in_dc`                 | 复用 `megatron_gpt_experiment/gpt_76b_1024/topology.txt`（单 DC 2-tier） | 1281 / 257 / 2176 | 无      |
| E2 `inter_dc_pp`           | `build_topology.py --partition pp`                  | 1285 / 261 / 2180 | DGX k → DC (k // 32)：同 PP stage 共 DC |
| E3 `inter_dc_dp`           | `build_topology.py --partition dp`                  | 1285 / 261 / 2180 | DGX k → DC (k mod 4)：DP group 跨 4 DC |
| E4 `inter_dc_dp_localsgd`  | 软链 → `inter_dc_dp/topology.txt`                   | 同 E3            | 同 E3   |

### 1.5 ASTRA-sim 配置

全部 4 组共用（拷自 `megatron_gpt_experiment/gpt_76b_1024/`）：
- `astra_system.json`：LIFO / endpoint-delay=10 / active-chunks-per-dim=2 / preferred-dataset-splits=4 / ring AR / ring AG / ring RS / direct A2A / localBWAware / peak=312 TFLOPS / mem-BW=1560 GB/s / roofline on
- `logical_topo.json`：`{"logical-dims": ["1024"]}`
- `no_memory_expansion.json`
- `analytical_network.yml`：`topology: [Custom], topology_file: topology.txt`
- 运行环境：`ASTRA_EVENT_PARALLEL_THREADS=8`、`ASTRA_EVENT_PARALLEL_MIN_EVENTS=4`

---

## 2. 结果

### 2.1 关键指标（对 "last-finishing rank" 统计，即端到端 wall 时间）

| #  | 实验                       | last-fin rank | **max cycles** | wall (s) | Δ vs E1 | **TFLOPs/s/GPU** | **% of peak** | exposed comm (cycles) | Δ vs E1  |
| -- | -------------------------- | ------------- | -------------- | -------- | ------- | ---------------- | ------------- | --------------------- | -------- |
| E1 | `in_dc` (Single-DC)        | sys[104]      | 14,072,143,445 | 14.072   | —       | **84.05**        | **26.94%**    | 8,974,025,831         | —        |
| E2 | `inter_dc_pp`              | sys[104]      | 14,114,705,325 | 14.115   | +0.30%  | 83.79            | 26.86%        | 9,016,587,711         | +42 M    |
| E3 | `inter_dc_dp`              | sys[136]      | 15,897,391,476 | 15.897   | +13.0%  | 74.40            | 23.84%        | 10,799,273,862        | +1.83 G  |
| E4 | `inter_dc_dp_localsgd`     | sys[136]      | 14,161,049,805 | 14.161   | +0.63%  | 83.52            | 26.77%        | 9,062,932,191         | +89 M    |

> wall (s) = `max_cycles / 1e9`（ASTRA-sim cycles 以 ns 计）。
> TFLOPs/s/GPU 与 % of peak 的推导见 §2.6。

辅助指标（last-finishing rank 上）：

| #  | GPU time (cycles) | Comm time  | overlap    | bubble | mem util | op intensity |
| -- | ----------------- | ---------- | ---------- | ------ | -------- | ------------ |
| E1 | 5,098,117,614     | 13.60 G    | 4.62 G     | 20     | 32.4%    | 2035.7       |
| E2 | 5,098,117,614     | 13.64 G    | 4.62 G     | 47     | 32.4%    | 2035.7       |
| E3 | 5,098,117,614     | 15.42 G    | 4.62 G     | 12     | 32.4%    | 2035.7       |
| E4 | 5,098,117,614     | 13.68 G    | 4.61 G     | 35     | 32.4%    | 2035.7       |

所有实验 GPU time 完全一致（5,098,117,614 cycles）——说明 workload/并行 strat 相同，差异全部来自网络。所有实验无 error/warning/kill。

### 2.2 同一 rank 在 4 组间的比较（critical-path rank，sys[0] 代表 pp=0/tp=0/dp=0）

max cycles 的 "最后完成" rank 在 E1/E2 是 sys[104]（pp=0, tp=3, dp=8），在 E3/E4 是 sys[136]（pp=0, tp=4, dp=8）——本身是同类关键节点，只是在不同拓扑下落到了不同的具体 rank 上。所有位于 PP stage 0（嵌入层所在）的 TP 早期 rank 都在 14 G+ cycles 附近，群体行为一致。

### 2.3 结论对比

**E1 vs E2（PP 跨 DC 的代价）**：Δ=+0.30%，几乎可忽略。
- 每个 PP boundary 单次传输 ≈ `seq × hidden × μBS × bf16 × (1/TP)` = `2048 × 8192 × 2 × 2 / 8` ≈ **8 MB**（因 SGO 再分片）。
- 跨 DC WAN 800 Gbps 传 8 MB 仅 ~80 μs，但加上 0.5 ms WAN latency，单 transfer 主导在延迟上。
- PP 边界数 = 3，每 μB 4 次 xfer（2 fwd activation + 2 bwd grad），每 iter 8 μB，2 iter：`3 × 4 × 8 × 2 = 192` 次 xfer ≈ 96 ms ≈ 96 M cycles @ 1 GHz。
- 实测 exposed comm 增量 42 M cycles 略低于估算，因为部分 PP xfer 与 1f1b 的 forward/backward 其他 compute 重叠。

**E1 vs E3（DP 跨 DC 的代价）**：Δ=+13.0%（+1.83 G cycles）。
- 32-way DP ring all-reduce 跨 4 DC，每次 AR 走 4 段 WAN 链路；
- Ring AR 总数据量 ≈ `2 · (n-1)/n · model_params(fp32) ≈ 2 · 31/32 · 70B × 4 B = 542 GB` 每 AR；
- 跨 DC 瓶颈是 800 Gbps trunk，数据 BW bound，耗时近似 `542 GB / 800 Gbps × 8 = 5.42 s`？但 ring 是 chunked 且多链路并行，实际耗时被分散到多跳。
- E3 每 iter 1 AR × 2 iter = 2 AR，合计 1.83 G exposed cycles ≈ 0.92 G/AR。

**E3 vs E4（LocalSGD 收益）**：Δ=-10.9%（相对 E3），E4 回到 E1 基线水平。
- LocalSGD interval=2 在 ITER=2 里只在 iter 1 末尾做 1 次 DP AR；iter 0 无 AR。
- 2 AR → 1 AR，节省 ~50% 的 AR 次数，理论应省 0.92 G cycles ≈ 5.8%。
- 实测 E4 vs E3 省 **10.9%**（+0.63% vs E1，对照 E3 的 +13.0%）——超预期：
  - 唯一剩下的那次 AR 落在整次训练尾部，后续无 compute 可被拉长关键路径，在关键 rank 上 "看得到" 的 exposed comm 更少；
  - 相比之下 E3 的 iter-0 AR 会阻塞 iter-1 的 first-layer 输入准备，放大关键路径。
- 若 ITERATION ≥ 4，interval=4 会进一步摊薄 1 次 AR 的尾部成本，E4 相对 E3 的收益会继续接近 "∼ 1 − 1/interval" 上限。

### 2.4 GPU 实测性能（= paper Table 1 里的 "TFLOP/s per GPU" 指标）

对齐 Megatron paper（arXiv:2104.04473）的报告方式：把一次 end-to-end 训练的 HW FLOPs 除以 wall 时间与 GPU 数，得到 **achieved TFLOPs/s/GPU**，并表示为 A100 bf16 peak（312 TFLOPs/s）的百分比。

**HW FLOPs 公式（包含 activation recompute，= 4× forward）**：

每 iteration 的 forward FLOPs：
```
per_layer_fwd = QKV (GQA) + Attn(Q·K^T + softmax·V) + O-proj + SwiGLU MLP(3 matrices)
              = 2·B·s·(h² + 2·h·h·kv/heads)      # QKV (GQA kv=8/64)
              + 4·B·s²·h                          # attention core
              + 2·B·s·h²                          # output proj
              + 6·B·s·h·dff                       # SwiGLU (3 matrices of h×dff)

body_fwd = per_layer_fwd × 80
lm_head_fwd = 2·B·s·h·V                            # V=128256
fwd_per_iter = body_fwd + lm_head_fwd

hw_flops_per_iter = 4 × fwd_per_iter               # fwd + bwd×2 + recompute×1
```

代入 B=512, s=2048, h=8192, dff=28672, V=128256, heads=64, kv=8：

| 项                          | 值         |
| --------------------------- | ---------- |
| forward / iter              | 1.514×10¹⁷ |
| HW FLOPs / iter（× 4）      | 6.055×10¹⁷ |
| HW FLOPs / 2 iters（total） | 1.211×10¹⁸ |

对比 Narayanan paper 的近似式 `F = 96·B·s·l·h²·(1 + s/(6h) + V/(16·l·h))` 给出 5.696×10¹⁷ FLOPs/iter，
与本公式差 6.3%——来自 SwiGLU（3 矩阵 × dff ≈ 3.5h）相比普通 MLP（2 矩阵 × 4h）多出来的那部分。

**结果**：

| #  | 实验                         | wall (s) | achieved TFLOPs/s/GPU | % of 312 peak |
| -- | ---------------------------- | -------- | --------------------- | ------------- |
| E1 | `in_dc` (Single-DC)          | 14.072   | **84.05**             | **26.94%**    |
| E2 | `inter_dc_pp`                | 14.115   | 83.79                 | 26.86%        |
| E3 | `inter_dc_dp`                | 15.897   | 74.40                 | 23.84%        |
| E4 | `inter_dc_dp_localsgd`       | 14.161   | 83.52                 | 26.77%        |

参考值：paper Table 1 row 6 的 GPT 76.1B 在 1024 × A100 上报告 **140 TFLOPs/s/GPU（45% of peak）**。
本实验 ~27% of peak 显著低于 paper 的 45%。为排除 "是不是仿真器本身有偏差"，我在同一台机器的 *同一个* `AstraSim_Analytical_Congestion_Aware` 下重新抽取了 `megatron_gpt_experiment/gpt_76b_1024/` 这个 paper recipe 参考实验的结果——它的 workload 本身已经存在，直接复用：

| 实验                              | BATCH | μB/iter | ITER | wall (s) | TFLOPs/s/GPU   | % peak         |
|-----------------------------------|-------|---------|------|----------|----------------|----------------|
| 本仿真器 × gpt_76b_1024 (paper)   | 1792  | 28      | 1    | 15.843   | **142.14**     | **45.56%**     |
| 本实验 E1 (llama3_70b, Single-DC) | 512   | 8       | 2    | 14.072   | 84.05          | 26.94%         |

**仿真器自身校准无偏差**——GPT-76B 仿真结果 142 TFLOPs/s / 45.56% 与 paper 报告的 140 TFLOPs/s / 45% 误差仅 1.5%。所以 Llama 下的 27% 是 workload 配置差异造成的，不是仿真器问题。

**84.05 → 142.14 的差距拆解**（共 41% drop）：

1. **Pipeline bubble（主因，占约 70% 的差距）**
   - 1f1b 每 iter wall = `μB + (PP-1)` 个 μB-time，"有效" 计算占比 = `μB / (μB + PP - 1)`：
     - paper / gpt_76b（μB=28）：28/31 = **90.3%** 有效（bubble 9.7%）
     - 本实验 Llama（μB=8）：8/11 = **72.7%** 有效（bubble 27.3%）
   - 单论 bubble 一项，Llama util 上限被压到 `142.14 × 72.7/90.3 = 114.3` TFLOPs/s（36.6% of peak）。
   - 即 bubble 解释了 **~28 TFLOPs/s** 的 drop。

2. **其余 ~30 TFLOPs/s drop（占约 30%）**：
   - `ITER=2` → DP all-reduce 次数翻倍（每 iter 末尾一次，~8.8 GB per-rank），固定开销被摊在更少的有效计算上。
   - 每层 TP AR + 每 PP 边界 send/recv 的 **latency-bound 启动成本**（常数 μs 级别）在 μB=8 时相对暴露；μB=28 时 1f1b 的 overlap 能把这部分吞掉。
   - 模型形状差异基本互抵——Llama GQA（kv=8）让 attention 轻了约 58%，SwiGLU（3 矩阵）让 MLP 重了约 31%。

若能用 paper recipe 的 `BATCH=1792` 重跑（即把 μB/iter 拉回 28），预期 util 会恢复到 40–45% 级别，与 GPT-76B 仿真持平。

再次复跑 helper 脚本可以一键得到上表：
```bash
/home/ps/sow/part2/astra-sim/.venv/bin/python \
  astra-sim/llama3_70b_experiment/compute_achieved_tflops.py
```

### 2.5 内存预算：为什么 GPT-76B 能在本机跑 BATCH=1792，Llama-70B 却 OOM

首轮尝试用 `BATCH=1792 × ITER=2` 生成的 W-std 在 ASTRA-sim 初始化时 OOM（exit 137）；缩到 `BATCH=512 × ITER=2` 后通过。但同一台机器的 `gpt_76b_1024` 实验用 `BATCH=1792` 却能跑。关键在 ETFeeder 的 `dep_resolver` 内存与 **μB × layers × iter** 的乘积近似线性：

| 配置                                 | μB/iter | layers | ITER | μB·layer·iter 乘积 | 单 rank `.et` | 总 `.et` | 本机 30 GB 能否跑 |
|--------------------------------------|---------|--------|------|---------------------|----------------|----------|---------------------|
| gpt_76b_1024 (paper)                 | 28      | 60     | 1    | **1,680**           | ~4.8 MB        | 4.9 GB   | ✅ wall 15.8 s       |
| llama3_70b BATCH=1792 ITER=2 (首轮)  | 28      | 80     | 2    | **4,480** (2.67×)   | ~17.7 MB       | 17 GB    | ❌ OOM               |
| llama3_70b BATCH=512  ITER=2 (本实验)| 8       | 80     | 2    | **1,280** (0.76×)   | ~5.0 MB        | 4.9 GB   | ✅ wall 14.1 s       |

3 个放大因子相乘：
1. **LAYER 80 vs 60**：×1.33（Llama3-70B 多 20 层）
2. **ITER 2 vs 1**：×2（用户要求 iter=2）
3. **SwiGLU + GQA** 在 STG 里生成的 chakra 节点数比 GPT vanilla 的 MHA+MLP 略多：×≈1.05-1.10

合计 2.67×。而 ASTRA-sim 的 `ETFeeder.dep_resolver` 为每 rank 存 3 层 × 2 向的 `unordered_map<NodeId, unordered_set<NodeId>>`（C++ std 容器每条目 64-256 字节开销），内存跟节点数线性增长。GPT 那套 1680 单位对应约 25 GB 总内存刚好塞进 30 GB；Llama 4480 单位对应 ~60-80 GB，直接爆掉。

**结论**：不是 `BATCH=1792` 本身压垮了内存，是 `BATCH × LAYER × ITER` 这 3 个维度乘在一起超预算。缓解方式（按优先级）：

1. 缩 BATCH（本实验采纳）：`1792 → 512`，乘积直接降到 1280，反比 GPT 还小。
2. 缩 ITER（若可接受）：`2 → 1`，`BATCH=1792 × LAYER=80 × ITER=1 = 2240` 仅为 GPT 的 1.33×，按 `.et` 大小线性估 ~6.5 GB，总内存约 40 GB——**本机配合 8 GB swap 预计能跑**，可作 util 对齐 paper 的对照点。
3. 提供更大内存的机器：≥ 128 GB 可直接跑 paper recipe 完整配置。

### 2.6 定性总结

1. **跨 DC 训练的主要瓶颈是 DP all-reduce，不是 PP send/recv**。PP 在 1f1b + SGO + activation recompute 下本就属于 "小包 + 频繁" 模式，WAN 延迟代价被 1f1b overlap 和部分 forward/backward 并行吸收；DP 则属于 "大包 + 带宽饱和" 模式，直接暴露 WAN 800 Gbps trunk 的上限。
2. **LocalSGD 是跨 DC DP 的有效缓解手段**：将 N iter 压成 1 次 AR，WAN 上的 AR 次数几乎消失在尾部。这与 "用 local SGD 做跨地域/跨云训练" 的 practitioner 直觉一致。
3. 本实验观察到 E4 ≈ E1；这暗示 LocalSGD + DP-跨-DC 组合在 ITER=2、BATCH=512 这档微小规模下，端到端训练成本与 "所有 1024 GPU 在同一 DC" 几乎等同——**只要 convergence 质量可接受，跨 DC 训练 Llama3-70B 在这种拓扑下是可行的**。

### 2.7 已知限制

- **BATCH=512 偏离 paper recipe 的 1792**，是本机内存上限妥协；定性结论（PP 廉价、DP 昂贵、LocalSGD 救场）应随 BATCH 缩放保持。对 absolute 时间估算，建议在内存更大的机器上用 BATCH=1792 复跑对照。
- `ITERATION=2 interval=2` 是最小可演示 LocalSGD 的配置；用 `ITERATION=8 interval=8` 能把 AR 摊销更彻底地体现。
- 本实验用 `logical_topo.json={"logical-dims":["1024"]}` 单维逻辑拓扑，物理 DGX 打包按 `GPU_id // 8`（继承 `build_selene_topology.py` 习惯）；这意味着 TP 组会跨 8 张 DGX，TP 流量走 leaf/spine 而非 NVLink。与 `gpt_76b_1024` 参考实验一致，便于横向对比；但若改用 "TP 锁在 DGX 内" 的布局，E1 / E3 的 base 数会下降，E3 的 DP 跨 DC 相对开销可能放大到 15% 以上。
- ASTRA-sim analytical 的 comm model 是 roofline + localBW-aware，不含 TCP/incast/PFC 细节；若要精细化 WAN incast 行为需改跑 ns-3。

---

## 3. 文件列表

```
astra-sim/llama3_70b_experiment/
├── plan/plan_llama70b_4dc.md           # 实验计划
├── build_topology.py                   # 4-DC 拓扑生成器
├── report.md                           # 本文档
├── in_dc/
│   ├── analytical_network.yml, astra_system.json, logical_topo.json, no_memory_expansion.json
│   ├── topology.txt                    # 复制自 gpt_76b_1024
│   ├── run_analytical.sh
│   └── run_analytical.log              # E1 结果（1024 sys finished）
├── inter_dc_pp/                        # E2
│   ├── ...、topology.txt (partition=pp)、run_analytical.log
├── inter_dc_dp/                        # E3
│   └── ...、topology.txt (partition=dp)、run_analytical.log
└── inter_dc_dp_localsgd/               # E4
    └── ...、topology.txt → ../inter_dc_dp/topology.txt、run_analytical.log
```

Workload：
```
dnn_workload/llama3_70b/
├── fused_standard_80_2_512_2_2048_1f1b_v1_sgo1_ar1/   # W-std，E1–E3 共用
└── fused_localsgd_80_2_512_2_2048_1f1b_v1_sgo1_ar1/   # W-lsgd，E4 专用
```

---

## 4. 结果一览（CSV 已写至 `report.csv`）

```csv
experiment,last_rank,max_cycles,wall_s,delta_vs_E1_pct,tflops_per_gpu,pct_of_peak,exposed_comm_cycles,delta_expo_cycles_vs_E1,gpu_time,comm_time,overlap,mem_util_pct,op_intensity
E1 in_dc,sys[104],14072143445,14.072,0.00,84.05,26.94,8974025831,0,5098117614,13597116163,4623090332,32.357,2035.731
E2 inter_dc_pp,sys[104],14114705325,14.115,0.30,83.79,26.86,9016587711,42561880,5098117614,13639678043,4623090332,32.357,2035.731
E3 inter_dc_dp,sys[136],15897391476,15.897,12.97,74.40,23.84,10799273862,1825248031,5098117614,15423573496,4624299634,32.357,2035.731
E4 inter_dc_dp_localsgd,sys[136],14161049805,14.161,0.63,83.52,26.77,9062932191,88906360,5098117614,13677912554,4614980363,32.357,2035.731
```
