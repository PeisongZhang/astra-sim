# 跨DC大模型训练仿真实验计划

## 0. 实验目的
本实验旨在通过Astra-Sim仿真平台，评估跨DC训练大模型（LLaMA3.1 8B）时不同并行策略（数据并行 DP 和流水线并行 PP）
在不同网络拓扑下的性能表现。通过对比跨DC各种拓扑进行训练的性能数据，分析通信开销和计算效率，
- 比较不同的并行策略进行跨DC模型训练的通信开销和计算效率，验证哪种策略适合跨DC训练；
- 验证跨DC进行模型训练的可行性；
- 评估使用光交换机OCS和电交换机Spine Switch在跨DC训练中的性能差异；
- 利用光交换机OCS的可重构性，比较不同的网络拓扑在跨DC训练的性能差异；
- 通过多个光交换机组成跨DC网络，在OCS节点故障的情况下进行模型训练，评估系统的鲁棒性和性能表现。


## 1. 实验背景与配置

### 1.1 模型配置: LLaMA3.1 8B
参考链接: [config.json](https://huggingface.co/dphn/Dolphin3.0-Llama3.1-8B/raw/main/config.json)

```json
{
  "hidden_size": 4096,
  "intermediate_size": 14336,
  "model_type": "llama",
  "num_attention_heads": 32,
  "num_hidden_layers": 32,
  "num_key_value_heads": 8,
  "torch_dtype": "bfloat16",
  "vocab_size": 128258
}
```

### 1.2 训练超参数 (仿真一个训练Iteration)
- TP = 1
- DP = 4
- PP = 4
- Sequence Length = 8192
- GBS = 128 (微调)
- Token/Iteration = 1M
- Micro Batch Size = 2
- 不使用ZeRO，FlashAttention等优化技术

### 1.3 硬件参数与集合通信
- **NPU算力**: 312 TFLOPS (A100)
- **NPU显存带宽**: 1.56 TB/s (A100)
- **集合通信算法**: AllReduce - Ring (Chunk=4)

---

## 2. 网络拓扑架构

### 2.1 DC * 1 (单数据中心)
- 每四个NPU和一个HBW Switch互联，模拟DGX A100 4GPU的Server Node，NPU带宽600GB/s
- Node之间的NPU通过LBW Switch组成Clos网络拓扑，带宽收敛比为1：1，NPU带宽200Gbps

![alt text](dc.svg)

### 2.2 DC * 4 (跨数据中心)
- 每四个NPU和一个HBW Switch互联，模拟DGX A100 4GPU的Server Node，NPU带宽600GB/s
- 跨Node的NPU通过LBW Switch组成Clos网络拓扑，带宽收敛比为1：1，NPU带宽200Gbps
- 四个Node分别位于不同的Data Center中：
  - DC 0: 上海临港数据中心
  - DC 1: 苏州常熟数据中心  
  - DC 2: 杭州滨江数据中心
  - DC 3: 宁波杭州湾数据中心
- 跨DC交换机(Spine Switch)位于嘉兴
- 跨DC链路带宽:800Gbps
- 各DC到嘉兴跨DC交换机的距离和时延：
  - 上海临港 ↔ 嘉兴: 112.374km, 0.562ms (单向时延)
  - 苏州常熟 ↔ 嘉兴: 100.225km, 0.501ms (单向时延)
  - 杭州滨江 ↔ 嘉兴: 80.429km, 0.402ms (单向时延)
  - 宁波杭州湾 ↔ 嘉兴: 63.375km, 0.317ms (单向时延)

![4 DC Cross-Datacenter Topology](spine.svg)


### 2.3 跨DC多个电Switch (Spine Switch)
- DC内部的网络配置和2.1, 2.2相同
- 跨DC通过2个Spine Switch完成互联，组成Clos拓扑，链路带宽都是400Gbps
- 数据中心配置：
  - DC 0: 上海临港数据中心
  - DC 1: 苏州常熟数据中心
  - DC 2: 杭州滨江数据中心  
  - DC 3: 宁波杭州湾数据中心
- 跨DC交换机配置：
  - Spine Switch 1: 嘉兴
  - Spine Switch 2: 上海松江
- 跨DC链路带宽: 400Gbps
- 各DC到Spine Switch的距离和时延：
  - 到 Spine Switch 1 (嘉兴):
    - 上海临港 ↔ 嘉兴: 112.374km, 0.562ms (单向时延)
    - 苏州常熟 ↔ 嘉兴: 100.225km, 0.501ms (单向时延)
    - 杭州滨江 ↔ 嘉兴: 80.429km, 0.402ms (单向时延)
    - 宁波杭州湾 ↔ 嘉兴: 63.375km, 0.317ms (单向时延)
  - 到 Spine Switch 2 (上海松江):
    - 上海临港 ↔ 上海松江: 68.000km, 0.340ms (单向时延)
    - 苏州常熟 ↔ 上海松江: 82.207km, 0.411ms (单向时延)
    - 杭州滨江 ↔ 上海松江: 134.036km, 0.670ms (单向时延)
    - 宁波杭州湾 ↔ 上海松江: 79.390km, 0.397ms (单向时延)

![Dual Spine Switch Topology](dual_spine.svg)


### 2.4 单个光交换机OCS
#### 2.4.1 物理拓扑
- DC内部的网络设置和2.1, 2.2, 2.3完全相同
- 数据中心配置：
  - DC 0: 上海临港数据中心 (LBW Switch 0)
  - DC 1: 苏州常熟数据中心 (LBW Switch 1)
  - DC 2: 杭州滨江数据中心 (LBW Switch 2)
  - DC 3: 宁波杭州湾数据中心 (LBW Switch 3)
- 一个OCS光交换机位于嘉兴
- 链路带宽: 800Gbps
- 各DC的LBW Switch到OCS的距离和时延：
  - LBW Switch 0 (上海临港) ↔ OCS (嘉兴): 112.374km, 0.562ms
  - LBW Switch 1 (苏州常熟) ↔ OCS (嘉兴): 100.225km, 0.501ms
  - LBW Switch 2 (杭州滨江) ↔ OCS (嘉兴): 80.429km, 0.402ms
  - LBW Switch 3 (宁波杭州湾) ↔ OCS (嘉兴): 63.375km, 0.317ms

<!-- ![alt text](image-2.png) -->

![OCS Physical Topology](ocs.svg)

#### 2.4.2 逻辑拓扑Full mesh
- 每个LBW Switch都和其他三个LBW Switch直接相连，组成full mesh拓扑
- 各LBW Switch之间的链路参数（通过OCS实现）：
  - Switch 0 ↔ Switch 1: 1.063ms (上海临港 ↔ 苏州常熟, 通过嘉兴OCS中转)
  - Switch 0 ↔ Switch 2: 0.964ms (上海临港 ↔ 杭州滨江, 通过嘉兴OCS中转)
  - Switch 0 ↔ Switch 3: 0.879ms (上海临港 ↔ 宁波杭州湾, 通过嘉兴OCS中转)
  - Switch 1 ↔ Switch 2: 0.903ms (苏州常熟 ↔ 杭州滨江, 通过嘉兴OCS中转)
  - Switch 1 ↔ Switch 3: 0.818ms (苏州常熟 ↔ 宁波杭州湾, 通过嘉兴OCS中转)
  - Switch 2 ↔ Switch 3: 0.719ms (杭州滨江 ↔ 宁波杭州湾, 通过嘉兴OCS中转)
- 链路带宽都是266.7Gbps

<!-- ![alt text](image-3.png) -->

![OCS Full Mesh Topology](ocs_fullmesh.svg)

#### 2.4.3 逻辑拓扑Ring
- 4个LBW Switch组成Ring拓扑，通过OCS完成光路配置
- Ring连接顺序: LBW Switch 0 ↔ 1 ↔ 2 ↔ 3 ↔ 0 (顺时针方向)
  - Switch 0 (上海临港) ↔ Switch 1 (苏州常熟): 1.063ms, 400Gbps
  - Switch 1 (苏州常熟) ↔ Switch 2 (杭州滨江): 0.903ms, 400Gbps  
  - Switch 2 (杭州滨江) ↔ Switch 3 (宁波杭州湾): 0.719ms, 400Gbps
  - Switch 3 (宁波杭州湾) ↔ Switch 0 (上海临港): 0.879ms, 400Gbps
<!-- ![alt text](image-4.png) -->

![OCS Ring Topology](ocs_ring.svg)

### 2.5 跨DC直拉光纤(Full mesh)
- DC内部的网络设置和2.1, 2.2, 2.3, 2.4完全相同
- 数据中心配置：
  - DC 0: 上海临港数据中心 (LBW Switch 0)
  - DC 1: 苏州常熟数据中心 (LBW Switch 1)
  - DC 2: 杭州滨江数据中心 (LBW Switch 2)
  - DC 3: 宁波杭州湾数据中心 (LBW Switch 3)
- **直拉光纤Full mesh**: 每个DC的LBW Switch通过直拉光纤与其他所有DC的LBW Switch直接相连，无需跨DC交换机中转
- 各LBW Switch之间的直连链路参数（基于DC之间的直接时延）：
  - Switch 0 ↔ Switch 1: 0.694ms (上海临港 ↔ 苏州常熟, 直连时延)
  - Switch 0 ↔ Switch 2: 0.910ms (上海临港 ↔ 杭州滨江, 直连时延)
  - Switch 0 ↔ Switch 3: 0.477ms (上海临港 ↔ 宁波杭州湾, 直连时延)
  - Switch 1 ↔ Switch 2: 0.844ms (苏州常熟 ↔ 杭州滨江, 直连时延)
  - Switch 1 ↔ Switch 3: 0.770ms (苏州常熟 ↔ 宁波杭州湾, 直连时延)
  - Switch 2 ↔ Switch 3: 0.479ms (杭州滨江 ↔ 宁波杭州湾, 直连时延)
  - 注：各链路带宽均为266.7Gbps
- 链路带宽都是266.7Gbps（与2.4.2 OCS Full mesh保持一致）

![Direct Fiber Full Mesh Topology](fullmesh.svg)


### 2.6 分布式光交换机 (双OCS拓扑)

#### 2.6.1 物理拓扑

**拓扑设计**：
- **OCS 1**: 位于嘉兴
- **OCS 2**: 位于上海松江
- **物理连接**: 每个OCS与4个DC形成星型拓扑，即每个DC都有到两个OCS的直连链路

**物理连接参数**：

| DC | 到OCS 1 (嘉兴) | 到OCS 2 (上海松江) |
| --- | --- | --- |
| DC 0 (上海临港) | 0.562ms | 0.340ms |
| DC 1 (苏州常熟) | 0.501ms | 0.411ms |
| DC 2 (杭州滨江) | 0.402ms | 0.670ms |
| DC 3 (宁波杭州湾) | 0.317ms | 0.397ms |

![Dual OCS Physical Topology](dual_ocs.svg)



#### 2.6.2 逻辑拓扑

**拓扑设计**: 4个DC通过双OCS系统形成全连接网络，任意两个DC之间有两条不同时延的路径。

**逻辑路径配置**：

每对DC之间的两条路径（路径1通过OCS 1，路径2通过OCS 2）：

- **DC 0 ↔ DC 1**:
  - 路径1 (via OCS 1): 0.562 + 0.501 = 1.063ms
  - 路径2 (via OCS 2): 0.340 + 0.411 = 0.751ms
  
- **DC 0 ↔ DC 2**:
  - 路径1 (via OCS 1): 0.562 + 0.402 = 0.964ms  
  - 路径2 (via OCS 2): 0.340 + 0.670 = 1.010ms
  
- **DC 0 ↔ DC 3**:
  - 路径1 (via OCS 1): 0.562 + 0.317 = 0.879ms
  - 路径2 (via OCS 2): 0.340 + 0.397 = 0.737ms
  
- **DC 1 ↔ DC 2**:
  - 路径1 (via OCS 1): 0.501 + 0.402 = 0.903ms
  - 路径2 (via OCS 2): 0.411 + 0.670 = 1.081ms
  
- **DC 1 ↔ DC 3**:
  - 路径1 (via OCS 1): 0.501 + 0.317 = 0.818ms
  - 路径2 (via OCS 2): 0.411 + 0.397 = 0.808ms
  
- **DC 2 ↔ DC 3**:
  - 路径1 (via OCS 1): 0.402 + 0.317 = 0.719ms
  - 路径2 (via OCS 2): 0.670 + 0.397 = 1.067ms

![Dual OCS Logical Topology](dual_ocs_fullmesh.svg)

**网络特性**：
- 链路带宽: 每条物理链路133.3Gbps
- 冗余路径: 每对DC之间有两条不同时延的路径，提供负载均衡和容错能力
- 路由策略: 可以根据流量负载和时延要求选择最优路径

---

## 3. 实验结果与性能分析

本节对比不同的并行策略（数据并行 DP 和流水线并行 PP）在不同网络拓扑下的性能。

### 3.1 性能数据汇总表

| 实验场景 | 并行策略映射 | Wall Time (Cycles) | 暴露通信时间 (Cycles) | Wall Time相对值 | 暴露通信时间占比 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **(In-DC)** | Intra-Node DP + Inter-Node PP | 6,118,860,709 | 242,317,857 | 1.0000x | 3.96% |
| **(Inter-DC) Spine Switch * 1** | Intra-DC DP + Inter-DC PP | 6,129,586,309 | 253,043,457 | 1.0018x | 4.13% |
| **(Inter-DC) Spine Switch * 2** | Intra-DC DP + Inter-DC PP | 6,132,309,258 | 255,766,406 | 1.0022x | 4.17% |
| **(Inter-DC) OCS-Fullmesh** | Intra-DC DP + Inter-DC PP | 6,138,431,999 | 261,889,147 | 1.0032x | 4.27% |
| **(Inter-DC) OCS-Ring** | Intra-DC DP + Inter-DC PP | 6,134,505,058 | 257,962,206 | 1.0026x | 4.21% |
| **(Inter-DC) Direct Fiber-Fullmesh** | Intra-DC DP + Inter-DC PP | 6,134,727,471 | 258,184,619 | 1.0026x | 4.21% |
| **(Inter-DC) Dual OCS-Fullmesh** | Intra-DC DP + Inter-DC PP | 6,140,378,702 | 263,835,850 | 1.0035x | 4.30% |

### 3.2 结果分析
----

## 4 实验计划
- [x] ns-3 网络分流问题: 存在多路径流量可以按配置比例分配到不同的路径上
- [ ] 在Astra-Sim中实现DiLoCo/Local SGD
- [x] 按照第二节的网络拓扑架构，分别进行训练仿真(Inter-DC PP)
- [ ] 按照第二节的网络拓扑架构，分别进行训练仿真(Inter-DC DP)
