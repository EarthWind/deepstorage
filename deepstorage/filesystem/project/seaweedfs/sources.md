# SeaweedFS 调研基线、资料来源与方法

## 1. 研究范围

本调研从专业分布式存储工程视角回答以下问题：

- SeaweedFS 的 Master、Volume Server、Filer、Filer Store、S3 Gateway 和 mount 如何分工；
- volume、needle、collection、chunk、manifest、replication placement 和 EC shard 如何落盘与寻址；
- 控制面、数据副本和文件元数据分别具有什么一致性、持久性和故障边界；
- 复制、EC、Vacuum、Tiering、备份、跨集群同步如何工作，RPO/RTO 由什么决定；
- S3 与 POSIX 支持到了什么程度，哪些“兼容/原子/强一致”表述必须加条件；
- 性能宣称能否外推，容量、内存、后台 I/O 与恢复窗口如何估算；
- 安全默认值、内部信任模型、认证、加密、遥测和升级策略是否满足生产要求。

不在本次范围内：

- 对某一硬件集群运行完整容量/性能 benchmark；
- 对每一种 Filer Store 驱动逐一做数据库故障注入；
- 对所有 AWS S3 API 和错误码运行官方 conformance suite；
- 对 Enterprise 私有功能做实现审计；
- 用当前环境完成 SeaweedFS 全量编译和集成测试。

## 2. 固定版本

| 项目 | 固定值 | 说明 |
| --- | --- | --- |
| 调研日期 | 2026-08-08 | 结论只对该时间点的公开信息负责 |
| 正式 Release | `4.41` | GitHub 标记为 Latest，非 draft/prerelease |
| Release 时间 | 2026-08-06 07:52 UTC | GitHub Release 页面 |
| Release/tag commit | `de34a1a87c02893507f961cda9574172ee5064e9` | 本文源码事实的主基线 |
| 调研时 master HEAD | `af7cf6ab8a9c3533788f20676714c8cb30480bcc` | 仅用于识别 tag 后变化，不作为生产基线 |
| Wiki commit | `4e9c7cd62efcaedd79a9f89678e87b0eff0a32f7` | 2026-08-04 |
| License | Apache License 2.0 | 以仓库 `LICENSE` 为准 |

GitHub 搜索摘要曾把 `4.29` 显示为最新版本，但 GitHub Release API、tag 远端和 Release 页面均确认 `4.41`。本文没有使用滞后的搜索摘要作为版本基线。

## 3. 证据等级

本文采用以下优先级：

1. **L1：固定 tag 源码、测试和 protobuf。** 用于判断调用顺序、默认值、错误路径、是否 fsync、是否回滚、持久化字段等实现事实。
2. **L2：同版本官方 Release notes 与安全策略。** 用于确认当前发布状态、已知修复方向、支持窗口和官方威胁模型。
3. **L3：官方 Wiki/README。** 用于理解设计意图、操作方法、能力矩阵和官方 benchmark；发现与源码冲突时以 L1 为准。
4. **L4：本文工程推断。** 从实现顺序、故障模型和容量公式推出的风险或建议，明确使用“推断”“意味着”“不能推出”等表述。

特别处理：

- Wiki 的 `Replication.md` 包含 `_investigate...`、`_check...` 等编辑占位符，说明该页部分文字仍是草稿；不作为精确保证。
- Wiki 的 “Supported APIs vs MinIO” 自述由 AI 扫描源码生成并定位为 todo list；仅用于发现检查项，不作为独立强证据。
- README 的“O(1)”“40 bytes overhead”“billions of files”等是项目目标/宣称；本文结合数据布局解释成立条件，不把它们变成无条件 SLA。
- 4.41 Release notes 中大量正确性修复可证明项目在积极演进，但也提示 versioning、EC、复制、元数据日志等复杂路径的回归风险。

## 4. 主要官方资料

### 4.1 项目与发布

