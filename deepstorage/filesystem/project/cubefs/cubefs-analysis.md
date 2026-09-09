# CubeFS 调研（五）：设计评估与对 LightStore 的启示

> 基线：cubefs commit `8193603`

CubeFS 是本轮调研中与 LightStore 架构最接近的系统。它已经在生产中跑了多年，
它做对的地方是验证，它撞到的墙是预警。

## 1. 架构对照总表

| 维度 | CubeFS | LightStore | 评价 |
|------|--------|-----------|------|
| 管控 | Master（Raft） | Manager（Raft 5 副本 + Observer） | 同构 |
| 元数据 | MetaNode，**全内存 BTree** + Raft + 5 分钟快照 | MetaServer，Range 分片 + Multi-Raft | **LightStore 更优** |
| 元数据分片 | **inode ID 区间** | **key 范围（目录局部性）** | **LightStore 明显更优** |
| 数据容器 | Data Partition 120 GiB | Volume 128 GiB | 同构 |
| 数据寻址 | ExtentKey{DP, ExtentID, ExtentOffset, Size} | Loc{volume_id, offset, length, cookie} | 同构，LightStore 少一层间接 |
| 小文件 | Tiny Extent（64 个/DP，共享追加） | Haystack 打包进 volume | 同构 |
| 覆盖写 | 写时原地替换 extent 列表 | 异地写 + 区间替换 | 同构 |
| 副本复制 | 星型主副本转发，**write-all** | 链式复制，密封长度对齐 | 同思路，拓扑不同 |
| EC | BlobStore 独立子系统，**quorum 写** | 卷内 EC 条带追加 | 需借鉴 quorum |
| 失败处理 | 换 extent/DP 重放 | seal-and-new | 同构 |
| 空间回收 | tiny 打洞 / normal 删文件 / EC compact | 卷内 compaction | **可借鉴打洞** |
| 后台任务 | 服务端驱动 | 服务端驱动 | 同构 |

**结论：LightStore 的整体架构方向与 CubeFS 一致，且在两个关键点（元数据分片方式、
元数据是否全内存）上做了更适合超大规模的选择。** 主要的可借鉴点集中在数据层实现细节。

## 2. 可直接借鉴的设计

### 2.1 EC 写入必须用 quorum，不能照搬副本的 write-all ★★★

CubeFS 在同一个项目里做了两个相反的选择：

- DataNode 三副本：**write-all**（`datanode/repl/repl_protocol.go:389`）
- BlobStore EC（16~36 分片）：**quorum + 后台补齐**（`blobstore/access/stream/stream_put.go:205`）

原因是尾延迟。等待 3 个节点里最慢的一个，和等待 16 个节点里最慢的一个，
是完全不同量级的问题——后者几乎必然踩到某个节点的 GC、盘抖动或网络重传。

LightStore 的 EC 是 RS(12,4) = 16 个分片。设计文档目前描述的是
"EC RS(12,4) 条带化追加"，但没有明确写入确认策略。**建议明确：**

- 副本卷：保持 write-all（密封长度对齐），3 副本下代价可控
- EC 卷：quorum 确认，剩余分片后台补齐，缺失分片可由 EC 重建

quorum 下界照搬 CubeFS 的约束（`blobstore/common/codemode/codemode.go:165`）：

```
(N + M) / AZCount + N  ≤  PutQuorum  ≤  N + M
```

RS(12,4) 单 AZ：`16/1 + 12 = 28 > 16`，说明**单 AZ 下这条不等式无解**——
CubeFS 的 EC12P4 配的是 `PutQuorum = 15`，即只允许 1 个分片后台补齐。
这条不等式本身是"容忍整 AZ 故障"的约束，单 AZ 场景不适用，
但它提醒了一件事：**quorum 取值必须保证已确认数据在预期故障域失效后仍可重建**，
LightStore 需要按自己的故障域模型推导这个下界，不能凭感觉取 N+1。

### 2.2 小文件删除用打洞（fallocate PUNCH_HOLE），而不是 compaction ★★★

`datanode/storage/extent.go:787`：

```go
fallocate(fd, FALLOC_FL_PUNCH_HOLE|FALLOC_FL_KEEP_SIZE, offset, size)
```

tiny extent 里删一个小文件就是打一个洞，本地文件系统回收物理块，
文件逻辑长度不变，读到洞返回零。**三个副本各自打洞，结果天然一致，
不需要任何跨节点协调。**

