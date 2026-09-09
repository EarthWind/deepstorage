# CubeFS 调研（二）：元数据服务

> 基线：cubefs commit `8193603`

## 1. MetaNode 的基本形态

一个 MetaNode 进程承载多个 Meta Partition（MP），每个 MP 是一个独立的 Raft 组
（默认 3 副本），构成 Multi-Raft。

```go
type metaPartition struct {
    config        *MetaPartitionConfig
    applyID       uint64          // 已 apply 的 raft index
    dentryTree    *BTree          // 内存 BTree
    inodeTree     *BTree
    extendTree    *BTree          // xattr
    multipartTree *BTree          // S3 分段上传
    txProcessor   *TransactionProcessor
    raftPartition raftstore.Partition
    freeList      *freeList       // 待删 inode
    extDelCh      chan []proto.ExtentKey  // 待删 extent
    ...
}
```
（`metanode/partition.go:484`）

**四棵树全部在内存里**（`metanode/btree.go:31`，包装 google/btree），
持久化靠两条腿：

1. **Raft WAL**：每次变更先写 raft 日志
2. **周期性全量快照**：`intervalToPersistData = 5 分钟`（`metanode/const.go:261`），
   把四棵树各自 dump 成一个文件（`inode` / `dentry` / `extend` / `multipart`）
   加一个 `apply` 文件记录 applyID（`metanode/partition_store.go:38`）

重启时先 load 最近快照，再从 applyID 之后重放 raft 日志。

### 这个设计的代价

**元数据容量 = MetaNode 内存容量。** 这是 CubeFS 最硬的规模约束。
默认每个 MP 覆盖 `1<<22 ≈ 419 万` 个 inode（`master/const.go:215`），
按每 inode 百字节量级估算，单 MP 内存占用在数百 MB 级。要支撑万亿文件
需要数十万个 MP，而每个 MP 是一个独立 Raft 组——Raft 组数量会先爆掉。

对于万亿级文件的目标，这条路走不通。要突破这个约束，元数据服务需要
"单分片体积有界 + 数据落盘（LSM 类引擎、增量刷盘）"而非全内存——
这是 CubeFS 这个设计反向给出的启示。

## 2. 核心数据结构

### 2.1 Inode

```go
type Inode struct {
    sync.RWMutex
    Inode, Size, Generation uint64
    CreateTime, AccessTime, ModifyTime int64
    Reserved, LeaseExpireTime uint64
    Type, Uid, Gid, NLink uint32
    Flag int32
    StorageClass, ClientID uint32
    LinkTarget []byte
    multiSnap                   *InodeMultiSnap
    HybridCloudExtents          *SortedHybridCloudExtents
    HybridCloudExtentsMigration *SortedHybridCloudExtentsMigration
}
```
（`metanode/inode.go:78`）

注意字段是**按宽度分组排列**的（8 字节、4 字节、指针），这是为了减少 Go 结构体
内存对齐带来的 padding 浪费。在"所有 inode 常驻内存"的前提下，这个优化是必需的。

`LeaseExpireTime` / `ClientID` 是较新加入的**文件租约**机制，用于给单写者提供
更强的缓存保证。

### 2.2 Dentry

```go
type Dentry struct {
    ParentId uint64
    Inode    uint64
    Name     string
    Type     uint32
    multiSnap *DentryMultiSnap
}
```
（`metanode/dentry.go:53`）

BTree 排序键是 `(ParentId, Name)`，所以**同一目录下的 dentry 在树里相邻**，
readdir 是一次范围扫描。这部分是好的。

### 2.3 SortedExtents：写时原地替换

这是 CubeFS 与 JuiceFS 最本质的分歧点。

```go
type SortedExtents struct {
    sync.RWMutex
    eks []proto.ExtentKey    // 按 FileOffset 排序的数组
}
```
（`metanode/sorted_extents.go:13`）

`Append` 不是简单追加，而是**立即计算覆盖并原地替换**（`metanode/sorted_extents.go:96`）：

