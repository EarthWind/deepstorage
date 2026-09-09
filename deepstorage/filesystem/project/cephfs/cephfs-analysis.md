# CephFS 技术评估与 LightStore 对照

## 1. 执行结论

CephFS 是一个值得深入学习的成熟分布式文件系统，但不应成为 LightStore 的整体实现模板。

两者共享“客户端直达数据节点、控制面不代理稳态数据、按故障域放置、后台修复”的正确方向；关键分歧来自目标：CephFS 为完整共享 namespace、Linux/POSIX、多客户端 cache coherence 和统一 RADOS 生态优化，LightStore 为 `10^12–10^13` 小文件/记录、EiB、append-only volume packing、SDK API、Range Raft 和 replica/RS EC 优化。

对 LightStore 价值最高的 CephFS 机制：

1. 单 authority 与 durable redundancy 分层；
2. dynamic subtree + directory-internal fragmentation；
3. capability recall + blocklist + OSDMap epoch barrier fencing；
4. early reply + unsafe request replay/dedup；
5. journal 化的多阶段 authority migration；
6. replay/resolve/reconnect/rejoin/clientreplay 恢复状态机；
7. Purge Queue、backtrace、scrub 和 damage table 运维闭环；
8. snapshot context 在客户端/metadata/data/GC 之间贯穿。

最不应照搬：

1. 每小文件至少一个 RADOS object/backtrace 的对象数放大；
2. MDS 内存 cache 覆盖 working set 才有高 metadata 性能；
3. 全 POSIX caps/locks/session state 给海量客户端带来的恢复状态量；
4. metadata 大灾难依赖全 data-pool object scan；
5. 协作式 quota 和异步 snapshot creation 被误解成强边界；
6. 共享 Ceph 集群的复杂 blast radius。

## 2. 路线对比

| 维度 | CephFS 20.2.3 | LightStore 当前设计 | 判断 |
|------|---------------|---------------------|------|
| 主场景 | 共享 POSIX、HPC/AI、K8s RWX、home/project | 海量小文件/记录、EiB、SDK-first | 目标不同 |
| 客户端 | kernel/FUSE/libcephfs，完整 session/caps | SDK，未来 FUSE/协议适配 | LightStore 可控制语义面 |
| 管理共识 | MON quorum 维护 maps；MGR 管理 | Manager Raft | 都有 epoch/map，但职责不同 |
| metadata authority | MDS dynamic subtree/dirfrag 单 authority | Range leader | 概念可对照 |
| metadata durability | per-rank journal + RADOS replicated metadata pool | Range Raft log/state | LightStore 多数派语义更直接 |
| metadata 扩展 | 多 active ranks、迁移子树、目录 hash fragments | Range split/merge/placement | LightStore 更适合主动细粒度 shard |
| data location | pool + inode/object index，CRUSH 计算 PG/OSD | `volume_id + offset` + placement | Ceph 无中心查找；LightStore 可 packing |
| 数据组织 | 默认 4 MiB RADOS objects | append-only volume records | LightStore 小文件效率优势 |
| 冗余 | RADOS replicated/EC，BlueStore checksum | replica/RS EC，需固化 checksum/commit | Ceph 运维成熟，LightStore协议需明确 |
| 一致性 | MDS locks + caps + client cache | Range linearizability + write lease 规划 | LightStore 不必复制全 POSIX |
| fencing | OSD blocklist + map epoch barrier | placement/lease epoch 待完善 | Ceph 机制强烈值得借鉴 |
| snapshot | SnapRealm/SnapContext + RADOS COW，异步 writeback | 尚需统一 metadata/data checkpoint | 应早设计 |
| quota | 递归统计、客户端协作、近似 | 可设计服务端硬限额 | LightStore 应更强制 |
| delete/GC | per-rank Purge Queue 删除 objects | volume live/dead + compaction | 都需 backlog/physical accounting |
| DR | 异步 directory snapshot mirror | 尚需设计 | 不应把 async mirror 称零 RPO |
| 恢复 | journal replay + reconnect + scan tools | Raft replay + volume/index repair | LightStore 避免全池 scan |
| 运维成熟度 | 多年生产，scrub/fsck/maps/metrics | 演进中 | Ceph 的闭环最有借鉴价值 |

## 3. CephFS 做得好的地方

### 3.1 metadata/data path 分离彻底

MDS 返回足够 layout 与 caps 后，客户端纯计算 object/PG/OSD。这个设计消除中心 chunk-map 请求，让 data throughput 随 OSD 扩展。LightStore SDK 也应一次获得 Location、placement set、generation、fence epoch 和 checksum policy，后续批量 I/O 不回 Manager/MetaServer。

