# 3FS 性能证据、容量模型与 PoC 方案

## 1. 官方公开结果

### 1.1 聚合读取

官方 README 披露：

- 180 个 Storage 节点；
- 每节点 2×200 Gbps InfiniBand；
- 每节点 16×14 TiB NVMe；
- 500 多个 Client；
- 有后台流量时约 6.6 TiB/s 聚合读带宽。

这是自报告峰值/案例结果，不是独立第三方基准。

### 1.2 GraySort

官方披露：

- 25 个 Storage 节点；
- 50 个 compute 节点；
- 110.5 TiB 数据；
- 8192 partitions；
- 30 分 14 秒；
- 3.66 TiB/min。

算术核验：

```text
30m14s = 30.233 min
110.5 TiB / 30.233 min ~= 3.655 TiB/min
```

与 3.66 TiB/min 一致。

### 1.3 KV Cache

官方 README 披露 KVCache 相关峰值约 40 GiB/s。该数字高度依赖 KV block 大小、并发、读写比、cache 命中、Client/RNIC 和服务设置，公开摘要不足以形成通用容量公式。

## 2. 聚合读结果归一化

### 2.1 每 Storage 节点

```text
6.6 TiB/s * 1024 GiB/TiB / 180
= 37.55 GiB/s per storage node
```

每节点有两条 200 Gbps 链路，理论单向线速合计：

```text
400 Gbit/s / 8 = 50 GB/s
约 46.57 GiB/s
```

37.55 GiB/s 相当于节点名义双端口线速约 80.6%（忽略协议开销和端口实际用法）。说明结果非常接近网络/PCIe 工程上限，绝非只由文件系统代码决定。

### 2.2 每 NVMe

```text
180 * 16 = 2880 NVMe
6.6 TiB/s * 1024 / 2880
= 2.35 GiB/s per NVMe
```

平均值低于高端 NVMe 顺序读峰值，合理地反映网络、复制读取选择、客户端和后台流量的综合瓶颈。但平均值不能说明：

- 每盘负载是否均匀；
- block size；
- 是否所有副本都承担读；
- CPU 利用率；
- P99；
- 热点文件；
- failure/recovery 时表现。

### 2.3 原始容量

```text
180 * 16 * 14 TiB = 40,320 TiB
                         ~= 39.375 PiB raw
```

三副本理论用户数据上限约：

```text
39.375 PiB / 3 = 13.125 PiB
```

还要扣除格式化、metadata DB、COW、GC、恢复预留和高水位，实际明显更低。

## 3. 不能从官方结果推出什么

公开摘要没有完整给出：

- block size、alignment、read ahead；
- 单文件/多文件、顺序/随机；
- FUSE 还是 USRBIO；
- chain replication factor 和 read selection；
- 数据是否全缓存；
- Client CPU/RNIC/NUMA；
- Storage CPU/内存占用；
- write bandwidth；
- fsync/close 延迟；
- P50/P99/P999；
- 元数据 QPS；
- 小文件；
- 降级/恢复性能；
- 多租户 QoS；
- 运行时长和方差；
- checksum/认证开关；
- 具体 commit/config；
- 独立复现。

因此正确表述是：“官方在特定 Fire-Flyer 级硬件和网络上展示了 6.6 TiB/s 读吞吐”，而不是“部署 3FS 即可获得 6.6 TiB/s”。

## 4. 性能机制

### 4.1 有利因素

- Client 直接计算布局，Meta 不传数据；
- RDMA 避免传统 TCP 复制和内核协议栈开销；
- 服务端 RDMA Read 主动拉数据，有利于调度和背压；
- CRAQ clean read 可分散到全部 replica；
- 多 chain 和宽 stripe 提供并行度；
- NVMe 全闪存；
- USRBIO 批量异步 ring；
- COW 避免覆盖 committed block；
- Meta 无状态，可随 namespace QPS 横向增加。

### 4.2 不利因素

