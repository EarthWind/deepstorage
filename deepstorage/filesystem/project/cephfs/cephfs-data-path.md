# CephFS 文件布局与数据路径

## 1. 核心判断

CephFS 数据路径的本质是：**MDS 授权并返回 file layout，客户端把文件 offset 确定性映射成 RADOS object，再用 OSDMap + CRUSH 直连 PG primary。** 没有逐对象 metadata lookup，也没有集中式 data gateway。

这个设计非常适合并行大文件和统一 RADOS 治理；对海量小文件则需看到另一面：默认不 inline、不 packing，每个 inode 至少要在 default data pool 留下对象/backtrace，非空文件再产生实际 payload/object metadata，固定对象开销和全对象恢复成本不可忽略。

## 2. file layout

layout 包含：

| 字段 | 含义 | 默认示例 |
|------|------|----------|
| `pool` / `pool_id` / `pool_name` | 数据对象所在 RADOS pool | 创建 FS 时的 default data pool |
| `pool_namespace` | pool 内 RADOS namespace | 空 |
| `stripe_unit` | 每个连续条带单元的字节数 | 4 MiB |
| `stripe_count` | 一个逻辑 stripe 中并行对象数 | 1 |
| `object_size` | 单个 RADOS object 的逻辑大小 | 4 MiB |

layout 可通过 `ceph.file.layout` / `ceph.dir.layout` 虚拟 xattr 查看或设置。目录 layout 是新子文件的模板：文件创建时复制最近祖先的显式 layout，之后修改父目录不会改变或迁移既有文件。非空文件不能再更改 layout。

默认 `stripe_count=1` 不代表 CephFS 只能单 OSD I/O；不同 file objects 会按 hash/PG/CRUSH 分散。提高 `stripe_count` 主要改变单个连续文件区域在多个对象间的轮转方式，适合高并发大 I/O，但也增加小 I/O fan-out、失败面和调优复杂度。

## 3. offset 到 object 的映射

设：

- `su = stripe_unit`
- `sc = stripe_count`
- `os = object_size`
- `stripes_per_object = os / su`

对文件 offset：

```text
stripe_no      = floor(offset / su)
stripe_pos     = stripe_no mod sc
stripe_row     = floor(stripe_no / sc)
object_set     = floor(stripe_row / stripes_per_object)
object_no      = object_set * sc + stripe_pos
offset_in_obj  = (stripe_row mod stripes_per_object) * su + (offset mod su)
```

概念对象名为 `<inode-number>.<object-index>`。对象名与 pool/namespace 一起映射到 PG；客户端再使用当前 OSDMap 和 CRUSH rule 计算 acting set。

### 3.1 默认布局

默认 `su=os=4 MiB, sc=1` 时映射退化为：

```text
object_no     = floor(file_offset / 4 MiB)
offset_in_obj = file_offset mod 4 MiB
```

一个 10 MiB 文件对应 3 个逻辑 data objects。最后一个对象只写实际数据，BlueStore 不会因为逻辑 `object_size=4 MiB` 必然预分配完整 4 MiB，但仍有每对象的 PG/BlueStore/RocksDB 元数据和恢复枚举成本。

### 3.2 大 object 风险

RADOS 默认 `osd_max_object_size` 为 128 MiB。官方不建议盲目提高上限：超大 object 会拉长单操作、recovery、scrub 和 EC 重建粒度。CephFS layout 不是简单地“object 越大越快”；应匹配应用 I/O size、并发和故障恢复目标。

## 4. 读路径

1. 应用 `open/read`，客户端通过 cache 或 MDS 得到 inode、layout 和读取所需 caps。
2. 客户端按 offset 拆出一个或多个 object extents。
3. 通过 OSDMap/CRUSH 找 PG/OSD 并发起 RADOS read；MDS 不在数据流中。
4. 有 `FILE_CACHE` cap 时，数据可进入客户端 page/object cache；后续读取在 cap 有效且未被 recall 时命中本地。
5. OSD 返回 checksum 校验后的数据；若 PG degraded，读可能由剩余 replica/EC shards 重构，延迟上升。

