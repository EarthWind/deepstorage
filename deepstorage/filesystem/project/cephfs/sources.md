# 调研基线与证据来源

## 1. 方法

本调研使用“官方承诺 → 固定版本源码/默认值 → 工程推断 → 本地 PoC 待验证”的证据链。

1. **官方版本化文档**用于确认支持边界、默认行为、已知限制和运维流程。
2. **固定 tag 源码**用于确认模块边界、状态机、配置默认值和恢复工具实现入口。
3. **工程推断**用于分析瓶颈、故障域和对 LightStore 的启示；推断不冒充 Ceph 官方 SLA。
4. **未引用通用性能数字**。MDS ops/s、单文件带宽、EC 写放大和 failover 时间与硬件、网络、PG、缓存命中、客户端版本及 namespace 形态强相关，应由本地 PoC 给出。

## 2. 版本基线

调研截止日期为 2026-08-08。

| 项目 | 基线 | 说明 |
|------|------|------|
| 最新稳定 major | Tentacle 20 | Ceph 官方称其为第 20 个 stable release |
| 最新补丁 | `v20.2.3` | 2026-08-05 发布，官方建议所有用户升级 |
| 源码 commit | `06c2f9c35b67055a8a6fb99d1be236b3c4832ace` | tag `v20.2.3` 的 peeled commit，提交时间 2026-08-03T16:40:44Z |
| 同期维护分支 | Squid `19.2.5` | 仍受维护，但不是本调研实现基线 |

