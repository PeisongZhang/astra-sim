# Llama3-70B 跨 DC 训练仿真实验计划（4 组 analytical 实验）

## 0. 任务目标

用 Llama3-70B workload 在 ASTRA-sim analytical（congestion-aware）后端跑 4 组端到端仿真，
对比在相同模型、相同并行策略下、不同 DC 拓扑布局对一次完整训练 batch 的影响：

| #  | 场景                        | 拓扑划分                                 | Workload    |
| -- | --------------------------- | ---------------------------------------- | ----------- |
| E1 | Single-DC 基线              | 所有 128 DGX 节点在同一 DC               | **W-std**   |
| E2 | Inter-DC PP                 | 4 个 PP stage 分属 4 个 DC               | **W-std**   |
| E3 | Inter-DC DP                 | 每个 DP group 的 32 成员跨 4 个 DC 平分  | **W-std**   |
| E4 | Inter-DC DP + LocalSGD      | 同 E3（topology 相同）                   | **W-lsgd**  |

约束条件：

1. **E1–E3 workload 完全相同**（共用同一份 `.et`/`workload.json`），差异只体现在 `topology.txt` 的 GPU→DC 分配。
2. **E4 topology 与 E3 完全相同**，差异在于 workload 用 LocalSGD 版本。
3. DC 内/跨 DC 时延 & 带宽参考 `astra-sim/llama_experiment/in_dc` / `inter_dc`。
4. 其余参数尽量对齐 `dnn_workload/megatron_gpt_76b/megatron_gpt_76b.sh` + `astra-sim/megatron_gpt_experiment/gpt_76b_1024/`（即 arXiv:2104.04473 Table 1 row 6 的 t=8, p=4, d=32, GBS=1792, μBS=2, seq=2048 recipe）。

---

## 1. 模型 & 并行配置（对齐 megatron_gpt_76b）

### 1.1 模型形态（来自 `dnn_workload/llama3_70b/llama3_70b.json`）

| 字段                  | 值         | 对应 STG 参数        |
| --------------------- | ---------- | -------------------- |
| `hidden_size`         | 8192       | `--dmodel 8192`      |
| `intermediate_size`   | 28672      | `--dff 28672`        |
| `num_hidden_layers`   | 80         | `--num_stacks 80`    |
| `num_attention_heads` | 64         | `--head 64`          |
| `num_key_value_heads` | 8 (GQA)    | `--kvhead 8`         |
| `vocab_size`          | 128256     | `--dvocal 128256`    |
| `torch_dtype`         | bfloat16   | `--mixed_precision true` |

### 1.2 并行 recipe（paper Table 1 row 6 的 t/p/d, 应用到 Llama3-70B）

| 维度 | 值  | 理由                                                                   |
| ---- | --- | ---------------------------------------------------------------------- |
| TP   | 8   | ≤ `num_key_value_heads=8`（GQA 边界）；一个 DGX 内 8 GPU 刚好走 NVLink |
| PP   | 4   | `80 % 4 == 0`，每 stage 20 层                                          |
| DP   | 32  | 1024 / (8×4)                                                           |
| SP   | 1   | 不做 sequence parallel（与 76B 基线一致）                              |
| 总 NPU | **1024** (= 128 DGX × 8 A100) |                                                                   |

### 1.3 训练超参（= megatron_gpt_76b.sh 默认值）

| 字段                  | 值              | 备注                               |
| --------------------- | --------------- | ---------------------------------- |
| `SEQUENCE`            | 2048            |                                    |
| `BATCH` (GBS)         | 1792            | `1792 % (2·32) == 0` → 28 μB/iter  |
| `MICROBATCH`          | 2               | per-rank μBS                       |
| `ATTENTION`           | fused           |                                    |
| `PP_SCHEDULE`         | 1f1b            | Megatron 标准                      |
| `PP_VIRTUAL`          | 1               | 非 interleaved                     |
| `SGO` (scatter-gather)| 1               | paper §4.1                         |
| `ACTIVATION_RECOMPUTE`| 1               |                                    |
| `weight_sharded`      | 0               | 不开 ZeRO / FSDP                   |
| `mixed_precision`     | true            | bf16 权重 + fp32 master + Adam m/v |

### 1.4 SGD & 迭代数（E1–E3 vs E4 的 workload 差异）

