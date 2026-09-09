# BeeGFS 数据布局与 I/O 路径

## 1. 结论先行

BeeGFS 数据面的高吞吐来自三个直接选择：

1. 文件 inode 内保存完整 stripe pattern，客户端无需查询中心 chunk map；
2. 客户端把逻辑请求按 chunk 切分，对多个 storage targets 并发发起 I/O；
3. 每个 target 上的 chunk 是本地文件，storage service 主要做协议、session、镜像和本地 `pread/pwrite/fsync`。

这是一个为并行流式 I/O 优化的“文件级静态布局”。它没有在核心路径上提供任意副本数、EC、透明冷热迁移或
BeeGFS 自有端到端 data checksum；这些能力分别依赖 Buddy Mirroring、底层存储、Remote Storage Targets 或外部流程。

## 2. Stripe Pattern

### 2.1 组成

文件创建时保存的主要布局参数是：

- pattern type：常用为 `RAID0` 或 `BuddyMirror`；
- chunk size：每次连续落到同一 target 的逻辑区间；
- target count：参与该文件条带的 target/group 数；
- target vector：有序 storage target IDs 或 Buddy Group IDs；
- storage pool/路径信息：用于解释目标域和 chunk 路径。

目录保存的是新文件默认值。改变目录 pattern 只影响随后创建的文件；已有文件的 target vector 不被原地改写。
这一点既保证客户端映射稳定，也意味着扩容后的历史数据不会自然铺到新 target。

### 2.2 映射公式

设逻辑偏移为 `p`、chunk size 为 `C`、target 数为 `N`：

```text
chunk_index          = floor(p / C)
target_index         = chunk_index mod N
offset_in_chunk      = p mod C
stripe_set_index     = floor(chunk_index / N)
target_local_offset  = stripe_set_index * C + offset_in_chunk
target_id            = target_vector[target_index]
```

`common/source/common/storage/striping/StripePattern.h:167-210` 计算 chunk start 和 target index；
内核客户端 `FhgfsOpsRemoting.c:2528-2559` 计算压缩后的 target-local offset。

例如 `C=1 MiB`、`N=4`：

| 逻辑区间 | target index | target-local 区间 |
|----------|--------------|-------------------|
| 0–1 MiB | 0 | 0–1 MiB |
| 1–2 MiB | 1 | 0–1 MiB |
| 2–3 MiB | 2 | 0–1 MiB |
| 3–4 MiB | 3 | 0–1 MiB |
| 4–5 MiB | 0 | 1–2 MiB |

因此每个 chunk file 是原文件属于该 target 的条带拼接，不是按原文件 offset 留出其他 targets 的空洞。

### 2.3 为什么布局基本不可变

静态 target vector 让任何持有 inode 的客户端都能纯计算定位，避免访问 chunk-map service。若在线改变 target count/order，
相同逻辑 offset 会映射到不同物理位置，需要原子切换 layout epoch、双布局读写或全文件搬迁；BeeGFS 核心路径选择不承担这套复杂度。

工程后果：

- 文件创建前应根据大小/并发选择 pattern；
- 条带过宽会增加 open/stat/close/fsync fan-out 和小 I/O RPC；
- 条带过窄会限制单文件聚合带宽；
- target 故障影响所有引用它的历史文件，不能通过修改目录默认值修复；
- 重平衡需要显式移动 chunk 并协调 metadata，必须评估前台干扰。

## 3. Target 选择

创建文件时 metadata service 从指定 storage pool 中选择处于较优 capacity pool 的 targets，并考虑 preferred targets。
BuddyMirror pattern 选择的是 group IDs，物理 primary/secondary 由 management 映射。

放置不是一致性 hash：文件 inode 持有显式有序列表，所以 management 改变候选集合不会让旧文件自动重新映射。
这种稳定性对于文件系统至关重要，也导致容量均衡是“新分配导流 + 显式历史迁移”的组合。

选择器需要同时看 free bytes 和 free inodes。本地文件模型下，target 可能有充足空间却无法再创建 chunk inode；
metadata store 同样可能先耗尽 inode。

## 4. Chunk 的本地表示

### 4.1 路径

`common/source/common/toolkit/StorageTk.h:334-374` 支持 legacy hash 路径和较新的 v3 路径。v3 概念上包含：

