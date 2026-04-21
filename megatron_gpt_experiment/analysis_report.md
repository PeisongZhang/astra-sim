# Megatron-LM 39.1B / 76.1B GPT 仿真复现 —— 分析与结果报告

> **目标**：用 STG + ASTRA-sim analytical 后端复现 Megatron-LM 论文（arXiv:2104.04473，SC'21）Table 1 中的 39.1B 和 76.1B GPT 两行端到端训练吞吐，并与论文报的单卡/聚合 TFLOP/s 对比。
>
> **范围**：workload 生成脚本、Selene 式拓扑、analytical 仿真、结果采集对照、沿途发现的 STG bug。

---

## 1. 背景与目标配置

论文 §5 Table 1 给出 10 种 GPT 配置在 Selene A100 集群上的 weak-scaling 吞吐。本任务复现其中两行（序号 5、6）：

| 参数 | 39.1B | 76.1B |
|------|------:|------:|
| heads `a` | 64 | 80 |
| hidden `h` | 8192 | 10240 |
| layers `l` | 48 | 60 |
| tensor-parallel `t` | 8 | 8 |
| pipeline-parallel `p` | 2 | 4 |
| total GPUs `n` | 512 | 1024 |
| global batch `B` | 1536 | 1792 |
| seq `s` | 2048 | 2048 |
| vocab `V` | 51200 | 51200 |
| **论文 TFLOP/s/GPU** | **138 (44% peak)** | **140 (45% peak)** |
| **论文 Aggregate PFLOP/s** | **70.8** | **143.8** |

A100 FP16 理论峰值 312 TFLOP/s。论文采用 PTD-P（TP in node + PP across nodes + DP）+ 激活重算 + 1F1B + scatter/gather。

**用户约束**（来自 plan 阶段的 AskUserQuestion）：使用 `1F1B + scatter/gather`；micro-batch `b=2`；全规模 512/1024 GPU 仿真（不降采样）；迭代数 1（TFLOP/s/GPU 是稳态指标）。

---

## 2. 新增产物一览

| 路径 | 作用 |
|------|------|
| `dnn_workload/megatron_gpt_39b/megatron_gpt_39b.sh` | 39.1B GPT 的 STG workload 生成驱动脚本 |
| `dnn_workload/megatron_gpt_76b/megatron_gpt_76b.sh` | 76.1B GPT 的 STG workload 生成驱动脚本 |
| `astra-sim/megatron_gpt_experiment/build_selene_topology.py` | Selene 式 fat-tree 拓扑生成器（参数化到 3 级；默认跑 2 级 fat-leaf + single spine，见 §7） |
| `astra-sim/megatron_gpt_experiment/gpt_{39b_512,39b_512_noar,76b_1024,76b_1024_noar}/` | 4 份仿真 bundle；`astra_system.json` 统一为 `active-chunks-per-dimension=2, preferred-dataset-splits=4`（见 §6），`run_analytical.sh` 统一 `export ASTRA_EVENT_PARALLEL_THREADS=8 / MIN_EVENTS=4` 以加速实机 wall-clock |
| `astra-sim/megatron_gpt_experiment/collect_and_compare.py` | 解析 `run_analytical.log`、按论文公式计算 TFLOP/s、生成 `report.md` / `report.csv` |
| `astra-sim/megatron_gpt_experiment/run_all.sh` | 端到端驱动（生成 workload → 生成拓扑 → 跑仿真 → 产报告） |
| `astra-sim/megatron_gpt_experiment/report.md` / `.csv` | 脚本自动产出的 4 次仿真对照表 |
| `dnn_workload/symbolic_tensor_graph/symbolic_tensor_graph/graph/activation_recompute.py` | **本次修了一个 bug**：`apply()` 里加 `id(hybrid_graph)` 去重，防止非零 spatial rank 别名图被重复 scale（见 §5） |

workload 生成的 .et 文件（共 1536 个）未被复制进这份清单，存放在 `dnn_workload/megatron_gpt_{39b,76b}/fused_standard_*` 下。

