# JuiceFS 调研（四）：空间回收与一致性

> 基线：juicefs v1.5.0-dev，commit `44a5657`

append-only 的 slice 模型让写入路径极其干净，代价全部转移到了这一侧：
碎片要合并、被覆盖的数据要回收、删除要延迟、而这一切都得在**没有中心协调者**的前提下完成。

## 1. Compaction

### 1.1 触发

| 触发点 | 条件 | 模式 |
|--------|------|------|
| `Read` | 该 chunk 的 slice 条数 ≥ 5 | 异步 |
| `Write` | `numSlices % 100 == 99` 或 `> 350` | 异步 |
| `Write` | `numSlices ≥ maxSlices (2500)` | **同步阻塞** |
| `juicefs compact` | 手动 | 同步 |

同步 compaction 是硬性反压：写得太碎，就让写变慢。这防止了单个 chunk 的 slice 列表
无限增长导致读放大失控。

### 1.2 并发限制

`compactChunk`（`pkg/meta/base.go:2809`）用 `(inode, indx)` 组合 key 做去重：

```go
k := uint64(inode) + (uint64(indx) << 40)
if once || force {
    for m.compacting[k] { sleep(10ms) }      // 强制模式：等
} else if len(m.compacting) > 10 || m.compacting[k] {
    return                                    // 尽力模式：单客户端最多 10 个并发 compaction
}
```

注意这个限制是**客户端本地的**。N 个客户端挂载同一个卷，理论上可以有 10N 个 compaction
并发跑。冲突由后面的 CAS 兜底。

### 1.3 skipSome：不重复搬运大块

`skipSome`（`pkg/meta/slice.go:183`）是个务实的优化。合并之前先判断：
开头的那些 slice 是不是已经足够大、且没有被后续写覆盖？是的话就跳过不动。

```go
first := ss[0]
if first.len < (1<<20) || first.len*5 < size || size == 0 {
    break        // 太小（<1MiB）或占比不足 1/5 → 值得合并
}
if !isFirst(pos, c[0]) {
    break        // 已经被后面的 slice 覆盖了 → 必须参与合并
}
skipped++
```

没有这个优化，一个 64MiB 的完整 slice 后面追加了 5 个小 slice，就要把整个 64MiB
重新下载、合并、上传一遍。有了它，只合并尾部的小碎片。

### 1.4 执行与 CAS 提交

```
1. doRead 取出全部 slice（超过 maxCompactSlices=1000 则截断）
2. skipSome 跳过头部大块
3. compactChunk(compacted) → 计算合并后的扁平视图 (pos, size, []Slice)
4. NewSlice 领一个新 id
5. newMsg(CompactChunk, slices, id, tier)
      → 回调到客户端：读出这些 slice 的数据，合并写成一个新 slice 上传对象存储
6. 如果开启了 trash，把旧 slice 编码进 dsbuf（延迟删除列表）
7. en.doCompactChunk(inode, indx, origin, compacted, skipped, pos, id, size, dsbuf)
```

第 7 步是关键：`origin` 是**合并前的完整 slice 列表的序列化**。
后端实现（如 `pkg/meta/redis.go` 的 `doCompactChunk`）在事务里比对当前 chunk 的内容
是否仍等于 `origin`，相等才替换。这是一个 **compare-and-swap**——
如果这期间有别的客户端写入了新 slice 或抢先完成了 compaction，CAS 失败，本次合并作废，
新上传的 slice 变成孤儿，由 GC 回收。

代码里还有一段防御性注释（`pkg/meta/redis.go:3814`）：

```go
// there could be false-negative that the compaction is successful, double-check
```

即 CAS 结果本身可能因为网络原因判断错误，需要二次确认合并出来的 slice 到底有没有被采用，
没被采用则删掉。**在无中心协调的架构里，每一步都要假设自己可能失败且不知道自己失败了。**

## 2. Slice 引用计数

Key：`Kcccccccc nnnn`（TKV）/ `sliceRef` hash（Redis）/ `slice_ref` 表（SQL）。

设计上有个省空间的技巧（`pkg/meta/redis.go:3144` 注释）：

```go
// most of chunk are used by single inode, so use that as the default (1 == not exists)
```