**W-std**（E1–E3 共用）：
```
SGD=standard  ITERATION=1  DP_LOCAL_SGD_INTERVAL=1
```
即仿真完整的 1 个 training step（28 μB × forward/backward + 最终 DP all-reduce）。输出目录名：
```
dnn_workload/llama3_70b/fused_standard_80_1_1792_2_2048_1f1b_v1_sgo1_ar1/
```

**W-lsgd**（E4 专用）：
```
SGD=localsgd  ITERATION=8  DP_LOCAL_SGD_INTERVAL=8
```
仿真 8 个 step，DP all-reduce 只在最后发生一次（延迟到 sync 边界）。输出目录名：
```
dnn_workload/llama3_70b/fused_localsgd_80_8_1792_2_2048_1f1b_v1_sgo1_ar1/
```

> **说明**：若 E4 也用 `ITERATION=1`，`SGD=localsgd` 与 `SGD=standard` 退化为同一图（`interval==ITERATION==1`）。
> LocalSGD 的跨 DC 收益只有在 `ITERATION ≥ 2 且 interval > 1` 时才体现。
> K=8 与现有 llama3_8b 实验默认一致，便于横向参考。E4 结果需按 `wall_time / ITERATION` 做归一化再与 E3 对比。

### 1.5 生成 workload 的命令

```bash
# W-std（E1–E3 共用）
cd /home/ps/sow/part2
DP=32 TP=8 PP=4 SP=1 \
LAYER=80 SEQUENCE=2048 BATCH=1792 MICROBATCH=2 \
SGD=standard ITERATION=1 \
ATTENTION=fused PP_SCHEDULE=1f1b PP_VIRTUAL=1 SGO=1 ACTIVATION_RECOMPUTE=1 \
bash dnn_workload/llama3_70b/llama3_70b.sh

# W-lsgd（E4 专用）
DP=32 TP=8 PP=4 SP=1 \
LAYER=80 SEQUENCE=2048 BATCH=1792 MICROBATCH=2 \
SGD=localsgd ITERATION=8 \
ATTENTION=fused PP_SCHEDULE=1f1b PP_VIRTUAL=1 SGO=1 ACTIVATION_RECOMPUTE=1 \
bash dnn_workload/llama3_70b/llama3_70b.sh
```

产物：每组 1024 个 `workload.<rank>.et` + 1 个 `workload.json`（comm group）。

---

## 2. STG rank → 物理 NPU ID 映射（决定拓扑如何编号）

STG 的 `BundledTensorGraph` 在 `_spatial_copy_graphs` 中按 spatial\_parallel\_dims = `[dp, tp, sp]`
+ temporal = `[pp]` 逐层展开；最终 `readable_rank_map_number_rank` 按 key 插入顺序 enumerate：

```
num_rank = pp_rank * (sp * tp * dp)
         + sp_rank * (tp * dp)
         + tp_rank * dp
         + dp_rank
```

代入 `(pp, sp, tp, dp) = (4, 1, 8, 32)`：

```
num_rank = pp_rank * 256 + tp_rank * 32 + dp_rank         # dp 最快变化
```

| 区段 (num_rank)     | pp_rank | 含义         |
| ------------------- | ------- | ------------ |
| 0 … 255             | 0       | PP stage 0   |
| 256 … 511           | 1       | PP stage 1   |
| 512 … 767           | 2       | PP stage 2   |
| 768 … 1023          | 3       | PP stage 3   |

每 32 个连续 rank 同属一个 `(pp, tp)` 组且 dp 变化 0..31。
每 256 个连续 rank 同属一个 PP stage（包含所有 tp×dp）。

**DGX (8 GPU) 物理打包**：沿用 `build_selene_topology.py` 的默认 `gpu // 8 = DGX_id`。
由此连续 8 个 rank 同在一张 DGX，对应 `(pp_rank, tp_rank, dp_rank=8i..8i+7)`——
即一张 DGX 承载 8 个 DP 副本的 (pp, tp) 切片，TP 组横跨 8 张 DGX（同 gpt_76b_1024 布局，
TP 流量经 leaf/spine 而非 NVLink；该侧不优的布局与参考实验保持一致，便于对比）。

**关键推论**：

- PP 边界（pp_rank × 256）对齐 DGX 边界（每 256 rank = 32 DGX）。**E2 按 PP 切 DC** 天然对齐。
- DGX id `k` 归属于 `pp_rank = k // 32`、`tp_rank = (k % 32) // 4`、`dp_block = k % 4`。
- **E3 按 DP 切 DC**：`DC_id = k mod 4`。这样每 DC 拿到每个 (pp, tp) 组的 8 个连续 DP rank，
  跨 DC 合成完整的 32-way DP group。