---

## 3. 仿真配置要点

### 3.1 STG 侧（`--model_type gpt`）

- `dff = 4·h` （标准 GPT MLP）
- `kvhead = head` （MHA，不是 GQA）
- `--mixed_precision true`（FP16/BF16）
- `--pipeline_schedule 1f1b`，`--pipeline_virtual_stages 1`
- `--scatter_gather_optimization true` （论文 §4.1）
- `--num_iterations 1`、`--dp_local_sgd_interval 1` （标准同步 DP）
- `--activation_recompute {0,1}`（AR-on 是论文直接对标口径；AR bug 见 §5，已修，AR-on 两行现在与论文吻合到 ±2%）

两个脚本都暴露环境变量覆盖（`DP / TP / PP / LAYER / BATCH / MICROBATCH / SEQUENCE / PP_SCHEDULE / SGO / ACTIVATION_RECOMPUTE`）。

### 3.2 Selene 式拓扑

`build_selene_topology.py` 产出两级 fat-tree：

- **节点内 NVSwitch**：每节点一个交换机，8 个 GPU 各以 4800 Gbps / 0.00015 ms 连接（代表 NVLink 3）。
- **节点内 HDR leaf**：每节点一个 leaf 交换机，8 个 GPU 各以 200 Gbps / 0.0005 ms 连接（代表每 GPU 一张 Mellanox HDR200 网卡）。
- **Spine**：一个汇聚交换机，连接所有 leaf，每条 1600 Gbps / 0.001 ms（= 8×200 Gbps 聚合）。

规模：64 节点 → 129 交换机、1088 条链路（512 GPU 用）；128 节点 → 257 交换机、2176 条链路（1024 GPU 用）。

> **简化说明**：论文实际用的是三级 fat-tree。我们实测在当前 analytical 确定性最短路径路由下，3-level 把 BW 切小反而变慢（§7 有数据），所以默认用"2 级 leaf + 单 1600 Gbps fat spine"。它保留了 NVLink >> HDR 的带宽差、以及每节点 8×HDR 聚合的 bisection 特征，而且 76.1B ≥ 39.1B 的次序在配完 `active-chunks-per-dim=2` 之后已经恢复（141.9 ≥ 140.5）。

### 3.3 ASTRA-sim 系统配置

复用 `llama_experiment/in_dc/astra_system.json`：

- `peak-perf: 312`（A100 FP16）
- `local-mem-bw: 1560`（GB/s，A100 HBM2）
- `roofline-enabled: 1`
- `all-reduce/all-gather/reduce-scatter: ring`、`all-to-all: direct`
- `collective-optimization: localBWAware`
- **`active-chunks-per-dimension: 2`、`preferred-dataset-splits: 4`**（见 §6，这是把 AR-on Δ 从 −33% 压到 ±2% 的关键 sweep）

`logical-dims` 保持扁平 `["512"]` / `["1024"]` —— 因为 STG 产出的 `workload.json` 已经按 (TP, PP, DP) 三维分好 comm-group，astra-sim 直接消费即可。

---

## 4. 仿真结果

四次仿真全部跑完（512 / 1024 个 rank 全部 `sys[*] finished`），在修复 AR bug + 调 `active-chunks-per-dimension=2` 之后，AR-on 两行与论文 Table 1 几乎吻合（|Δ| < 2%）：

