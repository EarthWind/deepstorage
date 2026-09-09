# JuiceFS 调研（三）：数据路径

> 基线：juicefs v1.5.0-dev，commit `44a5657`

## 1. 三级切分模型

```
文件 (逻辑无限长)
 └─ Chunk  固定 64 MiB，按 offset 划分，序号 = off >> 26        [不落盘，纯计算]
     └─ Slice  一次连续写入，≤ 64 MiB，全局唯一 id              [落盘，24 字节/条]
         └─ Block  默认 4 MiB，= 对象存储的一个对象             [不落盘，key 可推导]
```

三个层级各自解决一个问题：

- **Chunk** 让元数据可以按固定粒度分片，避免单个 key 里塞下一个 TB 级文件的全部索引。
  64MiB 意味着 1TB 文件有 16384 个 chunk key。
- **Slice** 是写入的原子单位与覆盖写的载体，也是引用计数、compaction、GC 的单位。
- **Block** 是 IO 的单位，也是本地缓存的单位。4MiB 是"对象存储单次请求效率"与
  "随机读放大"之间的折中。

对象 key 推导（`pkg/chunk/cached_store.go:74`）：

```go
func (s *rSlice) key(indx int) string {
    if s.store.conf.HashPrefix {
        return fmt.Sprintf("chunks/%02X/%v/%v_%v_%v", s.id%256, s.id/1000/1000, s.id, indx, s.blockSize(indx))
    }
    return fmt.Sprintf("chunks/%v/%v/%v_%v_%v", s.id/1000/1000, s.id/1000, s.id, indx, s.blockSize(indx))
}
```

key 里带 blockSize 是为了让**最后一个不满块**也能被正确推导——读的时候不需要 HEAD 请求
就知道对象多大。`blockSize(indx)` 由 slice 的总长度算出（`pkg/chunk/cached_store.go:66`）。

## 2. 写路径

```
FUSE Write
   │
   ▼
vfs.VFS.Write ──► fileWriter.Write            按 chunk 边界拆分
   │
   ▼
fileWriter.writeChunk(indx, off, data)
   │  findWritableSlice: 能续写就复用，否则新建 sliceWriter
   ▼
sliceWriter.write ──► chunk.Writer.WriteAt     写入内存 page（64KB 池化）
   │
   │  slen ≥ blockSize  ──► FlushTo() ──► 后台 goroutine 上传该 block
   │  slen == 64MiB     ──► freeze + flushData()
   │  5 秒无写入        ──► freeze + flushData()
   ▼
chunkWriter.commitThread                       每个 chunk 一个，串行按创建顺序提交
   │
   ▼
meta.Write(inode, indx, off, Slice{id,size,off,len}, mtime)
```

### 2.1 slice 复用与冻结

`findWritableSlice`（`pkg/vfs/writer.go:164`）决定这次写落到哪个 slice：

```go
for i := range c.slices {            // 从最新往回找
    s := c.slices[len(c.slices)-1-i]
    if !s.freezed {
        flushoff := s.slen / blockSize * blockSize
        if pos >= s.off+flushoff && pos <= s.off+s.slen {
            return s                 // 可以续写（不能改已刷出的 block）
        } else if i > 3 {
            s.freezed = true         // 往回找超过 4 个就把它冻结掉
            go s.flushData()
        }
    }
    if pos < s.off+s.slen && s.off < pos+size {
        return nil                   // 与已有 slice 重叠 → 必须新建
    }
}
```

三条规则：

1. **只能往后续写**，且不能写进已经 FlushTo 出去的 block 区间——因为那些 block 已经在上传了。
2. **重叠必新建**。代码里留了 `// TODO: write into multiple slices`，说明跨 slice 拆分尚未实现。
3. **超过 4 个候选就冻结**，避免一个 chunk 内维持大量半活跃 slice 占内存。

顺序写因此天然合并成一个 64MiB 的大 slice；随机写则每次一个新 slice——
这就是随机写场景 slice 数暴涨、进而触发 compaction 的根源。

### 2.2 块上传时机

`sliceWriter.write`（`pkg/vfs/writer.go:131`）：

```go
if s.slen == meta.ChunkSize {          // 写满 64MiB
    s.freezed = true; go s.flushData()
} else if int(s.slen) >= f.w.blockSize {
    s.writer.FlushTo(int(s.slen))      // 满一个 block 就发出去
}
```

