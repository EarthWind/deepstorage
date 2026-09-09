# 调研基线与证据来源

## 1. 方法

本调研以“可复核的事实 → 实现机制 → 工程推断 → 设计启示与选型建议”为证据链，使用三类材料：

1. **官方 8.4 文档**：用于确认产品承诺、支持边界、默认行为、已知限制和运维流程。
2. **固定 tag 源码**：用于确认请求顺序、落盘模型、缓存/锁默认值、错误分支以及管理数据库结构。
3. **工程推断**：从前两类证据推导扩展瓶颈、故障域和适用场景。推断会明确标注，不冒充官方保证。

未采用厂商性能数字作为本地容量规划依据，也没有把旧版本文档中的行为直接套用到 8.4；历史文档只用于解释功能演进。

## 2. 版本与仓库基线

调研日期为 2026-08-07。BeeGFS 8 将不同语言的组件拆到多个仓库，本调研固定如下：

| 仓库 | tag | commit | 本调研使用范围 |
|------|-----|--------|----------------|
| [`ThinkParQ/beegfs`](https://github.com/ThinkParQ/beegfs/tree/8.4.0) | `8.4.0` | `4942de5924ed8e669b906ab784d1a545f81c5f89` | 内核客户端、metadata、storage、fsck、monitoring、公共协议实现 |
| [`ThinkParQ/beegfs-rust`](https://github.com/ThinkParQ/beegfs-rust/tree/v8.4.0) | `v8.4.0` | `e3495286010a7d6b9c2caf98fa8da6f916f1ddb1` | BeeGFS 8 management service、SQLite 封装 |
| [`ThinkParQ/beegfs-go`](https://github.com/ThinkParQ/beegfs-go/tree/v8.4.0) | `v8.4.0` | `1f8238880262f30041f0aae1276aba3d490aa42f` | 新 `beegfs` CLI、Remote/Sync/Watch/Index 相关组件 |
| [`ThinkParQ/protobuf`](https://github.com/ThinkParQ/protobuf/tree/v0.8.4) | `v0.8.4` | `ae240cc861a3fa3efcbf5ff254ceb07d61cca3e1` | gRPC/Protobuf 接口定义 |

版本状态以 [BeeGFS Release 页面](https://www.beegfs.io/release/) 和
[8.4 Release Notes](https://doc.beegfs.io/latest/release_notes.html) 为准。8.x 组件具有同一 major 内的语义兼容目标，
但新功能需要相应版本；8.x 因网络和磁盘格式变化不与 7.x 混用。生产变更仍应以具体补丁版本的 release notes 为准。

## 3. 官方资料索引

### 架构与数据模型

- [Architecture Overview](https://doc.beegfs.io/latest/architecture/overview.html)
- [Architecture Details](https://doc.beegfs.io/latest/architecture/overview.html#architecture-details)
- [Striping](https://doc.beegfs.io/latest/advanced_topics/striping.html)
- [Client Caching](https://doc.beegfs.io/latest/advanced_topics/client_caching.html)
- [Client Metadata Caching](https://doc.beegfs.io/latest/advanced_topics/client_meta_caching.html)
- [Client Tuning](https://doc.beegfs.io/latest/advanced_topics/client_tuning.html)

### 高可用、恢复与保护

- [Mirroring](https://doc.beegfs.io/latest/advanced_topics/mirroring.html)
- [Metadata Mirroring](https://doc.beegfs.io/latest/advanced_topics/metadata_mirroring.html)
- [Target States](https://doc.beegfs.io/latest/reference/target_states.html)
- [Resynchronization](https://doc.beegfs.io/latest/trouble_shooting/resynchronization.html)
- [File System Check](https://doc.beegfs.io/latest/advanced_topics/fscheck.html)
- [Backup](https://doc.beegfs.io/latest/advanced_topics/backup.html)
- [Split-brain behavior](https://doc.beegfs.io/latest/trouble_shooting/general.html#what-happens-with-beegfs-in-a-split-brain-scenario)

### 部署、性能与扩展

- [Manual Installation](https://doc.beegfs.io/latest/advanced_topics/manual_installation.html)
- [Metadata Node Tuning](https://doc.beegfs.io/latest/advanced_topics/metadata_tuning.html)
- [Storage Node Tuning](https://doc.beegfs.io/latest/advanced_topics/storage_tuning.html)
- [RDMA Support](https://doc.beegfs.io/latest/advanced_topics/rdma_support.html)
- [Benchmarking](https://doc.beegfs.io/latest/advanced_topics/benchmark.html)
- [Monitoring](https://doc.beegfs.io/latest/advanced_topics/mon.html)
- [Data Migration](https://doc.beegfs.io/latest/advanced_topics/data_migration.html)
- [Remote Storage Targets](https://doc.beegfs.io/latest/advanced_topics/remote_storage_targets.html)

### 安全、权限与商业边界

- [Authentication](https://doc.beegfs.io/latest/advanced_topics/authentication.html)
- [TLS](https://doc.beegfs.io/latest/advanced_topics/tls.html)
- [ACL](https://doc.beegfs.io/latest/advanced_topics/acl.html)
- [Quota](https://doc.beegfs.io/latest/advanced_topics/quota.html)
- [Licensing](https://doc.beegfs.io/latest/advanced_topics/licensing.html)
- [Upgrade Guide](https://doc.beegfs.io/latest/advanced_topics/upgrade.html)

## 4. 关键源码入口

以下链接固定到 8.4.0 tag；文档中的 `path:line` 均可在这里复核。

| 主题 | 源码入口 |
|------|----------|
| EntryID 生成 | [`common/toolkit/StorageTk.h`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/common/source/common/toolkit/StorageTk.h#L212) |
| 元数据目录布局 | [`common/storage/Metadata.h`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/common/source/common/storage/Metadata.h#L6)、[`MetaStorageTk.h`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/common/source/common/toolkit/MetaStorageTk.h#L23) |
| dentry/inode 落盘 | [`meta/storage/DirEntry.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/meta/source/storage/DirEntry.cpp#L16)、[`DirEntryStore.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/meta/source/storage/DirEntryStore.cpp#L52) |
| 新目录 owner 选择 | [`MkDirMsgEx.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/meta/source/net/message/storage/creating/MkDirMsgEx.cpp#L116) |
| 跨目录 rename | [`RenameV2MsgEx.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/meta/source/net/message/storage/moving/RenameV2MsgEx.cpp#L318)、[`MetaStoreRename.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/meta/source/storage/MetaStoreRename.cpp#L328) |
| 元数据镜像框架 | [`MirroredMessage.h`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/meta/source/net/message/MirroredMessage.h#L55) |
| 条带映射 | [`StripePattern.h`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/common/source/common/storage/striping/StripePattern.h#L167) |
| chunk 路径 | [`StorageTk.h`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/common/source/common/toolkit/StorageTk.h#L334)、[`PathInfo.h`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/common/source/common/storage/PathInfo.h) |
| 客户端并行写 | [`FhgfsOpsRemoting.c`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/client_module/source/net/filesystem/FhgfsOpsRemoting.c#L1459) |
| 存储端写与镜像 | [`WriteLocalFileMsgEx.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/storage/source/net/message/session/rw/WriteLocalFileMsgEx.cpp#L56) |
| `fsync` 路径 | [`FhgfsOpsFile.c`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/client_module/source/filesystem/FhgfsOpsFile.c#L1303)、[`FSyncLocalFileMsgEx.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/storage/source/net/message/session/FSyncLocalFileMsgEx.cpp#L15) |
| 动态文件大小 | [`MsgHelperStat.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/meta/source/net/msghelpers/MsgHelperStat.cpp#L19)、[`StatData.cpp`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/common/source/common/storage/StatData.cpp#L19) |
| 客户端默认值 | [`Config.c`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/client_module/source/app/config/Config.c#L267) |
| 锁和 append | [`FhgfsOpsFile.c`](https://github.com/ThinkParQ/beegfs/blob/8.4.0/client_module/source/filesystem/FhgfsOpsFile.c#L693) |
| 管理 DB 可靠性参数 | [`sqlite/connection.rs`](https://github.com/ThinkParQ/beegfs-rust/blob/v8.4.0/sqlite/src/connection.rs#L19) |
| 管理 DB schema | [`mgmtd/db/schema/1.sql`](https://github.com/ThinkParQ/beegfs-rust/blob/v8.4.0/mgmtd/src/db/schema/1.sql#L60) |
| 目标状态判定 | [`mgmtd/bee_msg/common.rs`](https://github.com/ThinkParQ/beegfs-rust/blob/v8.4.0/mgmtd/src/bee_msg/common.rs#L288) |

## 5. 证据强度与限制

| 标记 | 含义 | 可用于什么结论 |
|------|------|----------------|
| 官方保证 | 8.4 官方文档明确陈述 | 功能、支持边界、已知限制、推荐流程 |
| 源码事实 | 固定 tag 的代码/默认配置可直接观察 | 当前请求顺序、数据结构、错误分支、默认值 |
| 工程推断 | 基于架构和实现推演 | 瓶颈、风险排序、适用性；需 PoC 验证 |

本调研没有覆盖闭源企业实现的全部内部细节，也没有获得厂商支持团队的 SLA/故障处置承诺。
许可可用性、企业功能清单和支持矩阵可能随补丁版本或合同变化，采购/上线前必须再次核验。
