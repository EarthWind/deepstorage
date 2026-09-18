# JuiceFS 调研（二）：元数据引擎

> 基线：juicefs v1.5.0-dev，commit `44a5657`

## 1. 抽象分层

```
              meta.Meta 接口（对外，~70 方法）
                        │
                  baseMeta（公共逻辑）
                  ├─ 权限检查 / 配额检查
                  ├─ openfile 缓存（attr + slices）
                  ├─ inode / slice id 批量发号
                  ├─ compaction 触发与调度
                  ├─ 后台任务（GC / trash / stats flush）
                  └─ 调用 en engine 接口
                        │
        ┌───────────────┼────────────────┐
   redisMeta        dbMeta(SQL)       kvMeta(TKV)
   6251 行           6149 行           5111 行
```

`baseMeta` 持有 `en engine`（`pkg/meta/base.go:75` 起的内部接口），所有 `doXxx` 方法由后端实现。
公共语义（谁能删、要不要进回收站、配额够不够、要不要触发 compaction）只写一遍，
后端只负责"在自己的事务里原子地改这几个 key/行"。这个切分很干净，值得借鉴。

## 2. 核心数据模型

### 2.1 Inode 属性

`Attr`（`pkg/meta/interface.go:155`）手写二进制编解码，不用 protobuf/json：

```go
type Attr struct {
    Flags uint8; Typ uint8; Mode uint16
    Uid, Gid uint32; Rdev uint32
    Atime, Mtime, Ctime int64; Atimensec, Mtimensec, Ctimensec uint32
    Nlink uint32; Length uint64
    Parent Ino          // 0 表示由 parentKey 追踪（硬链接场景）
    Full, KeepCache bool // 内存态，不落盘
    AccessACL, DefaultACL uint32
    Tier uint8
}
```

落盘布局（`Marshal`，`pkg/meta/interface.go:181`）：基础 72 字节，ACL 存在时 +8，Tier 非 0 时 +1。
`Typ` 和 `Mode` 打包进一个 uint16：`(typ<<12) | (mode & 0xfff)`。
反序列化用 `rb.Left()` 判断可选字段，实现了**向后兼容的追加式扩展**——旧客户端读新数据只会丢掉尾部字段。

`Parent` 字段是个值得注意的设计：普通文件直接内嵌父 inode，硬链接（Nlink>1）时置 0，
改由独立的 `parentKey` 记录多个父目录。这样"绝大多数文件"的路径回溯是零额外读，
只有硬链接才付出额外成本（`pkg/meta/base.go` 的 `getParents`）。

### 2.2 文件数据索引：Chunk → Slice

文件内容的索引就三层，且**只有 Slice 需要持久化**：

| 层级 | 大小 | 是否持久化 | 说明 |
|------|------|-----------|------|
| Chunk | 固定 64 MiB（`ChunkBits = 26`） | 否，纯逻辑 | chunk 序号 = `offset >> 26`，无需存储 |
| Slice | ≤ 64 MiB | **是** | 一次连续写入产生的一段，有全局唯一 id |
| Block | 默认 4 MiB | 否，key 可推导 | 对象存储中的一个对象 |

每个 chunk 的元数据就是**一个 slice 记录的追加列表**，单条记录固定 24 字节
（`pkg/meta/slice.go:91`）：

```
pos(4) | id(8) | size(4) | off(4) | len(4)
 │        │       │        │        └─ 本次引用的长度
 │        │       │        └────────── 在 slice 内的起始偏移
 │        │       └─────────────────── slice 的完整长度
 │        └─────────────────────────── 全局唯一 slice id
 └──────────────────────────────────── 在 chunk 内的起始位置
```

Block 完全不出现在元数据里。对象 key 由 `(id, indx, blockSize)` 直接推导
（`pkg/chunk/cached_store.go:74`）：

```go
// 默认
"chunks/%v/%v/%v_%v_%v"      // id/1000/1000, id/1000, id, indx, blockSize
// HashPrefix 时（打散对象存储分区热点）
"chunks/%02X/%v/%v_%v_%v"    // id%256, id/1000/1000, id, indx, blockSize
```

