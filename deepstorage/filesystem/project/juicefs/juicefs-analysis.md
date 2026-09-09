# JuiceFS 调研（五）：设计评估与对 LightStore 的启示

> 基线：juicefs v1.5.0-dev，commit `44a5657`

前四篇是事实描述，这一篇是判断。结论分三类：**可直接借鉴**、**需规避**、**架构性差异（不可比）**。

## 1. 两个系统的定位差异

| 维度 | JuiceFS | LightStore |
|------|---------|-----------|
| 服务端 | 无（纯客户端 + 第三方引擎） | Manager / MetaServer / DataServer |
| 元数据规模上限 | 单引擎实例（Redis 内存 / 单机 SQL / TiKV 集群） | 数千 Raft 组，Range 自动分裂，目标 10^12~10^13 文件 |
| 数据存储 | 第三方对象存储 | 自研 append-only Volume（Haystack 风格） |
| 冗余 | 由对象存储负责，JuiceFS 不感知 | 自管副本 + EC，卷内闭环 |
| 小文件 | 一个 slice 至少一个对象，无打包 | 打包进 volume，一次 IO 读取 |
| 一致性 | 元数据强一致，数据 close-to-open | 元数据线性一致 |
| 后台任务 | 客户端抢租约执行 | volume 主副本驱动 / 删除日志驱动 |
| 运维成本 | 极低（无自研服务端） | 高（完整分布式系统） |

**这不是同一类系统。** JuiceFS 的目标是"用最低成本在任意对象存储上得到一个能用的 POSIX 文件系统"，
LightStore 的目标是"在自有硬件上做到万亿文件 / EiB 级"。JuiceFS 的很多"缺陷"是它定位的必然结果，
不构成对它的批评；但它们恰好标定了 LightStore 必须自己解决的问题边界。

真正值得比较的是**局部机制**——那些与规模无关、纯粹是工程手艺的部分。

## 2. 可直接借鉴的设计

### 2.1 索引可推导，而非可枚举 ★★★