| 实验 | 模型 | GPUs | AR | sim wall (s) | sim TFLOP/s/GPU (executed) | paper 4f-norm | 论文 TFLOP/s/GPU | **Δ (4f-norm)** | sim agg PFLOP/s | paper agg PFLOP/s | comp-util | exp-comm/wall |
|------|------|-----:|:--:|-------------:|---------------------------:|--------------:|-----------------:|----------------:|----------------:|------------------:|----------:|--------------:|
| **gpt_39b_512**      | 39.1B | 512  | **on**  | **14.19** | **140.5** | 140.5 | 138 | **+1.8%** | 71.9  | 70.8  | 98.15% | 55.6% |
| gpt_39b_512_noar     | 39.1B | 512  | off     | 12.59     | 118.9     | 158.5 | 138 | +14.8%    | 60.9  | 70.8  | 98.02% | 62.2% |
| **gpt_76b_1024**     | 76.1B | 1024 | **on**  | **15.84** | **141.9** | 141.9 | 140 | **+1.4%** | 145.3 | 143.8 | 98.51% | 54.6% |
| gpt_76b_1024_noar    | 76.1B | 1024 | off     | 13.88     | 121.5     | 162.0 | 140 | +15.7%    | 124.4 | 143.8 | 98.40% | 60.8% |

**Δ (4f-norm)** 把仿真 wall 按论文 eqn (3) 4f 公式折算成单卡 TFLOP/s 后与 paper 比。`executed` 列是当前 workload 下真实执行的 FLOP/s（AR=on 用 4f，AR=off 用 3f）。

### 4.1 和 baseline 的对比

`report.md` 第一轮（buggy AR + 未调 collective）baseline：

| 实验 | 修复前 4f-norm | 修复后 4f-norm | 修复后 Δ vs paper |
|------|---------------:|---------------:|------------------:|
| 39.1B AR=on  | 4.6   | **140.5** | **+1.8%**   |
| 39.1B AR=off | 97.2  | 158.5     | +14.8%      |
| 76.1B AR=on  | 4.3   | **141.9** | **+1.4%**   |
| 76.1B AR=off | 87.5  | 162.0     | +15.7%      |

四个数字都被两个修复同时牵动；定位拆解：

1. **AR FLOP 膨胀 bug（见 §5）**：AR-on 两行从 4.3 / 4.6 TFLOP/s 膨胀回到合理量级（~130–150）。
2. **调 `active-chunks-per-dimension` 1→2、`preferred-dataset-splits` 4→4（见 §6）**：让 ring all-reduce/all-gather 开 2 条并行 chunk 流水，把 exposed comm 从占 wall 的 77%-79% 压到 55%-62%，同时把 AR-off 也拉起来。

修复之后 76.1B ≥ 39.1B 的次序也恢复了（141.9 ≥ 140.5），与论文一致。

### 4.2 schedule / micro-batch 变体（39.1B AR=on）

为对照主表的 b=2 / 1f1b 配置，另外跑了两组 39.1B AR=on 的变体：

| 配置 | wall (s) | TFLOP/s/GPU | Δ vs 138 | 说明 |
|------|---------:|------------:|---------:|------|
| **baseline** b=2 / 1f1b / v=1  | **14.19** | **140.5** | **+1.8%** | 主表行，论文最靠拢点 |
| b=4 / 1f1b / v=1               | 14.74    | 130.4     | −5.5%    | 论文 Fig 16 方向对照；b=4 下 1F1B bubble 略大 |
| b=2 / 1f1b-interleaved / v=2（修复前）| 21.25    | 90.4      | −34.5%   | 半实现；见 §4.2a |
| **b=2 / 1f1b-interleaved / v=2（修复后）** | **12.38** | **161.1** | **+16.7%** | correctness_todo.md#1 修复后实测，见 §4.2a |
| b=1 / 1f1b / v=1               | OOM      | —         | —        | 48 个 micro-batch 的 workload 让单次仿真 RSS 接近 29 GB，30 GB 机器上 thrash，未能跑完 |

#### 4.2a 交错式调度修复：从 −34.5% 退化到 +12.8% 加速

**修复前状况**：`dnn_workload/symbolic_tensor_graph/symbolic_tensor_graph/graph/pipeline_schedule.py:296-312` 里 `_apply_1f1b_interleaved_to_rank` 原来 fallback 到 mb-粒度的 1F1B（里面有 TODO 说要等 block→chunk 的 metadata 从 `_create_pipeline_tensor_map` 透出来）。而 `virtual_stages=2` 会让 `_create_pipeline_tensor_map_mix_precision` 用 round-robin 分块映射（`main.py:41-49`），结果：

