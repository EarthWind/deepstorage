# GlusterFS 性能模型与压测方法

## 1. 不给脱离环境的“单节点性能数字”

GlusterFS 性能由 translator graph、volume topology、文件大小分布、目录形态、client 数、网络 RTT、后端 filesystem/cache 和故障状态共同决定。任何没有同时说明以下条件的 MB/s 或 ops/s 都不可用于选型：

- Gluster/client/server 版本与 op-version；
- FUSE 或 libgfapi/NFS/SMB；
- distributed/replica/arbiter/disperse topology；
- bricks、nodes、failure domains；
- XFS/盘/NIC/CPU；
- file count/size/directory fanout；
- sync/direct/cache 模式；
- heal/rebalance/snapshot/scrub 状态；
- P50/P99/P99.9 和 errors，而非只有平均吞吐。

本章给出性能因果模型和可复现 PoC，而不编造通用峰值。

## 2. 延迟分解

### 2.1 Lookup

健康 warm-cache 的最后一级 file lookup 近似：

```text
client/FUSE scheduling
+ DHT hash compute
+ one replica/disperse-set lookup fanout/selection
+ slowest required brick RPC + local inode/xattr lookup
+ unwind/cache update
```

以下情况增加一轮或全局 fanout：

- hashed child 是 linkfile；
- DHT layout/cache miss；
- lookup-unhashed/everywhere；
- AFR pending 需要查询/heal；
- EC 需要 K responses；
- path 每一级都 cache miss。

所以 `stat /a/b/c` 的冷路径不是一次 RPC，而可能是 depth × lookup chain。

### 2.2 Replicated write

忽略 write-behind 提前返回，durable replicated write 的下层延迟近似：

```text
internal lock RTT
+ changelog/dirty xattr phase
+ max(required replicas: network + backend write)
+ post-op xattr/durability
+ unlock
+ fsync barrier（若应用调用）
```

默认 eager-lock 和 optimistic changelog 试图省掉/合并部分往返。多 writer 竞争、一个慢 replica、xattr latency 或 fsync 抖动会直接进入 P99。

### 2.3 EC partial write

```text
lock
+ max(K old-fragment reads)
+ decode/merge/encode CPU
+ max(required N/quorum fragment writes)
+ metadata/dirty update
+ unlock/fsync
```

完整 stripe 顺序写可去掉 old read；4 KiB random write 通常无法。EC 容量效率必须与 RMW、degraded read、heal bandwidth 一起比较。

### 2.4 Metadata operations

`mkdir`/directory rename 访问所有 DHT subvolumes，再在每个 child 内访问 replicas/fragments。尾延迟由最慢 child 主导，近似 fanout barrier：

```text
latency ≈ max(all required child FOPs) + distributed-lock phases
```

brick 数增加会提高文件级并行度，却增加全目录操作的 straggler 概率。

## 3. 吞吐扩展模型

### 3.1 多文件顺序 I/O

当不同文件均匀 hash 到不同 DHT sets：

- aggregate read/write 可随 sets 增长；
- 每个 client 直连 bricks，没有中心 data proxy；
- AFR read 可将不同 files 分配到不同 replicas；
- 上限由总 NIC/brick/backend 和 client CPU/FUSE 决定。

前提是 filename/hash/目录 layout 足够均匀，且应用有足够并发文件。

### 3.2 单文件

未启用 sharding 时，一个普通文件属于一个 DHT child：

- replica volume 的单文件 write 要写同一 replica set，不会使用其他 sets 容量；
- read 常态从一个 replica，不能自动聚合全部 bricks；
- EC 文件可并行访问一个 disperse set 的 K/N fragments，但仍受该 set 限制；
- sharding 可让 blocks 成为多个 hidden files 分布，但引入 metadata/正确性复杂度。

不能用集群总盘数推算单流带宽。

### 3.3 Metadata throughput

create workloads 可按 basename hash 分到 sets；但：

- parent directory 在所有 sets 有副本；
- directory locks/layout state 是共享热点；
- readdir 要汇总所有 sets；
- 每文件仍产生 inode/xattr/GFID handle；
- client thread/event/RPC connections 也可能先成为瓶颈。

“无中心 MDS”避免一个 MDS CPU 上限，却没有提供自动分裂的 directory metadata shard。一个热目录无法像按 key range 分片的元数据服务那样，被拆分到多个独立 authority（例如多个共识 leader）上。

## 4. Workload 分析

### 4.1 海量小文件

主要成本不是 payload bandwidth，而是：

- create 的 DHT + AFR/EC locks/xattrs；
- XFS inode allocation/journal；
- `.glusterfs` GFID hardlink；
- directory entry/cache；
- stat/lookup RPC；
- heal index 和 full crawl；
- unlink 与 backend journal。

建议用实际 size histogram（如 0 B、1 KiB、4 KiB、64 KiB、1 MiB）分别测，不要用单一 1 MiB 文件代表。

### 4.2 大顺序文件

相对适合 Gluster：

