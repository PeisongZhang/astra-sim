
# NS-3 多链路生效分析与方案建议

## Question

运行@experiment/run_scripts/ns3/Ring_allgather_16npus.sh ， 当 @extern/network_backend/ns-3/scratch/topology/16_nodes_1_switch_topology.txt switch16与NPU0之间有两条200Gbps的链路时，似乎只有一条链路生效了。我需要让两条链路都生效，并且可以指定两条链路上分配的流量比例。你来分析是否可行，提出可行的方法

## 回答

● **结论：可行。**你看到“只有一条链路生效”基本是实现上的数据结构限制，不是 ns-3 本身不支持多路径。

  根因在 extern/network_backend/ns-3/scratch/common.h：
  nbr2if 是 map<node,map<node,Interface>>，同一对节点（switch16↔NPU0）的第二条链路会覆盖第一条；后续 SetRoutingEntries() 也只取一个 idx。所以两条 200G 
  里只会真正用到一条。
  但底层 SwitchNode 和 RdmaHw 的路由表本来就是 vector<int>，并且按 hash 做 ECMP 选路（天然支持多下一跳）。

  推荐方案（改动中等，最稳）：加权 ECMP（按流分流）

   1. 把拓扑邻接从“每对节点一个 Interface”改成“每对节点多个 Interface/edge”。  
   2. 路由计算与下发表按接口列表下发，而不是单个接口。  
   3. 拓扑文件扩展一个可选 weight 字段（默认 1），例如两条链路设 3 和 1。  
   4. 下发表时把同一接口按 weight 重复写入路由向量，利用现有 hash % size 实现比例分流（约 75/25）。

  这样两条链路都会被使用，并且可配比例。
  注意这是按流（QP）比例，不是严格按字节瞬时比例；流数少时会有抖动。可通过增大 split/chunk 提高逼近度。

  如果你要“严格按字节比例”，需要更重方案：在 send_flow 把一次消息拆成两个子流并做完成聚合回调（侵入更大，改动面更广）

## Impl

 已实现 加权 ECMP，现在同一对节点的多条链路会同时生效，并可通过拓扑文件权重控制分流比例。

  主要改动在 extern/network_backend/ns-3/scratch/common.h 与 scratch/config/config_doc.txt：

   1. nbr2if 从单接口改为“邻居 -> 多接口列表”，Interface 新增 weight（默认 1）。
   2. 拓扑解析支持可选第 6 列权重：src dst rate delay error_rate [weight]，不写时默认 1。
   3. 下发路由时按 weight 重复写入路由表项，复用现有 hash % size 实现按流加权分流。
   4. TakeDownLink 现在会同时处理该节点对之间的所有并行链路（不再只处理一条）。
   5. 文档已补充 topology 的可选 weight 字段说明。

  你现在可以直接在拓扑里这样写两条并行链路来做 3:1 分流： 16 0 200Gbps 0.0005ms 0 3
  16 0 200Gbps 0.0005ms 0 1

## 如何按比例分流（按本方案）

1. **先确定目标比例**：把目标分流比写成整数比 `a:b(:c...)`。  
   例如希望两条链路 75% / 25%，对应 `3:1`；希望均分，对应 `1:1`。

2. **把比例写到拓扑 weight 列**：同一对节点的每条并行链路各写一行，第 6 列为 weight。  
   示例（switch16 到 NPU0 两条 200Gbps，按 3:1）：
   ```
   16 0 200Gbps 0.0005ms 0 3
   16 0 200Gbps 0.0005ms 0 1
   ```

3. **比例换算规则**：实际分流近似为  
   `link_i share ≈ weight_i / sum(weights)`。  
   所以 `3,1` 约等于 `75%/25%`，`2,2` 等价于 `1,1`。

4. **多于两条链路时同理**：例如三条链路希望 `50%/30%/20%`，可写成 `5:3:2`。

5. **注意语义是“按流（QP）加权”**：不是严格按字节实时切分。  
   流数量少时会有偏差；要更接近期望比例，需要有足够多的并行子流（例如启用前端 send_flow striping）。
