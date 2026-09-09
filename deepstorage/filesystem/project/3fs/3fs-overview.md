# 3FS 系统定位与总体架构

## 1. 设计目标

3FS 的首要目标是让 AI/HPC 集群中的所有客户端共同访问一个高吞吐存储池，并尽可能接近 NVMe 与 RDMA 网络的聚合硬件上限。它解决的核心矛盾不是低成本保存海量冷对象，而是：

- GPU/CPU 训练节点数量多，本地盘容量与数据生命周期不匹配；
- 大规模训练、Checkpoint、模型加载需要高聚合带宽；
- 数据集需要 POSIX 风格路径供既有框架使用；
- 高性能应用又不能承受 FUSE 的复制、锁竞争和系统调用开销；
- 存储节点失效后应在线恢复，客户端不应经中心代理转发数据。

由此形成了几项明确取舍：

- 元数据集中到事务 KV，但 Meta 服务本身无状态；
- 数据采用固定 chunk 和客户端可计算布局；
- 数据面依赖 RDMA，客户端直接访问 Storage；
- 复制采用 chain，优先简化一致性和扩大读带宽；
- FUSE 提供兼容性，USRBIO 提供性能；
- 默认假设单数据中心、受控网络和专门运维团队。

## 2. 组件职责

| 组件 | 持久状态 | 主要职责 | 是否在数据热路径 |
| --- | --- | --- | --- |
| Client/FUSE | 本地缓存、连接和打开文件上下文 | 路径访问、布局解析、chunk 请求、重试 | 是 |
| USRBIO | 注册内存、I/O ring、请求上下文 | 批量异步零拷贝 I/O | 是 |
| Meta | 无本地权威状态 | inode/dentry 事务、open session、GC 调度 | open/stat/namespace 时 |
| FoundationDB | 全部权威元数据 | ACID、冲突检测、lease/config/session/GC queue | 不传文件数据 |
| MgmtD | 权威信息最终落 FDB | 主选举、服务发现、配置、chain/target 状态 | 控制面 |
| Storage | SSD 数据、chunk metadata | RDMA 数据传输、CRAQ、校验、恢复 | 是 |
| Monitor | 非权威指标 | 汇聚服务指标 | 否 |
| ClickHouse | 指标历史 | 查询与保存监控时序数据 | 否 |

一个常见误解是把 ClickHouse 当作元数据数据库。3FS 的权威元数据后端是 FoundationDB；ClickHouse 只在监控链路中承担指标存储。

## 3. 控制面与数据面

### 3.1 控制面

Meta 和 Storage 周期性向 MgmtD 报告心跳。多个 MgmtD 中只有主实例修改 cluster configuration、target state 和 chain table。主 lease、配置和服务信息存入 FDB，使管理面不依赖额外一致性系统。

客户端通过 Meta 获取 inode 和布局，通过 MgmtD/配置得到服务端点与 chain table。chain table 每次变更都应增加 version；Storage 对过期版本请求进行拒绝，客户端刷新路由。这一 version 是防止旧拓扑继续写入的 fencing token。

### 3.2 数据面

客户端拿到文件布局后：

1. 根据文件偏移计算 chunk index；
2. 由 inode ID 和 index 得到 chunk ID；
3. 用 chain table 范围、stripe size 和 shuffle seed 计算 chain；
4. 选择 chain 头执行写，或选择可读副本执行读；
5. Storage 通过 RDMA 与客户端注册缓冲区交换数据；
6. 写在 chain 内复制，读通常不再访问 Meta/FDB。

因此 Meta 扩展主要影响 namespace/open/stat 吞吐，而不会按数据字节数扩展。相反，chain 成员数量、RDMA 拓扑、SSD 带宽和客户端并发决定数据吞吐。

## 4. 元数据与数据布局

每个普通文件 inode 至少保存：

- 文件长度；
- chunk size；
- chain table 起始范围/选择信息；
- stripe size；
- shuffle seed；
- 权限、owner、时间和链接计数等属性。

目录 inode 还可以保存默认布局，新建文件继承目录默认值。文件切成等长 chunk，chunk 在若干 chain 上条带化。生产说明中 stripe size 可较大，例如 200，使连续 chunk 在多个 chain 间批量分布。

客户端可计算布局减少 Meta 热点，但也带来约束：

- 布局算法和 shuffle 行为必须跨版本稳定；
- chain table version 必须严格单调；
- 扩容不能随意改变旧文件映射，需要通过新表或迁移处理；
- 客户端、Storage 和 MgmtD 的版本兼容成为正确性条件。

## 5. 两种客户端路径

### 5.1 FUSE

FUSE 提供路径、权限、目录遍历和常规 POSIX 风格读写。优点是应用改造小；缺点包括用户态/内核态复制、共享队列锁，以及 Linux FUSE 对同文件并发写的限制。

设计文档给出的经验上限是约 400K 次 4 KiB read/s，继续增加并发收益有限。这是 FUSE 路径的设计测量，不应套用到大块 USRBIO。

### 5.2 USRBIO

USRBIO 在 3FS FUSE daemon 中实现，应用先通过挂载点 open 文件，再注册 fd 和 RDMA 内存，使用 I/O ring 批量提交。它不是完全独立、无挂载的对象 SDK。

核心约束：

