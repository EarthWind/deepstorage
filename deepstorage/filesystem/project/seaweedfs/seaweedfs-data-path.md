# SeaweedFS 磁盘布局、索引与 I/O 数据路径

## 1. 技术总结

SeaweedFS 正常 volume 的快路径是 append-only data file 加 needle map。写入把完整 needle 追加到 `.dat`，再更新 id 到 offset/size 的索引；读取先查索引再定点读取并校验 cookie/CRC；更新继续追加同 id 的新版本，索引指向较新的 offset；删除追加 size 为 0 的记录并把索引标成 deleted。空间回收由 Vacuum 复制 live needle 到新文件完成。

最关键的工程边界有三项：

1. 默认 write 不调用 `Sync()`，`fsync=true` 才进入 group-commit 路径；
2. 数据 append 和 index update 不是一个外部事务，启动恢复与 watermark/索引重建必须处理中断；
3. replication 在本地 append 后执行，远端失败不会回滚已写数据。

## 2. Needle 磁盘格式

4.41 正常 needle 包含：

```text
+---------+-----------+------+----------------------------------+
| cookie  | needle id | size | variable data and attributes     |
| 4 bytes | 8 bytes   | 4 B  | data/name/mime/pairs/ttl/mtime   |
+---------+-----------+------+----------------------------------+
| CRC32 | append timestamp (v3) | 8-byte alignment padding       |
+-------+-----------------------+--------------------------------+
```

注意：

- `size` 是 needle body 大小，不等于原始文件 cleartext size；
- 自动 gzip 或 filer encryption 会改变 on-disk 数据大小；
- cookie 和 id 同时参与读取验证；
- CRC 主要覆盖 needle data，不覆盖所有 volume/EC padding/parity；
- v3 `AppendAtNs` 使用 `max(now, last+1)` 维持本 volume 内单调追加时间。

单个 needle 注释上限为 4 GB，但 Volume HTTP 默认 `fileSizeLimitMB`、Filer `maxMB`/chunking 会更早限制或拆分；大文件应经 Filer/S3 分块，而不是直接塞一个超大 needle。

## 3. Index

### 3.1 `.idx` 记录

固定记录为：

```text
needle id (8) | offset (4 or build-dependent) | size (4)
```

常规 4-byte offset 不是逐字节偏移，而由转换函数表示实际对齐 offset，从而覆盖大 volume。构建也有 5-byte offset 变体，混用二进制/格式前必须核对。

### 3.2 Needle map 选择

| 类型 | 优点 | 代价/适用性 |
| --- | --- | --- |
| memory | lookup 快；正常读可保持一次数据定点 I/O | 启动需加载索引，约 20 B/needle 级内存 |
| leveldb | 内存小、启动较快 | lookup 增加本地 DB 成本，需管理 `.ldb`/watermark |
| leveldbMedium/Large | 更多 cache/write buffer | 用内存换 LevelDB 性能 |
| sorted file/其他内部形式 | 特定只读/EC/维护路径 | 不等价于默认可写 map |

容量估算示例：

```text
index RAM ≈ needle_count × 20 B × 预留系数

1 billion live needle:
  theoretical estimate ≈ 20 GB
  production reserve (allocator/cache/rebuild) should be materially higher
```

不能只用 live object 数估算：旧/删除索引记录、volume load、Filer chunk cache、并发请求 buffer 都会占内存。

### 3.3 Index 与 data 的恢复关系

写入顺序是先 append `.dat`，再 `nm.Put`。可能出现：

- data 成功、index 失败：尾部存在未索引 needle；
- data partial：append helper 尝试 truncate 回原长度；
- fsync group 失败：尝试 truncate 整批到 batch 起点，但代码注释仍承认可能有 dirty/inconsistent data；
- LevelDB watermark 过期/大于文件等异常：从 index 重建。

因此 `.idx` 不是可以脱离 `.dat` 单独信任的业务真值。恢复工具应比较 data tail、index、append timestamp、CRC 和 watermark。

## 4. Blob 写路径

### 4.1 Assign

客户端向 Master 请求：

- count；
- replication；
- collection；
- TTL；
- data center/rack/data node；
- disk type；
- expected data size。

Master 从匹配的 writable volume layout 选择 volume，生成 needle id/cookie，返回目标和副本位置。4.41 会用 expected size 跟踪分配中的 pending bytes，降低心跳间隔内过量 assign 导致 volume 超填；未提供时按 1 MiB/文件估算。

### 4.2 本地写

Volume Server：

1. 验证写 JWT（若配置）；
2. 解析 multipart/body，生成 needle、CRC、flags；
3. 检查同 id 的旧 cookie；
4. 可选比较旧数据，完全相同时返回 unchanged；
5. 在 volume data lock 下 append `.dat`；
6. 更新 needle map；
7. 再复制到远端。