**这是整个系统最关键的省元数据手法**：一个 64MiB 的连续写，元数据只有 24 字节，
而它对应对象存储上的 16 个 4MiB 对象——对象列表零成本，因为它是算出来的。
代价是 blockSize 一旦 format 就不能改。

### 2.3 覆盖写：Slice 叠加 + 读时展开

JuiceFS **从不原地修改已写数据**。覆盖写只是往 chunk 的 slice 列表尾部再追加一条记录。
读的时候按追加顺序回放，后写的覆盖先写的，得到扁平的、互不重叠的视图。

这个展开由 `buildSlice`（`pkg/meta/slice.go:134`）完成，用的是一棵按 pos 排序的二叉树：

```go
func buildSlice(ss []*slice) []Slice {
    var root *slice
    for i := range ss {          // 按写入顺序
        s := new(slice); *s = *ss[i]
        var right *slice
        s.left, right = root.cut(s.pos)          // 在新 slice 左边界切开
        _, s.right = right.cut(s.pos + s.len)    // 在右边界切开，丢弃中间被覆盖部分
        root = s                                  // 新 slice 成为根，天然"最新"
    }
    // 中序遍历，空隙补 Id=0 的洞（读作全零）
}
```

`cut`（`pkg/meta/slice.go:55`）递归地在指定位置劈开区间树，必要时插入 `id=0` 的空洞节点。
每插入一条 slice 是 O(树高)，总体 O(n log n)，n 是该 chunk 的 slice 条数。

**n 必须被限制住**，否则读放大不可接受——这就是 compaction 存在的理由（见
[GC 与一致性](juicefs-gc-consistency.md) 第 1 节）。触发阈值直接写在 `baseMeta`：

- 读路径：`len(ss) >= 5` 就异步触发一次 compact（`pkg/meta/base.go:2129`）
- 写路径：`numSlices % 100 == 99 || numSlices > 350` 触发；
  `numSlices >= maxSlices(2500)` 时**同步阻塞**执行（`pkg/meta/base.go:2185`）

同步 compact 是最后一道防线：写得太碎就让写变慢，把碎片压回去。

### 2.4 id 分配

`nextInode` / `nextChunk`（slice id）/ `nextSession` 都是元数据引擎里的计数器。
客户端**批量领号**后本地发放（`pkg/meta/base.go:2139` `NewSlice`）：

```go
inodeBatch   = 1 << 10   // 1024
sliceIdBatch = 4 << 10   // 4096
```

写一个 4KB 小文件需要 1 个 slice id——但因为批量领号，平均 1/4096 次元数据往返。
客户端崩溃会浪费一段 id 空间，用 64 位 id 承受得起。

## 3. 三种后端的存储布局

### 3.1 TKV（TiKV / etcd / BadgerDB / FoundationDB / memkv）

单一有序 KV 空间，key 布局在 `pkg/meta/tkv.go:201` 有完整注释：

```
setting                  卷格式（Format JSON）
C...                     计数器
Aiiiiiiii I              inode 属性
Aiiiiiiii D<name>        目录项（dentry）
Aiiiiiiii P iiiiiiii     父目录（仅硬链接）
Aiiiiiiii C nnnn         chunk 的 slice 列表（append）
Aiiiiiiii S              符号链接目标
Aiiiiiiii X<name>        扩展属性
Diiiiiiii llllllll       待删除 inode（inode + length）
Fiiiiiiii                flock
Piiiiiiii                POSIX record lock
Kcccccccc nnnn           slice 引用计数
Ltttttttt cccccccc       延迟删除的 slice（trash 开启时）
SE ssssssss              session 过期时间
SI ssssssss              session 信息
SS ssssssss iiiiiiii     session 持有的 sustained inode
Uiiiiiiii                目录统计（length/space/inodes）
Niiiiiiii                detached inode
QD iiiiiiii              目录配额
Raaaa                    POSIX ACL
XKDaaaa / XLOG...        委派 token / changelog
```

