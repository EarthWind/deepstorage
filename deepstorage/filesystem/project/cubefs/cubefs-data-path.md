# CubeFS 调研（三）：数据路径（多副本栈）

> 基线：cubefs commit `8193603`

本篇讲 DataNode 多副本栈。纠删码栈（BlobStore）见 [下一篇](cubefs-blobstore.md)。

## 1. 存储层次

```
Data Partition（默认 120 GiB，3 副本，= LightStore 的 Volume）
  └─ Extent（分区内的一个本地文件）
       ├─ Normal Extent：ID ≥ 1024，最大 128 MiB，一个 extent 属于一个文件
       └─ Tiny Extent：ID 1~64，每个 DP 固定 64 个，多个小文件共享追加
```

关键常量（`util/unit.go:35,40`、`datanode/storage/extent_store.go:52`）：

```go
DefaultDataPartitionSize = 120 * GB
BlockCount        = 1024
BlockSize         = 65536 * 2       // 128 KiB，CRC 校验粒度
ExtentSize        = BlockCount * BlockSize    // 128 MiB
TinyExtentCount   = 64
TinyExtentStartID = 1
MinExtentID       = 1024
```

Extent 在本地就是一个普通文件，文件名即 extent ID。CRC 按 128KiB 分块维护
（`datanode/storage/persistence_crc.go`），支持块级校验与修复。

## 2. Tiny Extent：小文件打包

这是 CubeFS 与 LightStore 的 Haystack 打包最直接对应的机制。

每个 DP 启动时预创建 64 个 tiny extent（`datanode/storage/extent_store.go:1181`）：

```go
for extentID = TinyExtentStartID; extentID < TinyExtentStartID+TinyExtentCount; extentID++ {
    err = s.Create(extentID)
    ...
    s.brokenTinyExtentC <- extentID     // 初始都放进"待校验"队列
}
```

分配走两个 channel：`availableTinyExtentC`（可用）和 `brokenTinyExtentC`（需修复校验）。
写入时 `GetAvailableTinyExtent()` 取一个，写完归还。**同一时刻一个 tiny extent 只被一个写者独占**，
这样避免了并发追加的偏移竞争。

小文件写入后，`ExtentKey.ExtentOffset` 记录它在这个共享文件里的位置——
这正是 Haystack 的思路：多个逻辑对象打包进一个物理文件，用偏移寻址。

一个实现细节：**normal extent 的 ID 由客户端（sender）分配，tiny extent 的 ID 由 DataNode（receiver）分配**
（`sdk/data/stream/extent_handler.go:136` 的注释）。因为 tiny extent 是共享资源，
必须由持有者决定分配给谁。

### 2.1 小文件删除：打洞，而不是 compaction

这是本次调研**最值得 LightStore 借鉴的一个点**。

删除一个 tiny extent 里的小文件，CubeFS 不做卷内 compaction，而是直接打洞
（`datanode/storage/extent.go:787`）：

```go
err = fallocate(int(e.file.Fd()), util.FallocFLPunchHole|util.FallocFLKeepSize, offset, size)
```

`FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE` 让本地文件系统（XFS/ext4）
释放该区间对应的物理块，文件逻辑长度不变，读到洞返回全零。

**碎片治理被完全下推给了本地文件系统。** 不需要实现卷内搬迁、不需要更新任何索引、
不需要跨副本协调——因为三个副本各自打洞，结果一致。

`MarkDelete`（`datanode/storage/extent_store.go:873`）的完整策略：

```go
if IsTinyExtent(extentID) {
    return s.punchDelete(extentID, offset, size)     // tiny：永远打洞
}
// normal extent：
if funcNeedPunchDel() {          // 部分删除（offset≠0 或 size≠全长）
    return s.punchDelete(...)     // 也打洞
}
os.Remove(extentFilePath)         // 整个 extent 删光 → 直接删文件
```

三条路径都不涉及数据搬迁。

**对 LightStore 的意义**：设计文档里 Volume 的回收路径是
`SEALED → COMPACTING → DROPPED`，即卷内 compaction 搬迁存活 record。
如果 record 落在本地文件上，打洞可以让"卷内死数据回收"这件事的绝大部分场景
不需要真正的 compaction——只有当整卷存活率极低、想回收整个卷时才需要搬迁。
这能省掉大量 IO 和一整套搬迁-换址-更新索引的复杂逻辑。