```go
func (se *SortedExtents) Append(ek proto.ExtentKey) (deleteExtents []proto.ExtentKey) {
    // 快路径 1：追加到末尾（顺序写）
    if lastKey.FileOffset+lastKey.Size <= ek.FileOffset { se.eks = append(se.eks, ek); return }
    // 快路径 2：插到最前
    // 慢路径：线性扫描找到被完全覆盖的区间，收集进 invalidExtents，
    //         用新 ek 替换这一段，返回被覆盖的 ek 供调用方删除数据
}
```

三个直接后果：

1. **读路径零开销**：extent 列表永远是扁平、有序、不重叠的，
   读取直接二分查找即可。不需要 JuiceFS 那种读时区间树展开。
2. **不需要 compaction**：碎片在写入时就被消除了。
3. **代价转移到写路径**：覆盖写要做数组的插入/删除（`copy` 搬移），
   而且**必须在持有 inode 锁的 Raft apply 里同步完成**。极端碎片场景下
   单个 inode 的 eks 数组会很大，线性扫描 + 数组搬移都是 O(n)。

被覆盖的 extent 通过返回值 `deleteExtents` 交给 `extDelCh` 通道，
由后台批量投递给 DataNode 执行真正的删除。

**这是设计 extent 索引时必须明确站队的分歧点**：
- JuiceFS 路线（追加 + 读时展开 + compaction）：写快、读慢、需要碎片治理
- CubeFS 路线（写时替换）：写慢一点、读快、无需 compaction、GC 路径简单

详见 [分析文档](cubefs-analysis.md) 第 5 节的评估。

## 3. 分片策略：inode ID 区间（这是个教训）

Meta Partition 按 **inode ID 区间**切分（`master/meta_partition.go:54`）：

```
MP1: inode [1, 4194304)
MP2: inode [4194304, 8388608)
MP3: ...
```

新建文件时，客户端从**可写 MP 列表里挑一个**（round-robin / 随机），
在那个 MP 上分配 inode ID。而 dentry 存在**父目录 inode 所属的 MP** 上
（`sdk/meta/api.go:345`）：

```go
func (mw *MetaWrapper) Lookup_ll(parentID uint64, name string) (...) {
    parentMP := mw.getPartitionByInode(parentID)   // dentry 在父目录的 MP
    status, inode, mode, err := mw.lookup(parentMP, parentID, name, ...)
    ...
}
```

于是一次 `lookup + getattr` 变成：

```
1. 查 parentID 所在 MP  → 得到子项的 inode ID
2. 查该 inode ID 所在 MP → 得到属性
```

**两个 MP，两次 RPC，且这两个 MP 大概率不在同一台机器上。**
路径深度为 d 的 `open("/a/b/c/d/file")` 需要约 2d 次跨节点往返。

更糟的是**创建文件不是原子的**：dentry 在父目录 MP，inode 在另一个 MP，
两者要跨 Raft 组一致。CubeFS 为此实现了一套两阶段事务
（`metanode/transaction.go`，1593 行，含 `TransactionProcessor`、
回滚记录 `TxRbInode` / `TxRbDentry`、事务超时清理）。

### 另一条路：key 范围分片 + 目录局部性

另一种分片方式是 **key 范围分片 + 目录局部性**：以 `(parent_inode, name)` 一类的 key
做范围切分，让一个目录的全部 dentry 在 key 空间连续，并让子 inode 尽量与父目录
落在同一个分片。这直接规避了 CubeFS 的两个问题：

- lookup 与 getattr 大概率落在同一个分片 → 一次 RPC
- create 的 dentry 与 inode 同分片 → 单 Raft 组事务，不需要分布式事务

**这是设计新元数据服务时相对 CubeFS 路线最明确的改进空间。**
但要注意"尽量同分片"总有退化路径——当目录跨分片（十亿级大目录）
或分片内 inode 段耗尽时仍会退化为跨分片操作，跨分片事务的路径必须存在且被测试到。
CubeFS 的 `transaction.go` 可以作为实现参考（它是被逼出来的，但实现是完整的）。

## 4. Raft 层

`raftstore` 包（仅 1.2k 行）是对 `tiglabs/raft` 的薄封装。
每个 MP 一个 Raft 组，MetaNode 上所有 MP 共享底层的网络与 WAL 存储。

