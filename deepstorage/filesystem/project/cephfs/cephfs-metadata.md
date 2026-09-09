# CephFS 元数据模型与横向扩展

## 1. 核心判断

CephFS metadata 架构的关键不是“有多个 MDS”，而是：**任一时刻每个 inode 只有一个 authoritative MDS，authority 以目录子树/dirfrag 为单位动态分布；所有可恢复状态最终落在 RADOS metadata pool 的持久对象和每 rank journal 中。**

这是一种“单 authority + durable shared backing store + replay failover”的设计，不是每个 metadata shard 的 Raft/多数派复制。其优点是常态 metadata 路径短、缓存局部性强、authority 可迁移；代价是 failover 需要 journal replay、客户端 reconnect 和分布式锁重建。

## 2. 持久数据模型

metadata pool 中不仅有 namespace：

| 类别 | 内容 | 作用 |
|------|------|------|
| dirfrag objects | dentry keys、内联 inode、目录统计、snapshot dentry versions | 路径解析与目录持久 backing store |
| per-rank journal | metadata updates、session、open inode、subtree map、import/export 等事件 | crash consistency、failover replay、批量顺序写 |
| inode table | rank 分配过/使用中的 inode number | 防止 inode 重用冲突 |
| session map | 客户端会话状态 | 重启后恢复/重连 |
| snap table | snapshot ID 与有效集合 | SnapServer 的全文件系统状态 |
| open file/table 状态 | 打开 inode 等恢复信息 | failover 时恢复客户端可见状态 |
| damage/scrub state | 已知损坏条目与检查进度 | 隔离和修复 |

普通文件的 inode 通常内联在所属目录的 dentry 中，lookup 不必额外读取独立 inode object；hard link 因多个 dentry 指向同一 inode，会引入额外管理和性能成本。目录过大时，一个逻辑目录被拆成多个 dirfrag RADOS objects。

文件数据对象的第一个对象还存 backtrace，使恢复工具能从 data pool 对象反推出 inode/父目录关系。它是灾难恢复线索，不等于对完整 namespace 的实时反向索引。

## 3. MDS cache

MDS 把 RADOS metadata 当 backing store，把热点 inode、dentry、dirfrag、locks、caps 和 subtree map 保存在内存。cache 命中时无需读取 metadata pool，因此工作集是否装得下会造成明显的两种性能区间。

v20.2.3 默认 `mds_cache_memory_limit=4 GiB`，但它是目标值而非硬上限：

- MDS 在约 95% 目标处进入保留区并 trim 未使用 metadata、recall 客户端 caps；
- 客户端仍持有 caps、metadata 被 pin、journal 未 trim 或 recall 过慢时，RSS 可继续增长；
- 默认达到目标的 150% 才报 oversized health warning；
- 官方部署建议至少给 MDS 约 8 GiB 内存；1000+ clients 的生产实例常需要显著更大的、例如 64 GiB 级 cache，但应按实际 bytes/inode 与 working set 测量。

### 3.1 cache 不只在服务端

客户端持有 caps 时也缓存 inode、dentry 和文件数据。MDS 内存回收因此是分布式过程：MDS 先发 recall，客户端回写脏状态并释放 caps，MDS 才能安全 drop 本地 metadata。这解释了为什么“把 cache limit 调小”可能变成 cap recall 风暴，而不是简单降低内存。

### 3.2 关键指标

- MDS cache bytes/inodes/dentries 与 limit/reservation；
- per-client caps、cap hits/misses、recall 数量与释放速率；
- `MDS_HEALTH_CLIENT_RECALL`、`MDS_CACHE_OVERSIZED`；
- metadata pool read latency 与 cache miss 后的请求 P99/P999；
- journal segments、uncommitted/expired segments 和 trim lag。

## 4. authoritative MDS 与分布式锁

一个 inode 在任意时刻只有一个 authoritative MDS。修改必须在 auth MDS 执行；非 auth MDS 可以：

- 转发变更请求；
- 持有 read locks，在 auth MDS 不改变对应状态时为本地客户端服务读取；
- 缓存 replica metadata，减少跨 rank 请求。

MDS 内的 `Locker` 协调 inode 各类 lock state 和客户端 caps。若 MDS 操作与某客户端 cap 冲突，必须先 recall cap；若跨 rank 操作涉及多个 authority，则使用 inter-MDS 协议和 journal event 保持可恢复顺序。