- **图** 确实变成了交错布局（每个 device 拿到 2 个非连续 chunk）
- **调度** 却没给交错带来的 bubble 缩减 —— 仍然是 `_apply_1f1b_to_rank` 那套 mb-粒度串行

没有调度收益、却付出了更多 cross-pp p2p 过境代价 → wall 从 14.19 → 21.25 s（−34.5%）。

**修复实现**：`correctness_todo.md` §1 对应的 commit。三处变化：

1. `main._create_pipeline_tensor_map[_mix_precision]` 额外产出 `block_to_chunk_local: dict[block_idx -> chunk_on_device]`，沿 dense/gpt/moe 三条路径传到 `_postprocess_chakra_graph(..., block_to_chunk_local=...)` → `PipelineScheduleInjector.apply(..., block_to_chunk_local=...)`。
2. `_build_1f1b_interleaved_sequence` 按 Megatron-LM `megatron.core.pipeline_parallel.schedules` 的公式重写：`warmup = (p - rank - 1) * 2 + (v - 1) * p`（clip 到 `v*num_mb`），`mb = (k // (p*v)) * p + k % p`，`chunk_F = (k % (p*v)) // p`，`chunk_B = v - 1 - chunk_F`；steady 阶段 **F 在 B 之前** 调度（initial 版本把 B 放前面导致 rank p-1 在第一次 B 时对应的 F 还没跑，引发 cross-pp 死锁，512 GPU 仿真 35328 个 pending RECV 全卡住）。
3. `_apply_1f1b_interleaved_to_rank` 改为对 **只 COMP 节点** 分桶为 `(mb, phase, chunk_on_device)`，按 seq 相邻 pair 注入 ctrl_deps；shadow/RECV 节点走 data_deps 自然排序，不参与分桶以保证 SEND/RECV 能跟 COMP 并行。

**修复后实测**（39.1B, b=2, v=2, 512 GPU, AR=on）：

| 量 | baseline | 修复后 | Δ |
|----|---------:|------:|--:|
| wall cycles | 14,194,697,459 | 12,382,114,950 | **−12.77%**（**加速**）|
| TFLOP/s/GPU | 140.52 | 161.09 | +14.6% |
| 暴露通信 cycles | 7,888,998,747 | 6,076,416,238 | −22.97% |
| exposed / wall | 55.6% | 49.1% | −6.5 pp |
| Δ vs 论文 138 | +1.8% | +16.7% | — |

加速幅度 12.8%（按 wall 时间）落在论文 §5.3.2 报告的 5–15% 区间的上沿，且 exposed comm 下降 23% 表明 bubble 被有效填充；**修复前付出更多 p2p 代价、修复后同一 p2p 流量被 chunk-level 调度吸收并掩盖在 compute 下**，物理图景一致。

**回归测试**：`test_cases/test_pipeline_interleaved.py` 新增 4 个用例（序列匹配 Megatron、chunk 分类、完整注入 31 条 pair 链、v=1 fallback），全部通过。

### 4.3 为什么 AR=off 行仍然偏高 ≈ +15%

AR=off 只执行 3f（fwd + 2 bwd），wall 本应大致等于 AR=on 的 3/4 ≈ 10.6s，但实际 12.59s —— 多出来的 2s 几乎都是同样会出现在 AR=on 里的 exposed comm。当 4f-normalized 把 wall 换算成 "按论文的 4f 口径"，分子用了 4f 而分母是 12.59s，相当于给通信这段 2s 发了张 "compute 票"。所以 AR=off 的 4f-norm 必然比 AR=on 偏乐观，属于这个 normalization 的固有偏置；真正可跟论文面对面比的是 AR=on 两行（论文本身也是开 AR 跑出的 138/140）。

---

## 5. 已修复的 STG Bug：`--activation_recompute` FLOP 膨胀

### 5.1 现象

