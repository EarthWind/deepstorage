# 3FS（Fire-Flyer File System）技术调研

> 调研角色：分布式存储架构与工程评审
> 调研日期：2026-08-08
> 源码基线：`deepseek-ai/3FS@22fca04564c7cc230fd8b9523b8b92864e1dad47`（2026-05-07）
> 证据状态：官方仓库当前无 Git tag、无 GitHub Release；本文不把主分支能力等同于稳定发行承诺

## 技术摘要

3FS 是面向大规模 AI 训练、推理和高性能计算的全闪存分布式文件系统。它把 POSIX 风格命名空间和数据路径解耦：无状态 Meta 服务将全部文件元数据存入 FoundationDB（FDB），客户端根据 inode 中的布局直接计算 chunk 所属 chain；Storage 服务用基于 CRAQ 思想改造的 Chain Replication 保存完整副本，通过 RDMA 拉取客户端缓冲区，客户端可经 FUSE 访问，也可在已挂载文件和文件描述符基础上使用异步、零拷贝的 USRBIO 接口。

它最有价值的工程设计不是“通用文件系统”，而是针对单数据中心、可信高带宽 RDMA 网络、NVMe 全闪存和 AI 大块并行 I/O 的垂直优化。官方公开结果在 180 个存储节点上达到约 6.6 TiB/s 聚合读带宽，但该结果来自 2×200 Gbps InfiniBand、2880 块 NVMe、500 多客户端及专门调优的网络环境，不能直接外推到普通 RoCE/以太网集群。

从生产评审看，3FS 的突出优点是数据路径短、读副本负载可分散、元数据事务语义清晰、故障目标状态机和在线增量同步设计具体；突出代价是三副本约 3 倍原始容量、写请求穿越整条 chain、强依赖 RDMA 与 FDB、运维组件多、公开版本治理尚不成熟。公开基线没有发现实际数据编解码/重建意义上的纠删码实现，也没有完整的原生快照、配额、通用 xattr/ACL、POSIX 锁、传输加密和端到端灾备方案。

## 核心结论

| 维度 | 评估 | 工程判断 |
| --- | --- | --- |
| 目标工作负载 | 强项明确 | 大文件、只读/读多、训练样本、Checkpoint、KV Cache、单机多 GPU 并发 |
| 元数据 | 架构简洁但依赖外部系统 | Meta 无状态，FDB 提供全局 ACID；上限和故障域转移到 FDB |
| 数据一致性 | chunk 内强一致，多 chunk 非原子 | 默认读遇到 pending 版本会重试；relaxed read 明确放宽语义 |
| 数据保护 | 全量 Chain Replication | 默认部署示例为三副本；公开数据路径未实现 EC，容量成本高 |
| I/O 路径 | RDMA + USRBIO 是性能核心 | FUSE 更兼容，USRBIO 更高效但依赖挂载、打开文件和注册内存 |
| 高可用 | 状态机可操作 | serving/syncing/waiting/lastsrv/offline 配合 chain version 做隔离和恢复 |
| POSIX 完整性 | 有意取舍 | 基础命名空间和读写可用；锁、通用 xattr、配额、原生快照等能力不足 |
| 安全 | 默认面向可信内网 | 默认认证关闭；未见公开的数据面传输加密；需网络隔离和外部加密补齐 |
| 可运维性 | 工具较多，产品化不足 | 需要 FDB、ClickHouse、RDMA、XFS/NVMe 和多类服务；无正式 release/tag |
| 适合直接生产 | 有条件 | 适合有 HPC 网络与存储平台团队的 AI 集群，不适合作为低成本通用存储直接替换 |

## 最重要的工程事实

1. **Meta 不在稳定数据热路径。** open/lookup 从 FDB 取得 inode、chunk 大小、chain table 范围和 shuffle seed 后，客户端可以独立计算 chunk 到 chain 的映射。
2. **写入不是“客户端推送后立即返回”。** chain 头节点用 RDMA Read 拉取数据，写入逐级传播，尾节点提交后 ACK 反向传播；慢尾节点或慢成员会直接抬高写延迟。
3. **读任意副本有条件。** 目标只有 committed 版本时可直接返回；同时存在 pending 版本时，默认客户端等待/重试。relaxed read 可读 pending，但一致性随之降低。
4. **FDB 解决的是元数据事务，不是文件数据事务。** rename/link/unlink 等命名空间操作可落入 FDB 事务；跨 chunk 数据写、文件长度更新和命名空间变更之间不存在一个全局原子事务。
5. **文件长度在活跃并发写期间可能暂时陈旧。** 客户端周期性上报最大写位置，close/fsync 可触发更精确的长度计算；应用不能把每次 stat 都理解为数据面瞬时真值。
6. **恢复是全副本同步。** 返回目标先处于 syncing，接收线上写的完整 chunk replacement，同时由前驱比较 chunk 版本并补数据；恢复带宽与业务流量竞争。
7. **所谓 EC 配置不能等同于 EC 能力。** 仓库中的 EC 字样集中在放置求解/生成脚本，公开客户端、Storage、恢复路径未发现编码、解码和重建逻辑。
8. **公开性能数字是架构上限案例，不是采购承诺。** 6.6 TiB/s 平均约 37.5 GiB/s/存储节点、2.35 GiB/s/NVMe，依赖定制拓扑、协议栈和网络调优。
9. **生产发布纪律需要使用方自己建立。** 仓库没有 release/tag，构建时还必须冻结与历史数据放置相关的 shuffle 方法；升级、回滚、混部兼容需要自建矩阵。
10. **安全边界默认是可信集群网络。** 用户 token、Unix mode 权限可用，但默认认证关闭，FDB 本身也不是多租户安全边界，传输/静态加密需外部方案。

