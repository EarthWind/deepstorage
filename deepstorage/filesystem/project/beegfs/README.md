# BeeGFS 调研

调研基线：BeeGFS `8.4.0`（调研日期：2026-08-07）。核心 C/C++ 仓库基于
`ThinkParQ/beegfs` tag `8.4.0`、commit `4942de5924ed8e669b906ab784d1a545f81c5f89`；
BeeGFS 8 拆出的管理、工具和协议仓库基线见 [sources.md](sources.md)。源码位置引用均以该基线为准。

BeeGFS 是面向 HPC、AI/HPC 融合与高吞吐共享文件场景的并行 POSIX 文件系统。它的核心路线是：

> Linux 内核客户端掌握文件布局，元数据与数据服务分离，客户端绕过管理/元数据服务并行直连存储目标；
> 服务端把 BeeGFS 对象落到本地 POSIX 文件系统，以目录归属实现元数据横向扩展，以条带和双副本镜像换取吞吐与可用性。

这条路线的工程价值非常明确，但它不是“通用强一致、任意规模的小文件存储”。专业评估后的核心结论是：

1. **大文件并行数据路径简洁且成熟。** 文件创建时确定不可变的目标向量；客户端按 chunk 映射直接并发访问多个存储目标，管理服务和元数据服务不进入稳态数据流。
2. **元数据扩展单位是目录，而不是目录内分片。** 一个目录的全部 dentries 归属于一个元数据节点/镜像组。不同目录可并行扩展，但单个超大、超热目录仍受单元数据服务和底层目录实现约束。
3. **默认语义偏向性能。** 默认元数据 TTL、客户端数据缓存、本地 `flock`/range lock、非全局 append lock，意味着跨客户端工作负载不能只凭“POSIX 文件接口”推断出强 POSIX 一致性。
4. **Buddy Mirroring 是同步双副本，不是共识协议。** 正常路径等待副本；降级或副本通信异常时，系统会以状态传播、切换和后续 resync 收敛。官方明确记录了状态传播窗口及特定 `fsync` 故障下的数据丢失边界。
5. **管理面是必须保护的单一权威数据库。** BeeGFS 8 管理服务使用 SQLite WAL 保存节点、目标、存储池、Buddy Group 和根 inode 映射；内建数据/元数据镜像不等于管理服务自身具有 Raft 级容错。
6. **本地文件承载对象降低了实现复杂度，但放大 inode 和小文件成本。** 每个元数据对象、每个文件在各条带目标上的 chunk 都会消耗底层文件系统对象；BeeGFS 没有小文件打包（volume packing）机制，也没有核心数据路径上的 EC。
7. **8.4 的 Remote Storage Targets 是异步数据管理层。** 它可同步到 S3 兼容存储并支持 stub/恢复，但自动同步是 best-effort，不构成主数据路径的透明分层一致性或备份保证。

## 文档索引

| 文档 | 内容 |
|------|------|
| [beegfs-overview.md](beegfs-overview.md) | 产品定位、组件拓扑、数据/控制路径、扩展单位、版本与功能边界 |
| [beegfs-metadata.md](beegfs-metadata.md) | EntryID、磁盘布局、目录归属、create/rename/unlink/stat、并发与规模瓶颈 |
| [beegfs-data-path.md](beegfs-data-path.md) | 条带公式、chunk 落盘、并行读写、缓存、`fsync`、小文件与重平衡 |
| [beegfs-consistency.md](beegfs-consistency.md) | 一致性语义矩阵、缓存失效、锁、append、跨节点事务和应用约束 |
| [beegfs-ha-recovery.md](beegfs-ha-recovery.md) | Buddy Mirroring、目标状态机、切换、resync、fsck、备份与故障矩阵 |
| [beegfs-operations.md](beegfs-operations.md) | 部署、容量规划、监控、基准、扩容、安全、许可、RST 与运维清单 |
| [beegfs-analysis.md](beegfs-analysis.md) | 技术取舍、适用性评分、与其他系统定位、通用设计启示、选型建议和 PoC 计划 |
| [sources.md](sources.md) | 调研方法、版本/源码基线、官方资料和证据强度说明 |

## 建议阅读路径

- 需要快速决策：先读本页，再读 [beegfs-analysis.md](beegfs-analysis.md)。
- 评审架构：依次阅读 overview、metadata、data-path、consistency、HA。
- 准备 PoC 或上线：重点阅读 operations，并把 HA 文档中的故障注入项纳入验收。
- 核验结论：通过 [sources.md](sources.md) 回到官方 8.4 文档和固定 tag 源码。

## 结论适用范围

本调研是“官方文档 + 固定版本源码”的桌面研究，不包含对目标硬件、网络、内核版本和真实数据集的实测。
因此：架构、默认配置和故障处理结论可信度较高；吞吐、IOPS、尾延迟、最大文件/目录数量没有脱离环境给出单一数字，
必须通过文末建议的 PoC 复核。