**这对 LightStore 的价值**：设计文档里 Volume 的回收路径是
`SEALED → COMPACTING → DROPPED`。如果 record 存在本地文件里，
大部分"卷内死数据回收"可以用打洞完成，把真正的 compaction（搬迁 + 换址 + 更新索引）
留给"整卷存活率极低、想回收整个卷"的场景。

**但必须清楚它的三条限制**，CubeFS 也都遇到了：

1. **粒度是文件系统块**（通常 4 KiB）。小于一块的删除回收不了空间。
   小文件密集场景下这个浪费不可忽略。
2. **打洞不改变存活 record 的地址**。LightStore 的 `Loc` 含 `offset`，
   所以打洞只能回收空间，**不能提升卷的空间连续性**。想真正压缩卷、
   腾出整卷来回收，仍然需要搬迁式 compaction。
   这就是为什么 CubeFS 的 BlobStore（offset 必须稳定）用 compact，
   而 tiny extent 用打洞——两种场景，两种策略。
3. **空洞成为需要复制的状态**。新副本重建时，如果只复制数据不复制"哪里被删了"，
   会把已删数据复原。CubeFS 为此维护了独立的 `tinyDeleteRecordFile`，
   修复时重放删除记录（`datanode/data_partition_repair.go`）。
   **LightStore 若采用打洞，必须同步设计删除记录的持久化与复制。**

结论：**打洞值得引入，但作为 compaction 的补充而非替代**，
且要一并设计删除记录的复制。

### 2.3 失败重试要换资源类别，不只是换实例 ★★

`sdk/data/stream/extent_handler.go:703` 的注释：

```go
// Always use normal extent store mode for recovery.
// Because tiny extent files are limited, tiny store
// failures might due to lack of tiny extent file.
```

写 tiny extent 失败，恢复时**降级到 normal extent**，而不是再找一个 tiny extent。
因为失败的根因很可能是"tiny extent 资源耗尽"，同类重试必然再失败。

LightStore 的 SDK 在选卷重试时应有等价规则：小文件写入失败时，
除了换 volume，还应考虑降级到独立 record 路径，避免在同一个瓶颈上反复撞。

### 2.4 Location 的游程压缩 ★★

`blobstore/common/proto/blob.pb.go:177`：

```go
type Slice struct {
    MinSliceID BlobID   // 起始 id
    Vid        Vid
    Count      uint32   // 连续 blob 数
    ValidSize  uint64
}
```

连续分配的 blob 只记 `(起点, 数量)`，不逐个记 ID。

LightStore 的 extent 索引 `(inode_id, file_offset) → Loc` 是逐条记录的。
大文件顺序写时，多条 record 大概率在同一个 volume 内连续，
可以压缩成 `(volume_id, start_offset, record_count, record_size)`。
**对 TB 级大文件，元数据条数可降一到两个数量级**，
直接减轻 MetaServer 的存储与 Raft 日志压力。

代价是覆盖写时要分裂游程，实现复杂度上升。建议：
**只在 `CommitExtents` 批量提交时做游程合并**，覆盖写路径保持逐条，
用后台整理把碎片重新合并成游程。

### 2.5 Vuid 的 epoch fencing ★★

`blobstore/common/proto/vuid.go:53`：`vuid = vid << 8 | index`，再拼 `epoch`。
每次分片被迁移/修复到新位置，epoch 递增，旧 epoch 的写入被拒绝。

LightStore 的 `vol_epoch` 已有同样设计，此处是成熟实现的印证。
可借鉴的细节是**把 epoch 编进寻址标识本身**，而不是作为旁路检查——
这样任何一次 IO 都自动带上了版本，不会漏检。

### 2.6 NopData 与 Inline ★

`blobstore/blobnode/core/shard.go:156`：

- `NopData`：数据全零时只记标志，不落盘
- `Inline`：极小数据内联进索引记录，读取一次 IO 搞定

两个改动成本都极低。LightStore 的 record 头部可以加同样的标志位，
稀疏文件和预分配场景直接受益。

## 3. 需规避的设计（CubeFS 撞过的墙）

### 3.1 元数据全内存 ★★★

MetaNode 的 inode/dentry/xattr/multipart 四棵树全在内存
（`metanode/partition.go:489`），靠 5 分钟一次全量快照 + Raft WAL 持久化。