**key 不存在即代表引用数为 1。** 只有在 clone、compaction 保留旧 slice 等场景下
引用数才会 >1，此时才真正写入 key。绝大多数 slice 因此不占任何引用计数存储。

回收判断（`pkg/meta/tkv.go:2957`）：

```go
scan("K", func(k, v) {
    refs := parseCounter(v)
    if refs < 0      { deleteSlice(id, size) }      // 引用已归零，删对象
    else if refs == 0 { cleanupZeroRef(id, size) }   // 清理计数 key 本身
})
```

`refs < 0` 而不是 `== 0` 触发删除，是因为"默认 1"的编码：显式写入的计数是相对于
隐含的 1 的增量。

## 3. 删除路径

### 3.1 三条路径

```
unlink 一个文件
   │
   ├─ TrashDays > 0        → 移入 .trash/YYYY-MM-DD-HH/，保留期满后再删
   │
   ├─ 文件正被本进程打开    → 记入 SS{sid}{inode}（sustained），close 或 session 消失后删
   │
   └─ 其他                 → 写入 delfiles/D{inode}{length}，后台异步删块
```

### 3.2 回收站

`checkTrash`（`pkg/meta/base.go:3028`）按小时创建子目录：

```go
name := time.Now().UTC().Format("2006-01-02-15")
if name == m.subTrash.name { return m.subTrash.inode }   // 本地缓存当前小时的 trash 目录
```

trash inode 从 `TrashInode = 0x7FFFFFFF10000000` 起分配，`Ino.IsTrash()` 通过数值比较判断。
按小时分目录避免了单个目录塞进海量条目。

保留期由 `cleanupTrash` 后台任务处理，`CleanupTrashBefore(edge)` 删除早于某时刻的子目录。

### 3.3 打开时删除（POSIX 语义）

文件被打开时 unlink，POSIX 要求内容保持可访问直到最后一个 fd 关闭。
JuiceFS 的做法是把 inode 记入 session 的 `sustained` 集合：

- `Close` 时若引用归零且该 inode 在 `removedFiles` 中 → `doDeleteSustainedInode`
  （`pkg/meta/base.go:2155`）
- 客户端崩溃 → session 过期 → `CleanStaleSessions` 代为清理

这是 session 机制存在的核心理由之一。

### 3.4 延迟删除的 slice

开启 trash 时，compaction 替换掉的旧 slice 不能立即删——回收站里的文件可能还引用它们。
于是写入 `Ltttttttt cccccccc`（TKV）/ `delSlices` hash（Redis），带时间戳，
由 `doCleanupDelayedSlices(edge)` 在保留期后清理。

## 4. 后台任务的分布式协调

这是无中心架构最考验设计的地方：N 个客户端都在跑同样的后台任务，如何避免重复劳动？

答案是 **`setIfSmall` 抢占式选举**（`pkg/meta/base.go:1018`）：

```go
case <-time.After(utils.JitterIt(time.Hour)):          // 带抖动的周期，错开唤醒
    if ok, err := m.en.setIfSmall("lastCleanupFiles", now, hour*9/10); ok {
        // 只有 CAS 成功的那个客户端执行本轮任务
        ...
        if time.Since(jobStart) > 50*time.Minute {
            status = bgJobCanceled                      // 主动让出时间片
            break
        }
    }
```

三个要素：

1. **`setIfSmall`**：仅当存储的计数器值小于阈值时才更新——一个基于计数器的分布式租约。
   谁抢到谁干活，其他人这一轮跳过。
2. **`JitterIt`**：周期加随机抖动，避免所有客户端同时唤醒形成惊群。
3. **50 分钟自限时**：一轮任务最多干 50 分钟（租约 1 小时），到点主动退出，
   把机会让给下一轮的其他客户端。注释写得很直白：
   `// Yield my time slice to avoid conflicts with other clients`

后台任务清单（`pkg/meta/base.go:816`）：

| 任务 | 周期 | 作用 |
|------|------|------|
| `cleanupDeletedFiles` | 1h | 删除 delfiles 中文件的数据块（单轮最多 6e5 个） |
| `cleanupSlices` | 1h | 扫描引用计数，删除无引用 slice |
| `cleanupTrash` | — | 清理过期回收站 |
| `cleanupChangelog` | — | 修剪 changelog |
| `flushStats` / `flushDirStat` / `flushQuotas` | 秒级 | 刷本地累积的统计增量 |
| 删除 worker × `MaxDeletes` | 常驻 | 消费 `dslices` channel 实际发起对象删除 |

