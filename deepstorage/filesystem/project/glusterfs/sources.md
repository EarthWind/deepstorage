# GlusterFS 调研基线与证据来源

## 1. 调研方法

本调研使用以下证据链：

1. **版本化源码**：以 `v11.2` tag 固定实现、默认值和状态机入口。
2. **上游官方文档**：确认对外功能、部署约束、运维命令与已知边界。
3. **官方发布与生命周期页面**：区分 upstream release、社区维护状态和 Red Hat 商业产品生命周期。
4. **工程推断**：从实现与文档推演扩展瓶颈、故障域和 LightStore 设计启示；推断均不冒充官方 SLA。
5. **不引用脱离环境的性能数字**：GlusterFS 的 ops/s、带宽、heal/rebalance 时间高度依赖文件大小、brick 数、replica/disperse 形态、XFS、网络 RTT、客户端数和 translator 选项，应由本地 PoC 给出。

## 2. 版本与维护状态基线

调研截止日期为 2026-08-11。

| 项目 | 观察结果 | 证据与判断 |
|------|----------|------------|
| 最新 GitHub release | `v11.2` | 2025-07-02 发布；tag/commit 均为 `15d3c0f8435814fdb7242a8a82fa5db140013d0a` |
| `release-11` 分支 | 仍指向 `15d3c0f…` | 截止调研日未见 11.2 之后的 release-11 提交 |
| `devel` 分支 | `ae1d69672fe0271265ab6f09ec2c2f93d4208511` | 最后可见提交日期 2026-02-16，说明项目并非完全没有后续开发 |
| 上游发布政策 | major 通常维护 12 个月 | Release Schedule 页面自身仍显示 11.0/10，未同步 11.2，也没有列 v11 确切 EOL |
| upstream EOL 判断 | **未找到明确的 v11 EOL 公告** | 按一般政策推算已超过常规窗口是工程风险判断，不写成官方事实 |
| Red Hat Gluster Storage | 2024-12-31 EOL | 这是商业产品生命周期，不等同于 upstream 代码库停止存在 |

关键来源：

