
## experiment
1. All Nodes in a dc, pp among nodes. @in_dc/run.log
2. All Nodes in a dc, dp among gpus. @in_dc_dp/run.log
3. A node in a dc, spine, pp among nodes. @inter_dc/run.log
4. A node in a dc, spine, dp among nodes. @inter_dc_dp/run.log
5. A node in a dc, spine, dp among nodes, local SGD. @inter_dc_dp_localsgd/run.log
6. A node in a dc, pp among nodes, direct mesh. @inter_dc_mesh/run.log
7. A node in a dc, pp among nodes, mesh via ocs. @inter_dc_ocs_mesh/run.log
8. A node in a dc, pp among nodes, ring via ocs. @inter_dc_ocs_ring/run.log

## result
提取规则：每个 `run.log` 取时间顺序上最后一条 `sys[x] finished` 对应 GPU 的完整统计块。
`Wall time (rel.)` 的基线：总表相对 `In dc, pp among nodes`，分组表相对各表第一行。
CSV 导出：`report.csv`。

### All Experiments

| Experiment | Log | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| In dc, pp among nodes | `in_dc/run.log` | `sys[3]` | 135656641179 | 19317861109 | 135656641179 | 1.000000 | 116338780070 | 130816725077 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| In dc, dp among gpus | `in_dc_dp/run.log` | `sys[3]` | 136594692806 | 20255912736 | 136594692806 | 1.006915 | 116338780070 | 131754776704 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, pp among nodes | `inter_dc/run.log` | `sys[3]` | 135742445979 | 19403665909 | 135742445979 | 1.000633 | 116338780070 | 130902529877 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, dp among nodes | `inter_dc_dp/run.log` | `sys[0]` | 139668742889 | 23329962819 | 139668742889 | 1.029575 | 116338780070 | 134828826787 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, dp among nodes, local SGD | `inter_dc_dp_localsgd/run.log` | `sys[0]` | 136036790518 | 19698010448 | 136036790518 | 1.002802 | 116338780070 | 131145762432 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc direct mesh, pp among nodes | `inter_dc_mesh/run.log` | `sys[3]` | 135981020183 | 19642240113 | 135981020183 | 1.002391 | 116338780070 | 131141104081 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc OCS mesh, pp among nodes | `inter_dc_ocs_mesh/run.log` | `sys[3]` | 136002396183 | 19663616113 | 136002396183 | 1.002549 | 116338780070 | 131162480081 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc OCS ring, pp among nodes | `inter_dc_ocs_ring/run.log` | `sys[1]` | 135886122693 | 19547342623 | 135886122693 | 1.001692 | 116338780070 | 131046206591 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |

### 1. In dc dp vs pp (Among Nodes)

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| In dc, pp among nodes | `sys[3]` | 135656641179 | 19317861109 | 135656641179 | 1.000000 | 116338780070 | 130816725077 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| In dc, dp among gpus | `sys[3]` | 136594692806 | 20255912736 | 136594692806 | 1.006915 | 116338780070 | 131754776704 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |

### 2. Inter dc pp vs dp (Among Nodes)

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Inter dc spine, pp among nodes | `sys[3]` | 135742445979 | 19403665909 | 135742445979 | 1.000000 | 116338780070 | 130902529877 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, dp among nodes | `sys[0]` | 139668742889 | 23329962819 | 139668742889 | 1.028925 | 116338780070 | 134828826787 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, dp among nodes, local SGD | `sys[0]` | 136036790518 | 19698010448 | 136036790518 | 1.002168 | 116338780070 | 131145762432 | 111447751984 | 97.308% | 97.316% | 20.670% | 4283.712 |

### 3. PP Among Nodes

#### 3.1 In dc vs Inter dc spine

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| In dc, pp among nodes | `sys[3]` | 135656641179 | 19317861109 | 135656641179 | 1.000000 | 116338780070 | 130816725077 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, pp among nodes | `sys[3]` | 135742445979 | 19403665909 | 135742445979 | 1.000633 | 116338780070 | 130902529877 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |

#### 3.2 OCS Mesh vs OCS Ring

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Inter dc OCS mesh, pp among nodes | `sys[3]` | 136002396183 | 19663616113 | 136002396183 | 1.000000 | 116338780070 | 131162480081 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc OCS ring, pp among nodes | `sys[1]` | 135886122693 | 19547342623 | 135886122693 | 0.999145 | 116338780070 | 131046206591 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |

#### 3.3 Mesh vs OCS Mesh

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Inter dc direct mesh, pp among nodes | `sys[3]` | 135981020183 | 19642240113 | 135981020183 | 1.000000 | 116338780070 | 131141104081 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc OCS mesh, pp among nodes | `sys[3]` | 136002396183 | 19663616113 | 136002396183 | 1.000157 | 116338780070 | 131162480081 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |

#### 3.4 Mesh vs Inter dc spine

| Experiment | Last GPU | Finish cycles | Exposed communication | Wall time | Wall time (rel.) | GPU time | Comm time | Total overlap | Compute bound | Avg compute util | Avg memory util | Avg op intensity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Inter dc direct mesh, pp among nodes | `sys[3]` | 135981020183 | 19642240113 | 135981020183 | 1.000000 | 116338780070 | 131141104081 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
| Inter dc spine, pp among nodes | `sys[3]` | 135742445979 | 19403665909 | 135742445979 | 0.998246 | 116338780070 | 130902529877 | 111498863968 | 97.308% | 97.316% | 20.670% | 4283.712 |