---

## 3. 拓扑设计

每个 DC 内采用 3 层 Selene-like fat-tree（= `build_selene_topology.py` 默认风格 +
单一 DC-spine），DC 之间通过一个全局 core 交换机互连。BW/时延标准取自 `llama_experiment/in_dc`、
`inter_dc` 与 `gpt_76b_1024/topology.txt`。

### 3.1 单 DC 内部结构（所有 4 组实验复用同样的 DC-内层次）

| 层 | 器件                     | 数量                 | 链路 BW    | 链路时延   |
| -- | ------------------------ | -------------------- | ---------- | ---------- |
| 0  | NVSwitch (per DGX)       | 每 DGX 1 个，接 8 GPU | 4800 Gbps | 0.00015 ms |
| 1  | Leaf/ToR (per DGX)       | 每 DGX 1 个，接 8 NIC | 200 Gbps  | 0.0005 ms  |
| 2  | DC-spine (per DC)        | 每 DC 1 个，接 32 leaf | 1600 Gbps | 0.0005 ms  |

DC-spine 上行到全局 core：

| 场景         | DC-spine ↔ core 链路 | 单向时延                                                                     |
| ------------ | ---------------------- | ---------------------------------------------------------------------------- |
| E1（单 DC）  | 不存在（拓扑无 core 层） | n/a                                                                          |
| E2/E3/E4     | 800 Gbps               | `{0.562, 0.501, 0.402, 0.317}` ms，每 DC 一条，对应临港/常熟/滨江/杭州湾 ↔ 嘉兴 |

### 3.2 E1 topology（Single-DC，直接复用 gpt_76b_1024 拓扑）

```
拓扑文件: astra-sim/megatron_gpt_experiment/gpt_76b_1024/topology.txt  （2-tier，无 core 层）
节点分布: GPU 0..1023 全在同一个 leaf/spine 域
节点数: 1281 entities, 257 switches, 2176 links
```

直接硬链接或拷贝此文件即可；不引入跨 DC 结构，用作 apples-to-apples 基线。

### 3.3 E2 topology（Inter-DC PP）

256 个 rank（每个 PP stage）= 32 张 DGX，打包到 1 个 DC。

| DC  | DGX id 区间 | GPU (num_rank) 区间 | 承载的 PP stage |
| --- | ----------- | ------------------- | --------------- |
| DC0 | 0 … 31      | 0 … 255             | pp = 0          |
| DC1 | 32 … 63     | 256 … 511           | pp = 1          |
| DC2 | 64 … 95     | 512 … 767           | pp = 2          |
| DC3 | 96 … 127    | 768 … 1023          | pp = 3          |

拓扑节点分配（按 `build_selene_topology.py` 的 ID 区段习惯推广）：

```
GPUs            : 0 .. 1023          (1024)
NVSwitches      : 1024 .. 1151       (128)
Leaves          : 1152 .. 1279       (128)
DC-spines       : 1280, 1281, 1282, 1283   (4)
Global core     : 1284                      (1)
总 entities = 1285, switches = 261, links = 2180
```

关键链路：
- 每个 Leaf `L` 连到 DC-spine `1280 + (L-1152)//32`（所在 DC）。
- 4 条 DC-spine ↔ 1284 的 WAN 链路，每条 800 Gbps，时延分别 0.562 / 0.501 / 0.402 / 0.317 ms。

### 3.4 E3 topology（Inter-DC DP）

DGX 按 `DC_id = DGX_id mod 4` 条带分配：每个 DC 恰好拿到每个 PP stage 内 DP rank 的 1/4。

| DC  | DGX id（共 32 张） | 该 DC 内每 (pp, tp) 组含有的 DP rank |
| --- | ------------------ | ------------------------------------ |
| DC0 | 0, 4, 8, …, 124    | dp = 0 … 7                           |
| DC1 | 1, 5, 9, …, 125    | dp = 8 … 15                          |
| DC2 | 2, 6, 10, …, 126   | dp = 16 … 23                         |
| DC3 | 3, 7, 11, …, 127   | dp = 24 … 31                         |

链路结构与 E2 完全相同（节点数、IDs、BW、WAN 时延都不变），**仅 Leaf→DC-spine 的归属改变**。
这正是 "通过 GPU/Node 编号区分跨 DC 的 DP/PP" 的要点所在。