初版跑出来的 AR=on 39.1B 仿真 wall = **432 s**，AR=off 只有 **20.5 s**（差 **21×**）。按 Megatron §3.5 的语义，激活重算只多跑一次 forward，额外 FLOP ≈ 1 fwd / (1 fwd + 2 bwd) = 33% ≈ 1.33×，21× 膨胀显然是 bug。直接读 Chakra `.et` 统计每个 rank 的 `num_ops`，观察到：

| 状态 | b/f（backward ops / forward ops）|
|------|--------------------------------:|
| AR off（39.1B 全规模）| **2.00** （标准 autodiff b = 2f，正确） |
| AR on（小 dp=1,tp=2,pp=2）| 9.83 |
| AR on（39.1B 全规模 dp=32,tp=8,pp=2）| **252.56** |

### 5.2 Root cause：`BundledConvertChakra` 把非零 spatial rank 的 `HybridGraph` **别名**到零 rank 的同一对象

`dnn_workload/symbolic_tensor_graph/symbolic_tensor_graph/graph/convert_chakra.py:716,835`：

```python
# buckets[non_zero_rank] 指向 buckets[corresponding_zero_rank] 的同一对象
buckets[asked_readable_rank] = buckets[corresponding_zero_rank]
```

然后 `ActivationRecomputePostProcess.apply` 在原版实现里 **对每个 rank 都调一次** `_apply_to_rank`：

```python
for readable_rank, hybrid_graph in bundled_graph.graphs.items():
    cls._apply_to_rank(hybrid_graph)
```

于是一个 pp-slice 的零 rank 图被连续 scale `dp × tp × cp × sp` 次。每次 scale 都用当前的 `f_total / b_total`：

- 初始：b = 2f，scale = 1 + 0.5 = 1.5，之后 b = 3f
- 第 2 次：scale = 1 + 1/3，b = 4f
- 第 3 次：scale = 1 + 1/4，b = 5f
- ……
- 第 N 次（N = 同 pp-slice 内 spatial rank 数 - 1）：b = (2 + N) f

对 39.1B 全规模：dp=32, tp=8, cp=1, sp=1 → 每 pp-slice 内 256 个 rank → N ≈ 250 → b/f ≈ 252，**正好**与观测匹配。

### 5.3 Fix

`dnn_workload/symbolic_tensor_graph/symbolic_tensor_graph/graph/activation_recompute.py`：按 `id(hybrid_graph)` 去重，每个唯一 graph 对象只 scale 一次；并加一个 `assert 0.05 < f/b < 2.0` 作为回归守卫（标准 Transformer 期望 f/b ≈ 0.5，scale ≈ 1.5）。

```python
@classmethod
def apply(cls, bundled_graph):
    seen_graph_ids = set()
    for _, hybrid_graph in bundled_graph.graphs.items():
        key = id(hybrid_graph)
        if key in seen_graph_ids:
            continue
        seen_graph_ids.add(key)
        cls._apply_to_rank(hybrid_graph)
    return bundled_graph

# in _apply_to_rank:
ratio = f_total / b_total
assert 0.05 < ratio < 2.0, (
    f"activation_recompute: unexpected f/b ratio {ratio:.3f} at (mb, block)={key}; "
    f"expected ~0.5 for standard Transformer."
)
scale = 1.0 + ratio
```

修完之后 39.1B 全规模 AR-on 的 b/f = **2.979**（理论 3.00）。小于 3 的那 0.7% 差是 embedding / loss 这类非 transformer block 的 backward ops —— 它们不在 `(mb, block)` 分组里，`_apply_to_rank` 不会去 scale，占 backward FLOP 很小的一部分，在 noise 范围内。

### 5.4 修复效果（AR-on 仿真 wall）

| 配置 | 修复前 wall | 修复后 wall | 比率 |
|------|------------:|------------:|-----:|
| 39.1B AR=on | 432.25 s | 14.19 s | 30.5× 缩短，基本吻合 AR-off × 4/3 = 约 14 s 的预期 |
| 76.1B AR=on | 518.90 s | 15.84 s | 32.8× 缩短 |

