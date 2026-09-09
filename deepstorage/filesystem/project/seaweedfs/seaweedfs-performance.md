# SeaweedFS 性能模型、容量规划与 PoC

## 1. 结论先行

SeaweedFS 的性能优势来自三件事：小对象被打包进大 volume，Master 不进入普通数据读路径，客户端拿到 FID/volume location 后可直达 Volume Server。它减少的是“小文件元数据与文件系统对象数”成本，不会消除磁盘带宽、网络复制、Filer Store、S3 语义和后台维护的成本。

不能用一个“每秒文件数”概括系统。至少要分开测：

- Blob API 与 S3/Filer 路径；
- 1 KiB、32 KiB、1 MiB、32 MiB、分片大对象；
- PUT、GET、HEAD、LIST、DELETE、Multipart、Versioning、rename；
- 热复制、健康 EC、降级 EC、Cloud Tier；
- 空闲、Vacuum、repair、balance、scrub、tier/backup 同时运行；
- 正常运行、单进程故障、单盘/单机/单 rack 故障和网络半断。

官方文档中的吞吐数据可用于理解相对趋势，不能直接用于采购或 SLA。硬件、数据大小、并发、网络、索引模式、缓存命中、复制策略和 Filer Store 均会改变结果。

## 2. 请求成本模型

### 2.1 Blob 直写

```text
client
  | 1. assign
  v
Master leader                  control-plane latency
  | FID + volume locations
  v
entry Volume Server
  | local append + index
  +---- parallel replicate ---> N-1 Volume Servers
  |
  +---- ACK after all requests return
```

一次新 Blob 写通常包含一次 assign 和一次数据请求；客户端可批量或缓存分配结果以降低 Master QPS。复制为 `N` 份时，逻辑写带宽近似放大到 `N` 倍，入口节点还承担接收流量和向其他副本扇出的发送流量。

对成功延迟可用下式理解，而不是作为精确实现公式：

```text
Tput ≈ Tassign + max(Tentry_append, Treplica_1 ... Treplica_N-1) + Tprotocol
```

开启 `fsync=true` 后，只应在 `Tentry_append` 中计入入口副本的 group commit；4.41 的复制请求不继续携带该参数，不能把上式解释成“所有副本 stable-storage barrier”。

### 2.2 Filer/S3 新对象写

```text
client -> S3/Filer
           | split/chunk, compress/encrypt if configured
           | assign + upload one or more chunks
           v
        Volume Servers
           |
           +---- data upload success
           |
           v
        Filer Store metadata commit
```

Filer/S3 路径额外引入：

- S3 签名、IAM/policy、配额与限流；
- auto-chunk、可选压缩/SSE、ETag/checksum；
- Filer Store 的 key lookup、condition、版本链和事务能力；
- 对象覆盖/版本化时的旧 chunk 处理；
- 元数据日志、通知或跨集群复制副作用。

小于 inline 阈值的内容可能直接存入 Filer Store。这能省去 Volume RPC，却把字节带宽、数据库日志、复制和备份压力转移到元数据后端。inline 阈值不能只按“更快”调大，应以数据库行大小、WAL 放大、缓存命中和恢复时间为依据。

### 2.3 读取

正常 Blob 读取的理想路径是：

1. 从 FID 得到 volume id；
2. 从缓存或 Master 查 volume locations；
3. 选择一个副本；
4. 用 needle 索引获得 offset/size；
5. 对 `.dat` 做定点读取并校验 needle CRC。

因此官方的 “O(1) disk access”描述的是正常 volume 的 needle 定位，不包括：

- Filer path 到 chunk 列表的元数据查询；
- location cache miss；
- 多 chunk、manifest 和 range 合并；
- 压缩/解密；
- 所选副本失败后的重试；
- EC index 二分查找、shard 读取与缺片重建；
- Cloud Tier 的远端 range 请求；
- FUSE page cache 和内核—用户态转换。

## 3. 主要瓶颈