**布局要点**：一个 inode 的属性、dentry、chunk、symlink、xattr 全部共享 `A{inode}` 前缀，
inode 用大端编码。这意味着：

- 单个 inode 的全部元数据在 KV 空间里物理相邻 → 一次 range scan 拿全（`dump`、`clone`、`rmr` 都靠这个）
- 删除一个 inode = 删一个前缀（`tx.deleteKeys(prefix)`，`pkg/meta/tkv.go:89`）
- 但**同一目录下的子项不相邻**（dentry 挂在 parent 的前缀下，inode 数据挂在自己的前缀下），
  所以 `readdir plus` 仍需 N 次点查

chunk 用 `append` 语义（`kvtxn.append`）写入，天然契合"slice 只追加"的模型。

### 3.2 Redis

key 前缀式（`pkg/meta/redis.go:649` 起）：

| Key | 类型 | 内容 |
|-----|------|------|
| `i{inode}` | string | Attr 二进制 |
| `d{parent}` | hash | name → (type, inode) |
| `c{inode}_{indx}` | **list** | slice 记录，RPUSH 追加 |
| `s{inode}` | string | symlink |
| `x{inode}` | hash | xattr |
| `p{inode}` | hash | 硬链接的父目录集合 |
| `sliceRef` | hash | slice 引用计数 |
| `delfiles` | zset | 待删文件 |
| `delSlices` | hash | 延迟删除的 slice |
| `allSessions` | zset | sid → 过期时间 |
| `sessionInfos` | hash | sid → info |
| `session{sid}` | set | sustained inode |
| `dirUsedSpace` / `dirQuota` | hash | 目录统计与配额 |

Redis 的 list 类型天然是 slice 追加列表，`RPUSH` 的返回值就是当前 slice 条数——
`doWrite` 直接拿它做 compaction 触发判断（`pkg/meta/redis.go:3154`），零额外开销。这是个漂亮的细节。

### 3.3 SQL（MySQL / PostgreSQL / SQLite，xorm）

关系表（`pkg/meta/sql.go:55` 起）：

| 表 | 主键 / 唯一键 | 说明 |
|----|--------------|------|
| `setting` | name | 卷格式 |
| `counter` | name | 计数器 |
| `node` | inode | inode 属性（列式展开，非二进制 blob） |
| `edge` | (parent, name) unique，inode 索引 | 目录项 |
| `chunk` | (inode, indx) unique | `Slices []byte`，多条 slice 拼接成一个 blob |
| `slice_ref` | id | 引用计数 |
| `sym_link` / `xattr` / `acl` | — | — |
| `flock` / `plock` | (inode, sid, owner) | 锁 |
| `session2` | sid | 过期时间 + info |
| `sustained` | (sid, inode) | — |
| `delfile` / `delslices` | — | 待删文件 / 延迟删除 slice |
| `dir_stats` / `dir_quota` / `user_group_quota` | inode / (qtype,qkey) | 统计与配额 |
| `detached_node` | inode | 未挂载完成的节点 |

注意 `chunk.Slices` 是一个 blob，追加 slice = 对 blob 做 `concat` 更新
（SQL 后端没有 append 原语，靠事务内读改写）。这是 SQL 后端写放大高于 Redis/TKV 的原因之一。

### 3.4 三者对比

| 维度 | Redis | SQL | TKV(TiKV) |
|------|-------|-----|-----------|
| 事务机制 | WATCH/MULTI 乐观锁 | 数据库事务 | 分布式事务（2PC） |
| slice 追加 | 原生 RPUSH | blob 读改写 | 原生 append |
| 元数据容量 | 受内存限制 | 单机磁盘 | 水平扩展 |
| 延迟 | 最低 | 中 | 较高（跨节点 2PC） |
| 持久性 | 依赖 AOF 配置，有丢数据风险 | 强 | 强 |
| 适用规模 | 亿级以内、追求延迟 | 中小规模 | 十亿级以上 |

