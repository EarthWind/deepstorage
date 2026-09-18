# CubeFS 调研（四）：BlobStore 纠删码子系统

> 基线：cubefs commit `8193603`

BlobStore 是 CubeFS 内一个**独立完整的纠删码对象存储**，约 176k 行代码，
占仓库近一半。它有自己的管控（ClusterMgr，独立 Raft 集群）、自己的存储节点（BlobNode）、
自己的接入层（Access）和后台调度（Scheduler）。

文件系统侧通过 `Inode.StorageClass == BlobStore` 把冷数据指向它。

## 1. 组件

| 组件 | 代码量 | 职责 |
|------|--------|------|
| `clustermgr` | ~22k 行 | 集群管控：卷分配、磁盘注册、CodeMode 策略；自己跑 Raft |
| `blobnode` | ~17k 行 | 存储节点：Chunk 管理、Shard 读写、本地 compact、巡检 |
| `access` | ~6.7k 行 | 接入层：EC 编解码、分片下发、读时重建 |
| `scheduler` | ~11k 行 | 后台任务：修复、均衡、磁盘下线、删除、巡检 |
| `shardnode` | ~15k 行 | KV/索引分片服务（较新，用于对象元数据） |
| `proxy` | ~2.7k 行 | 卷分配缓存、删除消息代理 |

## 2. 存储层次

```
Volume（逻辑卷，由 N+M 个 VolumeUnit 组成，跨 AZ/机架分布）
  └─ VolumeUnit（一个 EC 条带位，vuid = vid + index + epoch）
       └─ Chunk（BlobNode 上的一个 append-only 文件，默认 16 GiB）
            └─ Shard（一个 blob 的一个 EC 分片）
```

关键常量：`DefaultChunkSize = 16 GiB`（`blobstore/blobnode/core/config.go:31`）。

### 2.1 Vuid：带 epoch 的分片标识

```go
func EncodeVuid(v VuidPrefix, epoch uint32) Vuid
// VuidPrefix = vid << 8 | index
```
（`blobstore/common/proto/vuid.go:53`）

`vuid = (vid, index, epoch)`：
- `vid` 定位逻辑卷
- `index` 是它在 EC 条带中的第几位
- **`epoch` 是 fencing 版本**——每次这个位被迁移/修复到新磁盘，epoch 递增

旧 epoch 的写入会被拒绝，避免"修复完成后旧节点又写进来"的脑裂。
这是分布式存储中标准的 **epoch fencing** 机制的一个成熟实现。

### 2.2 Shard 支持 inline

```go
type Shard struct {
    Bid    proto.BlobID
    Vuid   proto.Vuid
    Size   uint32
    Offset int64      // chunk 内偏移，写入时对齐
    Crc    uint32
    Flag   bnapi.ShardStatus
    NopData bool      // 数据全零
    Inline  bool      // 数据内联在元数据里
    Buffer  []byte
}
```
（`blobstore/blobnode/core/shard.go:147`）

两个小优化值得注意：

- **`Inline`**：极小的 shard 直接内联进索引记录，不占独立数据区，
  读取时一次 IO 拿到（`blobstore/blobnode/core/shard.go:207`）
- **`NopData`**：全零数据只记标志位，不落盘

任何自定义的记录格式都可以在头部加同样的 `NopData` 标志——稀疏文件和
预分配场景下能省下可观空间，实现成本几乎为零。

## 3. EC 编码策略（CodeMode）

`blobstore/common/codemode/codemode.go:157`：

```go
type Tactic struct {
    N int   // 数据块数
    M int   // 校验块数
    L int   // 局部校验块数（LRC）
    AZCount int
    PutQuorum int   // 写入 quorum
    GetQuorum int
    MinShardSize int  // 每分片最小尺寸，不足补零
}
```

内置策略（`codemode.go:68` 起）：

| 模式 | N+M | AZ 数 | PutQuorum | 空间开销 | 场景 |
|------|-----|-------|-----------|----------|------|
| EC15P12 | 15+12 | 3 | 24 | 1.8x | 三 AZ，容忍整 AZ 故障 |
| EC6P6 | 6+6 | 3 | 11 | 2.0x | 三 AZ 小规模 |
| EC16P20L2 | 16+20+2L | 2 | 34 | 2.375x | 双 AZ |
| **EC12P4** | 12+4 | 1 | 15 | **1.33x** | 单 AZ，成本最优 |
| EC16P4 | 16+4 | 1 | 19 | 1.25x | 单 AZ |
| EC10P4 | 10+4 | 1 | 13 | 1.4x | 单 AZ |

**EC12P4 即 RS(12,4)，1.33x**，是单 AZ 部署下容错与成本之间常见的折中点。

`PutQuorum` 的约束写在注释里：

```
// MUST make sure that ec data is recoverable if one AZ was down
// (N + M) / AZCount + N <= PutQuorum <= M + N
```

这条不等式很有用：它保证了即使一个 AZ 全挂，已确认的写入仍然可恢复。
**任何做多 AZ EC 的系统都应按这条约束推导 quorum 下界**。

