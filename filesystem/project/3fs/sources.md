# 资料来源、版本基线与研究方法

## 1. 研究范围

本调研回答以下工程问题：

- 3FS 的真实组件边界、元数据模型、数据布局和 I/O 路径是什么；
- CRAQ/Chain Replication 在 3FS 中如何修改，读写一致性如何成立；
- 节点、磁盘、Meta、MgmtD、FDB 和网络异常时如何隔离与恢复；
- FUSE 与 USRBIO 的性能/语义差异，POSIX 兼容边界在哪里；
- 公开性能结果需要哪些前提，哪些结论不能从结果中推出；
- 部署、升级、监控、安全、备份和灾备是否达到生产要求；
- 3FS 有哪些可迁移到其他分布式存储系统设计的经验和反例。

不在范围内：

- 未在相同硬件上复现官方 benchmark；
- 未实施真实 NVMe 断电、RDMA 分区、FDB 跨机房恢复；
- 不对尚未合入主分支的 PR、issue 设想或第三方 fork 作能力承诺；
- 不把 README 宣传数字当作第三方认证的 SLA。

## 2. 固定版本基线

| 项目 | 基线 |
| --- | --- |
| 官方仓库 | [deepseek-ai/3FS](https://github.com/deepseek-ai/3FS) |
| 分支 | `main` |
| 提交 | `22fca04564c7cc230fd8b9523b8b92864e1dad47` |
| 提交时间 | 2026-05-07 17:31:53 +08:00 |
| 提交主题 | `[Fix] Ensure ChainTable's version is monotonically increasing (#413)` |
| Git tag | 调研时 [Tags 页面](https://github.com/deepseek-ai/3FS/tags) 显示无 tag |
| GitHub Release | 调研时 [Releases 页面](https://github.com/deepseek-ai/3FS/releases) 显示无 release |
| License | MIT |

使用 commit SHA 而不是“最新版”是必要的：主分支在 2025—2026 年仍持续修复超时、truncate/extend、分配任务限制和 chain table version 单调性等问题。本文所有源码结论都只对上述基线负责。

## 3. 证据等级

| 等级 | 定义 | 在本文中的用法 |
| --- | --- | --- |
| A | 固定提交下的源码、配置、测试和形式化模型 | 用于说明实际默认值、状态机、调用路径、接口缺失 |
| B | 官方设计文档、部署文档、项目 README | 用于说明设计意图、推荐拓扑和官方性能结果 |
| C | 官方依赖文档或原始论文 | 用于解释 FDB、Chain Replication、CRAQ 的外部语义与限制 |
| D | 基于 A/B/C 的工程推断或计算 | 必须明确标注“推断”“约”“建议验证” |

若设计文档与代码存在差异，以固定提交源码和默认配置为准。例如，设计说明把 FDB 语义称为 SSI，而 FDB 官方文档对默认事务的公开承诺是 strict serializability；本文不把术语差异扩展为对 3FS 每条代码路径的形式证明。

## 4. 一手资料

### 4.1 3FS 官方资料

- [项目 README](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/README.md)：定位、依赖、构建、性能数字、GraySort、KVCache。
- [Design Notes](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/docs/design_notes.md)：组件、元数据、chunk、CRAQ、故障恢复、FUSE、USRBIO。
- [Setup Guide](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/docs/setup-guide.md)：六节点示例、FDB/ClickHouse、RoCE、XFS、data placement。
- [Metrics](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/docs/metrics.md)：监控指标和 ClickHouse 写入路径。
- [Build 说明](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/docs/build.md)：依赖、工具链、构建选项和 shuffle 兼容性。
- [P 形式化规格](https://github.com/deepseek-ai/3FS/tree/22fca04564c7cc230fd8b9523b8b92864e1dad47/spec)：CRAQ 与 RDMA 模型、测试计划及已知 TODO。
- [源码提交历史](https://github.com/deepseek-ai/3FS/commits/main/)：用于判断项目演进与稳定性，不作为版本承诺。

固定提交中重点检查的代码/配置区域：

- `src/meta`：inode/dentry、事务、open session、GC、动态属性；
- `src/storage`：chunk、commit/pending version、目标状态、恢复和存储引擎；
- `src/mgmtd`：lease、primary、chain table、配置管理；
- `src/client`：FUSE callbacks、USRBIO、读写和重试；
- `src/core/user`：用户 token 和权限；
- `deploy` 与 `configs`：默认部署、认证、复制因子、超时；
- `tests`：功能与故障路径覆盖面；
- `spec`：模型验证范围与模型/实现间缺口。

### 4.2 原始论文

- [Fire-Flyer AI-HPC: A Cost-Effective Software-Hardware Co-Design for Deep Learning](https://arxiv.org/abs/2408.14158)，SC24 论文预印本。用于核验 180 存储节点、每节点 16 NVMe、2×200 Gbps 网卡和共网调优背景。该论文描述整个 Fire-Flyer 2，不是独立的 3FS 完整规范。
- [Chain Replication for Supporting High Throughput and Availability](https://www.usenix.org/conference/osdi-04/chain-replication-supporting-high-throughput-and-availability)，OSDI 2004。用于解释传统 head-write/tail-read 模型。
- [Object Storage on CRAQ](https://www.usenix.org/conference/usenix-09/object-storage-craq-high-throughput-chain-replication-read-mostly-workloads)，USENIX ATC 2009。用于解释 committed/pending 版本和任意副本读。

### 4.3 FoundationDB 官方资料

- [Developer Guide](https://apple.github.io/foundationdb/developer-guide.html)：ACID、事务、冲突范围和重试。
- [Consistency](https://apple.github.io/foundationdb/consistency.html)：严格可串行化及读版本语义。
- [Known Limitations](https://apple.github.io/foundationdb/known-limitations.html)：5 秒事务时长、10 MB affected data、key/value 限制和 hot key 约束。
- [Fault Tolerance](https://apple.github.io/foundationdb/fault-tolerance.html)：复制与故障容忍模型。
- [Backups](https://apple.github.io/foundationdb/backups.html)：备份、DR 和恢复边界。

需要特别注意：FDB 官方明确指出，能连接集群的主体原则上可读写所有 key；FDB 集群文件和网络访问不能被当作 3FS 租户隔离机制。

### 4.4 固定提交源码证据锚点

以下链接全部固定到本调研 SHA，便于后续复核而不受 main 分支变化影响。

| 主题 | 源码证据 |
| --- | --- |
| 构建与 shuffle 兼容 | [CMakeLists.txt](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/CMakeLists.txt) |
| Meta/MgmtD 认证默认值 | [meta_main.toml](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/configs/meta_main.toml)、[mgmtd_main.toml](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/configs/mgmtd_main.toml) |
| inode/dentry 编码 | [Inode.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/meta/store/Inode.cc)、[DirEntry.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/meta/store/DirEntry.cc) |
| inode ID 分配 | [InodeIdAllocator.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/meta/components/InodeIdAllocator.cc) |
| rename/session/GC | [Rename.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/meta/store/ops/Rename.cc)、[FileSession.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/meta/store/FileSession.cc)、[GcManager.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/meta/components/GcManager.cc) |
| Target 状态定义 | [MgmtdTypes.h](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/fbs/mgmtd/MgmtdTypes.h) |
| MgmtD lease/心跳 | [MgmtdLeaseExtender.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/mgmtd/background/MgmtdLeaseExtender.cc)、[MgmtdHeartbeatChecker.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/mgmtd/background/MgmtdHeartbeatChecker.cc) |
| Chain 写与可靠转发 | [ReliableUpdate.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/storage/service/ReliableUpdate.cc)、[ReliableForwarding.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/storage/service/ReliableForwarding.cc) |
| 返回目标同步 | [ResyncWorker.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/storage/sync/ResyncWorker.cc) |
| 传统/新 chunk engine | [ChunkEngine.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/storage/store/ChunkEngine.cc)、[Rust engine README](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/storage/chunk_engine/README.md) |
| FUSE callbacks | [FuseOps.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/fuse/FuseOps.cc) |
| USRBIO 接口与 ring | [hf3fs_usrbio.h](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/lib/api/hf3fs_usrbio.h)、[IoRing.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/fuse/IoRing.cc) |
| 用户 token 编码 | [UserToken.cc](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/src/core/user/UserToken.cc) |
| CR/EC placement 参数 | [data_placement.py](https://github.com/deepseek-ai/3FS/blob/22fca04564c7cc230fd8b9523b8b92864e1dad47/deploy/data_placement/src/model/data_placement.py) |

## 5. 研究方法

1. 固定官方仓库 SHA，记录提交时间、release/tag 状态。
2. 从组件入口、配置默认值、数据结构和状态枚举建立架构图。
3. 将 design notes 的叙述与具体读写、恢复、会话和 GC 代码交叉核验。
4. 用 FDB 官方约束检查元数据方案是否存在事务时长、大小、热点和备份边界。
5. 用 Chain Replication/CRAQ 原始论文区分标准算法与 3FS 改造。
6. 把官方性能数字归一化为节点/盘平均值，并列出缺失变量。
7. 对部署、安全、升级、灾备做“生产就绪清单”，没有证据的能力不作肯定。
8. 将结论提炼为可迁移到其他分布式存储系统设计的通用启示与反例。

## 6. 关键定义

| 术语 | 本文定义 |
| --- | --- |
| chunk | 文件按固定 chunk size 切分后的数据单元，chunk ID 由 inode 与 chunk index 导出 |
| target | Storage 服务管理的逻辑存储目标；同一 SSD 可以划分多个 target |
| chain | 保存一个 chunk 完整副本的一组有序 target |
| chain table | chain 集合及其版本；文件布局引用 chain table 范围 |
| committed version | 已完成尾端提交、可提供强一致读的 chunk 版本 |
| pending version | 正在 chain 上传播、尚未完成全链提交的版本 |
| relaxed read | 允许读取 pending 数据的低延迟模式，语义弱于默认读 |
| USRBIO | 基于已挂载 FUSE 文件描述符的用户态异步、批量、注册内存 I/O 路径 |
| Meta | 无状态元数据服务，代表客户端执行 FDB 事务 |
| MgmtD | 集群管理服务，主实例维护服务注册、配置、target 状态和 chain table |

## 7. 局限性与稳健性

- **未复现性能。** 归一化计算只验证数量级，不证明任意硬件可达到同样结果。
- **主分支持续变化。** 无 tag/release 意味着本文以后可能很快过时；部署前必须重新固定 SHA。
- **代码检查不是形式证明。** 没找到 EC、TLS、quota、snapshot 的完整实现，只能证明在检查范围内无明确公开实现，不能证明任何分支或私有版本都没有。
- **P 模型覆盖有限。** 模型能提升对 CRAQ/RDMA 状态机的信心，但 TODO 包括 leader election/target movement，且模型与 C++/Rust 实现不是自动等价。
- **配置组合多。** checksum、fsync length、引擎新旧、认证和超时均可配置，生产语义必须以实际配置和故障注入为准。
- **依赖系统独立演进。** FDB、内核 FUSE、RDMA 驱动、libfuse、RocksDB/LevelDB 的版本会改变行为。

## 8. 如何引用本文

引用结论时应同时附带：

- commit SHA；
- 文档路径或源码路径；
- 是否为默认配置；
- 是否经过本地硬件复现；
- 对应证据等级。

建议写法：“在 `22fca045` 默认部署配置和公开源码中，数据保护路径为 chain full replication，未验证 EC 数据编码/重建能力”，而不要写成没有版本边界的“3FS 永远不支持 EC”。
