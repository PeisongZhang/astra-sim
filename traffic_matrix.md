# 获取 Ring_allgather_16npus.sh 仿真时间轴上的流量矩阵

要获取 `Ring_allgather_16npus.sh` 仿真中时间轴上的网络流量矩阵，需要配置 Astra-Sim 的 **ns-3 网络后端 (ns-3 network backend)** 中内置的包级别追踪功能 (Packet-level Trace)。

按照仿真脚本和环境配置，流量追踪主要是通过 `config_clos.txt` 文件开启并输出为 `.tr` 追踪文件的。以下是具体的获取步骤：

### 1. 修改网络后端配置文件

仿真脚本中指定了 `NETWORK="${NS3_DIR:?}"/scratch/config/config_clos.txt`。你需要编辑这个配置文件（路径为 `extern/network_backend/ns-3/scratch/config/config_clos.txt`），确保以下几个参数配置正确：

```text
# 开启网络追踪
ENABLE_TRACE 1

# 指定监控节点列表的输入文件
TRACE_FILE ../../scratch/output/trace.txt

# 指定流量追踪的输出文件
TRACE_OUTPUT_FILE ../../scratch/output/mix.tr
```

### 2. 配置需要监控流量的节点 (trace.txt)

根据 `TRACE_FILE` 参数指定的路径，找到或创建 `extern/network_backend/ns-3/scratch/output/trace.txt` 文件。这个文件用来告诉 ns-3 你想要记录哪些节点的流量事件。

由于你的仿真包含 16 个 NPUs (0 到 15)，如果你想获取完整的全局流量矩阵，需要在此文件中把 16 个节点全部添加进去。它的格式是**第一行为节点数量，第二行为具体的节点 ID**：

```text
16
0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
```
*(默认情况下这里可能只写了少数几个节点，这会导致输出的 trace 文件里缺少其他节点的流量)*

### 3. 运行仿真并解析输出文件 (mix.tr)

再次运行 `./examples/run_scripts/ns3/Ring_allgather_16npus.sh`。仿真结束后，你可以在 `extern/network_backend/ns-3/scratch/output/` 目录下找到生成的 **`mix.tr`** 文件。

`mix.tr` 包含了每个节点在时间轴上的所有包级别（Packet-level）事件，例如：
* 数据包入队 (Enqueue)
* 数据包出队 (Dequeue)
* 拥塞控制帧/PFC (Priority Flow Control) 等

**如何提取成流量矩阵：**

`mix.tr` 是一个详尽的文本事件流，包含时间戳 (Timestamp)、源 (Src)、目的 (Dst)、包大小 (Packet Size) 等信息。为了得到“时间轴上的流量矩阵”，你可以编写一个简单的 Python 脚本（利用 pandas 或纯文本解析）来处理这个文件：
1. **定义时间窗口**（例如每 1000ns 或 1ms 为一个时间片/Time Bin）。
2. **过滤事件**（通常提取 Dequeue 或 Enqueue 且代表实际传输 Payload 的事件）。
3. **聚合统计**：将同一个时间片内相同 Src -> Dst 的 Packet Size 累加，即可得到该时间窗口的 $16 \times 16$ 流量矩阵 (Traffic Matrix)。

---

### 补充：获取应用层的逻辑通信时间轴

如果你只想知道“应用层上，哪两个节点在什么时间段发生了数据传输”而不关心底层的路由和数据包，你可以通过系统日志来获取。

修改 `examples/system/native_collectives/Ring_4chunks.json`（即脚本中的 `$SYSTEM` 参数），增加或修改 `"trace-enabled"` 参数：

```json
{
  "trace-enabled": 1,
  ...
}
```

这会让 Astra-Sim 在控制台（或者重定向的日志文件）中以 `DEBUG` 级别打印每个 Workload Node（如 `COMM_SEND_NODE`, `COMM_RECV_NODE`）的触发(issue)与完成(callback)的时间戳（Tick/ns）。