### 3.2 authority 可移动且迁移可恢复

CephFS 不把目录永久绑定一台 MDS。迁移 freeze、discover、EImportStart、EExport、bystander notify、EImportFinish 的多阶段协议让故障后能判定谁 authoritative。

LightStore Range split/leader transfer/replica reconfiguration也应保存明确 operation ID 和 durable phase，禁止仅靠“当前 map 看起来像完成”判断。

### 3.3 热目录可目录内拆分

dirfrag 让同一大目录的 hash fragments 成为独立 objects/authority。对 object-store-like flat namespace，这是比“一个目录一个 owner”更稳健的方向。LightStore 的 huge directory 必须支持按 name hash/range split，并给 list 一个稳定 merge cursor。

### 3.4 分布式缓存有明确所有权

caps 不是松散 TTL，而是可撤销 delegation；冲突发生前 recall，失联后 blocklist，并让新 owner 跨过 OSDMap barrier。它解决了“旧 writer 恢复网络后还能写旧副本”这一常被忽略的问题。

LightStore 即使不做 POSIX，也必须让 write lease 与 DataServer 接受写入的 epoch 同源，所有 fragments/replicas 拒绝旧 lease。

### 3.5 early reply 没有丢掉可恢复性

MDS 可以先返回，再让客户端保留 unsafe request；failover 时重发/去重。说明“低 latency”和“durable replay”可以通过协议状态拆开，不必把所有操作同步阻塞到 backing-store materialization。

LightStore 可对批量 create/commit 提供 accepted 与 durable 两级完成，但 SDK 必须保存 idempotency key，服务端保留有界 dedup state，API 明确哪个时点能向用户确认成功。

### 3.6 删除/损坏/恢复是显式状态

Purge Queue、stray、damage table、scrub、backtrace、journal export/recovery 让“namespace 已删除”“对象已回收”“发现损坏”“可自动修”“需专家恢复”可区分。LightStore 也应让 orphan、dead record、relocating extent、corrupt fragment、repair pending 成为可查询状态。

## 4. CephFS 的结构性代价

### 4.1 MDS 单线程与 cache working set

多个 ranks 能横向扩展，但每个 authority 的主路径仍受单线程 CPU，metadata miss 还受 RADOS latency。加 MDS 只有 workload 能分区时有效；单 inode/单目录锁冲突、全量 readdir、跨 rank rename 不会线性加速。

LightStore Range 也可能遇到相同陷阱：若一个 Raft apply loop/Range owner 承载热点 key，节点总数无关。需要 directory-internal split、热点 key 专用原语和 admission/fairness。

### 4.2 对象数与小文件固定成本

CephFS 不会真的给 1 KiB 文件预分配 4 MiB，但每文件仍形成 dentry/inode、journal/cap 和 RADOS object/backtrace 固定成本。10^13 量级时，object metadata、PG enumeration、scrub/purge/scan 的操作数可能比 payload 更难处理。

LightStore volume packing 是核心差异化：把许多小记录放入顺序大 extent，代价是 Location index、GC/compaction 和 relocation correctness。不能为复用 CephFS 简洁映射而放弃这个优势。

### 4.3 全 POSIX 状态爆炸

caps、dentry leases、distributed locks、open sessions、unsafe requests、snap contexts、hard links 和 mmap 边界带来复杂恢复状态。它对共享文件 API 必要，对 immutable/append record store 不是必需。

LightStore 应定义更窄但更诚实的原语：immutable put、CAS metadata、single-writer append、atomic manifest publish、versioned read、explicit durability。FUSE 只映射能正确实现的 syscall。

### 4.4 RADOS 统一底座的共因风险

统一 replication/EC/checksum/CRUSH/ops 是巨大优势，也让 MDS journal、CephFS data、RBD/RGW 共享 OSD/network/control plane。OSD churn、full、upgrade 或配置错误可能同时影响多类服务。

LightStore 全栈也会有类似风险；应让 Manager、Meta Raft、Data volumes、repair network 和 tenant placement 有可隔离的资源/故障域，避免“一套 map/队列慢，全系统都慢”。

### 4.5 灾难扫描不适合万亿对象 RTO

CephFS 可以从 backtrace 扫 object 重建 metadata，证明物理格式有可恢复性；但官方承认很慢且没有完成时间估算。对 10^13 objects，这只能是最后取证手段。

LightStore 应维护增量 manifests/index checkpoints、跨域备份和可分片恢复目录，使恢复与受损 volume/range 成比例，而不是与全系统对象数成比例。