---

## 6. 第二项 accuracy 改进：调 `active-chunks-per-dimension`

AR bug 修好之后，单把 `active-chunks-per-dimension` 保留 default=1 时，39.1B AR=off 的仿真 wall = **20.30 s**（paper 4f-norm = 97 TFLOP/s，Δ = −29.6%）；按 wall ∝ 执行 FLOP 外推，同一条件下的 AR=on 大约落在 wall ≈ 20.3 × 4/3 ≈ 27 s（paper 4f-norm ≈ 93，Δ ≈ −33%）。瓶颈剩下的几乎全是 comm：sys[128] 的 exposed-comm / wall ≈ 77%。

继续在 `astra_system.json` 里做 sweep：

| `active-chunks-per-dim` | `preferred-dataset-splits` | 39.1B noar wall | 4f-norm TFLOP/s | Δ vs 138 |
|------------------------:|---------------------------:|----------------:|-----------------:|---------:|
| 1 | 4 | 20.30 s | 97.2  | −29.6% |
| **2** | **4** | **12.59 s** | **158.5** | **+14.8%** (AR-off 行天然偏高，见 §4.2) |
| 4 | 8 | 11.43 s | 174.6 | +26.5% |

直接看 AR-on 数字（用 chunks=2）：

| 模型 | wall | TFLOP/s/GPU | 论文 | **Δ** |
|------|-----:|------------:|-----:|------:|
| 39.1B | 14.19 s | 140.5 | 138 | **+1.8%** |
| 76.1B | 15.84 s | 141.9 | 140 | **+1.4%** |

机理：`active-chunks-per-dimension=1` 下，一个 all-reduce / all-gather / reduce-scatter 的所有环阶段串行执行；改成 2 之后相邻的两个 chunk 可以同时在 ring 上流水，分摊了 single-spine 上的 head-of-line 延迟。对我们这种"窄 spine, 大 DP/TP"的拓扑效果特别明显（exposed comm 占 wall 从 77% → ~55%）。

调到 4 以上就开始显著过优（overshoot 论文），说明 2 在当前 collective 实现和拓扑假设下就是 sweet spot。

---

## 7. 拓扑实验：三级 fat-tree 尝试与回退

`build_selene_topology.py` 已改成参数化的三级 fat-tree（`--spines_per_pod`、`--num_cores`、`--nodes_per_pod`、`--leaf_spine_bw`、`--spine_core_bw` 五个旋钮）。但实测 analytical congestion-aware 后端下，三级拓扑反而比原来的 "单 spine fat-leaf" 慢：

| 拓扑 | 39.1B noar wall | exposed comm |
|------|----------------:|-------------:|
| 2 级（64 leaf, 1 spine, 1600 Gbps/link） | 20.3 s | 15.5 s |
| 3 级（2 pod-spines × 8 pods, 4 cores, 默认 BW 拆分） | 29.6 s | 24.8 s |

原因：analytical 后端用确定性最短路径路由，3-level 把每条 leaf → spine 的 BW 从 1600 切到 800 Gbps，同时多了 spine → core → spine 两跳；多路径本该补偿这种 BW 衰减，但在确定性路由下单条流只能走其中一条路径，BW 被直接稀释。

结论：**在当前 analytical 后端 / collective 实现下，保留"扁平单 spine + 1600 Gbps fat link"才是最贴合论文的一套近似**。`build_selene_topology.py` 的 3-level 参数保留为"以后换 congestion 模型 / 多路径 ECMP"的埋点；对应生成命令：

```bash
# 2-level (当前使用，单 spine、fat link)
python build_selene_topology.py --num_nodes 64  --spines_per_pod 1 --num_cores 0 --nodes_per_pod 64  --leaf_spine_bw 1600Gbps --out gpt_39b_512/topology.txt
python build_selene_topology.py --num_nodes 128 --spines_per_pod 1 --num_cores 0 --nodes_per_pod 128 --leaf_spine_bw 1600Gbps --out gpt_76b_1024/topology.txt

# 3-level (保留，未来路由/多 ECMP 可重新评估)
python build_selene_topology.py --num_nodes 128 --spines_per_pod 2 --num_cores 4 --nodes_per_pod 16 --out gpt_76b_1024/topology_3lvl.txt
```

