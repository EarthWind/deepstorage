# GlusterFS 深度技术调研

> 调研日期：2026-08-11
>
> 实现基线：GlusterFS `v11.2`（commit `15d3c0f8435814fdb7242a8a82fa5db140013d0a`，2025-07-02）
>
> 视角：分布式文件系统架构、无中心元数据、客户端复制/EC、一致性与脑裂、故障恢复、生产运维及通用设计启示

## 1. 技术摘要

GlusterFS 是一个以 **无独立元数据服务器、客户端 translator 图、后端原生文件系统**为核心的分布式文件系统。客户端拿到由 `glusterd` 生成的 volume file 后，可直接把路径操作路由到 brick：DHT 按目录内文件名哈希选择一个 replicate/disperse 子卷，AFR 在客户端同步复制，EC translator 在客户端执行 Reed-Solomon 编解码，brick 最终把文件、目录和扩展属性写入 XFS 等本地文件系统。

这一设计真正有价值的地方，是去掉了集中 metadata service 和独立对象层：普通文件在 brick 上仍是普通文件，容量/带宽通过增加子卷扩展，稳定数据面不经过 `glusterd`。代价同样来自这条路线：目录要存在于全部 DHT 子卷；目录布局、GFID、复制 changelog、heal 索引和迁移状态分散在文件与 xattr 中；客户端承担路由、锁、复制与 EC；跨 brick rename、目录遍历、rebalance 和 split-brain 处理因此成为系统复杂度中心。

从 2026 年生产选型看，**工程机制成熟不等于维护风险可接受**。GitHub 最新 release 是 2025-07-02 的 11.2，`release-11` 仍停在该 tag；`devel` 最后可见提交为 2026-02-16。上游发布日程页面没有及时反映 11.2，也没有给出 v11 的明确 EOL 日期；按其“major 发布后维护 12 个月”的一般政策推算，v11 已超过通常维护窗口，但这只是工程推断，不应冒充官方 EOL 公告。与此同时，Red Hat Gluster Storage 商业产品已于 2024-12-31 EOL。新项目必须先解决发行包、安全修复、内核/FUSE 兼容和专家支持来源，再讨论性能。

## 2. 关键结论

| 主题 | 结论 | 工程含义 |
|------|------|----------|
| 总体架构 | `glusterd` 只负责控制面；FUSE/libgfapi 客户端依据 volfile 直连所有 brick | 无集中 I/O/metadata 网关，但客户端和网络连接数随 brick 数增长 |
| namespace | 没有集中 inode/dentry 数据库；目录复制到所有 DHT 子卷，文件按 basename 的 32-bit hash 落到一个子卷 | 常规 lookup 可计算路由；mkdir/readdir/rename/rebalance 会产生多子卷协调或扇出 |
| 后端格式 | 文件以原生文件保存，`trusted.gfid`、`trusted.glusterfs.dht`、`trusted.afr.*` 等 xattr 保存分布式状态 | 可用标准工具做取证，但禁止绕过 Gluster 修改 brick；xattr/inode 完整性是系统正确性的一部分 |
| DHT 扩容 | add-brick 只改变拓扑；既有目录 layout 和文件需 fix-layout/rebalance 才利用新 brick | 扩容不是“瞬时均衡”；迁移周期、额外空间和前台干扰必须容量规划 |
| 同步复制 | AFR 在客户端加内部锁、记录 dirty/pending xattr、向 replica bricks 并行发 FOP | 正常路径无复制 leader；一致性依赖各客户端看到相容 topology、锁和 quorum |
| quorum | replica 2 默认无法同时保留分区可用性与防脑裂；replica 3/arbiter 默认 auto quorum 更合理 | 生产 RW 数据不应使用未启用有效 quorum 的 replica 2 |
| arbiter | 2 个数据 brick + 1 个仅存 namespace/xattr 的 arbiter，接近 replica 3 的仲裁语义但约 2x 数据空间 | arbiter 省数据容量，不省 inode/metadata，也不是一份可恢复的数据副本 |
| thin arbiter | 对整对 data bricks 记录好/坏，粒度比普通 arbiter 粗；常态不进数据路径 | 适合 stretch/witness，但故障后的可用性比逐文件 arbiter 更保守 |
| EC | 一个 disperse set 用 `K=N-R` 个数据自由度和 `R` 冗余片；stripe size 为 `512 × K` bytes | 容量效率高，但 partial write 触发 read-modify-write，锁、CPU、网络与尾延迟更重 |
| 一致性边界 | bricks 全在线时 AFR/EC 内部锁维持多客户端副本顺序；故障时能否继续服务由 quorum/topology 决定 | 不能把“POSIX 接口”理解为跨网络分区的线性一致共识系统 |
| split-brain | AFR 无法判定唯一正确副本时拒绝自动 heal；分 data/metadata/entry 三类 | `favorite-child-policy` 可能自动丢弃一侧更新，默认 `none` 是更安全的取证选择 |
| self-heal | index heal 根据 `.glusterfs/indices` 增量恢复；full heal 递归扫描全 namespace | backlog 与恢复时间和文件数强相关；海量小文件下 full heal/RTO 风险突出 |
| 数据完整性 | 默认依赖本地文件系统和复制；bitrot SHA-256 signer/scrubber 默认关闭 | 没有默认的端到端持续内容校验；启用后需预算全量 scrub I/O |
| 快照 | 依赖每个 brick 独立 LVM thin snapshot，提供多 brick crash-consistent snapshot | 不是 Gluster 自身 MVCC；受 LVM thin pool、快照顺序和 brick backend 强约束 |
| Geo-rep | changelog/rsync 驱动的异步单向增量复制，可用 checkpoint 判断某时刻以前变更是否同步完成 | 不是同步副本或双活；RPO 是最后完成 checkpoint/同步位点 |
| 安全默认值 | I/O TLS 默认关闭，`auth.allow=*`、root squash 默认关闭，client 传递 UID/GID | 只能部署在受控存储网络；必须显式做 TLS、证书 CN 白名单、地址 ACL 与管理面隔离 |
| 运维状态 | 上游 11.2 仍可用且 devel 有后续提交，但 release 分支、安全修复节奏和商业支持不确定 | 2026 年新建核心存储应默认“不采用”，除非已有可验证的维护方与退出计划 |