| 层 | 常见瓶颈 | 典型症状 | 应验证的指标/动作 |
| --- | --- | --- | --- |
| Master | assign、volume growth、海量心跳/拓扑更新、leader 抖动 | assign p99 上升、可写 volume 变少 | assign QPS/延迟、leader、Raft apply、pending writes/bytes、心跳 |
| Volume 写 | 单盘顺序写、索引追加、锁、fsync batch、入口复制扇出 | PUT 尾延迟与最慢副本同步恶化 | 每盘吞吐/await、写队列、replication error、fsync batch |
| Volume 读 | 介质随机读、page cache、热点 volume、并发 buffer | GET p99/吞吐不均、个别磁盘打满 | volume 热度、磁盘 IOPS/带宽、cache、各副本选择 |
| Filer | chunk 切分/合并、路径缓存、并发 buffer、manifest | 大对象内存峰值、path 操作 p99 | heap/GC、chunk 数、manifest、Filer RPC/HTTP latency |
| Filer Store | 点查、目录 LIST、热点目录、WAL/锁/连接池 | LIST/HEAD/rename 慢，Filer CPU 空闲但请求堆积 | DB p95/p99、连接池、锁等待、WAL、慢查询、容量 |
| S3 | SigV4/IAM、版本链、Lifecycle、Multipart、LIST | CPU 高、小 PUT/HEAD QPS 受限 | 按 API/状态码/tenant 的 QPS、延迟、并发和字节 |
| EC | shard 定位、额外 hop、重建 CPU/网络 | 健康 EC 已变慢，缺 shard 后尾延迟放大 | 健康/降级读分开，missing shard、decode time |
| Cloud Tier | 远端 RTT、range、限流和请求费用 | 首字节长尾、读取费用异常 | range 请求数/字节、cache hit、对象存储 4xx/5xx |
| 后台任务 | Vacuum、repair、balance、EC encode/decode、scrub | 前台 p99 周期性尖峰 | 后台速率/队列、磁盘利用率、前台 guardrail |

### 3.1 可写 volume 并行度

一个 collection/placement 可同时写入的 volume 数限制了热点分散。官方优化文档举例默认可能维护 7 个并发可写 volume；这不是通用 SLA，实际还受 grow 参数、拓扑约束、可用 slot 和 collection 数影响。小对象 QPS 高时，应检查请求是否均匀散到不同 Volume Server/磁盘，而不是只增加客户端并发。

### 3.2 一个目录对应一块盘

Volume Server 的目录/磁盘需要被当作独立资源池观察。把很多逻辑目录放在同一物理盘不会增加 IOPS；把一个 volume 的多个副本放到同一物理故障域也不会增加可靠性。容量调度使用的 free space 不能替代磁盘拓扑与设备身份治理。

### 3.3 Filer 内存

Filer 大文件写采用并发 chunk 流水线。4.41 数据路径分析显示，粗略峰值可按：

```text
upload_buffer ≈ active_uploads × 4 × chunk_size
```

再加 HTTP/gRPC buffer、manifest、压缩/加密工作区、Go heap 和 page cache。此式是上界规划起点，不是实测常数；实现、请求取消和对象大小会改变实际占用。读取也可能按最大 chunk 建 buffer，不能仅依据平均对象大小。

### 3.4 目录 LIST 与 bucket 基数

小文件数据面绕开中心元数据，并不意味着 S3 LIST 或 POSIX `readdir` 也绕开 Filer Store。海量扁平 key、热点 prefix、复杂版本链会把排序、分页和扫描成本落到数据库。

S3 bucket 常映射到 collection。collection 使用专属 volume，可造成大量半空 volume、文件描述符、索引、compaction 和调度开销。官方“many small buckets”文档举例：若每个新 bucket 最多触发 7 个 30 GB volume，1,000 个 bucket 可出现 7,000 个 volume。该例不是必然预分配 210 TB，但明确揭示了 volume slot 和稀疏度风险。

## 4. 容量模型

以下符号用于规划：

| 符号 | 含义 |
| --- | --- |
| `Lhot` | 热数据逻辑 live bytes |
| `Lwarm` | 温冷数据逻辑 live bytes |
| `N` | 热复制副本数，`1 + placement 三位数字之和` |
| `E` | EC 放大，OSS RS(10,4) 为 `14/10 = 1.4` |
| `F` | 目标有效填充率，0 到 1 |
| `G` | tombstone、旧版本和待 Vacuum 的垃圾比例 |
| `H` | 故障恢复、Vacuum、迁移、升级所需预留比例 |
| `V` | volume size limit |
| `A` | 单对象/needle 的索引与记录对齐等开销 |