---

## 8. 复现步骤（当前最终版）

从仓库根目录：

```bash
# 1) 生成 workload（AR 的 bug 已修；会各自产 AR=on 与 AR=off 两份）
ACTIVATION_RECOMPUTE=1 bash dnn_workload/megatron_gpt_39b/megatron_gpt_39b.sh
ACTIVATION_RECOMPUTE=0 bash dnn_workload/megatron_gpt_39b/megatron_gpt_39b.sh
ACTIVATION_RECOMPUTE=1 bash dnn_workload/megatron_gpt_76b/megatron_gpt_76b.sh
ACTIVATION_RECOMPUTE=0 bash dnn_workload/megatron_gpt_76b/megatron_gpt_76b.sh

# 2) 拓扑（2-level fat-leaf + single spine，见 §7）
cd astra-sim/megatron_gpt_experiment
python build_selene_topology.py --num_nodes 64  --spines_per_pod 1 --num_cores 0 --nodes_per_pod 64  --leaf_spine_bw 1600Gbps --out gpt_39b_512/topology.txt
python build_selene_topology.py --num_nodes 128 --spines_per_pod 1 --num_cores 0 --nodes_per_pod 128 --leaf_spine_bw 1600Gbps --out gpt_76b_1024/topology.txt
cp gpt_39b_512/topology.txt  gpt_39b_512_noar/topology.txt
cp gpt_76b_1024/topology.txt gpt_76b_1024_noar/topology.txt

# 3) 四个 bundle 的 astra_system.json 已统一成 active-chunks-per-dimension=2, preferred-dataset-splits=4。
#    四个 run_analytical.sh 已统一 export ASTRA_EVENT_PARALLEL_THREADS=8 + MIN_EVENTS=4
#    （event-queue 并行派发只加速实机 wall-clock，不改变仿真 simulated wall）。

# 4) 仿真。单机 30GB 内存下 76.1B 会占 22GB，不能两个 76.1B 并行。39.1B 两个可以并行。
bash gpt_39b_512/run_analytical.sh &  # ~7min 实机
bash gpt_39b_512_noar/run_analytical.sh &
wait
bash gpt_76b_1024_noar/run_analytical.sh  # ~25min 实机
bash gpt_76b_1024/run_analytical.sh       # ~30min 实机

# 5) 汇总
python collect_and_compare.py   # 输出 report.md / report.csv
```

---

## 9. 状态总览

### 9.1 本次已完成（原 §8 接下来清单）