### 3.5 E4 topology

与 E3 **逐字节相同**（只是指向不同的 workload dir）。

### 3.6 拓扑生成器

在新目录下新建 `astra-sim/llama3_70b_experiment/build_topology.py`，基于
`megatron_gpt_experiment/build_selene_topology.py` 的链路布局算法扩展：

- 输入：`--num_nodes 128 --gpus_per_node 8 --num_dcs 4 --partition {pp|dp}`
  - `partition=pp`：DGX k → DC `k // 32`（E2）
  - `partition=dp`：DGX k → DC `k % 4`（E3/E4）
- 输出：4-tier 拓扑（NVSwitch→Leaf→DC-spine→Core）加 WAN 链路。
- E1 直接复用 `megatron_gpt_experiment/gpt_76b_1024/topology.txt`，不走此脚本。

---

## 4. ASTRA-sim 配置文件

沿用 `megatron_gpt_experiment/gpt_76b_1024/` 的 3 个静态 JSON，4 组实验共用：

### 4.1 `astra_system.json`（= gpt_76b_1024 版）
```json
{
    "scheduling-policy": "LIFO",
    "endpoint-delay": 10,
    "active-chunks-per-dimension": 2,
    "preferred-dataset-splits": 4,
    "all-reduce-implementation": ["ring"],
    "all-gather-implementation": ["ring"],
    "reduce-scatter-implementation": ["ring"],
    "all-to-all-implementation": ["direct"],
    "collective-optimization": "localBWAware",
    "local-mem-bw": 1560,
    "boost-mode": 0,
    "roofline-enabled": 1,
    "peak-perf": 312
}
```

### 4.2 `logical_topo.json`
```json
{"logical-dims": ["1024"]}
```

### 4.3 `no_memory_expansion.json`
```json
{"memory-type": "NO_MEMORY_EXPANSION"}
```

### 4.4 `analytical_network.yml`
```yaml
topology: [ Custom ]
topology_file: "topology.txt"
```

---

## 5. 目录结构 & 运行

本实验独立于既有的 `llama_experiment/`（8B 系列），新建顶层目录：

```
astra-sim/llama3_70b_experiment/
├── plan/
│   └── plan_llama70b_4dc.md         # 本文档
├── build_topology.py                # 4-DC 拓扑生成脚本（见 §3.6）
├── run_all.sh                       # 一键跑 E1–E4 + 汇总
├── report.md                        # 汇总报告（实验后填充）
├── report.csv
├── in_dc/                           # E1: Single-DC 基线
│   ├── analytical_network.yml
│   ├── astra_system.json
│   ├── logical_topo.json
│   ├── no_memory_expansion.json
│   ├── topology.txt                 # 拷贝自 megatron_gpt_experiment/gpt_76b_1024/topology.txt
│   └── run_analytical.sh            # workload_dir = .../fused_standard_80_1_1792_2_2048_...
├── inter_dc_pp/                     # E2
│   ├── ...（同结构）
│   └── topology.txt                 # build_topology.py --partition pp 生成
├── inter_dc_dp/                     # E3
│   └── topology.txt                 # build_topology.py --partition dp 生成
└── inter_dc_dp_localsgd/            # E4
    ├── topology.txt                 # 与 inter_dc_dp/topology.txt 相同（可 symlink）
    └── run_analytical.sh            # workload_dir = .../fused_localsgd_80_8_...
```

4 个子目录统一约定：所有 JSON/YAML 都从 `megatron_gpt_experiment/gpt_76b_1024/`
拷贝过来，不做修改；每个子目录的唯一差异就是 `topology.txt` 和 `run_analytical.sh` 里的
`WORKLOAD_DIR_DEFAULT`。

`run_analytical.sh` 直接改自 `gpt_76b_1024/run_analytical.sh`，修改两处：

1. `WORKLOAD_DIR_DEFAULT` 指向对应的 llama3_70b workload dir（W-std 或 W-lsgd）。
2. 保留 `ASTRA_EVENT_PARALLEL_THREADS=8` / `ASTRA_EVENT_PARALLEL_MIN_EVENTS=4`（TP=8 有必要）。

运行命令（四组并行或依次）：
```bash
cd /home/ps/sow/part2/astra-sim/llama3_70b_experiment
bash in_dc/run_analytical.sh
bash inter_dc_pp/run_analytical.sh
bash inter_dc_dp/run_analytical.sh
bash inter_dc_dp_localsgd/run_analytical.sh
# 或：
bash run_all.sh
```