**这套机制的隐含前提是：至少有一个客户端长期在线。** 如果所有客户端都卸载了，
回收站永不清理、删除的数据永不释放。这是"把服务端做成客户端"的直接后果。
运维上通常靠一个常驻的挂载点或定时跑 `juicefs gc` 来兜底。

## 5. 一致性模型

### 5.1 元数据

**强一致**。所有元数据变更走引擎事务，可见性由引擎保证（Redis 单实例线性一致，
TiKV 快照隔离，SQL 按隔离级别）。

### 5.2 数据

**Close-to-open 一致性**，不是完整的 POSIX 一致性。具体来说：

| 场景 | 保证 |
|------|------|
| 同一客户端读自己的写 | 立即可见（写提交后 `reader.Invalidate`） |
| 客户端 A 写完 close，B 之后 open | 可见（B 的 open 会重新拉 attr 和 slices） |
| A 正在写，B 同时读 | **无保证**，B 看到的内容取决于 A 已提交了多少 slice |
| A、B 并发写同一区间 | **无冲突检测**，后提交的 slice 覆盖先提交的，按元数据引擎的提交顺序 |

三个可见性延迟来源：

1. **内核缓存**：`--attr-cache` / `--entry-cache` / `--dir-entry-cache`，默认 1 秒。
   这期间内核直接用缓存答复，不下探到 JuiceFS。
2. **openfile 缓存**：`--open-cache`，默认 0（关闭）。开启后 open 也可能拿到陈旧 attr。
3. **写缓冲**：数据在客户端内存里最多滞留 `flushDuration = 5 秒`
   （`pkg/vfs/writer.go:32`）才会被自动 flush，提交前对其他客户端完全不可见。

`KeepCache` 是这套机制的接口点：open 时若 mtime 与缓存的一致，就告诉内核保留页缓存
（`pkg/meta/openfile.go:140`），否则内核丢弃重读。

### 5.3 与 POSIX 的差距

- **无 write 原子性保证**：一个大 write 拆成多个 slice 分批提交，读者可能看到中间状态。
- **无 O_DIRECT 真语义**：仍走客户端缓冲。
- **文件长度的中间态**：靠 slice `dep` 依赖链缓解（见
  [数据路径](juicefs-data-path.md) 2.3），但不是事务性的。
- **fsync 是唯一的持久化点**：`Flush`/`Fsync` 会等待所有 in-flight slice 上传并提交完成。

对于大数据、AI 训练、备份归档这类"写完再读"的负载，close-to-open 完全够用。
对于数据库、需要多写者协同的负载，则不适用——这也是 JuiceFS 官方文档明确说明的定位。

## 6. 故障场景梳理

| 故障 | 后果 | 恢复 |
|------|------|------|
| 客户端崩溃（写入中） | 已上传但未提交的块成为孤儿；未上传的数据丢失 | `juicefs gc` 清理孤儿块；数据丢失由应用的 fsync 语义界定 |
| 客户端崩溃（持有锁） | 锁泄漏 | session 5 分钟过期后 `CleanStaleSessions` 释放 |
| 客户端崩溃（writeback 模式） | staging 中未上传数据丢失 | 无法恢复 |
| 元数据引擎故障 | 全卷不可用 | 依赖引擎自身 HA；周期性元数据备份可做灾难恢复（会丢一个周期） |
| 对象存储不可用 | 读写失败并重试 | `MaxRetries` 后返回 EIO |
| 所有客户端卸载 | 后台 GC 停止，空间不释放 | 重新挂载或跑 `juicefs gc` |
| Compaction 冲突 | CAS 失败，新 slice 成孤儿 | `juicefs gc` 清理 |

`juicefs fsck` 检查元数据与对象存储的一致性（引用的 block 是否都存在），
`juicefs gc` 反向检查（对象存储里的 block 是否都被引用）。这两个工具是这套
"允许泄漏、事后清理"设计的必要配套。

---

上一篇：[数据路径](juicefs-data-path.md) ｜ 下一篇：[设计评估](juicefs-analysis.md)