- 写入经过 chain 全成员；
- tail/慢成员决定写尾延迟；
- 同 chunk 写串行；
- pending 使默认读重试；
- FUSE 小 I/O 有共享队列/复制开销；
- 小文件导致 Meta/Storage metadata 放大；
- COW、metadata DB、checksum 增加写放大；
- GC/recovery 与前台竞争；
- RoCE congestion/PFC 可能形成相关尾延迟；
- close/fsync 精确 length 查询跨多个 chain。

## 5. FUSE 与 USRBIO 性能预期

| 维度 | FUSE | USRBIO |
| --- | --- | --- |
| 应用改造 | 低 | 中到高 |
| path/namespace | 原生入口 | 仍依赖 FUSE open/fd |
| 小 I/O | 受复制与共享队列限制 | 批量后更好 |
| 大块吞吐 | 可用但开销较高 | 主要高性能路径 |
| 零拷贝 | 受 FUSE 路径限制 | 注册内存/RDMA |
| 并发 | 内核/FUSE 队列约束 | 多 ring 可扩展 |
| 错误处理 | POSIX errno 风格 | 异步 completion 显式处理 |
| 集成风险 | syscall 兼容性 | buffer/fd/ring 生命周期 |

官方设计文档约 400K 4 KiB reads/s 的描述应理解为 FUSE 特定路径观察，不是整个系统的 4 KiB 上限，也不能代表 USRBIO 或多 mount 的结果。

## 6. 容量模型

### 6.1 大文件

```text
physical_data =
  logical_data * replication_factor
  + COW_temporary
  + metadata_DB/WAL
  + filesystem_overhead
  + unrecycled_deleted_data
  + recovery_reserve
```

建议正常运行不超过可分配空间的 70%—80%，具体阈值用故障恢复压测确定，而不是直接采用经验值。

### 6.2 小文件

若平均文件大小 `S` 小于最小物理分配单元 `B`：

```text
data_space_amplification >= replication_factor * B / S
```

还未包括 inode/dentry/chunk metadata。示例：4 KiB 文件若最小实际分配为 64 KiB，三副本仅数据块理论放大已达 48 倍。实际引擎是否对该路径打包/共享分配必须用固定版本验证；公开架构不是面向极小对象 packing 设计。

### 6.3 恢复预留

假设单节点数据量 `D`，可用于恢复的净带宽 `R`：

```text
ideal_recovery_time = D / R
```

真实时间还要乘：

- metadata scan；
- 小 chunk IOPS；
- 前台限速；
- checksum；
- COW/compaction；
- 多目标竞争；
- 重试。

规划时用实测 P90 recovery throughput，而不是链路线速。

## 7. PoC 测试原则

1. 固定 commit、配置、固件、内核、FDB 版本。
2. 每组结果同时报告吞吐、P99/P999、CPU、网络、盘和错误。
3. 预热与冷读分开。
4. FUSE 与 USRBIO 分开。
5. 正常、降级、恢复分开。
6. 至少三次重复，报告方差。
7. 用目标应用 trace，而不仅是 fio。
8. 72 小时长稳覆盖 GC、compaction、session、token 轮换。

## 8. PoC 矩阵

### 8.1 数据 I/O

| 维度 | 建议值 |
| --- | --- |
| I/O size | 4 KiB、16 KiB、64 KiB、256 KiB、1 MiB、4 MiB、16 MiB、64 MiB |
| alignment | 对齐、非对齐 |
| pattern | 顺序、随机、stride |
| read/write | 100/0、90/10、70/30、0/100 |
| access | FUSE、USRBIO |
| files | 单大文件、多文件、每 client 独立文件 |
| writers | 单 writer、多 writer 同文件/同 chunk/不同 chunk |
| queue depth | 1、8、32、128、应用实际值 |
| duration | 短峰值、1h、24h、72h |

### 8.2 元数据