**元数据容量 = 集群 MetaNode 总内存。** 默认每个 MP 覆盖 419 万 inode
（`master/const.go:215`），要支撑 10^12 文件需要约 24 万个 MP，
而每个 MP 是一个独立 Raft 组——Raft 组的数量、心跳开销、快照 IO 会先崩掉。

而且**全量快照本身是个隐患**：一个装满的 MP 做快照要写数百 MB，
5 分钟一次，几十个 MP 挤在一台机器上，IO 抖动会传导到前台请求。

LightStore 的 MetaServer 走 Range 分片 + 数据落盘（LSM 类引擎），
单分片体积有界、增量刷盘，是正确的方向。**本次调研的最大价值之一
就是印证了"元数据不能全内存"这条。**

### 3.2 按 inode ID 分片，导致目录局部性丢失 ★★★

这是 CubeFS 最深的架构债。

- dentry 存在**父目录 inode 所属的 MP**
- inode 存在**它自己 ID 所属的 MP**
- 新文件的 inode ID 从"任意可写 MP"分配

后果：

1. `lookup + getattr` = 2 个 MP、2 次 RPC。
   `open("/a/b/c/d/file")` 约 2d 次跨节点往返（`sdk/meta/api.go:345`）。
2. `create` 需要跨 MP 原子性 → 被迫实现两阶段事务
   （`metanode/transaction.go`，1593 行，含回滚记录、超时清理、幂等去重）。
3. `rename` 跨目录时更复杂。

LightStore 选的是 key 范围分片 + "子 inode 尽量与父目录同 Range"，
直接规避了这三条。**这是 LightStore 相对 CubeFS 最明确的架构优势。**

但要注意两个退化场景，必须被设计和测试覆盖：

- **超大目录跨 Range**：README 说"十亿级条目的超大目录允许跨多个 Range"，
  此时 dentry 与父目录 inode 就分离了
- **inode 段耗尽**：README 说"子 inode 尽量与父目录同 Range"——
  "尽量"意味着有退化路径

跨 Range 事务的实现不能省。CubeFS 的 `transaction.go` 虽然是被逼出来的，
但作为一份完整的两阶段提交 + 回滚 + 幂等去重实现，是很好的参考。

### 3.3 Master 缓存 per-extent 状态 ★★★

`master/data_partition.go:57`：

```go
FileInCoreMap           map[string]*FileInCore
FilesWithMissingReplica map[string]int64
```

Master 为一致性检查缓存了 DP 内**每个 extent 文件**的副本状态。
一个 120 GiB 的 DP 可能有上千个 normal extent，乘以集群 DP 总数，
这是 Master 内存里一份 O(extent 总数) 的状态。

**这直接违背 LightStore 设计原则第 1 条**（"Manager 只保存 O(集群规模) 的状态，
不保存任何 per-file / per-record 信息"）。

LightStore 已经明确禁止了这一点，但要警惕它以隐蔽形式回来：
"为了做一致性检查/修复调度，Manager 临时拉一份 record 列表"——
这类需求会不断出现，必须坚持**把检查下推到 volume 主副本**，
Manager 只接收聚合后的结论。

### 3.4 Raft 日志用 JSON 编码 ★★

`metanode/partition_item.go:41`：

```go
type MetaItem struct {
    Op uint32 `json:"Op"`
    K  []byte `json:"k"`
    V  []byte `json:"v"`
}
func (s *MetaItem) MarshalJson() ([]byte, error) { return json.Marshal(s) }
```

提交路径用 JSON（`metanode/partition_fsm.go:52` 的 `UnmarshalJson`），
而 `K`/`V` 是 `[]byte`，Go 的 `encoding/json` 会做 **base64 编码**，
二进制载荷膨胀 4/3，外加反射开销。

代码里**同时存在** `MarshalBinary`（紧凑二进制帧，`partition_item.go:53`）——
说明作者知道该怎么做，但提交路径一直没切过去。

LightStore 的 Raft 日志务必用紧凑二进制。这条看起来很基础，
但一个 CNCF 毕业项目在核心路径上留着它，说明这类"能跑就没人动"的债很容易积累。

### 3.5 分层存储是后加的，结构上留下了疤 ★

`Inode` 里同时挂着两套 extent 容器（`metanode/inode.go:103`）：

```go
HybridCloudExtents          *SortedHybridCloudExtents
HybridCloudExtentsMigration *SortedHybridCloudExtentsMigration
```