`FlushTo`（`pkg/chunk/cached_store.go:479`）把**完整覆盖**的 block 交给后台 goroutine 上传，
`uploaded` 水位单调前进。`Finish`（`pkg/chunk/cached_store.go:497`）刷完尾块并等待所有
in-flight 上传完成——这是唯一的同步点。

内存页管理：每个 block 由若干 64KB 的 `Page` 组成（`pageSize = 1<<16`），从池中分配；
上传时若只有一个 page 直接用，否则拷贝合并成一个连续 block（`pkg/chunk/cached_store.go:400`）。

### 2.3 提交顺序与依赖链

每个 chunk 启动一个 `commitThread`（`pkg/vfs/writer.go:186`），**严格按 slice 创建顺序提交**：

```go
for len(c.slices) > 0 {
    s := c.slices[0]
    for !s.done { ... }               // 等数据上传完
    for s.dep != nil && !s.dep.committed { ... }   // 等依赖的 slice 先提交
    err = f.w.m.Write(..., meta.Slice{Id: s.id, Size: s.length, Off: s.soff, Len: s.slen}, s.lastMod)
    f.w.reader.Invalidate(...)        // 使本地读缓存失效
    c.slices = c.slices[1:]
}
```

顺序提交是**正确性要求**：slice 列表的顺序就是覆盖顺序（见
[元数据文档](juicefs-metadata.md) 2.3），乱序提交会导致旧数据覆盖新数据。

`dep` 是一个跨 chunk 的依赖（`pkg/vfs/writer.go:305`）：新 chunk 的第一个 slice
依赖前一个 chunk 里最后一个 `growing`（正在扩展文件长度）的 slice。
目的是**防止文件长度出现瞬时空洞**——如果 chunk 1 的写先提交、chunk 0 的还没提交，
其他客户端会看到一个长度已经跨过 chunk 0 但 chunk 0 内容为空的文件。

### 2.4 失败处理

`commitThread` 里元数据提交失败的分支（`pkg/vfs/writer.go:214`）：

```go
if err == syscall.ENOENT || err == syscall.ENOSPC || err == syscall.EDQUOT {
    go f.w.store.Remove(s.id, int(s.length))   // 文件没了/配额满 → 直接删掉已上传的块
} else {
    err = syscall.EIO                           // 其他错误 → 记住，下次 fsync/close 返回 EIO
}
```

注意这里的语义：**数据先落对象存储，再提交元数据**。中间崩溃会留下没有元数据引用的孤儿块，
由 `juicefs gc` 扫描清理（对比 slice id 计数器水位与对象存储实际内容）。这是"宁可泄漏、
不可丢失/错乱"的经典取舍。

### 2.5 Writeback 模式

`--writeback` 开启后（`pkg/chunk/cached_store.go:400` 内的分支）：

1. block 先写本地 staging 目录 `rawstaging/`
2. 立即向上层返回成功
3. 后台按 `UploadDelay` / `UploadHours` / `MaxStageWrite` 策略上传
4. 上传成功后 staging 文件转为正式 cache 条目（`uploaded()` → `removeStage()`）

失败降级路径写得很谨慎：staging 写入用 `WithTimeout` 包裹（`PutTimeout`，默认较长），
超时或失败就**直接走直传**，避免因本地盘慢而返回 EIO。只有 `blen < WritebackThresholdSize`
的块才走 writeback。

代价明确：**staging 中的数据只存在于本地盘**，客户端所在机器故障即丢数据。文档定位是
"临时/可重建数据 + 高写入延迟场景"。

## 3. 读路径

### 3.1 结构

```
FUSE Read
   │
   ▼
vfs.VFS.Read ──► fileReader.Read
   │   splitRange: 按已有 sliceReader 边界切分请求
   │   checkReadahead: 判断顺序性并触发预读
   ▼
sliceReader（预读缓冲单元，有状态机）
   │   run(): meta.Read(inode, indx) 拿 []Slice
   ▼
dataReader.Read(page, slices, offset)
   │   逐 slice → 逐 block
   ▼
chunk.rSlice.ReadAt
   │   本地缓存命中？ → 读本地盘
   │   否 → 对象存储 range GET
   ▼
返回
```