- [GlusterFS 11.2 GitHub Release](https://github.com/gluster/glusterfs/releases/tag/v11.2)
- [`v11.2` 固定源码树](https://github.com/gluster/glusterfs/tree/v11.2)
- [`v11.2` release commit](https://github.com/gluster/glusterfs/commit/15d3c0f8435814fdb7242a8a82fa5db140013d0a)
- [2026-02-16 的 devel commit](https://github.com/gluster/glusterfs/commit/ae1d69672fe0271265ab6f09ec2c2f93d4208511)
- [Gluster Release Schedule](https://www.gluster.org/release-schedule/)
- [GlusterFS 11.0 Release Notes](https://docs.gluster.org/en/main/release-notes/11.0/)
- [Red Hat Gluster Storage Life Cycle](https://access.redhat.com/support/policy/updates/rhs)

### 2.1 如何解释维护风险

不能使用以下错误推理：

- “Red Hat 产品 EOL” ⇒ “开源 GlusterFS 当天停止工作”；
- “devel 还有 commit” ⇒ “release 分支仍有稳定安全维护”；
- “GitHub 标记 Latest” ⇒ “有与业务周期匹配的 LTS/SLA”；
- “Linux 发行版仍有包” ⇒ “该包包含最新 upstream 修复”。

生产决策需要单独核验：目标发行版的 package maintainer、CVE 回补策略、FUSE/libgfapi/openssl 兼容矩阵、修复响应时间、付费支持主体和迁移出口。

## 3. 上游官方文档索引

### 3.1 架构与 volume

- [GlusterFS Introduction](https://docs.gluster.org/en/main/Administrator-Guide/GlusterFS-Introduction/)
- [Architecture](https://docs.gluster.org/en/latest/Quick-Start-Guide/Architecture/)
- [Setting Up Volumes](https://docs.gluster.org/en/latest/Administrator-Guide/Setting-Up-Volumes/)
- [Managing Volumes](https://docs.gluster.org/en/main/Administrator-Guide/Managing-Volumes/)
- [Managing Trusted Storage Pools](https://docs.gluster.org/en/main/Administrator-Guide/Storage-Pools/)
- [Setting Up Clients](https://docs.gluster.org/en/latest/Administrator-Guide/Setting-Up-Clients/)
- [GFID to Path](https://docs.gluster.org/en/latest/Troubleshooting/gfid-to-path/)

### 3.2 复制、一致性与恢复

- [Automatic File Replication](https://docs.gluster.org/en/main/Administrator-Guide/Automatic-File-Replication/)
- [Arbiter Volumes and Quorum](https://docs.gluster.org/en/latest/Administrator-Guide/arbiter-volumes-and-quorum/)
- [Thin Arbiter Volumes](https://docs.gluster.org/en/main/Administrator-Guide/Thin-Arbiter-Volumes/)
- [Split-Brain Resolution](https://docs.gluster.org/en/main/Troubleshooting/resolving-splitbrain/)
- [Troubleshooting Self-Heal](https://docs.gluster.org/en/latest/Troubleshooting/troubleshooting-afr/)
- [Managing Volumes / Heal Commands](https://docs.gluster.org/en/main/Administrator-Guide/Managing-Volumes/)

### 3.3 数据保护与灾备

- [BitRot Detection](https://docs.gluster.org/en/main/Administrator-Guide/Managing-Volumes/#bitrot-detection)
- [Managing Snapshots](https://docs.gluster.org/en/v3/Administrator%20Guide/Managing%20Snapshots/)
- [Geo-Replication](https://docs.gluster.org/en/main/Administrator-Guide/Geo-Replication/)
- [Troubleshooting Geo-Replication](https://docs.gluster.org/en/latest/Troubleshooting/troubleshooting-georep/)

### 3.4 运维、性能与安全

- [Tuning Volume Options](https://docs.gluster.org/en/latest/Administrator-Guide/Tuning-Volume-Options/)
- [Monitoring Workload](https://docs.gluster.org/en/main/Administrator-Guide/Monitoring-Workload/)
- [Statedump](https://docs.gluster.org/en/main/Troubleshooting/statedump/)
- [GlusterFS Logs and Locations](https://docs.gluster.org/en/latest/Administrator-Guide/Logging/)
- [TLS/SSL Setup](https://docs.gluster.org/en/v3/Administrator%20Guide/SSL/)
- [Directory Quota](https://docs.gluster.org/en/main/Administrator-Guide/Directory-Quota/)
- [Users with Many Groups](https://docs.gluster.org/en/main/Administrator-Guide/Handling-of-users-with-many-groups/)
- [POSIX ACL](https://docs.gluster.org/en/main/Administrator-Guide/Access-Control-Lists/)
- [Upgrade to GlusterFS 11](https://docs.gluster.org/en/main/Upgrade-Guide/upgrade-to-11/)
- [Generic Upgrade Procedure](https://docs.gluster.org/en/main/Upgrade-Guide/generic-upgrade-procedure/)
- [Operating Version (op-version)](https://docs.gluster.org/en/main/Upgrade-Guide/op_version/)
- [Troubleshooting glusterd](https://docs.gluster.org/en/latest/Troubleshooting/troubleshooting-glusterd/)

> 文档站的 `/latest`、`/main` 和 `/v3` 内容混杂不同年代，部分表格未随源码更新。本调研把它们用于对外语义和运维入口，同时以 v11.2 源码确认关键默认值。涉及上线的命令必须在目标发行包上用 `gluster volume get <vol> all` 和实际 volfile 再核验。

## 4. 固定源码入口

以下链接全部固定在 `v11.2`，便于审计：

| 主题 | 源码/设计入口 |
|------|---------------|
| translator 核心与 graph | [`libglusterfs/src/xlator.c`](https://github.com/gluster/glusterfs/blob/v11.2/libglusterfs/src/xlator.c)、[`libglusterfs/src/graph.c`](https://github.com/gluster/glusterfs/blob/v11.2/libglusterfs/src/graph.c) |
| FUSE bridge | [`xlators/mount/fuse/src/fuse-bridge.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/mount/fuse/src/fuse-bridge.c) |
| libgfapi | [`api/src/glfs.c`](https://github.com/gluster/glusterfs/blob/v11.2/api/src/glfs.c) |
| client/server RPC | [`protocol/client/src/client.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/protocol/client/src/client.c)、[`protocol/server/src/server.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/protocol/server/src/server.c) |
| POSIX brick backend | [`storage/posix/src/posix.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/storage/posix/src/posix.c) |
| DHT 路由与 layout | [`cluster/dht/src/dht-common.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/dht/src/dht-common.c)、[`dht-layout.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/dht/src/dht-layout.c)、[`dht-hashfn.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/dht/src/dht-hashfn.c) |
| DHT linkfile/rename/rebalance | [`dht-linkfile.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/dht/src/dht-linkfile.c)、[`dht-rename.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/dht/src/dht-rename.c)、[`dht-rebalance.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/dht/src/dht-rebalance.c) |
| DHT namespace transaction 说明 | [`doc/developer-guide/dirops-transactions-in-dht.md`](https://github.com/gluster/glusterfs/blob/v11.2/doc/developer-guide/dirops-transactions-in-dht.md) |
| AFR 主逻辑 | [`cluster/afr/src/afr.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/afr/src/afr.c)、[`afr-transaction.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/afr/src/afr-transaction.c) |
| AFR read/write | [`afr-read-txn.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/afr/src/afr-read-txn.c)、[`afr-inode-write.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/afr/src/afr-inode-write.c)、[`afr-dir-write.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/afr/src/afr-dir-write.c) |
| AFR self-heal | [`afr-self-heal-common.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/afr/src/afr-self-heal-common.c)、[`afr-self-heald.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/afr/src/afr-self-heald.c) |
| AFR 设计说明 | [`doc/developer-guide/afr.md`](https://github.com/gluster/glusterfs/blob/v11.2/doc/developer-guide/afr.md)、[`afr-self-heal-daemon.md`](https://github.com/gluster/glusterfs/blob/v11.2/doc/developer-guide/afr-self-heal-daemon.md) |
| EC translator | [`cluster/ec/src/ec.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/ec/src/ec.c)、[`ec-data.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/ec/src/ec-data.c)、[`ec-locks.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/cluster/ec/src/ec-locks.c) |
| EC 实现说明 | [`doc/developer-guide/ec-implementation.md`](https://github.com/gluster/glusterfs/blob/v11.2/doc/developer-guide/ec-implementation.md) |
| sharding | [`features/shard/src/shard.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/features/shard/src/shard.c) |
| locks | [`features/locks/src/posix.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/features/locks/src/posix.c) |
| write-behind | [`performance/write-behind/src/write-behind.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/performance/write-behind/src/write-behind.c)、[设计说明](https://github.com/gluster/glusterfs/blob/v11.2/doc/developer-guide/write-behind.md) |
| index/heal 索引 | [`features/index/src/index.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/features/index/src/index.c) |
| bitrot signer/scrubber | [`features/bit-rot/src/bitd/bit-rot.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/features/bit-rot/src/bitd/bit-rot.c)、[`bit-rot-scrub.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/features/bit-rot/src/bitd/bit-rot-scrub.c) |
| quota | [`features/quota/src/quota.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/features/quota/src/quota.c)、[`features/marker/src/marker.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/features/marker/src/marker.c) |
| geo-replication | [`geo-replication/`](https://github.com/gluster/glusterfs/tree/v11.2/geo-replication)、[`features/changelog/`](https://github.com/gluster/glusterfs/tree/v11.2/xlators/features/changelog) |
| 管理面 | [`xlators/mgmt/glusterd/src/`](https://github.com/gluster/glusterfs/tree/v11.2/xlators/mgmt/glusterd/src) |
| volume 选项映射 | [`glusterd-volume-set.c`](https://github.com/gluster/glusterfs/blob/v11.2/xlators/mgmt/glusterd/src/glusterd-volume-set.c) |

## 5. v11.2 关键默认值

源码 translator 的内部 default 与最终生成 volfile 的“是否装载该 translator”是两层概念。以下表格给出对工程判断最重要的最终/实现默认：

| 配置 | v11.2 默认 | 含义 |
|------|------------|------|
| `network.ping-timeout` | 42 s | 客户端判定 brick 连接无响应的重要窗口；不是完整业务 RTO |
| protocol frame timeout | 1800 s | 单 FOP 无响应的上限很长，故障/卡顿排查需区分 ping 与 frame timeout |
| client/server event threads | 2 | 大并发是否增大必须压测，不能盲调 |
| `cluster.quorum-type` | `none`（一般 AFR 默认） | replica 3/arbiter 创建流程会设置适合拓扑的 quorum；replica 2 尤其危险 |
| `cluster.ensure-durability` | `on` | AFR transaction 为 changelog/data 执行所需 fsync；关闭可能产生坏数据 |
| `cluster.eager-lock` | `on` | 连续写复用全文件内部锁，减少锁往返但可能扩大竞争粒度 |
| AFR read hash mode | `1` | 按 GFID 选择 read child；默认优先 local brick |
| self-heal daemon | `on` | replicate/disperse 后台 heal 进程启用 |
| heal timeout | 600 s | SHD 周期检查基线 |
| AFR background heals | 8 | 每 client/相关上下文的并行 background heal 基线 |
| DHT `lookup-optimize` | `on` | negative lookup 可避免非哈希子卷广播；异常 layout/linkfile 场景仍需额外 lookup |
| DHT `min-free-disk` | 10% | 低于阈值开始偏移新文件放置并告警，不会自动释放空间 |
| DHT weighted rebalance | `on` | 按 brick 容量比例分配 hash range |
| rebalance throttle | `normal` | 每节点通常并行迁移 2 个文件 |
| rebalance `force-migration` | `off` | 默认跳过正在被写的文件，降低在线迁移损坏风险 |
| rebalance `ensure-durability` | `on` | 迁移后 fsync |
| disperse fragment size | 512 B | EC stripe size = `512 × data_fragments(K)` |
| EC eager lock | `on`，1 s | 连续操作复用锁 |
| EC stripe cache | 4 stripes/open file | 降低连续 partial write 的 RMW；增加每打开文件内存 |
| EC parallel writes | `on` | 不修改同一 stripe 的写可并行 |
| sharding | `off` | 需要显式启用 |
| shard block size | 64 MiB | 大文件被拆成 base + `.shard` 隐藏块 |
| write-behind translator | 默认装载 | 单文件 window 1 MiB；write 可先向应用返回，错误可能延后到 flush/fsync/close |
| open-behind / quick-read | 默认装载 | 降低 open/small-read latency，但扩大客户端缓存/延后错误语义 |
| io-cache/read-ahead/readdir-ahead | 默认不装载 | 需按 workload 明确开启 |
| I/O TLS | `client.ssl=off`、`server.ssl=off` | 默认明文 |
| address authorization | `auth.allow=*` | 默认允许所有地址连接，必须用网络与 ACL 收紧 |
| `auth.ssl-allow` | `*` | 即使启用 TLS，默认也允许所有被 CA 信任的证书 CN |
| `server.root-squash` | `off` | 客户端 root 默认仍具高权限 |
| `server.manage-gids` | `off` | 默认使用 client RPC 发送的辅助组 |
| bitrot | `disable` | 默认不执行持续内容签名/scrub |
| bitrot hash | SHA-256 | 启用后 signer/scrubber 使用 SHA-256 内容摘要 |
| scrub frequency/throttle | biweekly / lazy | 仅在 bitrot 启用后有意义 |

## 6. 证据等级

| 等级 | 定义 | 示例 |
|------|------|------|
| 官方事实 | 上游/厂商页面明确陈述 | v11.2 tag、RHGS EOL、volume 命令与功能约束 |
| 源码事实 | v11.2 固定源码可直接观察 | 默认值、xattr、translator 分层、锁与 heal 入口 |
| 工程推断 | 基于前两类证据的系统性判断 | 客户端连接规模、heal RTO、小文件 inode/xattr 放大、维护风险 |
| 待 PoC | 与部署环境强相关 | P99、最大 brick/client 数、rebalance 干扰、故障恢复时间 |

## 7. 调研限制

- 未部署真实 v11.2 集群，未运行 fio、smallfile、mdtest、fsx、fsstress 或故障注入。
- 未对目标 Linux 发行版 package patchset 做审计；发行包可能与 upstream v11.2 不同。
- 未逐版本比较 kernel FUSE、libfuse、Samba/NFS-Ganesha、QEMU/libgfapi 的兼容差异。
- Gluster 文档跨多个历史版本，个别示例、端口和默认值可能陈旧；本报告只把经 v11.2 源码或当前官方页面交叉核验的值作为基线。
- 未验证 snapshot 在特定 LVM/ZFS backend、geo-rep 在特定拓扑、bitrot 与 EC/arbiter 组合下的全部限制。
- split-brain 手工操作、直接修改 brick xattr/GFID 和 replace/remove-brick 都可能造成不可逆数据丢失；本文解释机制，不替代事故现场备份与专家 runbook。