---

## 6. 产出 & 评估指标

每组实验看 `run_analytical.log` 里 `sys[*] finished` 段：

| 指标                                 | 来源                                                | 用途                            |
| ------------------------------------ | --------------------------------------------------- | ------------------------------- |
| 最后完成 GPU 的 wall cycles          | `sys[*] finished, *` 最大值                         | end-to-end iter wall time       |
| 每 rank 的 exposed comm / compute    | `exposed communication cycles`、`compute cycles`    | PP/DP/TP 各维度瓶颈分解         |
| per-rank 压力分布                    | 所有 `sys[N] finished` 聚合                         | 识别跨 DC stage 拉长的 straggler |
| 集合通信 util                        | `collective-bandwidth-util` 字段                    | DP AR 在 WAN 上的实际利用率     |

对比分析（写入 `astra-sim/llama3_70b_experiment/report.md`）：
- E1 vs E2：衡量 PP send/recv 被 WAN 拉长的代价（应显著 > E1，因为 PP 在跨 DC 关键路径上）。
- E1 vs E3：衡量 DP all-reduce 走 WAN 的代价（ring AR 对延迟不敏感、对带宽敏感 → 预期比 E2 轻）。
- E3 vs E4：LocalSGD 对跨 DC DP 的收益；需除以 ITERATION=8 归一化后再比。
- 各组的 **compute util**（roofline 的 peak）对比，验证 `roofline-enabled=1` 的约束。

---

## 7. 风险点 & 待确认

1. **「128 Node」语义**：本方案按「128 DGX = 1024 GPU」解读（对齐 Megatron Table 1 row 6 与
   `megatron_gpt_experiment/gpt_76b_1024`）。若用户指的是 128 个单卡节点，则 TP 只能取 1，
   需另做一套缩比计划（DP=32, TP=1, PP=4）。**请先确认**。
2. **E4 迭代数选择**：当前取 `ITERATION=8`（= 8B 实验惯例），也可取 4 或 16；若希望 E1–E4
   强对称（每组都 = 1 batch），可把 E4 改成 `ITERATION=2, interval=2` 做最小演示。
3. **STG 的 rank 布局把 TP 组跨 DGX 摆放**，与「DGX 内 TP」的工业常规不符。沿用此布局是为了
   与 `gpt_76b_1024` 参考实验对齐，结果的 TP 通信开销会略偏大；如果想看 DGX 内 TP 的理想情况，
   需要在 STG 侧改 rank 排列或通过 `logical_topo.json` 做维度重映射，属独立工作量。
4. **拓扑脚本产物要验算**：生成后跑 `wc -l topology.txt`，核对 entity/switch/link 计数；
   核对每 Leaf 只连一个 DC-spine、每 DC-spine 只连一个 core。
5. **仿真时长估计**：`gpt_76b_1024` 单次 analytical 跑约 10–30 分钟（取决于 `ASTRA_EVENT_PARALLEL_*`）；
   E4 因 ITERATION=8，预计 × 8 左右。建议首轮先用 `ITERATION=1` 做冒烟 + 小 batch，再跑正式。

---

## 8. 执行 checklist（按顺序，先不动手）

- [x] 用户确认「128 Node」= 128 DGX（1024 GPU）
- [ ] 用户确认 E4 的 ITERATION=8（可调）
   - iteration改成2，否则仿真运行太慢
- [ ] 生成 W-std workload（`SGD=standard ITERATION=1 ...`）
   - iteration也是2
- [ ] 生成 W-lsgd workload（`SGD=localsgd ITERATION=8 ...`）
   - iteration改成2，否则运行太慢
- [ ] 在 `astra-sim/llama3_70b_experiment/` 下实现 `build_topology.py`（支持 `partition={pp,dp}`）
- [ ] 生成 E2 和 E3 的 topology.txt，手工 diff 只看 Leaf→DC-spine 行
- [ ] 新建 `in_dc/`、`inter_dc_pp/`、`inter_dc_dp/`、`inter_dc_dp_localsgd/` 四个子目录并放置 JSON/YAML/run_analytical.sh
- [ ] 跑 E1 并确认 log 无 Warning，metrics 合理
- [ ] 依次跑 E2/E3/E4，汇总到 `astra-sim/llama3_70b_experiment/report.md`