- FOP 数相对数据量小；
- DHT 不需要 per-block placement lookup；
- replicas/EC 可流式处理；
- backend native file 顺序 I/O 高效。

仍要关注一个 set 的上限、replica write amplification、EC stripe、FUSE copies 和 slow child。

### 4.3 VM image/Database

风险组合：

- 单热文件；
- 4–64 KiB random overwrite；
- 高频 fsync/barrier；
- advisory locks/failover fencing；
- snapshot/application consistency；
- rebalance 与 sharding；
- long-lived fd/client reconnect。

Sharding 常用于此类 workload，但必须把 snapshot、heal、rebalance、truncate、discard、fallocate 和 crash recovery 放入同一 PoC。只跑 fio random write 不足以证明可用。

### 4.4 Append-only/Immutable

这是更友好的 workload：

- 避免多 writer overlap 和 truncate；
- replica/EC transaction 更顺序；
- heal source 较明确；
- 可以按文件 hash 分散。

但若每条记录一个小文件，inode/metadata 成本仍在；把许多小记录打包到大顺序 volume 的设计（Haystack 式）在这一点有结构性优势。

### 4.5 Rename/Create storm

Build tree、maildir、package registry、Git checkout 等包含大量 create/rename/unlink：

- DHT entry locks 与 cross-subvolume rename；
- linkfile；
- directory layout/cache；
- AFR entry changelog；
- XFS directory/journal IOPS。

需要 smallfile/mdtest/fsstress 类工具加真实应用 trace，不可用 fio 代表。

## 5. FUSE 与 libgfapi

### 5.1 FUSE 成本

- syscall/VFS 到 userspace client context switch；
- request copy/iobuf/page handling；
- client process scheduling/event threads；
- kernel page/attribute cache 与 userspace cache 双层；
- mount process RSS/fd 随 working set 和 brick 数增长。

FUSE 的优势是应用透明、kernel cache 和标准工具链。是否为瓶颈要用 CPU profile/ctx-switch/perf 和 libgfapi 对照，而不是先验断言。

### 5.2 libgfapi

绕过 FUSE 可能降低 context switch/copy，并允许 QEMU 等更直接控制 I/O；代价是：

- translator graph 与应用共享 address space；
- client event threads/locks/RSS 进入应用；
- 每个进程可能创建独立 brick connections；
- crash 同时失去应用与 client write-behind state；
- API/ABI/package 兼容必须验证。

PoC 应比较同一 graph、同一 durability 语义下 FUSE vs gfapi，而不是一个用 buffered write、另一个用 fsync。

## 6. Translator 选项的性能—语义权衡

| 选项 | 默认/作用 | 可能收益 | 风险/验证点 |
|------|-----------|----------|-------------|
| write-behind | 默认装载，1 MiB/file | 合并 writes、降低应用 write latency | 提前返回、延迟错误、client crash durability |
| flush-behind | on | close/flush latency | flush 不等于 durable；错误暴露时点 |
| strict write ordering | xlator 内部 default off，最终配置需查询 | 允许不相关 writes 越过 | 应用 ordering/barrier |
| quick-read | 默认装载 | 小文件 lookup+read 合并 | cache/invalidation/RSS |
| open-behind | 默认装载 | 延后 backend open | open error 延迟到后续 FOP |
| io-cache | 默认不装载 | read cache | coherence/RSS/double cache |
| read-ahead | 默认不装载 | 顺序读 | 随机 workload 浪费 |
| readdir-ahead | 默认不装载 | 目录遍历 | cache/RSS/stale listing 边界 |
| DHT lookup-optimize | on | negative lookup 少 fanout | layout/linkfile 异常需 fallback |
| DHT readdir-optimize | off | 让 non-first subvol filter entries | correctness/版本兼容需测 |
| AFR eager-lock | on | 连续写少 lock RTT | 多 writer 粗锁竞争 |
| AFR read-hash-mode | GFID hash | 稳定 read child/cache locality | 热文件集中单 replica |
| AFR choose-local | true | 减少网络读 | 各 client locality/负载不均 |
| EC stripe cache | 4 | 降连续 RMW | 每 open file 内存 `cache×stripe` |
| io_uring backend | off | 可能降低 POSIX I/O overhead | v11.2/内核/盘/错误路径成熟度 |
| brick multiplexing | 视 global 配置 | 少进程/RSS | 一个 process 影响多个 bricks |

任何调优必须以 `gluster volume get VOL all` 的实际值为准，并做故障语义回归。

## 7. 缓存测试陷阱

至少区分：

1. application cache；
2. FUSE/kernel page cache；
3. Gluster quick-read/io-cache/md-cache；
4. brick host page cache；
5. disk/controller cache；
6. snapshot/COW 和 filesystem journal。

报告中每个结果标明：

- cold/warm；
- working set 是否大于所有 cache；
- 是否 drop cache/restart client；
- `O_DIRECT` 是否真的下传（`filter-O_DIRECT`/strict option 会改变）；
- 是否 fsync；
- 数据 checksum 是否读取验证。