普通路径使用 `WriteAt`，没有每请求 `Sync`。

### 4.3 `fsync=true`

开启后请求进入一个最多 128 个请求或约 4 MiB 的 batch：

1. 多请求在同一个 volume worker 串行 append；
2. 一次 `DataBackend.Sync()`；
3. 成功后分别完成请求；
4. Sync 失败时尝试 truncate 到 batch 前 `end`，把已成功 append 的请求改为失败。

这是吞吐与稳定写延迟的折中。它只同步 data backend；索引 backend 自身的 durable 边界还取决于实现。复制 URL 没有携带 `fsync=true`，所以远端副本不进入这个 group commit。

### 4.4 复制

入口先查 Master/location cache 得到所有副本，然后：

- 若位置数小于 placement 要求，写前直接失败；
- 先写本地；
- 并发向所有远端发送 `type=replicate`；
- 第一个远端错误就 fail-fast，并 cancel 其他请求；
- 全部成功才返回成功。

这个实现提供“所有收到响应的远端应用成功”式同步复制，但不是原子复制事务：

```text
T0 primary append success
T1 replica A append success
T2 replica B network error
T3 client gets 500
T4 client reassigns and retries elsewhere

possible state:
  old fid exists on primary/A, absent on B
  new fid exists on another volume
```

4.41 `UploadWithRetry` 对 5xx/transport error 可重新 assign，新 FID 提交后，旧 FID 的部分 needle 成为未引用垃圾。对直接 Blob API，应用若不做幂等记录，还可能不知道哪一个 FID 应保留。

## 5. 读取路径

### 5.1 普通 volume

```text
FID -> vid location -> needle map lookup -> ReadAt(offset, disk size)
    -> parse header/body/tail -> cookie/CRC/TTL -> HTTP response
```

“O(1)”表示查找步骤不随 volume 中 needle 数线性增长；它不保证：

- 一定一次物理盘 seek（page cache、文件系统 extent、远端 block device 会改变）；
- 网络只有一次 hop；
- Filer path 和 manifest 不增加 I/O；
- 故障副本不会重试；
- 加密/压缩不会增加 CPU/内存。

### 5.2 副本选择

Master lookup 可返回多个 location。客户端/网关选一个读取，发生错误时是否尝试其他副本取决于调用者和 read mode；Volume Server 也可按 `local/proxy/redirect` 处理非本地 volume。`R=1` 快，但不会比较多个副本的版本或 checksum。

### 5.3 EC volume

EC 读需要：

1. Master 返回持有 shard 的 servers；
2. 客户端选 A；
3. A 用 EC index 找到所需 shard/block；
4. A 可能从 B 拉取数据；
5. shard 缺失时从足够的其余 shard 在线重建所需范围。

即使健康 EC volume，官方设计也承认通常比正常 volume 多一次网络 hop。故障重建路径还要读取 10 个可用 shard 的对应条带。

### 5.4 Cloud Tier

只读 tiered volume 保留本地 index，把 `.dat` 放远端 S3/Rclone。读取仍由 offset/size 直接发一个 range request，但成本变为：

- 对象存储请求延迟/费用；
- TLS/公网网络；
- 远端 availability；
- range GET 的最小计费和吞吐。

它是 O(1) request count 的近似，不是本地盘级 latency。

## 6. 更新路径

### 6.1 同 FID 覆盖

新 needle 使用同 id/cookie 追加到尾部，index 更新到新 offset。旧字节保留为 garbage。`AppendAtNs` 帮助 tail/sync 判断新旧。

风险：

- 并发写同 FID 由单 volume lock 串行，但跨副本顺序依赖转发完成；
- 客户端超时重试可能追加相同内容；`isFileUnchanged` 仅在 TTL 空、能读旧 needle 且 cookie/checksum/data 相同才优化；
- 部分复制失败会造成副本 index 指向不同最新版本。

SeaweedFS 更适合 immutable/new-FID 模型，不适合高频原地覆盖。

### 6.2 Filer offset/append write

Filer 会：

- 上传新的 chunk；
- 调整 chunk 的逻辑 offset；
- 合并旧 chunk list；
- compact 被覆盖的 chunk view；
- 必要时 manifestize；
- 写回 entry；
- metadata 成功后删除被覆盖 chunk。

同一文件的 overlapping chunks 由时间戳/offset 视图决定可见范围。并发 append/offset write 必须依赖 Filer owner serialization/condition；普通 HTTP 路径和多 Filer 部署需要实测 lost update。

## 7. 删除路径

正常 volume 删除：

1. 读取 needle，验证 cookie；
2. 对 chunk manifest 先递归删除子 chunk；
3. 本地 append 一个 zero-size/tombstone needle；
4. needle map 标 deleted；
5. 并发向远端发送 delete。