- [SeaweedFS 官方仓库](https://github.com/seaweedfs/seaweedfs)
- [4.41 Release](https://github.com/seaweedfs/seaweedfs/releases/tag/4.41)
- [4.41 固定源码树](https://github.com/seaweedfs/seaweedfs/tree/4.41)
- [Apache-2.0 License](https://github.com/seaweedfs/seaweedfs/blob/4.41/LICENSE)
- [Security Policy](https://github.com/seaweedfs/seaweedfs/security/policy)

### 4.2 架构与生产部署

- [Architecture](https://github.com/seaweedfs/seaweedfs/wiki/Architecture)
- [Production Setup](https://github.com/seaweedfs/seaweedfs/wiki/Production-Setup)
- [Failover Master Server](https://github.com/seaweedfs/seaweedfs/wiki/Failover-Master-Server)
- [Replication](https://github.com/seaweedfs/seaweedfs/wiki/Replication)
- [Volume Management](https://github.com/seaweedfs/seaweedfs/wiki/Volume-Management)
- [Optimization](https://github.com/seaweedfs/seaweedfs/wiki/Optimization)
- [System Metrics](https://github.com/seaweedfs/seaweedfs/wiki/System-Metrics)

### 4.3 Filer 与元数据

- [Filer Stores](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Stores)
- [Filer Store Replication](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Store-Replication)
- [Filer Operation Serialization](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Operation-Serialization)
- [Filer Active-Active Cross-Cluster Sync](https://github.com/seaweedfs/seaweedfs/wiki/Filer-Active-Active-cross-cluster-continuous-synchronization)
- [Data Backup](https://github.com/seaweedfs/seaweedfs/wiki/Data-Backup)

### 4.4 纠删码、回收与分层

- [Erasure Coding for warm storage](https://github.com/seaweedfs/seaweedfs/wiki/Erasure-Coding-for-warm-storage)
- [EC Bitrot Detection](https://github.com/seaweedfs/seaweedfs/wiki/EC-Bitrot-Detection)
- [Cloud Tier](https://github.com/seaweedfs/seaweedfs/wiki/Cloud-Tier)
- [Tiered Storage](https://github.com/seaweedfs/seaweedfs/wiki/Tiered-Storage)

### 4.5 S3、POSIX 与安全

- [Amazon S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [S3 Object Versioning](https://github.com/seaweedfs/seaweedfs/wiki/S3-Object-Versioning)
- [S3 Object Lock and Retention](https://github.com/seaweedfs/seaweedfs/wiki/S3-Object-Lock-and-Retention)
- [S3 Conditional Operations](https://github.com/seaweedfs/seaweedfs/wiki/S3-Conditional-Operations)
- [S3 Bucket Policies](https://github.com/seaweedfs/seaweedfs/wiki/S3-Bucket-Policies)
- [Server-Side Encryption](https://github.com/seaweedfs/seaweedfs/wiki/Server-Side-Encryption)
- [POSIX Compliance](https://github.com/seaweedfs/seaweedfs/wiki/POSIX-Compliance)
- [Distributed POSIX Locks](https://github.com/seaweedfs/seaweedfs/wiki/Distributed-POSIX-Locks)
- [Security Overview](https://github.com/seaweedfs/seaweedfs/wiki/Security-Overview)
- [Security Configuration](https://github.com/seaweedfs/seaweedfs/wiki/Security-Configuration)

## 5. 关键源码锚点

以下链接都固定到 tag `4.41`，避免主分支持续变化：

### Master 与拓扑

- [Master 启动参数](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/command/master.go)
- [MasterServer 初始化与 telemetry](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/server/master_server.go)
- [Topology、NextVolumeId 与心跳软状态](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/topology/topology.go)
- [Raft MaxVolumeId/TopologyId command](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/topology/cluster_commands.go)
- [VolumeLayout 可写性与副本数检查](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/topology/volume_layout.go)

### Volume、needle 与复制

- [Needle 结构](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/storage/needle/needle.go)
- [Needle append](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/storage/needle/needle_write.go)
- [Volume 写入与 fsync group commit](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/storage/volume_write.go)
- [复制写/删除与副本查找](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/topology/store_replicate.go)
- [Volume HTTP 写处理](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/server/volume_server_handlers_write.go)
- [Vacuum 协调](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/topology/topology_vacuum.go)
- [Volume Vacuum 实现](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/storage/volume_vacuum.go)

### Filer

- [Filer Store 接口](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/filer/filerstore.go)
- [Filer Create/Update Entry](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/filer/filer.go)
- [Filer gRPC Create/Update/ObjectTransaction](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/server/filer_grpc_server.go)
- [Filer rename 与 Store transaction](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/server/filer_grpc_server_rename.go)
- [HTTP auto-chunk 与 metadata commit](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/server/filer_server_handlers_write_autochunk.go)
- [并发 chunk 上传与失败清理](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/server/filer_server_handlers_write_upload.go)
- [SQL Store transaction](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/filer/abstract_sql/abstract_sql_store.go)
- [LevelDB Store no-op transaction](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/filer/leveldb/leveldb_store.go)

### EC、跨集群与安全

- [EC storage](https://github.com/seaweedfs/seaweedfs/tree/4.41/weed/storage/erasure_coding)
- [Filer sync](https://github.com/seaweedfs/seaweedfs/blob/4.41/weed/command/filer_sync.go)
- [Replication sink](https://github.com/seaweedfs/seaweedfs/tree/4.41/weed/replication)
- [Security 示例配置](https://github.com/seaweedfs/seaweedfs/blob/4.41/docker/security.toml.example)
- [Telemetry client/collector](https://github.com/seaweedfs/seaweedfs/tree/4.41/weed/telemetry)
- [Telemetry protobuf 字段](https://github.com/seaweedfs/seaweedfs/blob/4.41/telemetry/proto/telemetry.proto)
- [Rust Volume Server README](https://github.com/seaweedfs/seaweedfs/blob/4.41/seaweed-volume/README.md)
- [Rust Volume Server missing features audit](https://github.com/seaweedfs/seaweedfs/blob/4.41/seaweed-volume/MISSING_FEATURES.md)

## 6. 研究方法

1. 通过 GitHub Release API、远端 tag 和 Release 页面交叉确认 `4.41` 是调研时最新正式版本。
2. 浅克隆固定 tag 到临时目录，对默认参数、写入顺序、错误路径、事务、Raft command、Vacuum 和 telemetry 做源码检索。
3. 克隆官方 Wiki 并固定提交，提取设计、部署、兼容矩阵与 benchmark。
4. 对高风险声明做“文档—源码—测试文件”三角核验，例如：
   - Wiki 的 `W=N` 与 `ReplicatedWrite` 实现；
   - `fsync=true` 是否传播到复制请求；
   - `ObjectTransaction` 是否调用 Store transaction；
   - LevelDB 的 transaction 是否真实实现；
   - Master Raft 到底持久哪些 command；
   - EC `.ecsum` 的默认值与 rebuild fail-close；
   - telemetry 是否默认开启、上报哪些字段。
5. 用故障时序推导可见性、残留、RPO/RTO 和后台修复条件。
6. 把容量/性能结论写成公式或条件，不直接外推官方单机/小集群数据。

## 7. 已发现的文档—实现差异

| 主题 | 文档表述 | 4.41 源码事实 | 本文处理 |
| --- | --- | --- | --- |
| 复制失败清理 | Wiki 称部分已写副本“would be deleted” | `ReplicatedWrite` 返回错误但未发起跨副本 delete/rollback | 按源码认定可能留下残留 needle |
| `fsync` | 常被理解为“写入持久化” | 入口读取 query，复制 URL 不携带 `fsync`；删除路径固定 false | 只承认入口本地 group commit |
| ObjectTransaction 原子性 | Wiki 使用“atomically” | handler 只持本地路径锁并顺序 mutation，没有 Begin/Commit/Rollback | 称“相对同对象写者串行”，不称通用 ACID |
| Filer 无状态 | Wiki 在共享 Store 场景成立 | 嵌入式多 Filer 依赖日志复制且最终一致 | 按 Store 部署模式分别评估 |
| Rust Volume parity | README 宣称 drop-in/full RPC | 同 tag `MISSING_FEATURES.md` 仍列部分 deferred/TODO | 视为快速发展实现，生产优先 Go 路径 |
| S3 full support | 支持表覆盖很广 | 同页列出 No、Stub、静态响应和行为差异 | 以应用回归为准，不写“完全兼容” |

## 8. 验证限制

尝试在固定源码上运行目标 Go 单元测试时，当前沙箱需要下载大量 Go modules，但网络代理连接被环境阻止，因此没有完成编译执行。这个限制不影响对已检出的固定源码、已有测试文件和官方文档进行静态交叉审计，但意味着：

- 本文没有声称在本机重现了 4.41 的测试通过状态；
- 官方 pjdfstest/EC benchmark 数字被标注为官方证据，不是本次独立复测；
- 所有性能、RPO、恢复时间和 S3 行为都必须在采用方 PoC 中再次验证；
- 对源码得出的关键风险应通过进程 kill、主机断电、网络故障和磁盘错误注入确认。

## 9. 术语

| 术语 | 本文含义 |
| --- | --- |
| Volume | append-only needle 容器及其索引，默认上限约 30 GB；复制、迁移、Vacuum、EC 的主要单位 |
| Needle | 存入 volume 的单个 Blob 记录，含 cookie、id、size、data/metadata、CRC、时间戳和 padding |
| FID | `volume id + needle id + cookie` 的外部文件标识 |
| Collection | 一组专用 volume 的逻辑分组；S3 bucket 通常映射为 collection |
| Filer | 路径/目录/属性/chunk 列表服务，不直接取代 Volume Server |
| Filer Store | Filer 元数据的持久后端，其数据库语义决定 namespace 的 HA/事务边界 |
| Hot replication | 正常 volume 的完整副本，同步扇出写 |
| EC volume | 封存 volume 经 RS 编码得到的 shard 集合；OSS 默认为 10 data + 4 parity |
| Vacuum | 把仍然 live 的 needle 复制到新 volume 文件并原子/分阶段切换，回收 tombstone/旧版本空间 |
| Cloud Tier | 保留本地索引，把只读 volume `.dat` 移到对象存储并用 range read 访问 |
| 强一致 | 本文只在明确的对象、路径和故障模型范围内使用，不把多个子系统的局部属性合并成全局承诺 |