## 5. CephFS 机制到 LightStore 的映射

| CephFS 机制 | LightStore 对应设计 | 建议 |
|-------------|---------------------|------|
| MDSMap epoch | Manager placement epoch | SDK/Meta/Data 全链路携带并拒绝旧 epoch |
| inode caps | read/write lease/token | 降维，只授权必要操作与 generation |
| OSD blocklist | writer/client fencing | DataServer 本地持久/缓存 blocked generation |
| osdmap epoch barrier | minimum fence epoch | 新 lease 生效前确认所有 write targets 已观察 epoch |
| unsafe request replay | idempotency/dedup log | SDK 重试 + Range durable op table |
| subtree export/import journal | Range split/move state machine | prepare/copy/cutover/finalize，可恢复、可审计 |
| dirfrag | huge-directory shards | hash/range split + consistent list cursor |
| MDS journal segments | Raft snapshot/log compaction | 限制 replay，显式不可 compact pin |
| SnapRealm/SnapContext | snapshot epoch/version vector | 贯穿 record write、manifest、GC |
| Purge Queue | tombstone/GC work queue | 记录 logical/physical bytes 与 backlog age |
| inode backtrace | record backpointer | 支持局部反向修复，带 checksum/version |
| damage table | corruption registry | 按 range/volume/fragment 隔离与修复状态 |
| CephFS mirror status | async DR checkpoint | last-complete generation 与 RPO age |

## 6. 建议的 LightStore 设计改进

### 6.1 统一 epoch fencing

定义：

```text
WriteToken = {
  tenant_id,
  object/range,
  writer_id,
  lease_generation,
  placement_epoch,
  min_fence_epoch,
  expiry,
  idempotency_scope
}
```

Manager 发布 placement/fence epoch；MetaServer 只发不旧于该 epoch 的 token；DataServer/EC shard 拒绝旧 generation。发生 writer eviction 时，先将 fence durable/广播到全部相关 DataServers，再发新 token，避免只靠 lease timeout。

### 6.2 directory shard 与 list

- 目录初始 locality，一个 Range；
- 达到 bytes/entries/QPS/lock wait 阈值后按 name hash/range split；
- shard map 带 epoch，create 用最新 map，旧 map 请求返回 redirect；
- list token 包含 directory generation、shard cursors、sort key；
- 明确 list 是 point-in-time、bounded-staleness 还是弱一致。

### 6.3 durability API

至少区分：

- `Accepted`：某服务内存/本地队列接受；
- `MetadataCommitted`：Meta Range Raft commit；
- `DataDurable`：replica quorum 或 EC 可解码 durable set；
- `Published`：metadata 指向已 durable data，读者可见；
- `SnapshotProtected`：generation 已进入 checkpoint/DR policy。

默认用户 API 只在 `Published` 返回成功，批量/异步 API 可显式订阅更早/更晚阶段。

### 6.4 GC 与 snapshot

record header 包含 object/version/location generation/checksum；volume manifest 记录 live/tombstone/snapshot refs。compaction 写新 location 后先 Raft commit mapping，再用 epoch 延迟回收旧 extent；snapshot deletion 只减少 ref，后台 queue 按安全水位 reclaim。

### 6.5 repairability

- 每个 volume 有可独立校验的 manifest/index checkpoint；
- data record backpointer 可恢复 object/version，但不是唯一索引；
- damage registry 区分 checksum mismatch、missing fragment、stale generation、orphan；
- repair 使用 source generation/checksum，旧副本不能覆盖新数据；
- dry-run fsck 输出 operation plan 和预计对象/字节/时间。

## 7. 是否采用 CephFS 的决策建议

### 适合直接采用 CephFS

- 业务硬需求是 Linux shared POSIX、现成应用无法改 SDK；
- 主要是中大文件，namespace 按项目/作业可分散；
- 已有成熟 Ceph SRE、足够 SSD/NVMe metadata 资源；
- 能接受 snapshot-based async DR、客户端受信和 documented POSIX gaps；
- 上线速度/生态比小文件极致成本更重要。

### 适合 CephFS + LightStore 并存

- CephFS 承载 POSIX workspace/checkpoints，LightStore 承载海量 immutable/append records；
- 通过 manifest/data mover 交换，不让一个系统强行模拟另一系统语义；
- CephFS 作为训练/计算热层，LightStore 作为规模/成本优化持久层。

### 继续自研 LightStore

- `10^12–10^13` 小对象是核心，不是边缘 workload；
- volume packing/compaction 是 TCO 必需；
- SDK/API 可控制应用，不需要完整 POSIX；
- 要求 metadata Raft 线性一致、服务端硬 quota/tenant isolation；
- 要把恢复范围限制在 range/volume，而非全池对象扫描。