cache miss 的读延迟主要由客户端到 OSD 网络、PG primary、BlueStore/介质和 degraded recovery 决定，而不是 MDS；首次 path/open/cap 获取仍可能受 MDS 影响。

## 5. 写路径

1. 客户端从 MDS 获取 `FILE_WR`，在无冲突时还可获得 `FILE_BUFFER`/`FILE_EXCL` 等更强 caps。
2. buffered write 先进入客户端缓存；同步/无 buffer cap 的写直接形成 RADOS ops。
3. 客户端把 extent 分解到 file objects，直连对应 PG primary。
4. primary OSD 按 pool 类型协调 replicated copies 或 EC shards，并在 RADOS 完成条件满足后返回。
5. 客户端维护 size/mtime 等 dirty cap metadata，按 `fsync`、close、cap recall 或后台 writeback 送回 MDS。
6. MDS 把 inode metadata 变更 journal 化并最终 flush 到 metadata pool。

数据和 metadata 是两条相关但独立的管线。`fsync` 的意义正是等待相关数据写回和 metadata/unsafe 状态达到可报告的持久边界；普通 buffered `write()` 或成功 `fclose()` 不提供同等级保证。官方 [full filesystem 文档](https://docs.ceph.com/en/tentacle/cephfs/full/) 明确指出，空间耗尽可能到 `fsync` 才报告，成功 `fclose` 不保证数据已落盘。

## 6. replicated 与 erasure-coded data pool

### 6.1 metadata pool

必须使用 replicated pool。CephFS metadata 大量使用 RADOS OMAP，EC pool 不支持该数据结构；更重要的是 metadata PG 丢失可能让整个 namespace 不可访问。官方建议 metadata pool 至少 3 副本，4 副本也不极端，并使用专用低延迟 SSD/NVMe。

### 6.2 default data pool

所有 inode 的 backtrace 位于 default data pool 的第一个 object。官方建议 default data pool 使用 replicated pool，以优化这些小对象更新和灾难恢复信息读取。它在文件系统创建后不能替换成另一个 default pool。

### 6.3 附加 EC pool

CephFS data pool 可使用 EC，但需满足：

- BlueStore backend；
- `allow_ec_overwrites=true`，因为文件支持原位覆盖/truncate；
- 可在支持的 EC profile 上启用 `allow_ec_optimizations=true`，改善小文件和频繁修改；
- metadata pool 仍不能 EC；
- 通过目录 layout 把合适的新文件导向 EC pool。

EC 的收益是容量效率，成本包括 partial-stripe read-modify-write、更多 shard/network ops、degraded read 重构与更复杂恢复。小随机覆盖、数据库 WAL、频繁 truncate 不应仅因“节省空间”就迁到 EC；应分别压测完整 stripe 顺序写、4–64 KiB random overwrite、fsync、degraded I/O 和 recovery 干扰。

## 7. CRUSH 与位置计算

CephFS 不为每个 file object 保存一条“对象→服务器”的中心映射。客户端和 OSD 对同一个 OSDMap/CRUSHMap epoch 做确定性计算：

```text
(pool, namespace, object_name)
        → hash / PG
        → CRUSH rule
        → failure-domain-aware acting set
```

优点：

- 无中央 chunk map 查询热点；
- OSD 扩容/故障通过 map epoch 与 PG peering/rebalance 处理；
- replicated/EC 和 host/rack/zone 故障域统一在 pool/CRUSH policy 表达。

代价：

- map 更新和 PG 状态是正确性路径的一部分；
- 集群 map 大、频繁 churn 或网络分区会影响所有客户端；
- placement 变化可能触发大量后台 recovery/backfill，与前台 CephFS 争用 OSD/network。

## 8. checksum、复制与加密

BlueStore 对 metadata 和 data 落盘做 checksum，data 默认 `crc32c`；checksum 用于发现 silent corruption，不提供保密性。副本/EC 提供冗余与修复，但不能替代备份和独立故障域。

加密需要分层理解：

- msgr2 `secure`：传输加密；普通 daemon/client 默认 mode 顺序为 `crc secure`，即优先 CRC，不应假设默认全链路加密。
- `ceph-volume --dmcrypt`：OSD device at-rest encryption；是设备层加密，不是文件/租户级密钥隔离。
- CephX：身份认证与 capability authorization，不等于传输/静态数据加密。

生产安全基线应显式强制 msgr2 secure、部署 dm-crypt/KMS 策略、限制 CephX pool/path caps，并验证 kernel/FUSE/gateway 的实际协商结果。

## 9. 小文件行为

CephFS 曾提供小于约 2 KiB 的 inline data experimental feature，但在 Tentacle 文档中已 deprecated、默认关闭；所有常规 file data 放在 RADOS objects 中。不能把它当成生产 packing 方案。

海量小文件成本包括：

- directory dentry + inline inode metadata；
- default data object/backtrace 和非空 payload object；
- 每对象 BlueStore/RocksDB/PG accounting；
- create/open/close/cap/journal 操作；
- snapshot metadata versions；
- scrub、purge、recovery 和灾难扫描对象数。

这和“4 MiB object_size 会浪费 4 MiB 容量”不是一回事：对象可稀疏存储，但 object count 的控制面与 metadata 固定成本仍真实存在。

## 10. truncate、sparse file 与最大文件

CephFS 支持 overwrite/truncate/sparse file，但不显式维护每个文件已分配 extent map。因此：

- `st_blocks` 以 size/block size 估算，sparse holes 也计入，`du` 可能高估；
- recursive directory size 也计入 holes；
- 文件逻辑 size 过大时，delete/stat 等操作可能需要枚举大量“可能存在”的 objects；
- 默认 `max_file_size` 为 1 TiB，可提高但应评估 purge/recovery 成本，而不只是应用上限。

## 11. unlink 与 Purge Queue

unlink 的 namespace 成功点和物理空间回收分开：

1. MDS 从 namespace 删除 dentry；仍有 open handle/hard link 时 inode 进入相应 stray/open 状态。
2. 可真正删除时，把包含 file size/layout 的 purge item 写进该 rank 的 purge queue journal。
3. 后台按小批次并发向 OSD 删除数据 objects。
4. 完成后更新 purge journal/状态。

每个 MDS rank 有独立 Purge Queue。默认最多并发 purge 64 个文件、8192 个 RADOS ops，并按每 PG 0.5 ops 的参数约束。若删除速度长期大于 purge 速度，namespace 已空但 data pool used 仍增长，`du` 与池占用不一致。

需要监控：

- `pq_item_in_journal`：尚未处理的文件数；
- `pq_executing`：正在 purge 的文件；
- `pq_executing_ops`：在途 RADOS object deletes；
- pool used/available、PG latency 和 client foreground latency。

提高 purge 并发会把压力转移到 OSD/PG，不是免费加速；应在前台 SLO、recovery/scrub 与容量水位之间限速。

## 12. 对 LightStore data plane 的启示

### 值得吸收

1. SDK 获得完整 Location/placement/epoch 后直连 DataServer，避免每个 record 查中心 map。
2. layout/pool policy 采用目录/租户级继承，但文件创建后固定，变更走显式 migration。
3. checksum、failure domain、replica/EC generation 和 repair 都成为持久协议字段。
4. namespace delete 与物理 reclaim 分离，并把 backlog/估算 bytes 做成一等指标。
5. 提供类似 backtrace 的反向恢复线索，但不依赖全池 scan 作为主要 RTO。

### 保留差异

1. 继续使用 append-only volume packing，避免每个小记录一个物理对象。
2. Location 使用 `volume_id + offset + length + generation/checksum`，GC 后用原子/epoch 化重定向。
3. EC 以大 volume/segment 为单位形成完整 stripe，减少小文件 partial-stripe 写放大。
4. 对逻辑/物理/可回收/快照占用分别计量，避免 `du` 一类近似值成为计费事实源。