## 3. 文档导航

1. [调研基线与证据来源](sources.md)：版本、维护状态、证据等级、固定源码入口和限制。
2. [系统概览与拓扑](glusterfs-overview.md)：组件、volume 类型、控制面/数据面、适用场景。
3. [Translator、DHT 与元数据组织](glusterfs-translators-metadata.md)：translator 图、GFID、目录 layout、linkfile、namespace 操作与 rebalance。
4. [读写路径、复制与纠删码](glusterfs-data-path.md)：FUSE/gfapi 到 brick 的调用链、AFR transaction、EC RMW、sharding 和 fsync。
5. [一致性、quorum 与 split-brain](glusterfs-replication-consistency.md)：一致性边界、client/server quorum、arbiter、heal 判定与脑裂处理。
6. [高可用、恢复与灾备](glusterfs-ha-recovery.md)：故障矩阵、self-heal、brick replacement、bitrot、snapshot 和 geo-replication。
7. [生产运维与安全](glusterfs-operations-security.md)：部署、容量、扩缩容、升级、监控、TLS、权限与 runbook。
8. [性能模型与压测方法](glusterfs-performance.md)：metadata/data 放大、热点、调优边界和可复现 PoC 矩阵。
9. [技术评估与设计启示](glusterfs-analysis.md)：结构性优缺点、可借鉴机制、不可照搬部分、通用设计启示和选型建议。

## 4. 阅读建议

- **做 2026 年新项目选型**：先读本文、[系统概览](glusterfs-overview.md) 和 [技术评估](glusterfs-analysis.md)，优先判断维护/支持风险。
- **维护既有集群**：读 [一致性](glusterfs-replication-consistency.md)、[HA/恢复](glusterfs-ha-recovery.md) 与 [运维安全](glusterfs-operations-security.md)。
- **排查 lookup/readdir/rebalance 问题**：读 [Translator、DHT 与元数据组织](glusterfs-translators-metadata.md)。
- **评估 VM、数据库或海量小文件**：读 [数据路径](glusterfs-data-path.md) 和 [性能模型](glusterfs-performance.md)，不要仅依赖顺序吞吐测试。

## 5. 总体判断

GlusterFS 的最佳适配场景，是已有 Gluster 运维能力、需要普通 Linux 文件可见性、容量以中大文件为主、可接受 FUSE 客户端和同步复制写延迟、故障域/仲裁部署清晰的存量环境。它也可作为“无中心元数据 + 客户端可组合数据面”的优秀研究对象。

它不适合作为 2026 年新建超大规模、多租户、强安全边界或极低 metadata P99 系统的默认选择；也不适合把 replica 2、默认安全设置或异步 geo-rep 当成低成本 HA/DR。对于以海量小文件和超大规模容量为目标的新系统设计，GlusterFS 更适合作为机制对照而不是实现模板。