### 一个值得注意的实现问题：Raft 日志用 JSON 编码

```go
type MetaItem struct {
    Op uint32 `json:"Op"`
    K  []byte `json:"k"`
    V  []byte `json:"v"`
}
func (s *MetaItem) MarshalJson() ([]byte, error) { return json.Marshal(s) }
```
（`metanode/partition_item.go:34`）

`Apply` 走的是 `msg.UnmarshalJson(command)`（`metanode/partition_fsm.go:52`）。

代码里**同时存在** `MarshalBinary`（紧凑二进制帧，`metanode/partition_item.go:53`），
但 Raft 提交路径用的是 JSON 版本。这意味着每个元数据操作都要：

1. JSON 序列化，其中 `K`/`V` 是 `[]byte` → Go 的 `encoding/json` 会做 **base64 编码**，
   二进制载荷膨胀 4/3
2. 每次 apply 反序列化，走反射路径

在元数据密集负载下这是笔实打实的开销。**Raft 日志务必用紧凑二进制编码**——
这看起来很基础，但 CubeFS 这样成熟的项目仍留着这条路径，说明它很容易被忽略。

## 5. 删除与空间回收

CubeFS 的回收链路比 JuiceFS 简单得多，因为没有 compaction。

### 5.1 Inode 删除

`unlink` 只减 `NLink`。归零后 inode 进入 `freeList`，由 `deleteWorker`
后台批量处理（`metanode/partition_free_list.go:162`）：

```go
if !isForceDeleted && mp.freeList.Len() < MinDeleteBatchCounts {   // 100
    // 攒够一批再删
}
batchCount := DeleteBatchCount()
mp.deleteMarkedInodes(buffSlice)
```

`deleteMarkedInodes` 负责把该 inode 的所有 extent 投递给对应的 DataNode 删除，
全部成功后才从 inodeTree 真正移除。

### 5.2 Extent 删除

被覆盖或随 inode 删除的 extent 走 `extDelCh` 通道，
落到本地的 delete-extent 文件（`defaultDelExtentsCnt = 100000`，`metanode/const.go:264`），
再批量下发 DataNode。

**关键优势：不需要全局扫描。** 每个 extent 的归属（哪个 DP、哪个 extent）
在 ExtentKey 里是明确的，删除是点对点的定向操作。
对比 JuiceFS 必须靠 `juicefs gc` 全量扫描对象存储比对引用，
CubeFS 这条路径在大规模下明显更健康，是值得沿用的方向。

代价是**必须保证删除消息不丢**：MetaNode 崩溃时未下发的删除会变成孤儿 extent。
CubeFS 靠 delete-extent 文件持久化 + 重启重放来兜底。

## 6. 事务

`metanode/transaction.go`（1593 行）实现两阶段提交，覆盖跨 MP 的操作：
`create`、`rename`、`link`、`unlink`、`mkdir`、`rmdir`。

- `TransactionProcessor` 管理事务生命周期
- 每个参与者写回滚记录（`TxRbInode` / `TxRbDentry`），随快照持久化
  （`metanode/partition_store.go:592` 的 `loadTxRbInode`）
- 事务有超时，超时后由后台清理并回滚
- `uniqChecker`（`metanode/uniq_checker.go`）为非幂等操作做去重，
  防止客户端重试导致重复执行

这套东西存在的唯一原因就是 inode ID 分片带来的跨分片操作。
**架构选择直接决定了要不要付这笔复杂度。**

## 7. 客户端元数据缓存

`sdk/meta` 维护：

- **MP 路由表**：从 Master 拉取，定期刷新
- **inode 属性缓存**：带 TTL
- **dentry 缓存**：`AddInoInfoCache(inode, parentID, name)`，只缓存目录
  （`sdk/meta/api.go:356`），因为目录的 parent 关系稳定

FUSE 层还有内核的 attr/entry 缓存。一致性模型与 JuiceFS 类似，
不是严格 POSIX，靠 TTL 收敛。

---

上一篇：[总体架构](cubefs-overview.md) ｜ 下一篇：[数据路径](cubefs-data-path.md)
