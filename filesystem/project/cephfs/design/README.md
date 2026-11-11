# CephFS 设计文档

> 基线：Ceph Tentacle `v20.2.3`（commit `06c2f9c3`），与上级目录 [sources.md](../sources.md) 一致
>
> 视角：存储系统架构师 / 存储研发工程师。回答“CephFS 为什么这样设计、各层之间的契约是什么、哪些不变量在保证正确性”。

设计文档关注**模型、契约与不变量**；具体到类、函数、消息和持久化编码的内容放在 [实现文档](../implementation/README.md)。

## 文档列表

| # | 文档 | 回答的问题 | 关键图 |
|---|------|------------|--------|
| 1 | [总体架构设计](cephfs-design-architecture.md) | 设计目标、分层、组件职责、控制面/数据面分离、关键设计决策 | 分层架构图、部署拓扑图、对象全景图 |
| 2 | [元数据设计](cephfs-design-metadata.md) | namespace 模型、authority 分区、dirfrag、递归统计、journal、负载均衡 | 子树分区图、dirfrag 分裂图、journal 生命周期 |
| 3 | [数据布局与 I/O 设计](cephfs-design-data.md) | 条带化、CRUSH 放置、副本/EC、caps 门控的 I/O、size 传播、删除回收 | 条带映射图、放置流程图、读写路径图 |
| 4 | [一致性与并发控制设计](cephfs-design-consistency.md) | caps 模型、分布式锁状态机、lease、fencing、POSIX 语义边界 | caps 位图、filelock 状态机、recall/fencing 时序 |
| 5 | [高可用与恢复设计](cephfs-design-ha.md) | rank 模型、failover 状态机、standby-replay、重连与 rejoin、scrub/修复 | rank 状态机、故障切换时序、修复决策树 |
| 6 | [快照、多租户与灾备设计](cephfs-design-snapshot-tenancy.md) | SnapRealm、COW、子卷、配额、权限隔离、异步镜像 | SnapRealm 树、快照 COW 流程、镜像架构 |

## 设计主线（一句话版）

```text
POSIX namespace = 单 authority MDS rank（按子树/dirfrag 动态分区）
               + 每 rank 一条 RADOS 中的 journal（可在任意节点 replay）
               + caps（MDS 向客户端租借的可撤销缓存/写权限）
文件数据      = inode 布局 → 条带化成 RADOS 对象 → CRUSH 计算放置 → 客户端直连 OSD
正确性边界    = MON 维护的 FSMap/OSDMap epoch + OSD blocklist fencing
```

## 阅读路径

- **第一次接触 CephFS**：1 → 3 → 4。
- **做元数据扩展/性能评估**：1 → 2 → 4，再读 [MDS 实现](../implementation/cephfs-impl-mds.md)。
- **做可靠性、故障演练**：5 → 4 的 fencing 一节 → [关键请求流程](../implementation/cephfs-impl-request-flows.md) 的 failover 部分。
- **做 Kubernetes / 多租户平台**：6 → [生产运维](../cephfs-operations.md)。