### 4.1 磁盘容量

粗略原始容量下界：

```text
raw_required ≈
  (Lhot × N + Lwarm × E + object_count × A)
  ÷ F
  × (1 + G + H)
```

实际规划应把以下项目单列，避免重复或漏算：

- Filer Store 主副本、WAL、索引和数据库备份；
- EC encode 前普通 volume 与生成中 shards 的并存窗口；
- EC decode/compact 时恢复普通 volume 的临时空间；
- Vacuum 复制 live data 时旧、新文件并存；
- 跨集群备份 staging、增量日志和重试；
- S3 Versioning、Multipart 未完成部分、delete marker；
- Cloud Tier 本地索引/cache 与远端存储费用；
- 节点/盘故障后恢复期间的目标水位。

不能把盘长期跑到接近 100%。如果一块盘故障后没有足够跨节点 free slot，`volume.fix.replication` 即使逻辑正确也无处创建副本。

### 4.2 volume 数与 slot

对某个 collection/placement：

```text
volume_count ≈ ceil(logical_or_physical_bytes / (V × target_fill))
volume_slots  ≥ volume_count × copies_or_shards + maintenance_headroom
```

默认 `V≈30,000 MB` 不是固定最佳值：

- 大 volume：文件数少、调度对象少，但单 volume 修复/搬迁/Vacuum/EC decode 时间更长，故障爆炸半径更大；
- 小 volume：恢复和封存粒度细，但 volume 数、FD、心跳、索引、调度与半空浪费增加。

应以“目标恢复窗口内单节点可搬完多少 volume”和“collection 基数”反推 `V`，而不是机械沿用默认值。

### 4.3 索引内存

固定 `.idx` entry 常见为 16 B；官方运维文档对 memory index 给出的粗略经验是约 20 B/needle。规划可用：

```text
memory_index_floor ≈ live_and_tombstoned_index_entries × 20 B
```

再加 map/allocator、volume 元数据、请求 buffer 和进程开销。注意：

- 该 20 B 是数量级估算，不是任何版本、平台都精确的上界；
- 删除仍会留下索引/垃圾，Vacuum 前不应只按 live object 数；
- 一个 30 GB volume 若平均对象 30 KiB，约 100 万对象，对应约 20 MB 索引的官方示例；
- 极小对象会先耗尽内存/索引/CPU，未必先耗尽磁盘；
- LevelDB index 可降低内存和启动加载压力，但 lookup 与本地 DB compaction 路径不同，必须实测；
- EC volume 使用排序索引而不把整个正常 volume index 常驻内存，适合低访问温数据。

README 的“每文件 40 bytes disk metadata overhead”与 16 B index entry、20 B memory 估算不是同一个口径；采购模型应以目标版本实测的 `.idx`、`.dat`、DB 和进程 RSS 为准。

### 4.4 网络

热复制 `N` 份时，集群内部写网络下界近似：

```text
cluster_write_bytes ≥ logical_ingress × N
entry_server_egress ≈ logical_ingress × (N - 1)
```

还有协议、TLS、metadata、重试和跨机房开销。若 placement 跨 DC，前台写尾延迟会受最慢 DC 影响。异步 `filer.sync` 则把跨集群带宽移到日志消费和对象复制，RPO 取决于 lag、失败重试和日志保留。

## 5. 官方性能证据及边界

官方 EC Wiki 在一个未完整披露硬件、网络、缓存热度的测试中，使用 `weed benchmark -n 102040` 随机读，报告：

| 模式 | 请求数 / 并发 | 官方吞吐（requests/s） | 相对正常 volume |
| --- | ---: | ---: | ---: |
| normal volume | 102,040 / 16 | 31,435.64 | 100% |
| healthy EC | 102,040 / 16 | 13,966.69 | 44.4% |
| EC，4 台服务器中 1 台下线 | 102,040 / 16 | 9,152.52 | 29.1% |

这组数字支持两个定性结论：

1. EC 读即使健康也有明显额外路径成本；
2. 缺 shard 时在线重建进一步降低吞吐。

它不能证明：

