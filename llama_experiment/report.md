
## experiment
1. All Nodes in a dc, pp among nodes. @in_dc/run.log
2. All Nodes in a dc, dp among gpus. @in_dc_dp/run.log
3. A node in a dc, spine, pp among nodes. @inter_dc/run.log
4. A node in a dc, spine, dp among nodes. @inter_dc_dp/run.log
5. A node in a dc, pp among nodes, direct mesh. @inter_dc_mesh/run.log
6. A node in a dc, pp among nodes, mesh via ocs. @inter_dc_ocs_mesh/run.log
7. A node in a dc, pp among nodes, ring via ocs. @inter_dc_ocs_ring/run.log

## result
提取规则：每个 `run.log` 取时间顺序上最后一条 `sys[x] finished` 对应 GPU 的完整统计块。
`Wall time (rel.)` 的基线：总表相对 `In dc, pp among nodes`，分组表相对各表第一行。

### All Experiments

| Experiment | Log | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| In dc, pp among nodes | `in_dc/run.log` | `sys[3]` | 135644156084 | 19305376014 | 135644156084 | 1.000000 | 116338780070 | 130753127998 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| In dc, dp among gpus | `in_dc_dp/run.log` | `sys[3]` | 135652835666 | 19314055596 | 135652835666 | 1.000064 | 116338780070 | 130761807580 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, pp among nodes | `inter_dc/run.log` | `sys[3]` | 135729960884 | 19391180814 | 135729960884 | 1.000633 | 116338780070 | 130838932798 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, dp among nodes | `inter_dc_dp/run.log` | `sys[0]` | 136036790518 | 19698010448 | 136036790518 | 1.002895 | 116338780070 | 131145762432 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc direct mesh, pp among nodes | `inter_dc_mesh/run.log` | `sys[3]` | 135843269561 | 19504489491 | 135843269561 | 1.001468 | 116338780070 | 130952241475 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc OCS mesh, pp among nodes | `inter_dc_ocs_mesh/run.log` | `sys[3]` | 135864645561 | 19525865491 | 135864645561 | 1.001625 | 116338780070 | 130973617475 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc OCS ring, pp among nodes | `inter_dc_ocs_ring/run.log` | `sys[1]` | 135825673592 | 19486893522 | 135825673592 | 1.001338 | 116338780070 | 130934645506 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |

### 1. In dc dp vs pp (Among Nodes)

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| In dc, pp among nodes | `sys[3]` | 135644156084 | 19305376014 | 135644156084 | 1.000000 | 116338780070 | 130753127998 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| In dc, dp among gpus | `sys[3]` | 135652835666 | 19314055596 | 135652835666 | 1.000064 | 116338780070 | 130761807580 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |

### 2. Inter dc pp vs dp (Among Nodes)

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Inter dc spine, pp among nodes | `sys[3]` | 135729960884 | 19391180814 | 135729960884 | 1.000000 | 116338780070 | 130838932798 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, dp among nodes | `sys[0]` | 136036790518 | 19698010448 | 136036790518 | 1.002261 | 116338780070 | 131145762432 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |

### 3. PP Among Nodes

#### 3.1 In dc vs Inter dc spine

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| In dc, pp among nodes | `sys[3]` | 135644156084 | 19305376014 | 135644156084 | 1.000000 | 116338780070 | 130753127998 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, pp among nodes | `sys[3]` | 135729960884 | 19391180814 | 135729960884 | 1.000633 | 116338780070 | 130838932798 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |

#### 3.2 OCS Mesh vs OCS Ring

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Inter dc OCS mesh, pp among nodes | `sys[3]` | 135864645561 | 19525865491 | 135864645561 | 1.000000 | 116338780070 | 130973617475 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc OCS ring, pp among nodes | `sys[1]` | 135825673592 | 19486893522 | 135825673592 | 0.999713 | 116338780070 | 130934645506 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |

#### 3.3 Mesh vs OCS Mesh

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Inter dc direct mesh, pp among nodes | `sys[3]` | 135843269561 | 19504489491 | 135843269561 | 1.000000 | 116338780070 | 130952241475 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc OCS mesh, pp among nodes | `sys[3]` | 135864645561 | 19525865491 | 135864645561 | 1.000157 | 116338780070 | 130973617475 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |

#### 3.4 Mesh vs Inter dc spine

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Inter dc direct mesh, pp among nodes | `sys[3]` | 135843269561 | 19504489491 | 135843269561 | 1.000000 | 116338780070 | 130952241475 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, pp among nodes | `sys[3]` | 135729960884 | 19391180814 | 135729960884 | 0.999166 | 116338780070 | 130838932798 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