JuiceFS 最值钱的一个决定：**元数据只存 slice（24 字节），block 的对象 key 由
`(slice_id, block_index, block_size)` 算出来**（[数据路径 1](juicefs-data-path.md#1-三级切分模型)）。
一个 64MiB 的顺序写，元数据成本是 24 字节，对应 16 个对象——而这 16 个对象的名字一个都不用存。

LightStore 的 `Loc = {volume_id, offset, length, cookie}` 是同构的思路：位置标识自身即路由，
不需要盘内索引。**建议把这条原则显式写进设计约束**：

> 任何 per-record 的信息，若能由 (上层 id, 固定参数) 计算得出，就不应落盘。

具体到 LightStore，可检查的点：
- extent 索引的 value 是否真的最小？`Loc` 16+ 字节已经很紧，但要确认没有冗余的
  长度/校验字段能从 record 头恢复。
- EC 条带的分片位置是否可由 `(volume_id, offset, ec_params)` 推导，而不是逐条带记录。

代价也要一并接受：**block_size 一旦格式化就不可改**。JuiceFS 在 `Format.update()` 里
硬性拒绝修改这类字段。LightStore 若采用同类推导，也要明确哪些参数进入"不可变格式"集合。

### 2.2 区间树覆盖展开算法 ★★★

`buildSlice` / `slice.cut`（`pkg/meta/slice.go:55,134`）解决的是一个 LightStore 也必然面对的问题：
**append-only 的覆写序列如何展开成扁平视图**。

LightStore 的 `extent: (inode_id, file_offset) → Loc` 采用"区间替换"语义，
但 README 里写的是"按区间替换旧项"——如果替换是在写入时立即完成的，就需要读改写，
会引入并发写冲突；如果是追加式的（像 JuiceFS 那样后写覆盖先写），就需要读时展开。

JuiceFS 的算法可以直接搬：

```
按写入顺序遍历 slice：
  新 slice 在其左边界切树 → 得到 left 子树
  在右边界切剩余部分     → 丢弃中间被完全覆盖的部分
  新 slice 成为根（天然"最新"）
中序遍历，空隙补 id=0 的洞
```

复杂度 O(n log n)，n 是区间数。**关键配套是必须限制 n**——JuiceFS 用三级阈值
（异步 5 / 异步 350 / 同步 2500）做到这一点。LightStore 若走追加式 extent，
同样需要一个"碎片过多时反压写入"的机制，否则读放大不可控。

### 2.3 引用计数"默认 1 即不存在" ★★

`// most of chunk are used by single inode, so use that as the default (1 == not exists)`
（`pkg/meta/redis.go:3144`）。

绝大多数数据块只被一个文件引用，为它们各存一条引用计数记录是纯浪费。
只在 clone / compaction 保留 / 快照等场景写入显式计数。

LightStore 如果要支持 clone / snapshot / 去重，这个技巧直接适用于 record 或 volume 级别的引用管理。

### 2.4 属性编码的向后兼容扩展 ★★

`Attr.Unmarshal`（`pkg/meta/interface.go:215`）用 `rb.Left() >= N` 逐段判断可选字段是否存在：

```go
if rb.Left() >= 8  { attr.Parent = Ino(rb.Get64()) }
if rb.Left() >= 8  { attr.AccessACL = rb.Get32(); attr.DefaultACL = rb.Get32() }
if rb.Left() >= 1  { attr.Tier = rb.Get8() } else { attr.Tier = 0 }
```

新版本追加字段，旧客户端读到会自然忽略尾部；旧数据被新客户端读到，缺失字段取零值。
比引入 protobuf 省空间（inode 属性是数量最大的元数据，每字节都乘以文件数），
比纯固定长度灵活。**万亿文件量级下，inode 属性每省 8 字节就是 8TB。**

同时注意它把 `Typ` 和 `Mode` 打包进一个 uint16（`typ<<12 | mode&0xfff`），省 1 字节。
这种级别的抠门在 LightStore 的规模下更有必要。

### 2.5 预读的双 session + 全局水位反馈 ★★★

`checkReadahead`（`pkg/vfs/reader.go:419`）值得整体移植到 C++ SDK：

- **2 个并行 session**：能同时跟踪两条交错的顺序流（典型场景：一个进程同时顺序读两个文件，
  或读写混合）。单 session 的预读器遇到交错访问会直接退化成随机读。
- **倍增/减半**：命中翻倍、失配减半，收敛快且不需要调参。
- **全局缓冲水位参与决策**：`readAheadTotal > used + readahead*4` 才扩大窗口，
  `readAheadTotal < used + readahead/2` 就收缩。多流并发时自动互相退让，
  这是纯单流启发式做不到的。

配套的三层缓冲回收（`cleanupRequests` / `releaseIdleBuffer` / `need()`）同样值得参考，
尤其是 `releaseIdleBuffer` 里"超水位时按超出倍数线性缩短空闲时间"这个自适应细节。

### 2.6 小随机读旁路整块缓存 ★★

`pkg/chunk/cached_store.go:155`：非块首且请求 < 1/4 block 时，直接 range GET，不拉整块。

LightStore 的 record 可能很大（上限 64MiB），小随机读同样面临"为读 4KB 拉 64MiB"的风险。
需要一个等价的启发式：**读长度与块长度的比值**决定是走整块缓存路径还是精确 range 读。

### 2.7 回收站按小时分目录 ★

`.trash/YYYY-MM-DD-HH/`（`pkg/meta/base.go:3032`），并在客户端本地缓存"当前小时的 trash 目录 inode"，
避免每次删除都查一次。简单有效，直接可用。

### 2.8 slice 提交的依赖链 ★★

`sliceWriter.dep`（`pkg/vfs/writer.go:305`）：新 chunk 的第一个 slice 依赖前一个 chunk 中
最后一个正在扩展长度的 slice，防止文件长度出现"跨过了前面的洞"的中间态。

LightStore 的 SDK 攒批提交 extent 时会遇到同一问题：如果按 64MiB 批量提交，
提交顺序乱了会让其他客户端看到长度已增长但中间区段为空的文件。
**建议在 `CommitExtents` 的设计里明确提交顺序约束，或在服务端强制按 file_offset 单调提交。**

### 2.9 元数据引擎抽象的分层切法 ★★

`baseMeta`（公共语义）+ `engine`（后端 doXxx）的切分（[元数据 1](juicefs-metadata.md#1-抽象分层)）
把权限检查、配额、缓存、compaction 触发这些**与后端无关的逻辑写了一遍**，
三个后端各 5~6k 行只负责事务内的读写。

LightStore 虽然只有一个自研元数据引擎，但同样会有"单机 KV 引擎可替换"（RocksDB / 自研 LSM）
的诉求，这个切法值得参考——尤其是把"什么时候触发 compaction"这类策略放在公共层，
而不是散落在存储引擎里。

## 3. 需规避的设计

### 3.1 后台任务依赖客户端在线 ★★★

`setIfSmall` 抢租约 + 50 分钟自限时（[GC 4](juicefs-gc-consistency.md#4-后台任务的分布式协调)）
是无中心架构下的精巧妥协，但它有个硬前提：**至少一个客户端长期在线**。
全部卸载后，回收站不清理、删除的数据不释放、碎片不合并。

LightStore 有 Manager 和 DataServer，**不应该复刻这个模式**。设计原则里已经写了
"修复与 compaction 由 volume 主副本驱动，GC 由删除日志订阅驱动"，方向是对的。
要确保的是：**没有任何后台任务的执行依赖于客户端存在**。

### 3.2 "允许泄漏、事后扫描清理" ★★★

JuiceFS 的多个路径会产生孤儿对象：
- 数据已上传但元数据提交失败（客户端崩溃）
- Compaction CAS 失败，新合并的 slice 无人引用
- 甚至 CAS 成功与否本身可能误判（`pkg/meta/redis.go:3814` 的 double-check）

清理手段是 `juicefs gc`——**全量扫描对象存储，比对元数据引用**。
在 PB 级卷上这已经是数小时的操作；在 LightStore 目标的 EiB 级、万亿记录规模下，
**全量扫描在物理上不可行**。

LightStore 的设计原则第 4 条已经识别到这点（"没有任何组件需要遍历全部文件/记录"），
但需要把它落实为具体机制：

- 写入失败的 record 不产生孤儿：因为 record 在 volume 内是追加的，未被 extent 索引引用的
  record 会在 volume compaction 时通过反向指针（`owner = (inode, file_offset)`）自然识别为死数据。
  **这比 JuiceFS 的方案好一个数量级**——回收是 volume 局部的，不需要全局扫描。
- 但要确认：**反向指针校验必须能独立判定"这条 record 是否还被引用"**，
  即 compaction 时对每条 record 反查 extent 索引。这是 volume 粒度的 O(volume 内记录数) 操作，
  可接受；要避免退化成全局 join。

### 3.3 小文件无打包 ★★★

JuiceFS 每个 slice 至少产生一个对象。100 亿个 4KB 小文件 = 100 亿个对象。
对象存储的 LIST/DELETE 成本、per-object 元数据开销、以及 4KB 对象的 IO 效率都很差。

这正是 LightStore 选择 Haystack 打包的理由，方向明确正确。要注意的配套问题：

- **打包后的删除更难**：JuiceFS 删一个小文件就是删一个对象，LightStore 删一个小文件
  只是在 volume 里留一个洞，必须靠 compaction 回收。compaction 的触发阈值
  （死数据占比）需要仔细设计，否则要么空间浪费、要么 compaction 打满 IO。
  可以参考 JuiceFS 的 `skipSome` 思路：**只搬运碎片，跳过仍然连续且足够大的区段**。

### 3.4 覆写产生的碎片没有上界保护（在 LightStore 侧） ★★

JuiceFS 用 `maxSlices = 2500` 同步阻塞写入来兜底。LightStore 的 extent 索引若也是追加式，
需要一个等价机制。**建议在 MetaServer 侧统计单文件（或单 Range 内单 inode）的 extent 条数，
超阈值时对写入返回软反压信号，由 SDK 触发同步 compaction。**

### 3.5 客户端版本管理 ★★

JuiceFS 把全部逻辑放在客户端，导致：
- 升级 = 让所有挂载点重新挂载
- 新老版本客户端同时访问同一个卷，靠 `Format.MinClientVersion` / `MaxClientVersion` 做兼容性守卫
- 一个有 bug 的客户端可以破坏卷（比如错误的 compaction CAS）

LightStore 有服务端，可以把 compaction、修复、GC 这类"能破坏数据"的操作**完全收在服务端**，
客户端只做 IO。这是架构优势，应该明确利用——**不要为了性能把 compaction 下放到 SDK**。

### 3.6 元数据引擎无分片层 ★★★

这是 JuiceFS 最大的规模瓶颈：单卷元数据必须放进一个引擎实例。
Redis 受内存限制（亿级文件已经吃力），SQL 受单机限制，TiKV 能扩展但每个操作变成分布式事务。

LightStore 的 Range 分片 + Multi-Raft 正是针对这一点。调研中值得注意的一个细节是
JuiceFS 的 **TKV key 布局把一个 inode 的所有元数据挂在 `A{inode}` 前缀下**
（[元数据 3.1](juicefs-metadata.md#31-tkvtikv--etcd--badgerdb--foundationdb--memkv)）：
属性、dentry、chunk、xattr 全部物理相邻。

好处：删除一个 inode = 删一个前缀；dump/clone 一次 range scan 拿全。
坏处：**同一目录下的子项不相邻**——dentry 挂在 parent 前缀下、inode 数据挂在自己前缀下，
`readdir plus` 仍需 N 次点查。

LightStore 的设计选了另一边（"key 编码保证目录局部性：一个目录的全部 dentry 在 key 空间连续"），
这对 `readdir` 友好、对超大目录跨 Range 友好，是更适合万亿级的选择。
但要注意 JuiceFS 那边换来的好处会失去：**删除一个 inode 需要多次跨 Range 的操作**，
需要确认这条路径的事务边界（inode 属性、extent 索引、dentry 可能落在不同 Range）。

## 4. 架构性差异（不可比，但值得记录）

| 点 | JuiceFS | 说明 |
|----|---------|------|
| 冗余 | 完全外包给对象存储 | 简化了系统，但也失去了对副本放置、修复速度、EC 参数的控制权。LightStore 自管冗余是为了修复速度（分钟级）和成本（1.33x） |
| 一致性 | close-to-open | 无中心协调者下的合理选择。LightStore 有 MetaServer，可以做更强的语义，但要评估代价 |
| 锁 | 非阻塞，EAGAIN + 上层轮询 | 因为没有地方挂等待队列。LightStore 的 MetaServer 可以实现真正的阻塞锁 |
| 配额 | 弱一致，允许短暂超配 | 同上，无协调者的必然结果。LightStore 若要精确配额，需要评估每次写入做一致性读的代价——大概率也应该选择弱一致 + 定期纠偏 |

第四条要特别提醒：**LightStore 有服务端不等于配额就能强一致**。
在千万 ops/s 的目标下，每次写入同步更新目录配额会让配额所在的 Raft 组成为热点。
JuiceFS 的做法（本地累积 delta + 秒级 flush + 定期重载纠偏，
[元数据 8](juicefs-metadata.md#8-quota)）在这里仍然是正确答案。

## 5. 结论摘要

**必须借鉴（直接影响 LightStore 的核心设计）**

1. 索引可推导原则——per-record 信息若可计算则不落盘（§2.1）
2. 区间树覆写展开算法 + 碎片数量的三级反压阈值（§2.2、§3.4）
3. 预读的双 session + 全局缓冲水位反馈（§2.5）
4. 属性编码的紧凑二进制 + 尾部可选字段兼容（§2.4）
5. extent 批量提交的顺序约束，防止文件长度中间态（§2.8）

**必须规避**

1. 后台任务依赖客户端在线（§3.1）
2. 依赖全量扫描的 GC——EiB 级不可行，必须靠 volume 局部反向指针（§3.2）
3. 把 compaction 等破坏性操作下放到 SDK（§3.5）

**已经做对的（本次调研提供了反向印证）**

1. 元数据 Range 分片 + Multi-Raft，突破单引擎瓶颈（§3.6）
2. 小文件打包进 volume（§3.3）
3. 后台任务由 volume 主副本 / 删除日志驱动（§3.1）
4. 配额走弱一致 + 定期纠偏，而非强一致（§4）

**需要补充设计的**

1. 单文件 extent 条数的上界保护与反压机制（§3.4）
2. 跨 Range 删除 inode 的事务边界（§3.6）
3. Volume compaction 的触发阈值与"只搬碎片"策略（§3.3）
4. 小随机读旁路整 record 读取的启发式（§2.6）

---

上一篇：[空间回收与一致性](juicefs-gc-consistency.md) ｜ 返回 [调研索引](README.md)
