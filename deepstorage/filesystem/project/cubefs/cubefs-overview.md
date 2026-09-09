# CubeFS 调研（一）：总体架构

> 基线：cubefs commit `8193603`（2026-08-05）

## 1. 定位

CubeFS 是一个**自研全栈的分布式文件系统**，同时提供 POSIX、HDFS 和 S3 三套接口。
与 JuiceFS "把文件系统做成客户端库"的路线相反，CubeFS 自己实现了元数据服务、数据服务
和集群管控，不依赖任何第三方存储引擎。

它有两套数据后端并存：

- **多副本栈**（DataNode）：低延迟，面向热数据与随机读写
- **纠删码栈**（BlobStore）：低成本，面向冷数据与大对象

这两套是**完全独立的子系统**，共用同一套元数据（MetaNode）和 Master。
BlobStore 本身就是一个完整的纠删码对象存储（有自己的 ClusterMgr、自己的 Raft 集群），
代码量占整个仓库的近一半。

## 2. 组件拓扑

```
        ┌──────────────────────────────────────────────────────┐
        │  接入层：FUSE Client / Java SDK(HDFS) / ObjectNode(S3)│
        └───────┬──────────────────────────┬───────────────────┘
                │ 元数据                    │ 数据
        ┌───────▼────────┐         ┌───────▼─────────────────────┐
        │   MetaNode     │         │  DataNode      │  BlobStore  │
        │  Meta Partition│         │ Data Partition │  (EC 子系统) │
        │  内存 BTree     │         │  Extent Store  │  Blob/Shard │
        │  + Multi-Raft  │         │  + 主副本转发   │  + EC 编码   │
        └───────┬────────┘         └───────┬────────┴──────┬──────┘
                │                          │               │
                └──────────┬───────────────┘               │
                           ▼                               ▼
                 ┌──────────────────┐            ┌──────────────────┐
                 │     Master       │            │   ClusterMgr     │
                 │ 集群/卷/分区管控  │            │ (BlobStore 自己的 │
                 │ Raft 复制         │            │  管控，Raft)      │
                 └──────────────────┘            └──────────────────┘
```

| 组件 | 代码量 | 职责 |
|------|--------|------|
| `master` | ~53k 行 | 集群成员、卷生命周期、Data/Meta Partition 的创建与调度、扩缩容与下线、负载均衡 |
| `metanode` | ~29k 行 | 元数据服务：inode/dentry/xattr/multipart，内存 BTree + Raft |
| `datanode` | ~17k 行 | 多副本数据服务：Extent 存储、复制、修复 |
| `blobstore` | ~176k 行 | 纠删码子系统（ClusterMgr / BlobNode / Access / Scheduler / ShardNode / Proxy） |
| `sdk` | ~28k 行 | 客户端核心：meta wrapper、data stream、缓存 |
| `objectnode` | ~20k 行 | S3 兼容网关 |
| `client` | ~12k 行 | FUSE 挂载与 libsdk |
| `remotecache` | ~12k 行 | FlashNode 分布式读缓存 |
| `lcnode` | ~2.5k 行 | 生命周期管理（冷热迁移、过期删除） |
| `raftstore` | ~1.2k 行 | Raft 封装（底层用 tiglabs/raft） |

## 3. 核心抽象：卷 → 分区

CubeFS 的一切都建立在**两级抽象**上：

```
Volume（卷，用户可见的文件系统实例）
  ├─ Meta Partition × N   ── 按 inode ID 区间切分命名空间
  └─ Data Partition × M   ── 数据容器，默认 120 GiB
       └─ Extent × K      ── 分区内的文件，normal 128MiB / tiny 共享
```

### 3.1 Data Partition

`DefaultDataPartitionSize = 120 * GB`（`util/unit.go:35`）。
一个 DP 就是若干台 DataNode 上各一份的副本组（默认 3 副本），
由 Master 在创建卷时批量预分配、并随容量增长动态补充。

DP 是**放置、复制与修复的单元**。
Master 只维护 O(DP 数) 的状态，不感知单个文件。

### 3.2 Meta Partition

按 **inode ID 区间**切分（`master/meta_partition.go:54` 的 `Start` / `End` 字段），
默认每个 MP 覆盖 `1<<22 = 4,194,304` 个 inode（`master/const.go:215`）。