- 任意硬件都能达到同样 QPS；
- 生产数据分布、对象大小、TLS、S3/Filer 路径下比例相同；
- p99/p999、首字节延迟或多租户公平性；
- 后台 rebuild 与前台读取并行时的稳定性；
- 4.41 在目标配置上的实际结果。

官方 benchmark 页面自己也提醒资源、客户端数量、并发和文件大小会显著影响结果。本文不引用年代较久的单机结果作为选型分数。

## 6. PoC 工作负载矩阵

### 6.1 数据分布

至少准备四类可复现数据集：

| 数据集 | 对象大小 | 目的 |
| --- | --- | --- |
| Tiny | 1–4 KiB | 压 Master assign、S3/Filer CPU、索引、DB 和 QPS |
| Small | 32–256 KiB | 代表图片缩略图、附件，验证 packing 主场景 |
| Medium | 1–32 MiB | 观察磁盘/网络带宽、chunk 阈值与缓存 |
| Large | 1–100+ GiB | Multipart、manifest、range、失败续传和内存上界 |

对象名需同时覆盖随机 key、单热点 prefix、多 bucket、多 tenant；可压缩和不可压缩内容分别测，避免压缩率让物理吞吐看起来虚高。

### 6.2 API 组合

- Blob：assign + PUT、FID GET、DELETE、重试；
- S3：PUT/GET/HEAD/DELETE、LIST v2、Multipart、Copy、range、条件写；
- Versioning/Object Lock：覆盖、delete marker、历史读取、retention/legal hold；
- Filer：create/read/list/delete/rename、单目录热点和深目录；
- FUSE：顺序/随机读写、metadata storm、多 mount 同文件、锁、rename、fsync、mmap；
- 生命周期：TTL、Lifecycle scan、过期、abort multipart；
- 管理：grow、balance、repair、Vacuum、EC encode/decode、scrub、tier move/compact。

### 6.3 状态矩阵

每个关键 workload 至少跨以下状态运行：

| 状态 | 注入/动作 | 观察 |
| --- | --- | --- |
| 基线 | 无后台任务 | 吞吐、p50/p95/p99/p999、错误率、资源 |
| 满水位 | 70%/80%/目标上限 | 调度、compaction 空间、尾延迟 |
| 单副本慢 | 网络延迟/限速、磁盘慢 | PUT 被最慢副本拖累程度 |
| 网络半断 | 只断单方向或复制端口 | 部分写、超时、重试残留、location 收敛 |
| 入口崩溃 | 本地 append 后 kill | ACK/非 ACK 对应的可见性与副本差异 |
| 主机断电 | 有/无 `fsync` | 实际 RPO、索引重放、坏尾处理 |
| Master leader 切换 | kill leader/隔离 | assign 停顿、已有 FID 读写影响 |
| Filer owner 重启 | 条件写/版本化并发中重启 | serialization cooling window、冲突和回滚 |
| Filer Store 故障 | 主从切换、连接耗尽、慢查询 | namespace 可用性、重复/孤儿 chunk |
| 单盘/节点失效 | replication 与 EC 分别测 | 读成功率、修复启动延迟、完成时间 |
| EC 缺片 | 丢 1–4 shard，随后再丢 1 | 降级性能与不可恢复边界 |
| 后台竞争 | repair/Vacuum/scrub/tier/backup | 前台 guardrail 和恢复时间 |

## 7. 指标、SLO 与验收

### 7.1 客户端 SLI

按 API、bucket/tenant、对象大小和状态码拆分：

- 成功率，明确重试前与重试后；
- p50/p95/p99/p999 总延迟和首字节延迟；
- logical bytes/s 与 physical disk/network bytes/s；
- timeout、5xx、条件冲突、throttle；
- LIST 每页延迟与每 key 成本；
- 后台任务期间前台 SLO 退化；
- 写后读、覆盖后读、删除后读的一致性检查。

### 7.2 系统 SLI

- Master leader/term、assign latency、volume layout、writable volumes、heartbeats；
- Volume per disk IOPS/throughput/await/queue、read/write errors、replica deficit；
- garbage ratio、Vacuum queue/bytes/time、volume move/repair backlog；
- EC shard 缺失、scrub 错误、rebuild throughput/time；
- Filer request latency、chunk count、manifest、heap/GC、owner routing；
- Filer Store latency、连接池、锁/WAL/compaction/replica lag；
- `filer.sync` checkpoint/lag/error 与日志保留余量；
- Cloud Tier request/byte/cache hit、远端 4xx/5xx 和成本；
- 节点/盘容量水位、volume slots、collection/volume 数。