`MinShardSize = 2 KiB`：数据不足 `N × 2KiB` 时补零对齐。
所以 EC 模式对小对象有固定的空间浪费下限——EC12P4 下，
一个 1KB 的对象也要占 12×2KiB = 24KiB 的数据分片空间。
**这就是为什么 CubeFS 把小文件放多副本栈的 tiny extent，而不是 EC 栈。**
"小文件打包进副本栈 + 大文件/冷数据走 EC"的分工是通用的合理选择。

## 4. 写路径：quorum，与 DataNode 相反

```go
// writeToBlobnodes write shards to blobnodes.
// return if had quorum successful shards, then wait all shards in background.
```
（`blobstore/access/stream/stream_put.go:205`）

流程：

1. Access 向 ClusterMgr/Proxy 申请一个卷（`stream_alloc.go`）
2. 数据切成 N 个数据分片，EC 编码出 M 个校验分片
3. 并发下发给 N+M 个 BlobNode
4. **达到 `PutQuorum` 个成功就返回客户端成功**，剩下的在后台继续写
5. 返回 `Location` 给调用方

**注意这与 DataNode 多副本栈的 write-all 是相反的选择。** 原因很清楚：

| | DataNode 多副本 | BlobStore EC |
|---|---------------|-------------|
| 分片数 | 3 | 16~36 |
| 等全部的代价 | 3 个里最慢的 | 36 个里最慢的（长尾必然被放大） |
| 补齐手段 | 换 extent 重写 | EC 可重建，后台补齐即可 |
| 选择 | write-all | **quorum + 后台补齐** |

**这是一条重要的设计规律**：副本数少时 write-all 简单且延迟可接受；
分片数多时必须走 quorum，否则尾延迟被 N+M 个节点里最慢的那个绑架。

以 RS(12,4) 为例就是 16 个分片——**如果照搬"等待全部"的副本逻辑，
尾延迟会很难看**。设计 EC 写路径时应明确写入确认策略：
用 quorum 确认（下界按上面的不等式和自身的故障域模型推导），
剩余分片后台补齐，而不是复用副本路径的"等待全部"。

## 5. Location：对象寻址

```go
type Location struct {
    ClusterID ClusterID
    CodeMode  codemode.CodeMode
    Size      uint64
    SliceSize uint32
    Crc       uint32
    Slices    []Slice
}

type Slice struct {
    MinSliceID BlobID   // 起始 blob id
    Vid        Vid      // 卷 id
    Count      uint32   // 连续 blob 个数
    ValidSize  uint64
}
```
（`blobstore/common/proto/blob.pb.go:27,177`）

**`Slice` 用 `(MinSliceID, Count)` 做游程压缩**：一个大对象被切成许多固定大小的 blob，
连续分配在同一个卷上的 blob 只记录起点和数量，不逐个记录 ID。

这是很好的元数据压缩手法：一个 1TB 的对象，按 8MB 一个 blob 是 131072 个 blob，
但如果它们连续落在少数几个卷上，`Slices` 数组只有几条记录。

**设计启示**：文件系统的 extent 索引通常是 `(inode, file_offset) → 位置` 逐条记录的。
如果一次大写入产生的多条记录在同一个数据容器内连续，
可以考虑同样的游程压缩：`(container_id, start_offset, record_count, record_size)`。
对大文件顺序写场景，元数据条数能降一到两个数量级。

## 6. 后台任务：Scheduler

`blobstore/scheduler/` 下每个文件一类任务：

| 文件 | 任务 |
|------|------|
| `disk_repairer.go` | 磁盘故障后的分片重建 |
| `balancer.go` | 卷均衡 |
| `disk_droper.go` | 磁盘下线迁移 |
| `blob_deleter.go` | 删除消息消费（从消息队列） |
| `volume_inspector.go` | 后台巡检，校验分片一致性 |
| `manual_migrater.go` | 手动迁移 |
| `migrate.go` | 迁移任务的公共框架 |

**全部是服务端驱动的，不依赖客户端在线**——与 JuiceFS 形成鲜明对比。

`blob_deleter` 走消息队列消费删除请求，这样删除是异步、可重试、可限流的。
"GC 由删除日志/删除消息订阅驱动"是值得沿用的思路。

### BlobNode 的本地 compact

`blobstore/blobnode/compact.go`：chunk 是 append-only 的 16GiB 文件，
删除只标记，空间由 compact 回收——**这里就没法用打洞了**，
因为 EC 分片的 offset 需要保持有效，且 chunk 内布局要能被巡检重建。

于是 BlobStore 走的是真正的 compact（搬迁存活 shard 到新 chunk），
而 DataNode 的 tiny extent 走打洞。**同一个项目里两种回收策略并存**，
说明这两条路各有适用场景：
- 索引在外部、offset 必须稳定 → 只能 compact
- 索引可容忍空洞、读到零即可 → 可以打洞

凡是寻址结构里直接含卷内 `offset` 的设计，都属于"索引在外部、offset 必须稳定"的形态，
此时**卷内 compaction 无法完全被打洞替代**——打洞只能回收空间，
不能改变存活记录的地址。这一点在 [分析文档](cubefs-analysis.md) §2.2 展开。

---

上一篇：[数据路径](cubefs-data-path.md) ｜ 下一篇：[设计评估](cubefs-analysis.md)
