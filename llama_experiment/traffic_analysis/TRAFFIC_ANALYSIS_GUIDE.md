# ns-3 仿真流量矩阵 analysis 工具使用指南

本指南介绍了如何使用配套的 Python 工具链，从 Astra-Sim + ns-3 仿真的原始追踪文件（`mix.tr`）中提取并可视化时间轴上的 16x16 流量矩阵。

## 0. 前置要求

在运行脚本之前，请确保已安装必要的 Python 库：
```bash
pip3 install numpy matplotlib seaborn
```

## 1. 核心工作流程

分析流程分为三个主要步骤：
1. **运行仿真**：生成原始二进制追踪数据。
2. **提取数据**：将二进制数据解析并分箱存为 `.npy` 矩阵。
3. **可视化**：生成静态图表或动态 GIF。

---

## 2. 详细脚本说明

所有的脚本都位于 `experiment/run_scripts/ns3/traffic_analysis/` 目录下。

### 步骤 1：生成追踪文件
首先运行您的仿真脚本（例如 `Ring_allreduce_16npus.sh`）。确保网络配置文件中开启了追踪：
- `ENABLE_TRACE 1`
- 生成的文件通常位于 `extern/network_backend/ns-3/scratch/output/mix.tr`。

### 步骤 2：数据提取 (`extract_traffic_matrix.py`)
该脚本负责解析二进制文件。它会根据指定的 **时间窗口 (Time Bin)** 累加节点间的流量。

**用法：**
```bash
# 进入分析目录
cd experiment/run_scripts/ns3/traffic_analysis/
# 执行提取（发送端视角）
python3 extract_traffic_matrix.py --bin_us 50 --view sender --output traffic_matrix_sender.npy
# 执行提取（接收端视角）
python3 extract_traffic_matrix.py --bin_us 50 --view receiver --output traffic_matrix_receiver.npy
```

**参数说明：**
- `--bin_us`: (可选) 时间窗口大小，单位为微秒。默认值为 `50`。
- `--view`: (可选) 分析视角。`sender` (默认, 记录 Dequeue 事件) 或 `receiver` (记录 Receive 事件)。
- `--trace`: (可选) 输入的 `mix.tr` 路径。
- `--output`: (可选) 输出的 `.npy` 矩阵路径。

### 步骤 3：数据校验 (`validate_matrix.py`)
使用理论基准（如 16 节点 Ring All-Reduce 1MB 的总流量为 31,457,280 字节）验证提取结果的准确性。

**用法：**
```bash
python3 validate_matrix.py --input traffic_matrix_sender.npy
```

### 步骤 3：静态可视化 (`visualize_traffic.py`)
生成全时段的累积流量热力图以及随时间变化的流量折线图。

**用法：**
```bash
python3 visualize_traffic.py --bin_us [提取时使用的微秒数]
```

**输出文件：**
- `traffic_over_time.png`: 网络总吞吐随时间变化的折线图。
- `total_traffic_heatmap.png`: 16x16 节点累计通讯量的热力图。

### 步骤 4：生成动画 (`animate_traffic.py`)
生成一个 GIF 动画，展示 16x16 流量矩阵在时间轴上的逐帧变化过程。

**用法：**
```bash
python3 animate_traffic.py --bin_us [提取时使用的微秒数]
```

**输出文件：**
- `traffic_animation.gif`: 流量矩阵演进动画。

---

## 3. 快速参考示例

如果您想以 **20us** 为粒度分析一次仿真：

1. 提取数据：
   ```bash
   python3 extract_traffic_matrix.py --bin_us 20
   ```
2. 生成图表：
   ```bash
   python3 visualize_traffic.py --bin_us 20
   ```
3. 生成动画：
   ```bash
   python3 animate_traffic.py --bin_us 20
   ```

## 4. 数据格式说明
提取出的 `traffic_matrix.npy` 是一个 3D NumPy 张量，形状为 `(T, 16, 16)`：
- `T`: 时间窗口的总数。
- `16, 16`: 源节点到目标节点的流量矩阵（单位：Bytes）。