## 8. 后台任务干扰

### 8.1 Self-heal

占用 source reads、sink writes、network、locks 和 xattr IOPS。增大 background-heals/window 可能提高恢复带宽，也可能使业务 P99 失控。

### 8.2 Rebalance

遍历 namespace、改 layout、复制/删除 files、fsync，并可能制造 linkfile。它会改变热文件 placement，导致 cache 冷启动和新旧 clients 路由差异。

### 8.3 Bitrot Scrub

全文件内容读取 + SHA-256，I/O bound 或 CPU bound 取决于盘/CPU。biweekly 并不保证在两周内完成；应监控 start-to-complete duration。

### 8.4 Snapshot

LVM thin COW 使写入变成 allocate/copy，snapshot age 越长、变更越多，空间和 latency 越高。

### 8.5 Geo-rep

primary changelog read、source read、WAN、secondary writes 与业务竞争。WAN 恢复后 catch-up burst 应限速，避免拖垮 primary/secondary。

## 9. Benchmark 设计

### 9.1 基线矩阵

| 维度 | 建议取值 |
|------|----------|
| 接入 | FUSE、libgfapi（业务使用时）、NFS/SMB gateway（业务使用时） |
| topology | distributed（仅对照）、replica 3、2+1 arbiter、目标 EC N/R |
| clients | 1、8、32、128、目标峰值 |
| file size | 0 B、1 KiB、4 KiB、64 KiB、1 MiB、1 GiB、目标大文件 |
| directories | 单热目录、hash 分散目录、百万 entries 大目录、深路径 |
| I/O | sequential/random、read/write/mix、buffered/direct、sync/async |
| fault state | healthy、1 brick down、heal、rebalance、near-full、WAN lag |
| cache | cold、warm、working set > cache |

### 9.2 工具与目的

| 工具/方法 | 回答的问题 |
|-----------|------------|
| fio | block-like data I/O、fsync、latency histogram |
| smallfile | create/stat/read/rename/delete 小文件 |
| mdtest | metadata scaling 与目录形态 |
| fsx/fsstress | truncate/rename/write race correctness |
| application trace/replay | 真实 syscall mix 与 transaction boundary |
| checksum/manifest | 性能测试后内容正确性 |
| tc/netem/iptables | latency/loss/partition |
| process/node power failure | write-behind/fsync/lock recovery |
| volume profile/top/statedump | 将应用慢定位到 FOP/brick/queue |

### 9.3 不可省略的输出

- throughput/IOPS；
- P50/P95/P99/P99.9/max；
- errors 和 error code；
- client/brick CPU、RSS、context switches；
- per-NIC/per-disk throughput、latency、queue；
- RPC/FOP count 与 amplification；
- heal/rebalance backlog and rate；
- physical bytes/inodes；
- test 后 checksum/split-brain count。

## 10. 故障注入矩阵

| 场景 | 注入点 | 必测结果 |
|------|--------|----------|
| client kill | write 返回后、fsync 前/中/后 | 哪些数据存在、错误是否正确返回 |
| brick kill | AFR pre-op/FOP/post-op 的近似窗口 | pending xattr、read source、heal |
| replica partition | 1:1、2:1、client views 不同 | quorum、split-brain、error |
| EC fragments loss | 缺 1..R..R+1 | degraded latency、不可用边界、rebuild |
| slow brick | 注入 100ms/IO stall | straggler 对 P99、timeout、queue |
| XFS ENOSPC/ENOSPC inode | 单 brick | DHT placement、partial transaction、heal |
| rebalance + write/rename | 在线迁移 | skipped/failed、linkfile、checksum |
| heal + second failure | backlog 10% 时再失效 | 是否仍有 source/quorum |
| TLS rotation | 证书过期/CA 更换 | mixed-mode failure 与回滚 |
| geo-rep WAN loss | 1h/24h | backlog、catch-up、checkpoint RPO |

## 11. Exit Gates

所有门槛应在测试前由业务填写：

- healthy P99.9 data/metadata/fsync SLO；
- degraded P99.9 与 error budget；
- 目标 namespace 规模下 full heal RTO；
- disk/node 故障后的 oldest-heal-age 上限；
- rebalance 对前台的最大 P99 增幅；
- replica/EC physical amplification 上限；
- client/brick RSS/fd/connection 上限；
- split-brain=0（使用预期 quorum 的注入场景）；
- fsync-ack 后 power loss checksum 100% 正确；
- geo-rep checkpoint RPO/RTO；
- 72h/7d soak 无 memory/backlog 单调增长。

## 12. 性能结论

GlusterFS 的强项是不同文件可计算路由、direct-to-brick 与中大文件流式带宽；弱项是全目录扇出、per-file inode/xattr、client-side synchronous replication/EC 和 live rebalance。对海量小文件或低延迟强一致 metadata 系统，它避免了集中 MDS 单点，却以更高的分散协调成本换取；这并不自动更可扩展。