需要注意的限制（见 [分析文档](cubefs-analysis.md) §2.2）：
打洞粒度是文件系统块（通常 4 KiB），小于一个块的删除回收不了；
且长期打洞会让文件在物理上高度碎片化，顺序读性能下降。

## 3. 复制协议：客户端驱动 + 主副本转发 + 等待全部

CubeFS 的多副本写**不用 Raft**（Raft 只用于 MetaNode 和部分特殊场景），
而是一套自己的复制协议（`datanode/repl/repl_protocol.go:34` 的注释描述了全流程）：

```
1. 客户端把 packet 发给第一个副本，packet 头里带着其余副本的地址
2. 该副本解析出 follower 地址列表
3. sendRequestToAllFollowers：转发给所有 follower（并发）
4. 本地执行写入
5. checkLocalResultAndReciveAllFollowerResponse：等待所有 follower 的响应
6. 全部成功才回客户端成功
```

关键在第 5 步（`datanode/repl/repl_protocol.go:389`）：

```go
// NOTE: wait for all followers
for index := 0; index < len(response.followersAddrs); index++ {
    ...
}
```

**这是 write-all，不是 quorum。** 任何一个副本失败，整个写就失败。

### 3.1 为什么敢这么做

因为写失败的代价很低：客户端直接换一个 extent（甚至换一个 DP）重写，
不需要修复、不需要等待。这就是 append-only 存储模型的红利。

对比 Raft：Raft 的 quorum 写允许少数派落后，但要维护日志、要处理落后副本追赶、
要选主。CubeFS 认为对于**追加写的大块数据**，write-all + 失败换址
比 Raft 更简单也更快（少了一轮日志复制和状态机 apply）。

代价是**可用性对副本故障敏感**：一个副本慢，所有写都慢；一个副本挂，
该 DP 立即不可写（要等 Master 把它标记为只读并补充新 DP）。

### 3.2 与 LightStore 的对照

LightStore 的设计是"主副本定序，链式复制"+"故障处理即 seal-and-new"。
这与 CubeFS 是**同一个思路**：

| | CubeFS | LightStore |
|---|--------|-----------|
| 拓扑 | 星型（主 → 所有从并发） | 链式（主 → 从 → 从） |
| 确认 | 等待全部 | 等待全部（密封长度对齐） |
| 失败 | 换 extent/DP 重写 | seal-and-new |

星型 vs 链式的取舍：星型延迟低（一跳），但主副本出口带宽是 N 倍写入量；
链式带宽均衡，但延迟是 N 跳累加。LightStore 选链式，对大块顺序写是合理的
（带宽比延迟重要）；但对小文件写入，链式的延迟劣势会放大。
**建议：小文件（tiny record）走星型，大块走链式**，CubeFS 的单一星型选择
说明它主要优化的是延迟。

## 4. 客户端写路径

```
FUSE Write
   │
   ▼
Streamer（每个 inode 一个）
   │  按 extent 边界切分
   ▼
ExtentHandler（每个 extent 一个，状态机）
   │  Open → Closed → Recovery → Error（只能单向前进）
   ▼
packet 发往 DP 的第一个副本
   │
   ▼
写完/关闭时 → MetaNode.AppendExtentKey 提交 ExtentKey
```

`ExtentHandler`（`sdk/data/stream/extent_handler.go:114`）是核心：

```go
type ExtentHandler struct {
    stream     *Streamer
    fileOffset int
    storeMode  int          // NormalExtentType / TinyExtentType
    status     int32        // Open/Closed/Recovery/Error，只能单向转移
    packet     *Packet
    inflight   int32        // 在途 packet 数
    extID      int
    dp         *wrapper.DataPartition
    key        *proto.ExtentKey
    recoverHandler *ExtentHandler   // 失败时的接管者
}
```

### 4.1 失败恢复：seal-and-new

`recoverPacket`（`sdk/data/stream/extent_handler.go:694`）——这段很值得细看：