`sliceReader` 有明确的状态机（`pkg/vfs/reader.go:60`）：
`NEW → BUSY → READY`，并发的失效请求把它推向 `REFRESH`（读完重来）或 `BREAK`（丢弃）。
读失败按 `retry_time(trycnt)` 退避重试，超过 `maxRetries` 返回 EIO，
并且失败时会 `InvalidateChunkCache`——防止缓存里存了坏的 slice 列表反复失败。

### 3.2 预读启发式

这是读路径最有意思的部分（`pkg/vfs/reader.go:419`）。每个文件句柄维护
**2 个 session**（`readSessions = 2`），用来同时识别两条交错的顺序流：

```go
func (f *fileReader) checkReadahead(block *frange) int {
    ses := &f.sessions[f.guessSession(block)]
    seqdata := ses.total          // 该 session 累计的顺序读量
    readahead := ses.readahead
    used := readBufferUsed.Load()

    if readahead == 0 && blockSize <= readAheadMax && (block.off == 0 || seqdata > block.len) {
        ses.readahead = blockSize                    // 起步：一个 block
    } else if readahead < readAheadMax && seqdata >= readahead && readAheadTotal > used+readahead*4 {
        ses.readahead *= 2                           // 顺序命中且缓冲充裕 → 翻倍
    } else if readahead >= blockSize && (readAheadTotal < used+readahead/2 || seqdata < readahead/4) {
        ses.readahead /= 2                           // 缓冲吃紧或不够顺序 → 减半
    }
    if ses.readahead >= blockSize {
        f.readAhead(&frange{block.end(), ses.readahead})
    }
}
```

**倍增/减半 + 全局缓冲水位反馈**。关键在第三条：预读窗口不只看单流的顺序性，
还看全局 `readAheadTotal` 水位——多个文件同时顺序读时会自动互相退让，
避免预读把内存吃光。`readAheadTotal = BufferSize * 80%`（默认 300M → 240M，
`pkg/vfs/reader.go:710`），`readAheadMax` 默认 `8 * blockSize = 32MiB`（`cmd/mount.go:414`）。

`readAhead`（`pkg/vfs/reader.go:529`）还会检查"下一个 block 是否已经 READY"，
是则把窗口缩掉半个 block——避免重复预读已经在手的数据。

反向的资源回收也做了三层：

- `cleanupRequests`：请求完成后丢弃与当前请求无重叠、且 30 秒未访问或不再被任何 session
  需要的缓冲；超过 `maxRequests` 强制丢弃
- `releaseIdleBuffer`：空闲缓冲按 1 分钟回收，**超水位时按超出倍数线性缩短空闲时间**
  （`idle /= used/readAheadTotal`）
- `need(block)`：判断某个缓冲区是否还落在任一 session 的预期窗口内

### 3.3 小随机读的短路

`rSlice.ReadAt`（`pkg/chunk/cached_store.go:155`）有一个明确的旁路：

```go
if (!store.conf.CacheFullBlock || in-mem-only) &&
   (!store.conf.CacheEnabled() || (boff > 0 && len(p) <= blockSize/4)) {
    // 直接对对象存储发 range GET，读多少要多少，不缓存整块
}
```

即：**非块首、且请求小于 1/4 block 时，直接 range GET**，不拉整个 4MiB 块。
这避免了随机小读把 64 倍的数据拉下来。反之顺序读或块首读则拉整块并缓存，
为后续读服务。

## 4. 缓存体系

四层，从近到远：

| 层 | 位置 | 大小 | 内容 | 失效 |
|----|------|------|------|------|
| 内核页缓存 | 内核 | 系统内存 | 文件页 | mtime 变化时 open 不带 KeepCache |
| 读缓冲 / 写缓冲 | 客户端内存 | `--buffer-size`，默认 300M | 预读的 block、待上传的 page | 写提交后 Invalidate |
| 本地磁盘缓存 | `--cache-dir` | `--cache-size`，默认 100G | 完整 block 文件 | LRU / 2-random / none |
| 对象存储 | 远端 | — | — | — |

### 4.1 本地磁盘缓存

`pkg/chunk/disk_cache.go`（1583 行，是 chunk 包里最大的文件）。要点：