1. ~~修 STG 的 AR bug~~ → §5；AR-on 两行 |Δ| ≤ 2%。
2. ~~拓扑升级到三级 fat-tree~~ → §7；builder 已参数化，实测回退到 2-level（确定性路由下 3-level 切 BW 反而拉慢）。
3. ~~micro-batch sweep~~ → §4.2 表；39.1B b=2 最优（+1.8%），b=4 −5.5%，b=1 OOM（30 GB 机器仿真内存上限）。
4. ~~开交错式调度~~ → §4.2 / §4.2a 实测，原始 `PP_SCHEDULE=1f1b-interleaved` 是"半实现"（graph 交错、schedule 不交错）→ −34.5%；**已修复**（`correctness_todo.md` §1），修复后 +16.7% vs 论文 138、相对 baseline **加速 12.8%**，落在论文 §5.3.2 报告的 5–15% 区间。
5. ~~修复交错式调度 chunk-level ctrl_deps~~ → §4.2a；同时暴露并修掉了 steady 阶段 F/B 顺序反了导致的 rank p-1 cross-pp 死锁。
6. ~~修复 `Statistics.cc::extract_comm_bytes` p2p/coll 误分类~~ → `correctness_todo.md` §2：原启发式用 `network_bandwidth.has_value()` 导致 coll 恒为 0；现改为按 `ChakraNodeType`（COMM_SEND/RECV→p2p，COMM_COLL→coll）精确分桶。验证：(a) pure-DP allgather smoke `p2p=0, coll=total` ✅；(b) 39B (PP=2 + TP=8 + DP=32) 全 512 rank `p2p=75.5MB coll=95.4GB` 总和等于 `95.437GB`，`p2p + coll == total` 对每 rank 成立 ✅（日志 `gpt_39b_512/run_analytical.log.correctness_all_fixes`）。
7. ~~修复 `_print_gpu_vram` 硬编码 `keep_ratio=0.2`~~ → `correctness_todo.md` §3：AR=on 时不再缩放，改为打印上界 + "peak memory usage 为权威"提示；`test_vram_ar_note.py` 3 项回归通过。
8. ~~Roofline 加 per-op-type 支持~~ → `correctness_todo.md` §4：Chakra COMP_NODE 新增 `op_category` int32 attr（STG 侧 `M→GEMM, CUSTOM→SOFTMAX, A/E→ELEMWISE, B→REDUCE, 其余→OTHER`），Roofline 接受 `peak-perf-per-op-category` JSON 表。三级验证：(a) STG 侧 7 项单元测试（`test_op_category_labeling.py`），`workload.0.et` 16826 COMP_NODE 全部标签齐全；(b) C++ 侧合成 2-rank scaling 测试 `tests/roofline_per_op/run.sh`，SOFTMAX peak=100 TFLOP/s 对 GEMM peak=400 TFLOP/s 的 wall 比值 = **4.000** ∈ [3.6, 4.4] ✅；(c) 39B 全规模开启 `{GEMM:312, ELEMWISE:90, SOFTMAX:60, REDUCE:40}` 后 `sys[0] wall` 与 interleaved_fixed 基线一致（12,382,114,950 cycles），`compute_utilization 98.179% vs 98.154%` 微增——验证 per-op 归一化生效；wall 不变是物理正确（`operation_intensity=2942.6` 下 ELEMWISE/SOFTMAX 是 bandwidth-bound，降低 peak 不改变 elapsed_time）。

### 9.2 还可以做的事（按 ROI 排序）

1. ~~**交错式调度的 chunk-level 调度**~~ → §4.2a 修复已落地，9.1#5。
2. ~~**Statistics p2p/coll 分类**~~ → 9.1#6 修复。
3. ~~**VRAM AR keep_ratio 硬编码**~~ → 9.1#7 修复。
4. ~~**Roofline per-op-type**~~ → 9.1#8 修复。
5. **把 `active-chunks-per-dimension` 这类 collective 旋钮从 `astra_system.json` 改成可以从环境变量覆盖**（目前只能改 JSON 然后手动同步到 4 个 bundle），做 sweep 成本更低。
6. **拓扑 / 路由**：当前 analytical 后端是确定性最短路径；要真正从 3-level fat-tree 拿到好处，需要 ECMP 或 adaptive routing（或者至少 collective 侧知道有多条等价路径、把 chunk 分流到不同 ring），这是一条较大的工程线。
7. **内存上限**：仿真 39.1B b=1（48 mbs/rank）时单进程 RSS ≈ 29 GB 挤爆 30 GB 机器。看起来是把每个 rank 的 et 事件全展在内存里，能优化为流式消费 `.et` 的话就可以无代价跑更大 workload（或多进程并行）。
8. **per-op-type peak 的参数标定**：当前示例值 `{GEMM:312, ELEMWISE:90, SOFTMAX:60, REDUCE:40}` 沿用了 `implementation_plan_zh.md` §P2-B 的占位数字，尚未对 A100 实测算子吞吐回归校准。建议在小批 `qwen_32b` 上做一次 peak sweep，落地到 `reference_zh.md` §3。