```go
packet.errCount++
if packet.errCount >= MaxPacketErrorCount { return error }

handler := eh.recoverHandler
if handler == nil {
    // Always use normal extent store mode for recovery.
    // Because tiny extent files are limited, tiny store
    // failures might due to lack of tiny extent file.
    extentType := proto.NormalExtentType
    if eh.meetLimitedIoError || enableRetryTiny { extentType = eh.storeMode }
    handler = NewExtentHandler(eh.stream, int(packet.KernelOffset), extentType, ...)
    handler.setClosed()
}
handler.pushToRequest(packet)    // 把失败的 packet 重放到新 handler
```

**失败后不重试原地址，而是新建一个 handler（新 extent，可能是新 DP），把 packet 重放过去。**
这正是 seal-and-new。

注释里那条规则也很实用：**恢复时默认降级到 normal extent**，
因为 tiny extent 数量有限（64 个），写 tiny 失败很可能就是因为没有可用的 tiny extent 了，
在同类资源上重试只会再失败一次。

LightStore 的 SDK 在选卷重试时应该有等价规则：**失败重试要换资源类别，不只是换实例。**

### 4.2 提交时机

ExtentKey 在 handler 关闭（写满 128MiB / flush / close）时提交给 MetaNode。
在此之前数据已经在 DataNode 上，但元数据不可见——与 LightStore 的
"攒批 64 MiB 或 Sync/Close 时 CommitExtents" 是同一模式。

## 5. 读路径

```
Streamer.read
  → ExtentCache 查 ExtentKey（客户端缓存的 extent 列表）
  → 按 ExtentKey 拆分成对 DP 的读请求
  → ExtentReader 发往某个副本
```

读可以走 follower（`isFollowerRead`，`metanode/partition.go:528` 是元数据侧的对应开关，
数据侧由卷的 `FollowerRead` 属性控制）。因为 write-all 保证了所有副本内容一致，
follower read 是安全的——**这是 write-all 相对 quorum 的一个实在好处**：
不需要 lease 或 read-index 就能安全地从任意副本读。

`sdk/data/stream/stream_aheadread.go`（784 行）实现预读。

## 6. 修复（Repair）

`datanode/data_partition_repair.go`（1023 行）。基本流程：

1. Leader 收集所有副本的 extent 列表与各自的 size
2. 对比得出 `ExtentsToBeCreated`（缺失的）与 `ExtentsToBeRepaired`（长度不足的）
3. 从数据最全的副本拉取缺失部分

因为 extent 是 append-only 的，**修复退化成"对齐长度"**：
谁短了就从长的那边补上差额。不需要比对内容、不需要版本向量。

Tiny extent 的修复要额外处理打洞造成的空洞——所以有独立的
`tinyDeleteRecordFile` 记录删除操作，修复时重放这些删除。
这是打洞方案的一个隐藏成本：**空洞本身成了需要复制的状态**。

LightStore 若采用打洞，同样需要一份"删除记录"随卷复制，否则新副本会把
已删数据当成有效数据补回来。

## 7. Master 的角色

Master 不在 IO 路径上，负责：

- 卷、DP、MP 的创建与生命周期
- 节点心跳、容量与负载统计
- DP/MP 的扩容、下线（decommission）、均衡（`master/cluster_balance.go`）
- 客户端路由表分发

`master/data_partition.go:34` 的 `DataPartition` 结构里有个值得警惕的字段：

```go
FileInCoreMap           map[string]*FileInCore
FilesWithMissingReplica map[string]int64
```

Master 会缓存 DP 内**每个 extent 文件**的副本状态用于一致性检查。
一个 120GiB 的 DP 可能有上千个 normal extent，乘以集群里的 DP 数量，
这是 Master 内存里一份 O(extent 数) 的状态——**违背了"中心组件状态与文件数解耦"的原则**。

LightStore 的设计原则第 1 条明确禁止了这一点（Manager 只保存 O(集群规模) 状态）。
CubeFS 这里是个反例，值得引以为戒。

---

上一篇：[元数据服务](cubefs-metadata.md) ｜ 下一篇：[BlobStore 纠删码子系统](cubefs-blobstore.md)