不要只报警“服务存活”。缺副本但仍可读、scrub 长期没跑、Vacuum 无临时空间、异步复制 lag 接近日志保留窗口，都是典型的静默风险。

### 7.3 建议验收门

门槛应由业务给出数值，至少包含：

1. 正常 p99 与故障/后台任务 p99；
2. 峰值与持续 QPS/吞吐，保留多少 headroom；
3. ACK 对应的明确 durability 语义和实测 RPO；
4. 单盘、单节点、单 rack 的 MTTD、修复开始时间和完成时间；
5. Filer Store 切换时可接受的错误与恢复窗口；
6. EC 丢片读性能、4 片恢复和第 5 片不可恢复演示；
7. 全量/增量恢复达到目标 RTO，且恢复后做对象与 namespace 校验；
8. 72 小时以上 soak，包含容量增长、删除、Vacuum 和重启。

## 8. 硬件与部署建议

- Volume Server 优先使用直连 JBOD/明确的本地盘；不要让底层 RAID/网络盘的故障语义与 SeaweedFS placement 重复而不可观察。
- 每块盘独立目录并暴露设备级指标；数据副本必须跨真实故障域。
- SSD/NVMe 适合索引、Filer Store、热点 volume 和 cache；容量 HDD 适合吞吐型冷温数据，但随机小读和 rebuild 更慢。
- Master 数据目录放可靠低延迟介质，3 或 5 个节点跨故障域；不要与高 I/O Vacuum/repair 混部。
- Filer Store 按数据库规范部署 HA、PITR、连接池和独立监控；其容量和恢复能力与 Volume Server 同等重要。
- 至少 10 GbE 级网络是否足够应由 `logical throughput × replication/tier/repair amplification` 计算；禁止用平均流量代替故障恢复峰值。
- CPU 需覆盖 TLS、SSE、压缩、EC decode、S3 鉴权和 Go GC；开启这些能力后重新基准。
- 生产 Volume Server 优先采用 Go 实现；Rust 路径在 4.41 同 tag 的能力审计仍有 deferred 项，应独立 canary。

## 9. 调优顺序

1. 先确认对象分布、SLO、复制/EC 和持久性目标；
2. 再按真实故障域布局 Master、Filer Store 和 Volume Server；
3. 依据恢复窗口与 bucket 基数选择 volume size；
4. 依据对象数选择 memory/LevelDB index，并测启动/恢复；
5. 调整可写 volume 数，让写负载跨盘均匀；
6. 按实测 heap 限制 chunk size、upload 并发、S3 read/write 并发；
7. 将 repair/Vacuum/scrub/tier 设置速率、窗口与前台 SLO guardrail；
8. 最后才扩大客户端并发。

若增加并发只提高队列和 p99，而磁盘/网络/DB 已饱和，它不是扩容。应通过新增独立盘/Volume Server、分片 Filer Store、拆热点 collection 或改变数据生命周期解除真实瓶颈。

## 10. 参考

- [官方 Optimization](https://github.com/seaweedfs/seaweedfs/wiki/Optimization)
- [官方 Benchmarks](https://github.com/seaweedfs/seaweedfs/wiki/Benchmarks)
- [官方 S3 API Benchmark](https://github.com/seaweedfs/seaweedfs/wiki/S3-API-Benchmark)
- [官方 EC warm storage benchmark](https://github.com/seaweedfs/seaweedfs/wiki/Erasure-Coding-for-warm-storage)
- [官方 Production Setup](https://github.com/seaweedfs/seaweedfs/wiki/Production-Setup)
- [官方 Many Small Buckets 优化](https://github.com/seaweedfs/seaweedfs/wiki/Optimization-for-Many-Small-Buckets)
- [磁盘布局与 I/O 数据路径](seaweedfs-data-path.md)
- [复制、纠删码与数据完整性](seaweedfs-replication-ec.md)
- [资料来源与研究方法](sources.md)