```go
type MetaPartition struct {
    PartitionID uint64
    Start       uint64   // inode ID 区间下界
    End         uint64   // 上界
    MaxInodeID  uint64
    InodeCount  uint64
    DentryCount uint64
    Replicas    []*MetaReplica
    ...
}
```

**注意这是按 inode ID 分片，不是按 key 范围分片。** 这个选择的后果在
[元数据文档](cubefs-metadata.md) 第 3 节详述——简单说：目录局部性丢失了。

## 4. 存储类型（StorageClass）

较新版本引入了 "hybrid cloud" 分级存储，一个卷内可以混合多种介质：

| StorageClass | 后端 | 用途 |
|--------------|------|------|
| Replica_SSD | DataNode（SSD 盘） | 热数据 |
| Replica_HDD | DataNode（HDD 盘） | 温数据 |
| BlobStore | 纠删码子系统 | 冷数据 |

`Inode.StorageClass` 字段（`metanode/inode.go:96`）记录当前所在层级，
`MigrationStorageClass` / `HasMigrationEk` 记录迁移目标与迁移中的 extent。
迁移由 `lcnode`（生命周期节点）按策略驱动。

这导致 Inode 结构里同时挂着两套 extent 容器：

```go
HybridCloudExtents          *SortedHybridCloudExtents           // 当前数据
HybridCloudExtentsMigration *SortedHybridCloudExtentsMigration  // 迁移中的副本
```

分层是后加的功能，这个"双份 extent 列表 + 一堆 Migration 标志位"的结构
明显是向后兼容妥协的产物，可读性代价不小。

## 5. 数据寻址：ExtentKey

文件内容由一组 `ExtentKey` 描述（`proto/extent_key.go:58`）：

```go
type ExtentKey struct {
    FileOffset   uint64  // 在文件中的偏移
    PartitionId  uint64  // 数据分区 ID
    ExtentId     uint64  // 分区内的 extent ID
    ExtentOffset uint64  // 在 extent 内的偏移（tiny extent > 0，normal 为 0）
    Size         uint32  // 本 inode 实际使用的长度
    CRC          uint32
    SnapInfo     *ExtSnapInfo  // 快照相关
}
```

这是典型的 `(数据容器, 容器内位置, 长度)` 三元组寻址：`PartitionId` 定位数据容器，
`ExtentId + ExtentOffset` 定位容器内位置，`Size` 是长度。
与"卷 ID + 卷内偏移"的扁平寻址相比，CubeFS 多一层 extent 间接（分区内还要定位到具体 extent 文件）；
扁平寻址少一层查找，但要求卷内布局完全由偏移决定。

CubeFS 用 `CRC` 做端到端校验，ExtentKey 中没有防越权构造的 cookie 一类字段。

## 6. 接入方式

| 接入 | 实现 | 说明 |
|------|------|------|
| FUSE | `client/` + `sdk/` | 主用法，基于 bazil.org/fuse |
| libsdk / gosdk | `client/libsdk`, `client/gosdk` | 免 FUSE 直连，供应用嵌入 |
| Java SDK | `java/` | HDFS 兼容 |
| S3 | `objectnode/` | 独立进程的 S3 网关 |
| BlobStore 直接访问 | `blobstore/access` | 绕过文件语义直接存取 blob |

## 7. 与 JuiceFS 的结构性差异

| 维度 | JuiceFS | CubeFS |
|------|---------|--------|
| 元数据 | 外置引擎，持久化在引擎 | 自研 MetaNode，**全内存 BTree** + Raft + 快照 |
| 元数据分片 | 无（单引擎实例） | inode ID 区间分片，Multi-Raft |
| 数据后端 | 对象存储 | 自研 DataNode（副本）+ BlobStore（EC） |
| 覆盖写 | 追加 slice，读时展开 | **写时原地替换** extent 列表 |
| 小文件 | 无打包，一 slice 一对象 | **Tiny Extent 打包** |
| 复制 | 由对象存储负责 | 自己实现：主副本转发 + 等待全部副本 |
| 后台任务 | 客户端抢租约 | Master / DataNode 驱动 |

后三行（覆盖写、小文件、复制）是自研全栈路线必须自己回答的问题，也是后续几篇的重点。

---

下一篇：[元数据服务](cubefs-metadata.md)