这不是无锁分片：rename、hard link、snapshot、跨 subtree 访问和客户端共享写都可能触发跨 rank 协调、auth pin、freeze 或 caps recall。

## 5. MDS journal

每个 active rank 在 metadata pool 中维护独立、跨多个 RADOS object 条带化的 journal。MDS 在执行 metadata 操作前记录事件；主要目的有两个：

1. **一致性**：崩溃后 replay 到一致状态，覆盖需要修改多个 backing objects 的操作；
2. **性能**：把随机、小粒度 metadata 变更汇聚成顺序、批量 journal write，之后再批量 flush 到 dirfrag/其他对象。

### 5.1 典型事件

| 事件 | 语义 |
|------|------|
| `EVENT_UPDATE` | inode/file operation 更新 |
| `EVENT_COMMITTED` | 某 request ID 已 commit |
| `EVENT_SESSION` | 客户端 session |
| `EVENT_OPEN` | 打开 inode |
| `EVENT_SUBTREEMAP` | directory subtree 到 rank 的映射 |
| `EVENT_EXPORT` | 目录 authority 导出 |
| `EVENT_IMPORTSTART/FINISH` | 导入阶段与完成 |
| `EVENT_FRAGMENT` | dirfrag split/merge 阶段 |
| `EVENT_SLAVEUPDATE` | 跨 MDS operation 的参与方状态 |
| `EVENT_TABLECLIENT/SERVER` | snap/inode 等 table transition |

### 5.2 segment 与 trim

journal 由逻辑 LogSegments 组成。一个 segment 中的多次修改可按 backing object 聚合写回；只有相关更新都已 flush，segment 才能 expire 并推进 journaler expire position。replay 必须从包含完整 subtree map 的 major segment 开始，因此 trim 不只是“删旧日志”，还要保留可建立 authority 基线的边界。

默认每段目标 1024 events，最多约 128 个未 trim segments，超过 2 倍默认触发 `MDS_HEALTH_TRIM`。长 journal 通常意味着：脏 metadata 无法 flush、客户端/锁状态被 pin、RADOS 慢或某个内部依赖未完成；直接重启可能让 replay 更慢。

### 5.3 early reply

`mds_early_reply=true` 允许 metadata 操作在“逻辑已完成、尚未 journal durable”时先回应用。客户端把此请求放入 unsafe list；MDS durable 后再确认移除。failover 时客户端在 reconnect 阶段重发，恢复 rank 在 `up:clientreplay` 阶段按 request identity 重放/去重。

所以 early reply 不是牺牲 crash consistency，而是把等待 journal commit 从前台移到“客户端保留可重放状态”；若客户端与 MDS 同时丢失且请求尚未 durable，仍可能只剩应用层观察到的脆弱窗口，应用应使用 `fsync`/事务边界表达耐久要求。

## 6. 动态子树分区

MDS balancer 统计目录热度，选择子树从 exporter rank 移到 importer rank。迁移协议不是简单修改一条 map：

1. exporter auth-pin 子树根并开始 freeze；
2. `MExportDiscover` 确保 importer 已打开并 pin 基目录 inode；
3. 若有其他 MDS 缓存该区域，向 bystanders 通告 authority 暂时为 exporter/importer 二义；
4. exporter 把完整缓存子树 metadata 发送给 importer；
5. importer 安装为 authority，写 `EImportStart` 并安全 flush 后 ACK；
6. exporter 写 `EExport`；恢复时正是该事件判定迁移是否已完成；
7. 通知 bystanders 新 authority，排空旧消息流；
8. importer 写 `EImportFinish(true)`，双方 unfreeze 并清理状态。

这个协议的工程价值在于把“迁移 authority”建模为可恢复的多阶段状态，而不是依赖瞬时 cluster map。代价是迁移期间 subtree freeze 和大量 metadata/cache 传输会产生尾延迟，频繁抖动也会浪费 CPU/网络。

## 7. multiple active MDS

`max_mds=N` 创建 N 个 active ranks。适用 workload 通常是多客户端、多个目录并行 metadata 操作；不适合把它理解为单流线性加速器。

### 7.1 active 与 standby