## 架构速览

```text
                     +---------------------------+
                     | FoundationDB              |
                     | inode / dentry / session  |
                     | config / lease / GC queue |
                     +------------+--------------+
                                  |
             +--------------------+-------------------+
             |                                        |
       +-----v------+                          +------v------+
       | MgmtD      | lease/election/          | Meta        |
       | primary    | chain table/config       | stateless   |
       +-----+------+                          +------+------+
             |                                        |
             +--------------------+-------------------+
                                  |
  Application -> FUSE / USRBIO client -> direct RDMA data I/O
                                  |
                    +-------------v-------------+
                    | Chain: head -> mid -> tail|
                    | committed / pending ver   |
                    +---------------------------+

  Monitor -> ClickHouse（指标后端，不是元数据后端）
```

## 建议的阅读路径

- 先读 [系统定位与总体架构](3fs-overview.md)，理解组件、依赖和适用边界。
- 再读 [元数据架构](3fs-metadata.md) 与 [数据布局和 I/O 路径](3fs-data-path.md)，掌握关键机制。
- 对语义敏感的应用应重点读 [一致性与 POSIX 语义](3fs-consistency.md)。
- 做生产方案评审时重点读 [高可用与故障恢复](3fs-ha-recovery.md)、[部署运维、安全与灾备](3fs-operations.md)。
- 做容量与性能决策时读 [性能证据与验证方案](3fs-performance.md)。
- 面向 LightStore 或选型决策，直接读 [技术评估与建议](3fs-analysis.md)。
- 所有版本、来源、证据等级和限制见 [资料来源与研究方法](sources.md)。

## 适用与不适用场景

### 推荐评估

- 单数据中心、RDMA 网络、NVMe 全闪存，训练数据以大块顺序/并行读为主；
- 需要聚合带宽远高于单机本地盘，客户端数量多且能通过 native I/O 接口改造；
- Checkpoint 写入、模型加载、Embedding/KV Cache 等可接受文件级而非跨文件事务；
- 团队有能力运营 FDB、RDMA、ClickHouse、XFS/NVMe，并维护固定源码版本；
- 三副本成本可以接受，性能优先于每 TiB 成本。

### 谨慎评估

- 大量 4 KiB 非对齐随机读、热目录小文件、高频 rename/unlink；
- 多写者并发写同一文件，应用强依赖实时文件长度；
- 共享 RoCE 网络存在拥塞、PFC 风暴或不稳定 ECN/DCQCN；
- 需要滚动升级、跨版本互通、成熟厂商支持和明确 SLA；
- 需要严格的租户隔离、传输加密、审计和细粒度 ACL。

### 不建议作为首选

- 跨城/跨区域多活或 WAN 文件系统；
- 冷数据和 EiB 级容量，成本模型依赖纠删码；
- 强依赖全 POSIX、文件锁、通用 xattr、原生快照、配额；
- 无法为 FDB 和控制面建立独立故障域、备份和恢复演练；
- 普通以太网且无法开展 RDMA 网络工程和端到端压测。

## 结论

3FS 是一个“为了 AI/HPC 数据面极限而主动收缩通用性”的系统。若环境与其假设一致，它的客户端直达、CRAQ 读扩展、RDMA 拉取、无状态 Meta 和在线同步都很有竞争力；若工作负载或基础设施不匹配，三副本成本、写链路尾延迟、FDB/RDMA 运维和产品成熟度会迅速成为主导风险。

对 LightStore 而言，最值得吸收的是 chain version 栅栏、显式目标状态机、在线 full-chunk replacement 恢复、客户端批量异步接口、元数据键分散和形式化故障模型；不应照搬的是全量三副本、每文件独立 chunk、小文件无 packing、完整 POSIX 包袱和对单一外部事务数据库的全局依赖。