- 一个 ring 内 I/O request 通常按只读或只写组织；
- 同一个 ring 推荐单 producer、单 consumer；
- 准备请求的接口未必线程安全；
- submit 更像通知，后台可能在 submit 前已观察到已准备项；
- 高并发应使用多个 ring，并考虑 NUMA、CQ 和 RNIC 亲和性；
- fd 生命周期、mount daemon 和注册内存生命周期必须一致。

## 6. 依赖与基础设施假设

### 6.1 FoundationDB

FDB 承担全部命名空间权威状态，也保存管理配置、lease、session 和 GC 工作项。它的优势是成熟 ACID 与无状态 Meta；代价是 3FS 的 namespace 可用性、尾延迟和灾备依赖 FDB。

需要纳入设计的 FDB 约束：

- 默认事务总时长约束为 5 秒；
- 单事务 affected data 最大 10 MB，超过 1 MB 已不建议；
- hot key 或集中的冲突范围不会自动无限扩展；
- 备份/DR 独立于 3FS 数据副本；
- FDB 连接权限本身不是租户级安全边界。

### 6.2 RDMA 网络

3FS 支持 InfiniBand/RoCE 场景，性能依赖：

- RNIC、NUMA、PCIe 和 NVMe 拓扑；
- MTU、队列深度、CQ 调度和 memory registration；
- RoCE 下 PFC/ECN/DCQCN 或其他无损/拥塞控制策略；
- 客户端到存储的双向可达；
- 故障时连接重建和路由刷新。

Fire-Flyer 论文披露其计算、存储与集合通信共用调优网络，并为 HFReduce 与 3FS 做了特定拥塞工程。这种前提是性能结论的重要组成部分。

### 6.3 本地文件系统和 NVMe

部署指南使用 XFS、`noatime,nodiratime`、4 KiB sector 和较高的 `fs.aio-max-nr`。Storage 以 O_DIRECT 和异步 I/O 访问预分配/稀疏数据文件，另用 RocksDB/LevelDB 或新 Rust engine 的 MetaStore 管理 chunk 元数据。

SSD 介质错误、断电保护、固件一致性、XFS 故障和 metadata DB 损坏仍是本地可靠性的一部分，不能由三副本自动消除所有相关失效模式。

## 7. 典型请求流程

### 7.1 创建并写文件

1. Client 向任一 Meta 发起 create。
2. Meta 在 FDB 事务中校验父目录、分配 inode、创建 inode/dentry。
3. Client open 后得到布局。
4. Client 将缓冲区注册/描述给 chain head。
5. head RDMA Read 客户端数据，生成 pending version。
6. 数据沿 chain 传播，tail 提交。
7. ACK 从 tail 反向传递，各成员提交并解锁。
8. Client 周期性或在 close/fsync 上更新文件长度。

### 7.2 读取文件

1. lookup/open 取得 inode 与布局。
2. Client 计算目标 chunk 和 chain。
3. 从适当副本读取 committed 数据。
4. 如目标同时有 pending，默认返回特殊状态让客户端等待/重试。
5. relaxed 模式可以接受 pending，以延迟换一致性。

### 7.3 rename

rename 主要发生在 FDB：

- 读取并锁定相关 dentry/inode 冲突范围；
- 检查目标覆盖、类型和目录循环；
- 在一个 FDB 事务中更新源/目标 dentry；
- 数据 chunk 不随路径移动。

这使 rename 不按文件字节数增长，但深目录祖先检查、巨型事务和热 dentry 会受 FDB 事务边界制约。

## 8. 扩展模型

| 维度 | 扩展方式 | 主要瓶颈 |
| --- | --- | --- |
| Meta QPS | 增加无状态 Meta | FDB 冲突、读写吞吐、hot range |
| 读带宽 | 增加 Storage、chain 副本、客户端并发 | 网络、SSD、pending 重试 |
| 写带宽 | 增加独立 chain/目标 | 每次写穿越所有副本，慢成员拖尾 |
| 容量 | 增加 target/chain table | 三副本成本、旧布局与迁移 |
| 小文件数 | FDB key range 和 inode 分配分散 | 每文件元数据/每 chunk 元数据、GC |
| 故障恢复 | 多 target 并行同步 | 源副本读、网络、SSD 写和线上竞争 |

## 9. 与常见架构的差异

- 对比 CephFS：3FS 不以通用 POSIX、CRUSH/对象层和多介质生态为首要目标，架构更短但覆盖面更窄。
- 对比 BeeGFS：3FS 的元数据依赖全局事务 KV，数据用 chain full replication；不是传统每服务本地元数据/条带目标的同一故障模型。
- 对比 HDFS：3FS 允许随机覆盖并用 chunk COW，支持 FUSE/USRBIO；不是 NameNode + pipeline block 的简单复刻。
- 对比对象存储：3FS 暴露层次命名空间、硬链接/符号链接和文件描述符，但没有对象存储常见的原生版本/生命周期/EC 完整产品面。

## 10. 架构判断

3FS 的架构自洽条件是：工作负载足够大块、读多，网络足够快且可控，副本成本可接受，应用可用 USRBIO，平台团队可承担 FDB/RDMA/多服务运维。任一条件不成立，都应通过 PoC 数据而不是官方峰值决定是否采用。