**这是 JuiceFS 元数据侧最大的结构性约束**：单卷元数据规模受限于单个引擎实例，
Redis 受内存、SQL 受单机。TiKV 可以扩展，但每个元数据操作变成一次分布式事务，
delay 上升明显。JuiceFS 没有元数据分片层——它把这个问题外包给了引擎。

## 4. 事务与并发控制

### 4.1 Redis：WATCH + 本地分桶锁

`redisMeta.txn`（`pkg/meta/redis.go:1140`）：

```go
h := fnv32(keys[0])
m.txLock(h)                     // 本地按 key hash 分桶加锁
defer m.txUnlock(h)
for i := 0; i < maxRetry(50); i++ {
    err := m.rdb.Watch(ctx, txf, keys...)
    if shouldRetry(err) {
        time.Sleep(rand % ((i+1)*(i+1)) ms)   // 平方级随机退避
        continue
    }
    return err
}
```

两个细节值得注意：

1. **本地分桶锁**：同一个客户端内部对同一 key 的并发事务先在本地串行化，避免自己跟自己
   在 Redis 上打 WATCH 冲突。这是纯粹的性能优化，不影响正确性。
2. **不做通用重试**：代码里有明确的 `// TODO: enable retry for some of idempotent transactions`。
   只有确定幂等的场景才启用 `retryOnFailure`，因为 WATCH 失败重试可能重复执行副作用。

### 4.2 SQL / TKV

SQL 后端依赖数据库自身事务隔离级别；TKV 依赖引擎的事务能力（TiKV 的乐观/悲观事务、
FoundationDB 的严格可串行化）。`kvTxn` 提供统一原语：`get/gets/scan/exist/set/append/incrBy/delete`。

值得注意的是 `simpleTxn`（`pkg/meta/tkv.go:73`）——只用于点查场景的轻量路径，
最新一个 commit（`44a5657`，就是本次调研的 HEAD）正是"meta/fdb: use snapshot read for simpleTxn"，
说明读事务的开销优化仍在持续进行。

### 4.3 写路径的原子性边界

一次 `Write` 的元数据事务只做三件事（`pkg/meta/redis.go:3114`）：

```go
RPUSH  c{inode}_{indx}   <24字节 slice 记录>    // 追加 slice
SET    i{inode}          <更新后的 attr>        // 更新长度和 mtime
INCRBY usedSpace         <delta>                // 空间统计
```

事务内还要做配额检查（`checkQuota`）。整个事务只涉及一个 inode，**不跨 inode**，
因此冲突面极小。这是 append-only slice 模型带来的直接收益：并发写同一个文件的不同区域
不会互相阻塞，最多是 RPUSH 顺序不同——而顺序不同不影响正确性，因为 `buildSlice` 按列表顺序回放，
Redis list 的顺序就是权威顺序。

## 5. openfile 缓存

`pkg/meta/openfile.go` 实现了客户端侧的 inode 缓存，缓存两样东西：`Attr` 和 **展开后的 `[]Slice`**。

```go
func (o *openfiles) OpenCheck(ino Ino, attr *Attr) bool {
    of, ok := o.files[ino]
    if ok && time.Since(of.lastCheck) < o.expire {   // --open-cache，默认 0（关闭）
        *attr = of.attr; of.refs++; return true
    }
    return false
}
```

- 默认 `--open-cache=0`，即**每次 open 都回元数据引擎**，保证多客户端场景下能看到别人的修改。
- 打开时若 `mtime` 未变，继承 `KeepCache=true`（`pkg/meta/openfile.go:140`），
  内核页缓存得以保留——这是 close-to-open 一致性的实现点。
- `Write`/`Truncate`/`Fallocate` 之后本地 `InvalidateChunk`（`pkg/meta/base.go:2177`），
  同时 `reader.Invalidate` 使 VFS 读缓冲失效。
- 缓存有条目上限和 12 小时强制淘汰，后台 `cleanup` goroutine 按"每轮最多扫 1000 个"的
  自适应节奏运行（`pkg/meta/openfile.go:68`）。