```text
<uid bucket>/<year-month>/<day>/<original-parent-entry-id>/<file-entry-id>
```

`PathInfo` 保存 original UID/original parent EntryID；文件 rename/chown 后这些定位信息保持不变，避免移动所有 storage chunks。
这也是“命名空间路径”和“物理 chunk 路径”解耦的关键。

### 4.2 文件格式

每个触达的 target 上，BeeGFS 为文件创建一个普通本地 chunk file。逻辑条带按上节 target-local offset 写入，
本地文件可为 sparse。它不是完整用户文件，不能脱离 stripe pattern 直接拼成语义正确的文件；官方 RST 文档因此称其为
BeeGFS chunk file format。

核心 C/C++ 数据路径中没有发现对每个用户数据块生成/校验 CRC 的逻辑；`checksum` 命中主要用于 hash 目录等内部计算。
因此应把端到端 bit-rot 保护视为部署责任：

- 选择带 checksum/scrub 的底层（如合适配置的 ZFS）或硬件保护；
- 定期介质巡检/RAID scrub；
- 上层数据集 checksum/manifest；
- 不要把 Buddy Mirroring 等同于校验——镜像可能复制同一错误写入，且无法判断哪份静默损坏正确。

### 4.3 本地文件系统依赖

Storage service 借用本地 FS 的 allocation、page cache、journal、sparse file、quota accounting 和设备错误返回。
官方 [Storage Node Tuning](https://doc.beegfs.io/latest/advanced_topics/storage_tuning.html) 推荐 XFS 作为常见 storage target
底层，理由是 RAID 上持续写吞吐和扩展性；ext4/ZFS 也可使用，但行为与调优不同。

这降低了 BeeGFS 自研 storage engine 的复杂度，但形成两层故障/空间语义：BeeGFS target state 之下还有 local FS、RAID、
controller cache 和磁盘。RPO 分析必须一直追到 stable media。

## 5. 客户端写路径

### 5.1 请求拆分和并行

`client_module/source/net/filesystem/FhgfsOpsRemoting.c:1459-1585` 实现跨条带并行写：

1. 按当前逻辑 offset 找到 chunk boundary 和 target index；
2. 计算 target-local offset；
3. 从用户 buffer/iov 中切出不跨 chunk 的子请求；
4. 一个 stripe set 内把不同 targets 的请求加入并行状态；
5. 以事件循环/多连接并发通信，收集各 target 结果；
6. 更新已写长度、客户端 inode size 和 per-target 首写状态。

大请求可同时占用 `N` 个 target 的带宽。小于 chunk size 且落在单 chunk 的请求只访问一个 target，因此“文件有 8 个 targets”
不等于每次 4 KiB I/O 都聚合 8 个 target。

### 5.2 Storage service

`storage/source/net/message/session/rw/WriteLocalFileMsgEx.cpp:56-266` 的主要步骤是：

1. 解析普通 target 或 Buddy Group，并决定本节点作为 primary/secondary；
2. 从 client/session/file handle 找到或打开 chunk file；
3. 检查 storage session 是否可能因 server restart 丢失；
4. 准备镜像通道；
5. 流式接收客户端 buffer，写本地 chunk，并在镜像场景向 secondary 转发；
6. 等待本地/镜像结果，返回已写字节或错误。

源码 `:332-435` 把每个 buffer 先送 secondary 通道再执行本地 `pwrite`，形成流水线，最终还要检查 secondary response。
这是同步镜像的正常路径，不是客户端分别写两份。

### 5.3 普通 write 成功意味着什么

普通 `write(2)` 成功主要表示数据已从客户端缓存送达 storage service 并被本地 `pwrite`/镜像请求接受；
它通常还在 storage host page cache、controller cache 或设备 cache 中，不等于掉电后可恢复。

Storage 可按 `tuneFileWriteSyncSize` 使用 `sync_file_range` 触发后台回写，但这不是应用 `fsync` 的稳定性承诺。
应用若要求 durability，必须检查并调用 `fsync`/`fdatasync`，同时验证底层 FS/barrier/controller 的语义。

### 5.4 镜像降级

正常时 primary 等 secondary 完整写入响应。若 management 已明确 secondary offline，primary 可把 secondary 标为/保持
`Needs Resync` 并继续本地写，以可用性优先；通信结果不确定时的重试很谨慎，因为部分 payload 可能已被 secondary 接收，
盲目从头重试会重复/覆盖不确定范围。

因此对 mirrored file 的严谨承诺应写成：

- 健康状态：写正常同步到两个 buddy targets；
- 已知降级状态：允许单副本继续服务，RPO 退化到当前 primary；
- 状态传播/切换窗口：官方记录特定情况下可能读旧副本或丢最近写，见 HA 文档；
- 恢复后：通过 resync 重新建立二副本，不是每个 write 的共识日志 replay。

## 6. 客户端读路径

`FhgfsOpsRemoting.c:1738-1810` 以 stripe set 为单位拆分 read，对涉及的 targets 并行请求；storage 端
`ReadLocalFileV2MsgEx.cpp` 从 session 打开 chunk，按 target-local offset `pread` 并流式发送，可使用 read-ahead。

读取路径的常见延迟组成是：

```text
client cache lookup
  + target-state/layout lookup（通常已缓存）
  + max(所有参与 target 的网络 + queue + local FS read)
  + 等待/重试慢或失败 target
```

宽条带的聚合吞吐随 targets 增长，但一次跨多个 targets 的同步请求尾延迟趋近最慢成员。对大量小随机读，宽条带不一定收益；
对大顺序读，chunk size、read-ahead、message size、connection count、NIC/HCA 队列和 target RAID 带宽共同决定上限。

BuddyMirror 读取按当前 Buddy Group 映射/目标状态路由。切换无需修改文件 inode 中的 group ID，但客户端获取 target states
有周期，management 必须在线传播一致视图。

## 7. 客户端数据缓存

### 7.1 `buffered`（默认）

8.4 内核配置默认 `tuneFileCacheType=buffered`、单 buffer `524288` bytes。BeeGFS 自有的小型静态 buffer cache
针对流式 I/O，内存占用可控，适合 HPC 大吞吐。它不会像 Linux page cache 那样长期缓存数 GiB 文件内容。

优点：

- 可预测的内存使用；
- 对顺序读写和 direct storage RPC 的路径成熟；
- 同机 storage service 与 client 共存时，官方只支持/建议该模式，避免双 page cache 问题。

限制：

- 重复随机读取的本地 cache 命中能力较弱；
- flush/close 时仍要处理 BeeGFS buffer；
- 同一客户端的 buffered、page-cache/mmap 交互需要 `tuneCoherentBuffers` 维护。

### 7.2 `native`

`native` 使用 Linux page cache，可缓存大量热点数据、改善重复随机读和 mmap，但 dirty page 回写、cache validity、内存压力
和跨客户端 invalidation 更复杂。配置中的超长 `tunePageCacheValidityMS` 不能被误读为全局强一致保证；它只是本客户端页面
有效期策略的一部分。

### 7.3 `tuneCoherentBuffers`

默认 `true`。客户端在普通 write 前等待/失效本 inode page cache，降低同一客户端不同 I/O 路径互相覆盖的风险。
`FhgfsOpsFile.c:1119-1129` 的注释明确承认：没有全局锁就无法在所有竞态中维持缓存一致，失效返回 `EBUSY` 时仍可能继续。

因此它是“单客户端内部尽力协调”，不是集群 cache-coherence protocol。

## 8. `flush`、`close` 与 `fsync`

### 8.1 默认值

8.4 `Config.c:267-309` 的相关默认值：

| 配置 | 默认 | 含义 |
|------|------|------|
| `tuneRemoteFSync` | `true` | 应用 `fsync` 会请求 storage 端真正执行 fsync |
| `sysSyncOnClose` | `false` | 普通 close 不强制稳定到远端介质 |
| `sysSessionCheckOnClose` | `false` | close 默认不额外进行该 session 检查 |
| `tuneEarlyCloseResponse` | `false` | close 正常等待服务端处理，而非提前响应 |

### 8.2 调用链

`FhgfsOpsFile.c:1303-1437` 中，`fsync`：

1. 回写/等待 Linux page cache；
2. flush BeeGFS buffer cache；
3. 在 `tuneRemoteFSync=true` 时向所有相关 stripe targets 发 remote fsync；
4. mirrored file 同时覆盖 secondary；
5. storage `FSyncLocalFileMsgEx.cpp:15-93` 对已打开的本地 chunk handle 调用本地 fsync；
6. 任一必要 target 错误向上返回。

普通 close 会 flush 客户端脏数据并关闭 session/汇总动态属性，但 `sysSyncOnClose=false` 意味着“不再可见于客户端缓存”与
“已到 stable media”仍是两件事。

### 8.3 Durability envelope

即使 remote fsync 返回成功，也要核验：

- 本地文件系统是否正确传递 flush/FUA；
- RAID controller write-back cache 是否有 BBU/PLP；
- SSD/HDD 是否正确声明 cache flush；
- mirrored secondary 是否健康，是否出现官方记录的 secondary fsync error 边界；
- metadata（文件大小、dentry）与数据 chunks 的持久化先后在崩溃后如何由 fsck/resync 收敛。

BeeGFS 提供 syscall 到各 chunk fsync 的路径，但不能消除下层设备谎报或跨服务原子提交问题。

## 9. 文件大小、稀疏文件和 truncate

### 9.1 文件大小

每个 storage target 只知道自己的 target-local chunk length。Metadata 的 `stat` 重建全局 size：找到能贡献最大逻辑末尾的
target，结合其 index、chunk length 和 chunk size 算回逻辑 offset。mtime/atime 在多个 targets 间聚合。

写 session 存在时 metadata 会主动刷新过期 dynamic attributes；close 将最新结果持久化。这种 lazy aggregation 避免写热路径
不断触碰 metadata，但使 `stat`、close 和故障恢复必须理解多 target 状态。

### 9.2 Sparse 与 truncate

Target-local chunk files 支持底层 sparse file。对逻辑空洞，相关 targets 可能根本没有 chunk 或本地文件有 hole。
truncate 需要对 stripe targets 计算新的本地末尾并并行调整，多 target 部分失败可能留下需重试/fsck 的不一致。

容量统计要区分逻辑 size、chunk apparent size 和底层 allocated blocks；对象存储同步前还需注意 ZFS 文件 size 更新边界，
8.4 RST 文档要求特定情况下先 `beegfs entry refresh`。

## 10. 小文件行为

BeeGFS 没有把用户小文件内容内联到 metadata，也没有把大量小文件打包进 append-only volume。空文件只需要 metadata；
一旦写入，小文件至少在一个 storage target 创建一个 chunk inode，并产生 metadata RPC、storage create/open/write/close 和底层 journal I/O。

对平均几 KiB 的海量小文件，放大主要来自：

- metadata 的 dentry/inode/xattr 和 ID hardlink；
- storage target 每个非空文件的 chunk inode/dentry；
- 两侧 Buddy Mirroring 后再乘副本；
- open/close/stat 相对 payload 的网络与 CPU 固定成本；
- 底层 FS journal、目录索引和 inode cache 压力。

提高 stripe count 对小文件通常没有帮助：小于一个 chunk 的内容只落一个 target，但 inode pattern、open/stat/close 管理成本可能增加。
合理做法是使用少 target/较大上层 container/shard，或选择原生 small-file packing 的系统。

## 11. 数据移动与重平衡

BeeGFS 8 提供面向 target 间数据重平衡的能力（具体可用性受版本/许可约束）。任何正确迁移都必须协调：

1. 阻止或序列化与该文件 range 的冲突 I/O；
2. 从旧 target 复制 target-local chunk 到新 target；
3. 处理迁移期间新增写；
4. 原子/可恢复地更新 inode target vector；
5. 清理旧 chunk，失败时留下可识别状态。

这比“复制普通文件然后改指针”复杂。生产扩容计划必须预留临时双份空间、后台带宽和失败重试窗口，并监控前台 p99。
如果不运行历史重平衡，新 target 主要承接新文件，容量倾斜会长期存在。

## 12. Remote Storage Targets 不是主条带层

8.4 可把文件同步到一个或多个 S3-compatible Remote Storage Targets：Remote service 保存 job 状态，多个 Sync workers 搬运数据；
文件可在成功上传后 stub 本地内容，再手动/自动恢复。

它与核心 data path 的差异：

| 核心 storage target | Remote Storage Target |
|---------------------|-----------------------|
| 同步 read/write 主路径 | 异步 push/pull/job |
| 客户端按 stripe 直接访问 | Remote/Sync 服务协调 S3 |
| 普通文件随时可读写 | stub 文件在恢复前返回阻塞/`EWOULDBLOCK` 类行为 |
| Buddy Mirror 可同步双副本 | 自动同步为 best-effort，cooldown queue 重启可丢 |
| 文件系统当前状态 | 远端状态还依赖 job DB/可选 provider 验证 |

RST 适合归档/共享副本/容量卸载，但不能被表述为“透明对象后端”或“自动一致的第三副本”。详见 operations 文档。

## 13. 性能调优原则

### 13.1 条带参数

- 单流大文件：逐步增加 target count，直到客户端/NIC/应用线程或存储聚合带宽成为瓶颈；
- 多文件高并发：较少 targets/file 往往能凭文件间分布获得全局并行，减少单操作 fan-out；
- chunk size：至少覆盖常见连续 I/O，避免一个请求切成过多消息；过大则短文件集中到第一个 target；
- 不用一套 root 默认 pattern 覆盖 checkpoint、dataset、日志和小文件元数据等不同 workload。

官方 [Striping](https://doc.beegfs.io/latest/advanced_topics/striping.html) 建议把 pattern 按目录设置，使新文件继承。
最终参数必须由真实文件大小分布、并发和网络消息大小验证。

### 13.2 网络与并发

- RDMA 可降低 CPU 和延迟，但 HCA/driver/kernel/firmware 组合需要在支持矩阵内；
- 多 rail、preferred interfaces、connection count 和 server workers 必须成套调优；
- 宽条带会按客户端数 × targets/file 放大连接和 in-flight requests；
- 慢 target/拥塞 rail 会成为 stripe-set 尾延迟长板。

### 13.3 分层基准

应按“磁盘 → 网络 → BeeGFS target → 端到端文件系统”逐层隔离：

1. 本地 fio/厂商工具确认 RAID 与 stable-write；
2. BeeGFS NetBench/网络工具确认 TCP/RDMA；
3. `beegfs benchmark`/StorageBench 绕过客户端文件路径测 targets；
4. IOR 测多客户端大 I/O；
5. mdtest 测 metadata；
6. 真实训练/checkpoint pipeline 测应用和 p99。

只跑 IOR 峰值不能证明小文件、fsync、降级、重平衡和恢复期 SLA。

## 14. 对 LightStore 的启示

### 可借鉴

- 布局携带于 metadata，SDK 纯计算 `offset -> target`，避免数据路径中心索引；
- 按 stripe set 并发且控制每 target in-flight，适合 LightStore SDK 的 RS/replica fan-out；
- target-local offset 压缩避免为其他 targets 留洞；
- original owner/path hint 在 rename 后保持物理定位稳定；
- 精确 stat 通过 per-target versioned dynamic attrs 汇总，不污染每次 append 热路径。

### 需保持 LightStore 差异

- LightStore volume packing 对海量小 record 更合适，不能退化为一 record 一底层文件；
- LightStore 的 replica/RS EC 应由系统自身校验和修复，不依赖每台机器的 local RAID 作为唯一保护；
- LightStore Location/volume epoch 能支持 compaction/GC 和重定位，需保留比 BeeGFS 静态 vector 更明确的版本切换；
- `fsync`/durability 契约应从 SDK、DataServer WAL/volume 到 device 明确定义，避免配置项组合才能推导语义。

## 15. PoC 验收矩阵

| 维度 | 至少覆盖 |
|------|----------|
| 文件大小 | 0 B、4 KiB、1 MiB、1 GiB、checkpoint 典型大小 |
| 模式 | sequential/random、read/write、append、truncate、sparse |
| 条带 | 1/2/4/8 targets，不同 chunk sizes，RAID0/BuddyMirror |
| 缓存 | buffered/native、冷/热 cache、mmap 混合 |
| 持久性 | write、close、fdatasync/fsync，storage 主机掉电/进程 kill |
| 故障 | 慢 target、offline primary/secondary、丢包、management 不可达 |
| 后台任务 | resync、fsck scan、rebalance、backup/RST sync 同时运行 |

报告应同时记录吞吐、p50/p99/p99.9、错误码、CPU、网络、target queue、dirty pages、allocated blocks 和恢复时间。