- create/open/stat/close 单独与组合；
- 同热目录和均匀目录；
- 1K/1M/100M entries 的 readdir；
- rename 同目录/跨目录/深目录；
- hardlink/symlink；
- unlink + open fd；
- rm-rf/trash/GC；
- session 崩溃；
- inode length 收敛。

### 8.3 故障

- head/middle/tail 分别 kill -9；
- 整机掉电；
- 单盘 timeout/read error；
- RDMA packet loss/congestion；
- MgmtD 主故障和时钟跳变；
- Meta 全部重启；
- FDB process/zone 故障；
- Client mount daemon 崩溃；
- 磁盘满；
- checksum corruption；
- recovery 中再次故障；
- 升级/回滚中故障。

### 8.4 结果字段

每条结果必须带：

- logical throughput/IOPS；
- physical network RX/TX；
- NVMe read/write；
- CPU、memory、NUMA remote；
- P50/P90/P99/P999/max；
- timeout/retry/error；
- pending read；
- FDB conflict/retry；
- target/chain state；
- recovery/GC bandwidth；
- checksum；
- commit/config hash。

## 9. AI 工作负载专项

### 9.1 训练样本读取

- 多 worker 同时打开共享 shard；
- sequential + random seek；
- epoch 边界造成同步热点；
- 小样本是否在 tar/parquet 等容器中；
- DataLoader prefetch 与 ring depth；
- FUSE page cache 与 direct/native 路径；
- 训练 step time 和 GPU idle，而不只存储吞吐。

### 9.2 Checkpoint

- 每 rank 独立文件与共享文件；
- burst write；
- fsync/close；
- 临时文件 + rename；
- 保留/删除引起 GC；
- 写 checkpoint 同时训练读；
- 故障后可恢复性和 manifest。

### 9.3 KV Cache

- block size；
- get/put 比；
- hot key skew；
- relaxed read 是否允许；
- tail latency 对 token generation；
- 容量淘汰与 GC；
- 多租户隔离。

### 9.4 模型加载

- 数百/数千客户端同读热点权重；
- CRAQ replica 负载均衡；
- Client cache cold/warm；
- pending 不常见时的 clean read 扩展；
- 交换机 uplink 与存储端 egress。

## 10. 网络专项

InfiniBand 与 RoCE 不能混为同一性能条件。RoCE PoC 应记录：

- PFC pause duration/count；
- ECN marking；
- DCQCN 参数；
- buffer occupancy；
- retransmission/NACK；
- QP timeout/retry；
- incast；
- storage 与训练 collective 共网干扰；
- 单 RNIC/链路故障；
- MTU mismatch；
- NUMA 和 IRQ/CQ affinity。

Fire-Flyer 论文披露为同时支持 HFReduce 与 3FS 做了特定网络调优，并在其环境中对拥塞方案作了取舍。普通共享 RoCE 环境必须从零验证。

## 11. 性能验收门槛示例

门槛应按业务定制。一个可讨论的框架：

- 正常读吞吐达到硬件可用上限的 70% 以上；
- 正常写吞吐达到三副本后网络/盘模型的 60% 以上；
- P99 满足训练 step/Checkpoint 窗口；
- 单节点失效期间吞吐不低于正常 70%，错误可重试；
- recovery 时前台 P99 增幅不超过约定值；
- 恢复 ETA 满足冗余暴露窗口；
- FDB failover 后 namespace 在 RTO 内恢复；
- 72h 无不可解释错误、内存增长和 GC backlog；
- 数据 checksum/manifest 验证零不一致。

这些百分比只是制定流程的示例，不是 3FS 官方承诺。

## 12. 性能结论

3FS 的公开峰值证明其架构在大规模全闪存 RDMA 集群中具有很高上限。它没有证明小文件、随机写、FUSE 兼容路径、降级恢复、共享 RoCE 或普通硬件同样优秀。选型应以“业务完成时间 + P99 + 故障时性能 + 每有效 TiB 成本”为主指标，而非单独追逐聚合 GiB/s。