## 8. PoC 方案

### 8.1 目标

不是证明“CephFS 能跑”，而是回答三个决策问题：

1. 真实 namespace 下 metadata P99.9 与 MDS scaling efficiency 是否满足 SLO？
2. 目标小文件/覆盖写在 replicated/EC 下的物理成本和恢复干扰是否可接受？
3. MDS/client/OSD/站点故障下实际 RTO、错误语义和数据完整性是否符合应用契约？

### 8.2 最小矩阵

| 场景 | 变量 | 输出 |
|------|------|------|
| 均匀 metadata | 1/2/4 active MDS、16–512 clients | ops/s、P99.9、rank load、migration |
| 单热目录 | 1M/10M entries、fragment thresholds | split 时间、fragment/rank 分布、list latency |
| 小文件 | 1–64 KiB、create/read/delete | objects、physical bytes、MDS memory、purge time |
| 大文件 | 1–100 GiB、stripe/layout | bandwidth、CPU、network、degraded impact |
| EC overwrite | 4–256 KiB random、fsync | latency、write amplification、recovery |
| caps | single/multi writer、slow client | recall latency、eviction、data loss boundary |
| failover | MDS kill/partition、cold/warm standby | detect/replay/reconnect/active RTO |
| capacity | nearfull/full、snapshot/purge backlog | ENOSPC point、fsync errors、reclaim lag |
| DR | snapshot schedule/mirror/promote | actual RPO/RTO、unsupported file semantics |

### 8.3 建议退出门槛

预先由业务填写，而不是测试后挑指标：

- metadata/data/fsync P99.9 SLO；
- 72h 无不可解释 cache/journal/purge 增长；
- 单 MDS/OSD/client partition 后 RTO 和错误率上限；
- 无旧 writer 越过 fence；
- physical amplification/TCO 上限；
- snapshot/mirror RPO 与实际恢复成功；
- lost/damaged injection 可定位受影响 tenant/files。

## 9. 风险排序

| 优先级 | 风险 | 原因 |
|--------|------|------|
| P0 | metadata pool 共因损坏/满 | 可影响整个 namespace 和恢复 |
| P0 | 客户端 fencing/dirty data 误解 | 可能形成数据丢失或旧 writer 冲突 |
| P0 | 把 close/snapshot/mirror 当 durable/零 RPO | 直接违反应用恢复假设 |
| P1 | MDS cache/cap 状态超规模 | 尾延迟、OOM、failover RTO |
| P1 | 小文件 object count 与 purge/scan | 影响成本和灾难恢复量级 |
| P1 | EC 小覆盖写/恢复干扰 | 延迟和网络/CPU 写放大 |
| P2 | balancer/pinning 不匹配 namespace | 热点与迁移抖动 |
| P2 | subvolume quota 被当硬隔离 | 不可信租户可突破 |
| P2 | msgr2 默认为 CRC 优先 | 误以为传输默认加密 |

## 10. 最终建议

1. 把 CephFS 作为 LightStore 的一致性、fencing、恢复状态机和运维工具链参考实现，而不是数据组织模板。
2. LightStore 在继续写功能前优先固化 write-token/fence epoch、ACK durability、snapshot generation 和 damage registry 四个协议。
3. 用相同 workload 同时测 CephFS 与 LightStore 原型，比较的不只是吞吐，还包括 object/metadata amplification、P99.9、failover RTO、purge/GC 和恢复扫描范围。
4. 如果近期必须服务现有 POSIX 应用，采用 CephFS 做前端共享层比在 LightStore 上仓促实现完整 POSIX 更稳妥；通过异步导入/manifest 与 LightStore 分层。
5. 若 LightStore 继续聚焦万亿小记录，坚持 Range Raft + append-only volume packing，并吸收 CephFS 的 epoch、caps/fencing 和可修复性设计。

## 11. 进一步研究问题

- LightStore 的 writer lease 如何在所有 replica/EC shards 上原子 fencing？
- Range split、directory list 与 concurrent rename 的线性化点是什么？
- `Published` ACK 在 data durable 与 metadata commit 之间如何避免 orphan/悬空引用？
- snapshot epoch 如何与 in-flight volume append、EC parity 和 compaction 协调？
- tenant hard quota 应在 reserve、append、commit、GC 哪个时点扣减/返还？
- volume manifest/checkpoint 能否把最坏恢复限定为单 volume，而不扫描全集群？
- 哪些 POSIX 功能由 CephFS 层提供，哪些在 LightStore API 明确不支持？
