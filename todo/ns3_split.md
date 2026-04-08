
# NS-3 多链路生效分析与方案建议

## Question

运行@experiment/run_scripts/ns3/Ring_allgather_16npus.sh ， 当 @extern/network_backend/ns-3/scratch/topology/16_nodes_1_switch_topology.txt switch16与NPU0之间有两条200Gbps的链路时，似乎只有一条链路生效了。我需要让两条链路都生效，并且可以指定两条链路上分配的流量比例。你来分析是否可行，提出可行的方法

## 回答

结论：可行。你现在这个现象基本可以确认是“并行链路被覆盖成单链路”导致的。

  根因在 extern/network_backend/ns-3/scratch/common.h：
  nbr2if 是 map<node, map<node, Interface>>（每对节点只存一个接口），而拓扑读取时对同一 (src,dst) 重复赋值（你的 16 0 ... 
  两行）会被后一次覆盖；后续路由下发也只拿一个 idx。所以 switch16<->NPU0 两条 200G 最终只等价于 1 条 200G。

  推荐可行方案（改动中等，收益最大）：做“并行边 + 加权ECMP”。 

   1. 把 `nbr2

● Response was interrupted due to a server error. Retrying...

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