- **多目录一致性哈希**：多个 cache dir 时用 `consistenthash`（100 虚拟节点，murmur3）
  映射 key → 目录（`pkg/chunk/disk_cache.go:1165`）。加减盘只迁移一部分 key。
  代码里同时保留了 `getStoreLegacy`，说明做过哈希算法变更且需要兼容旧布局。
- **淘汰策略**（`pkg/chunk/cache_eviction.go`）：`none` / `2-random` / `lru`，
  统一在 `KeyIndex` 接口后面。`2-random` 是"随机取两个淘汰更旧的"——
  近似 LRU 但不维护链表，内存开销更低。
- **多重保护**：`checkFreeSpace`（按剩余空间比例动态调低容量上限）、`cleanupExpire`
  （按 `CacheExpire` 过期）、`cleanupFull`（超容量淘汰）、`scanCached`（重启后扫描重建索引）、
  lock file 防止两个进程用同一个 cache dir。
- **校验**：`CacheChecksum` 支持对缓存块做校验，防止本地盘静默损坏被当成正确数据返回。

### 4.2 缓存预热与管理

- `juicefs warmup` → `FillCache` 消息（`pkg/vfs/fill.go`），把指定路径的块提前拉到本地
- `EvictCache` 主动逐出
- `CheckCache` 查询命中情况

## 5. 对象存储抽象层

### 5.1 接口

`object.ObjectStorage`（`pkg/object/interface.go:80`）约 15 个方法。
`Get` 带 `off, limit` 支持 range 读，这是随机读性能的前提。
`List` 同时支持 marker 与 continuation token 两种分页，兼容不同厂商。

约 30 个实现：S3、OSS、COS、OBS、KS3、QingStor、UFile、Azure、GCS、Ceph(rados)、
Swift、HDFS、SFTP、NFS、CIFS、WebDAV、Storj、Dragonfly、本地文件、内存等。

### 5.2 装饰器链

对象存储实例是层层包装出来的：

```
限速(withLimiter) → 分片(withShards) → 加密(withEncrypt) → 压缩(withCompress) → 实际后端
```

- **压缩**（`pkg/compress`）：LZ4 / Zstd，block 级别，格式化时固定。
- **加密**（`pkg/object/encrypt.go`）：数据用对称算法（AES-GCM / ChaCha20-Poly1305 / SM4-GCM），
  每个对象一个随机数据密钥，数据密钥用 RSA 或 SM2 公钥包装后存在对象头部。
  私钥可用 passphrase 保护。另有 `encrypt_chunked.go` 支持分段加密以便 range 读。
- **分片**（`Shards`）：把 key 按 hash 打散到 N 个 bucket，绕过单 bucket 的 QPS 限制。
- **限速**：上传/下载各自的令牌桶，`UploadLimit`/`DownloadLimit` 可在 format 里固化。

### 5.3 并发与超时

`cachedStore` 用带缓冲 channel 做并发控制（`pkg/chunk/cached_store.go`）：

- `currentUpload`：`MaxUpload` 个槽（默认 20）
- `currentDownload`：`MaxDownload` 个槽
- `GetTimeout`（默认 60s）/ `PutTimeout`
- `MaxRetries` 次重试
- `singleflight.go`：同一个 block 的并发下载合并成一次请求

## 6. 数据路径的默认参数

| 参数 | 默认值 | 影响 |
|------|--------|------|
| `--block-size` | 4 MiB | 对象大小，format 后不可改 |
| Chunk 大小 | 64 MiB | 编译期常量 `ChunkBits=26` |
| `--buffer-size` | 300 MiB | 读写缓冲总量 |
| `--max-readahead` | 8 × blockSize = 32 MiB | 单流预读上限 |
| readAheadTotal | buffer × 80% = 240 MiB | 全局预读上限 |
| `--prefetch` | 1 | 随机读时并发预取的块数 |
| `--cache-size` | 100 GiB | 本地盘缓存 |
| `--max-uploads` | 20 | 并发上传 |
| `--max-deletes` | 10 | 并发删除 |
| `--get-timeout` | 60s | 单次对象读超时 |
| `--attr-cache` / `--entry-cache` | 1s | 内核属性/目录项缓存 |
| `--open-cache` | 0（关闭） | 客户端 open 缓存 |
| `--trash-days` | 1 | 回收站保留 |

---

上一篇：[元数据引擎](juicefs-metadata.md) ｜ 下一篇：[空间回收与一致性](juicefs-gc-consistency.md)