**这个缓存只对本客户端有效，没有任何跨客户端失效机制。** 其他客户端的写入对本客户端的可见性，
完全由 `open-cache` / `attr-cache` / `entry-cache` 的超时决定。

## 6. Session 管理

客户端挂载时创建 session（`pkg/meta/base.go:790`）：

1. 从 `nextSession` 计数器领一个 sid
2. 写入 `SE{sid}`（过期时间）、`SI{sid}`（版本/主机名/IP/挂载点/PID）
3. 启动后台 goroutine：统计 flush、目录统计 flush、配额 flush、
   删除 slice 的 worker（`MaxDeletes` 个，默认 10）
4. 非只读且未禁后台任务时，再启动：清理已删文件、清理 slice、清理回收站、清理符号链接缓存

session 的用途：

- **崩溃恢复**：`CleanStaleSessions` 清理超过 5 分钟无心跳的 session，释放它持有的
  文件锁和 sustained inode（被打开时删除的文件）
- **可观测**：`juicefs status` 列出所有挂载点
- **锁的归属**：flock/plock 记录 sid，session 消失锁自动释放

只读挂载不创建 session（`pkg/meta/base.go:786`），因此不参与后台任务，也不占 sid。

## 7. 锁

| 类型 | 存储 | Key |
|------|------|-----|
| flock（BSD） | `F{inode}` hash / `flock` 表 | (sid, owner) → 类型 R/W |
| POSIX record lock | `P{inode}` hash / `plock` 表 | (sid, owner) → 区间记录数组 |

POSIX 锁的区间合并/分裂逻辑在 `plockRecord` 上实现。锁**不阻塞**：
`Setlk` 拿不到就返回 EAGAIN，阻塞式加锁由上层（`pkg/vfs`）轮询实现。
这在无中心协调者的架构下是必然选择——没有地方挂等待队列。

`redis_lock.go` / `sql_lock.go` / `tkv_lock.go` 分别实现，语义一致。

## 8. Quota

三个层级，检查点统一在 `checkQuota`（`pkg/meta/quota.go:276`）：

```go
1. user quota / group quota          → EDQUOT
2. 卷级 Capacity / Inodes            → ENOSPC
3. 目录 quota（需 DirStats 开启）     → EDQUOT
```

**目录配额建立在异步维护的目录统计之上**：

- 每次写/创建/删除，`updateParentStat`（`pkg/meta/quota.go:194`）把 delta 累加到内存 map
- `flushDirStat` 每秒把 delta 刷到 `U{inode}` / `dir_stats` 表
- 硬链接场景 parent 为 0 时，异步 goroutine 遍历所有父目录分别累加

因此**目录配额是弱一致的**：多客户端并发写时可以短暂超配，
`flushQuotas` 定期从引擎重新加载真实值来纠偏。这是可用性与精确性的明确取舍——
在没有中心协调者的前提下，强一致配额需要每次写都做一次全局同步读，代价不可接受。

## 9. 元数据备份与迁移

- `dump` / `load`（`pkg/meta/dump.go`、`pkg/meta/pb/`）：全量导出为 JSON 或 protobuf，
  可跨引擎迁移（Redis → TiKV 等）。
- 自动备份：挂载时按 `BackupMeta` 周期（默认 1 小时）把元数据快照写进对象存储的
  `meta/` 前缀（`pkg/vfs/backup.go`），并做保留策略淘汰。
- `redis_bak.go` / `sql_bak.go` / `tkv_bak.go` 是各后端的备份实现。

这套机制补上了"元数据引擎自身故障"这个单点风险的一部分——但注意它是**周期快照，不是连续复制**，
恢复会丢失一个备份周期内的变更。生产上仍需依赖引擎自身的高可用（Redis Sentinel/Cluster、
MySQL 主从、TiKV 多副本）。

---

上一篇：[总体架构](juicefs-overview.md) ｜ 下一篇：[数据路径](juicefs-data-path.md)