版本状态以 [Ceph Releases Index](https://docs.ceph.com/en/latest/releases/) 和
[Tentacle Release Notes](https://docs.ceph.com/en/latest/releases/tentacle/) 为准。20.2.3 与 CephFS 直接相关的修复包括：ephemeral pins 配合 `max_mds=0` 时的崩溃/关停问题、session reclaim 漏 blocklist，以及不可修复 hard link 的 scrub 识别。

文档页面中的 `latest` 可能带 development 提示，因此机制引用优先使用 `/en/tentacle/` 固定版本 URL；源码引用固定到 `v20.2.3` tag。

## 3. 官方资料索引

### 架构、元数据与数据路径

- [Ceph Architecture](https://docs.ceph.com/en/tentacle/architecture/)
- [CephFS Introduction](https://docs.ceph.com/en/tentacle/cephfs/)
- [CephFS I/O Path](https://docs.ceph.com/en/tentacle/cephfs/cephfs-io-path/)
- [Distributed Metadata Cache](https://docs.ceph.com/en/tentacle/cephfs/mdcache/)
- [Dynamic Metadata Management](https://docs.ceph.com/en/tentacle/cephfs/dynamic-metadata-management/)
- [Multiple Active MDS](https://docs.ceph.com/en/tentacle/cephfs/multimds/)
- [Directory Fragmentation](https://docs.ceph.com/en/tentacle/cephfs/dirfrags/)
- [MDS Journaling](https://docs.ceph.com/en/tentacle/cephfs/mds-journaling/)
- [File Layouts](https://docs.ceph.com/en/tentacle/cephfs/file-layouts/)
- [Create a Ceph File System](https://docs.ceph.com/en/tentacle/cephfs/createfs/)

### 一致性、HA 与恢复

- [CephFS Capabilities](https://docs.ceph.com/en/tentacle/cephfs/capabilities/)
- [Differences from POSIX](https://docs.ceph.com/en/tentacle/cephfs/posix/)
- [Client Eviction](https://docs.ceph.com/en/tentacle/cephfs/eviction/)
- [MDS States](https://docs.ceph.com/en/tentacle/cephfs/mds-states/)
- [MDS Standby](https://docs.ceph.com/en/tentacle/cephfs/standby/)
- [Disaster Recovery](https://docs.ceph.com/en/tentacle/cephfs/disaster-recovery/)
- [Advanced Metadata Repair](https://docs.ceph.com/en/tentacle/cephfs/disaster-recovery-experts/)
- [Scrub](https://docs.ceph.com/en/tentacle/cephfs/scrub/)
- [cephfs-journal-tool](https://docs.ceph.com/en/tentacle/cephfs/cephfs-journal-tool/)

### 快照、租户与灾备

- [CephFS Snapshots](https://docs.ceph.com/en/tentacle/cephfs/snapshots/)
- [Snapshot Internals](https://docs.ceph.com/en/tentacle/dev/cephfs-snapshots/)
- [Snapshot Mirroring](https://docs.ceph.com/en/tentacle/cephfs/cephfs-mirroring/)
- [FS Volumes and Subvolumes](https://docs.ceph.com/en/tentacle/cephfs/fs-volumes/)
- [Multiple Ceph File Systems](https://docs.ceph.com/en/tentacle/cephfs/multifs/)
- [CephFS Quotas](https://docs.ceph.com/en/tentacle/cephfs/quota/)

### 运维、性能与安全

- [Add or Remove MDS](https://docs.ceph.com/en/tentacle/cephfs/add-remove-mds/)
- [MDS Cache Configuration](https://docs.ceph.com/en/tentacle/cephfs/cache-configuration/)
- [Application Best Practices](https://docs.ceph.com/en/tentacle/cephfs/app-best-practices/)
- [Health Messages](https://docs.ceph.com/en/tentacle/cephfs/health-messages/)
- [CephFS Metrics](https://docs.ceph.com/en/tentacle/cephfs/metrics/)
- [Handling Full File Systems](https://docs.ceph.com/en/tentacle/cephfs/full/)
- [Client Authentication](https://docs.ceph.com/en/tentacle/cephfs/client-auth/)
- [Messenger v2](https://docs.ceph.com/en/tentacle/rados/configuration/msgr2/)
- [BlueStore Checksums](https://docs.ceph.com/en/tentacle/rados/configuration/bluestore-config-ref/#checksums)
- [Encryption](https://docs.ceph.com/en/tentacle/ceph-volume/lvm/prepare/#encryption)

## 4. 固定源码入口

以下链接均固定到 `v20.2.3`：

| 主题 | 入口 |
|------|------|
| MDS 服务与 rank 状态机 | [`src/mds/MDSRank.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/MDSRank.cc)、[`MDSMap.h`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/MDSMap.h) |
| 元数据缓存 | [`src/mds/MDCache.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/MDCache.cc)、[`CInode.h`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/CInode.h)、[`CDir.h`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/CDir.h)、[`CDentry.h`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/CDentry.h) |
| 动态负载均衡 | [`src/mds/MDBalancer.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/MDBalancer.cc) |
| 子树迁移 | [`src/mds/Migrator.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/Migrator.cc) |
| 分布式锁/caps | [`src/mds/Locker.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/Locker.cc)、[`src/mds/Capability.h`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/Capability.h) |
| MDS journal | [`src/mds/MDLog.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/MDLog.cc)、[`EUpdate.h`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/events/EUpdate.h)、[`EExport.h`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/events/EExport.h) |
| session 与 reconnect | [`src/mds/SessionMap.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/SessionMap.cc)、[`src/client/MetaSession.h`](https://github.com/ceph/ceph/blob/v20.2.3/src/client/MetaSession.h) |
| 快照 | [`src/mds/SnapRealm.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/SnapRealm.cc)、[`src/mds/SnapServer.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/SnapServer.cc) |
| 异步删除 | [`src/mds/PurgeQueue.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/PurgeQueue.cc) |
| scrub/damage | [`src/mds/ScrubStack.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/ScrubStack.cc)、[`src/mds/DamageTable.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/mds/DamageTable.cc) |
| 客户端实现 | [`src/client/Client.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/client/Client.cc)、[`src/client/Inode.cc`](https://github.com/ceph/ceph/blob/v20.2.3/src/client/Inode.cc) |
| MDS 默认配置 | [`src/common/options/mds.yaml.in`](https://github.com/ceph/ceph/blob/v20.2.3/src/common/options/mds.yaml.in) |
| 网络/BlueStore 默认配置 | [`src/common/options/global.yaml.in`](https://github.com/ceph/ceph/blob/v20.2.3/src/common/options/global.yaml.in) |

## 5. 关键源码默认值

| 配置 | v20.2.3 默认值 | 解释 |
|------|---------------|------|
| `mds_cache_memory_limit` | 4 GiB | 目标缓存上限，不是硬 RSS 上限；慢 cap recall 可使其超限 |
| `mds_cache_reservation` | 5% | 进入保留区后开始回收客户端状态 |
| `mds_health_cache_threshold` | 1.5 | 达到目标缓存的 150% 触发健康告警 |
| `mds_beacon_interval` / `grace` | 4 s / 15 s | MDS 对 MON 的心跳与 laggy 判定窗口 |
| `mds_reconnect_timeout` | 45 s | failover reconnect 阶段等待客户端的默认窗口 |
| `mds_early_reply` | true | 可在 metadata 请求完成但尚未 journal durable 时先回复，客户端保留 unsafe request 供重放 |
| `mds_log_events_per_segment` | 1024 | journal 逻辑段目标事件数 |
| `mds_log_max_segments` | 128 | 未 trim 段目标上限，超过 2 倍默认触发 trim 健康告警 |
| `mds_max_caps_per_client` | 1,000,000 | 单客户端 caps 目标上限 |
| `mds_recall_max_caps` | 30,000 | 单次 recall 的 cap 数上限 |
| `mds_cap_revoke_eviction_timeout` | 0 | 因 cap revoke 超时自动驱逐默认关闭 |
| `mds_max_purge_files` | 64 | 并发 purge 文件数 |
| `mds_max_purge_ops` | 8192 | 并发 purge RADOS 操作数 |
| `mds_max_purge_ops_per_pg` | 0.5 | purge 并发按 PG 限速 |
| `ms_cluster_mode` / `ms_service_mode` / `ms_client_mode` | `crc secure` | 普通 daemon/client 连接默认优先 CRC，不等于默认加密 |
| `ms_mon_*_mode` | `secure crc` | MON 相关连接默认优先 secure |
| `bluestore_csum_type` | `crc32c` | BlueStore 数据 checksum 默认算法 |

## 6. 证据等级

| 标记 | 含义 | 可支持的结论 |
|------|------|--------------|
| 官方保证 | 版本化官方文档明确陈述 | 功能、限制、推荐流程、兼容边界 |
| 源码事实 | v20.2.3 可直接观察 | 当前默认值、状态/数据结构、实现入口 |
| 工程推断 | 从前两者推演 | 扩展瓶颈、故障影响和架构建议，需 PoC 验证 |

## 7. 调研限制

- 未部署真实 Ceph 集群，未执行 mdtest/IOR/fio/FSx、断网、OSD 丢失或 MDS failover 实验。
- 未覆盖所有 kernel client 版本差异；kernel CephFS 行为同时受 Linux 内核版本影响。
- 未对 NFS-Ganesha、SMB、Ceph CSI、Manila 和 Rook 做逐实现源码审计，只分析它们与 CephFS 的接口边界。
- 未给出采购、支持合同和发行版打包矩阵；上线前需按操作系统、内核和厂商支持组合重新核验。
- 灾难恢复工具具有破坏性，本文只解释机制和风险，不能替代具体事故中的官方/专业支持操作手册。