固定源码明确有注释：

> delete info is always appended no fsync, it may need fsync in future

因此即便业务写入使用 `fsync=true`，删除 ACK 后的抗断电性也不是同一等级。远端 delete 失败会返回错误但本地 tombstone 已生效，仍可能副本分歧。

EC volume 不支持更新，但支持删除；删除 id 追加到 `.ecj`，并在 durable journal 后更新内存 deleted set。物理 shard 空间不会立即收回。

## 8. Filer chunking

### 8.1 小文件 inline

小于 `SaveToFilerLimit` 的内容可放进 Filer entry `Content`，减少 Volume I/O，但：

- 增大 Filer Store value、metadata log 和 cache；
- 备份/复制元数据就携带数据；
- 数据 durability 变成 Filer Store durability；
- 不同 Store 有 row/value 大小与吞吐限制。

### 8.2 大文件 chunk

Filer 默认按 `maxMB` 切块，最多 4 个 buffer 并发上传。内存粗略为：

```text
upload buffer upper bound per request ≈ 4 × chunkSize
concurrent memory ≈ requests × 4 × chunkSize + protocol/cipher overhead
```

实际代码一次最多 4 个 buffer，官方旧优化文档用并发读 × 32 MB 做保守估计。必须用 heap profile 校准。

### 8.3 失败清理

任何 chunk 上传失败时，Filer 遍历已上传/失败 FID 调用 `DeleteUncommittedChunks`。metadata commit 失败也做同样清理。这是合理补偿，但不是两阶段提交：

- cleanup RPC 也会失败；
-复制写本身可能留下部分副本；
- FID 已重新 assign；
- volume append-only，删除只新增 tombstone。

需要 `volume.fsck`、未引用 chunk 检查和 Vacuum 作为最终闭环。

## 9. 数据完整性

| 层 | 机制 | 能检测什么 | 检测不到/不会自动做什么 |
| --- | --- | --- | --- |
| Needle | CRC32/CRC32C 相关实现 | 被读取 needle data 损坏 | 未读取 parity/padding；不会自动巡检所有数据 |
| Index | size/id/offset 与 data parse | 错 offset、size mismatch、坏 header | 需要 scrub/rebuild 才覆盖冷数据 |
| Replication | 多完整副本 | 节点/盘丢失后读其他副本 | `R=1` 不比较副本；不会自动修正静默分歧 |
| EC | RS(10,4) | 最多 4 个缺失 shard | 不能自行识别“存在但错误”的 shard |
| EC `.ecsum` | 每 16 MiB block CRC32C + sidecar 自校验 | 冷 parity/data block bitrot | 需要显式 `ec.scrub`；缺 sidecar 表示 feature off |
| Vacuum scrub behavior | 复制 live needle 时读取校验 | 会遇到并记录 unreadable needle | 4.41 路径可能丢弃坏 entry，不能把 Vacuum 当无损修复 |

## 10. 性能和可靠性含义

### 写放大

```text
hot replication physical write ≈ logical bytes × copy_count
+ needle headers/padding/index
+ retry/partial-write garbage

overwrite-heavy:
physical until vacuum ≈ all historical appended bytes × copy_count
```

### 读放大

- 正常 needle：约一次 index lookup + 一次 data read；
- Filer multi-chunk：chunk 数/并发决定；
- manifest：先读 manifest；
- EC：通常额外网络 hop，故障时 10-way reconstruction；
- cloud tier：一个或多个远端 range GET。

### 恢复放大

修一个丢失的 10 KB 对象所在副本，通常复制整个 volume，而不是 10 KB。恢复吞吐受最慢源盘、目标盘和网络限制。

## 11. PoC 验证

必须对以下时序做数据对账：

1. primary append 后、replica fan-out 前 kill；
2. 一个 replica 成功、另一个超时；
3. `fsync=false/true` 下 primary 断电与 replica 断电；
4. delete ACK 后立即断电；
5. index update 前/后崩溃，重启后 FID 可读性；
6. 反复覆盖同 FID，Vacuum 前后 checksum；
7. Filer 4-way chunk 上传中一块失败；
8. metadata Store commit 超时但实际已提交；
9. EC 正常、缺 1 shard、缺 4 shard、存在 bitrot；
10. cloud tier range read、远端限流和 tier compact 中断。

## 12. 小结

SeaweedFS 的快来自紧凑索引和 append-only volume，而不是来自全局事务。正常 immutable workload 能充分利用这一设计；覆盖写、严格断电持久性和跨层原子性需要额外工程。生产设计应把“HTTP 成功”“本地 append”“本地 fsync”“所有副本 fsync”“Filer metadata commit”分别建模和监控。