外加 `StorageClass`、`MigrationStorageClass`、`HasMigrationEk`、
`MigrationExtentKeyExpiredTime`、`ForbiddenLc` 一堆标志位。

在"每个 inode 都常驻内存"的前提下，这些字段乘以 inode 总数就是实打实的内存。

LightStore 已经规划了副本卷 → EC 卷转码。**建议一开始就把"数据当前位置"
设计成统一的 Loc 列表 + 一个存储级别标记，而不是为每种迁移状态加一组字段。**
迁移中的临时状态应该放在独立的迁移任务表里，不要污染 inode 结构。

## 4. 两个系统都验证了的选择

这些是 JuiceFS 和 CubeFS 都这么做、LightStore 也已经这么设计的，可以放心：

1. **数据容器约 100 GiB 量级**（CubeFS DP 120 GiB，LightStore Volume 128 GiB）
2. **append-only + 异地覆写**，修复退化成长度对齐
3. **客户端攒批提交索引**（CubeFS handler 关闭时提交，LightStore 64 MiB 或 Sync）
4. **失败即换址重写**（seal-and-new）
5. **EC 参数 RS(12,4)，1.33x**（CubeFS EC12P4 逐字相同）
6. **小文件必须打包**，不能一文件一对象

## 5. 一个悬而未决的分歧：覆盖写的展开时机

这是 JuiceFS 与 CubeFS 的正面分歧，LightStore 需要明确站队：

| | JuiceFS | CubeFS |
|---|---------|--------|
| 写入时 | 只追加 slice 记录 | 立即计算覆盖，原地替换数组 |
| 读取时 | 区间树展开 O(n log n) | 二分查找 O(log n) |
| 碎片治理 | 需要 compaction + 三级阈值反压 | 不需要 |
| 写入锁持有 | 短 | 长（数组搬移在 Raft apply 内） |
| GC | 需全局扫描找孤儿 | 覆盖时直接产出待删列表 |

LightStore README 描述的是"extent 索引按区间替换旧项"，即 **CubeFS 路线**。
这个选择的连带后果需要被确认：

- **好处**：读路径干净、不需要 compaction 触发策略、GC 是定向的
  （覆盖时就知道哪些 record 死了，直接进删除日志）——这与
  "GC 由删除日志订阅驱动"的设计原则天然契合
- **代价**：区间替换发生在 MetaServer 的 Raft apply 内，
  单文件 extent 数很大时（随机写密集）是 O(n) 数组搬移，会拖慢整个 Range 的 apply

**建议**：保持 CubeFS 路线，但补一条保护——
**单 inode 的 extent 条数上界**。超过阈值时对写入返回软反压，
或触发一次后台的 extent 索引整理（合并相邻、游程压缩）。
CubeFS 没有这个保护，随机写密集的大文件会让单个 MP 的 apply 变慢，
这是它已知的性能陷阱之一。

## 6. 结论摘要

**必须借鉴**

1. EC 写入用 quorum，不照搬副本的 write-all（§2.1）
2. 小文件删除引入打洞，作为 compaction 的补充，并同步设计删除记录的复制（§2.2）
3. extent 索引的游程压缩，在批量提交时合并（§2.4）
4. 失败重试换资源类别而非仅换实例（§2.3）

**必须规避**

1. 元数据全内存（§3.1）
2. 按 inode ID 分片导致的目录局部性丢失与被迫的分布式事务（§3.2）
3. 中心组件缓存 per-record 状态（§3.3）
4. Raft 日志用 JSON（§3.4）

**已验证做对的**

1. Range 分片 + 目录局部性（相对 CubeFS 的明确优势）
2. 元数据落盘而非全内存
3. Volume 120~128 GiB、append-only、seal-and-new、EC RS(12,4)
4. 小文件打包、后台任务服务端驱动

**需要补充设计的**

1. EC 路径的写入确认策略与 quorum 下界推导（§2.1）
2. 打洞的删除记录持久化与副本复制（§2.2）
3. 单 inode extent 条数上界与反压（§5）
4. 跨 Range 事务路径（超大目录、inode 段耗尽的退化场景）（§3.2）
5. 分层存储的数据结构设计，避免 inode 膨胀（§3.5）

---

上一篇：[BlobStore 纠删码子系统](cubefs-blobstore.md) ｜ 返回 [调研索引](README.md)