- active rank 各自服务不同 authority，任一 rank 故障都需要接管；
- HA 仍需额外 standby，`max_mds=2` 但只有两个 MDS daemon 等于没有 spare；
- 要容忍一个 MDS host 故障，至少要保证所有 active ranks 之外还有合适 standby，且跨主机放置；
- standby-replay 只跟随一个指定 active rank，故障切换更快，但不能接管其他 rank；若启用，官方建议每个 active 都配一个。

### 7.2 手工和自动 pin

- `ceph.dir.pin=<rank>`：把目录子树显式固定到某 rank，适合隔离租户/应用，也可能制造热点。
- ephemeral pin：按 inode consistent hash 自动把很多子目录均匀映射到 ranks，减轻动态 balancer 的迁移成本。
- distributed/random ephemeral policies：适合已知层级下的大量并行目录，但需按版本和 workload 验证。

pinning 是 performance/isolation hint，不改变 RADOS 持久副本或 HA 语义。

## 8. 目录碎片化

大或繁忙目录可按 dentry name hash 拆成多个 dirfrags：

- 每个 fragment 是独立 metadata object，可以独立缓存、迁移和由不同 active rank authoritative；
- create/lookup 按 hash 直接选择 fragment，不必扫描完整目录；
- split/merge 自身通过 `EVENT_FRAGMENT` journal 化；
- 目录 fragmentation 默认开启。

v20.2.3 源码默认 `mds_bal_split_size=10000`，`mds_bal_merge_size=50`，fragment 满足条件后默认延迟 5 秒执行；单 fragment 达 `mds_bal_fragment_size_max=100000` 时新 create/link 可返回 ENOSPC，作为失控保护。阈值是默认实现值而非容量承诺，不应在不了解内存/OMAP/负载的情况下盲调。

### 8.1 限制

- root directory 不能 fragmentation；根下应尽早按租户/项目分层。
- `readdir`/完整 `ls` 仍要聚合所有 fragments；hash 分片解决点查询/并行写，不消除全量 list 成本。
- 标准 `ls` 还会在用户态排序百万名字；`ls -l` 会对每项取 metadata，遇到另一客户端扩展文件还可能等其 flush size。
- 目录有 1000 万文件“能工作”不等于高效；官方仍建议拆成更适中的层级。

## 9. 扩展瓶颈图谱

| 症状 | 可能根因 | 增加 active MDS 是否有效 |
|------|----------|--------------------------|
| 单目录多客户端 create 热点 | 未 split、dirfrag 未分散、同一锁冲突 | 可能；需确认 fragments 与 authority 分布 |
| 单客户端串行 create/stat | 客户端并发不足、同一 auth MDS | 通常无明显收益 |
| 所有工作集中一个 pinned subtree | 错误 pinning | 无；先解除/重分 pin |
| cache miss 后 P99 高 | metadata pool latency/working set 过大 | 有限；需增 cache/改善 pool |
| MDS RSS 超限 | caps 无法 recall、metadata pinned | 可能更糟；先治理客户端与 recall |
| 跨目录 rename P999 高 | inter-MDS locks/journal/authority | 不一定；更多 rank 增加跨域概率 |
| 大目录完整 list 慢 | 全 fragment 聚合、客户端排序/stat | 无法根治 |
| journal trim lag | backing RADOS 慢、dirty state pinned | 增 rank 不是直接解法 |

## 10. 对 LightStore metadata 的启示

### 值得吸收

1. Range owner 与 durable replica 概念分离，但 authority 迁移必须有 journal/epoch 证据。
2. 超大目录必须允许目录内 hash/range split；完整 listing 需要可恢复 cursor 和明确 snapshot 语义。
3. 把 cache delegation 视为 capability，带版本、可撤销、超时与 fencing，而不是无限 TTL。
4. 设计显式 recovery state machine，不只提供“leader 重新选出”一个状态。
5. 为每个 metadata shard 保存 damage table、scrub 进度和可离线解析的物理格式。

### 不应照搬

1. LightStore 已用 Range Raft，不应降级为 MDS journal + 单 authority failover；应保留多数派持久化与确定的 leader epoch。
2. 不应让万亿小文件性能依赖单机内存覆盖 metadata working set。
3. 不应把跨 Range 正确性隐藏在隐式 forwarding；需要 operation ID、intent、幂等与 reconciliation。
4. 避免把每个记录映射为独立底层对象，保留 append-only volume packing 的空间和恢复优势。
