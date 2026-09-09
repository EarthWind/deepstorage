# GlusterFS 一致性、Quorum 与 Split-Brain

## 1. 结论先行

GlusterFS 的一致性不能用“强一致”或“最终一致”一个词概括：

- **健康 replica/disperse set 内**：客户端内部 locks、同步 FOP 和 AFR/EC transaction 维持副本操作顺序，目标是向应用提供一致的 POSIX 文件视图；
- **brick/client/network 故障时**：是否继续读写由 client quorum、可用 fragments、pending/dirty 状态和 topology 决定；
- **没有有效 quorum 的 replica 2 分区**：两侧可接受冲突更新并形成 split-brain；
- **无法证明唯一正确副本时**：AFR 默认不自动选择 winner，需要阻止读写/heal 或人工裁决；
- **管理配置**：`glusterd` 分布式事务不是 per-file consensus，server quorum 也不替代 AFR client quorum。

所以最准确的描述是：**正常路径的同步复制 + 可配置的故障期 quorum + xattr 驱动的事后 heal**，而不是全局线性一致 replicated state machine。

## 2. 一致性的对象与边界

| 对象 | 正常保证机制 | 故障边界 |
|------|--------------|----------|
| 同一文件重叠 write 顺序 | AFR/EC internal file/range locks | client/brick disconnect 后锁重建与 pending 状态 |
| inode metadata | metadata transaction + AFR xattr | metadata split-brain 可与 data source 不同 |
| 目录 entry | entry locks + entry transaction | 同名不同 GFID/type 形成 entry split-brain |
| DHT placement | parent directory layout + hash/linkfile | layout 不一致、brick offline、rebalance 中间态 |
| POSIX advisory locks | brick locks translator | connection 丢失会清锁；不是持久分布式锁服务 |
| durability | write-behind drain + AFR/EC + backend fsync | `write()`/`close()` 不应冒充 `fsync()` |
| 管理配置 | glusterd locks + multi-peer transaction | peer 分区/配置不同步，无 Raft majority log |
| 跨站复制 | geo-rep changelog/checkpoint | 异步，有非零 RPO |

## 3. AFR 如何记录不一致

### 3.1 三类 changelog

AFR 把 pending 状态分成三个逻辑 lane：

- **data**：`writev`、truncate、fallocate 等 file content/size 变化；
- **metadata**：mode、uid/gid、times、xattr 等；
- **entry**：create、unlink、link、rename、mkdir 等 directory namespace 变化。

每个 replica 上针对其他 child 保存 `trusted.afr.<child>` 形式的计数/位图。可把它理解为“这个成功副本记录哪些 peers 没完成哪类 transaction”。另有 dirty xattr 表示操作可能在完成 post-op 前崩溃。

实际判 source/sink 还要结合：

- 哪些 bricks 在线且获得 heal locks；
- 各 child 相互 blame 的矩阵；
- GFID/type/size/mtime；
- quorum 和 arbiter/thin-arbiter 信息；
- 是否存在 in-flight transaction。

不要只看一个 xattr 非零就手工决定 source；应先用 `gluster volume heal ... info`、mount virtual xattr 和 glfsheal 结果建立完整矩阵。

### 3.2 为什么需要 pre-op/post-op

若不先留下意图，client 在只写成功一个 brick 后崩溃，恢复时无法区分：

- 成功 brick 是新版本；
- 成功 brick 是被部分覆盖的坏版本；
- 其他 brick 是旧版本；
- 操作从未对应用返回。

AFR 先标 dirty/pending、执行 FOP、再清成功项，使 crash 留下可枚举的 heal 候选。`optimistic-change-log` 可在全健康的 metadata/entry 操作中省部分 pre-op，降低延迟，但本质是用受控窗口换性能。

## 4. Client Quorum

### 4.1 `none`

未启用 client quorum 时，AFR 可在部分 bricks 可用时继续 transaction，并把失败 children 标为待 heal。这提高可用性，但 replica 2 网络分区两侧都可能各自成功，无法阻止 split-brain。

### 4.2 `fixed`

只有 active bricks 数达到 `cluster.quorum-count` 才允许 FOP。它适合显式 topology，但错误配置（例如 replica 2 设 count=1）不会提供防脑裂能力。

### 4.3 `auto`

官方定义：

- active bricks 大于一半：满足 quorum；
- 恰好一半且 replica count 为偶数：第一 brick 必须在 active 集合；
- replica 3 通常需要 2；
- 从较新版本开始，失去 quorum 时相关 FOP 返回 ENOTCONN，而不是简单只读。

“偶数一半必须含 first brick”只是一种 deterministic tie-break，意味着 first brick 是可用性特殊点，不会神奇地把 replica 2 变成对称 HA。

### 4.4 典型矩阵

| Topology | 可用 bricks | 安全写判断 | 说明 |
|----------|-------------|------------|------|
| replica 2, quorum none | 任意 1 | 可写但不防脑裂 | 两侧分区可各自更新 |
| replica 2, auto | first brick 单独或 2 | 防双写但不对称 | second brick 单独不可服务 |
| replica 2, fixed=2 | 2 | 安全但无单故障写 HA | 任一故障停止写 |
| replica 3, auto | 任意 2 | 通常安全 | 需要正确 failure-domain placement |
| arbiter 2+1 | 任意满足 per-file 仲裁的 2 | 视 blame 状态决定 | arbiter+stale data brick 会拒绝写 |
| thin arbiter | data pair 健康或 data+witness 可判定 | brick-pair 粒度保守裁决 | 某 brick 被标坏可影响其他 files |

## 5. Server Quorum 不是 I/O Quorum

Gluster 的 server quorum 作用于 trusted pool/glusterd/brick process：节点失去规定的管理节点比例时，可停止参与 volume 的 bricks，避免两边各自做管理操作或继续暴露服务。

它不能替代 client quorum，因为：

- server quorum 不按每个 replica set/per-file 观察成功副本；
- 一个无 brick 的 dummy peer 可让管理多数存在，却不能证明两个 data copies 谁新；
- bricks 被不同时间顺序停止/恢复时，replica 2 仍可能先后在两边接受更新；
- loss of server quorum 通常直接 kill/stop bricks，连 reads 也受影响。

正确分层：

```text
glusterd/server quorum -> 控制配置/brick participation
AFR client quorum      -> 控制每个 replica subvolume 的 I/O admission
application fsync      -> 控制应用 durable completion point
geo-rep checkpoint     -> 控制异步 DR 已完成位点
```

## 6. Arbiter 的一致性逻辑

### 6.1 存什么

2+1 arbiter set 中：

- data brick A：完整 data + entry + metadata + AFR xattr；
- data brick B：完整 data + entry + metadata + AFR xattr；
- arbiter C：entry、metadata、`.glusterfs` 和 AFR xattr；file size/data block 不作为数据副本。

因此容量近似 2x data，而不是 3x；但每文件 inode 与 namespace 成本仍是 3 份。

### 6.2 两个 participants 在线时

- A+B 在线，arbiter down：有两个完整 data copies，可继续 transaction；arbiter 回来 heal entry/metadata。
- A+C 在线：若 C 不 blame A，A 可被认为 fresh 并写；若 C blame A，唯一正确数据可能在离线 B，必须拒绝。
- 只有任意一个在线：不满足 quorum，拒绝。

Arbiter 的价值是保存“谁完成了上一事务”的第三票，不是存 parity 或恢复 content。

### 6.3 Sizing

官方给出约 `4 KiB × 文件数` 的粗估，还需考虑 XFS inode allocation。海量小文件场景必须按实际 inode size、xattr、`.glusterfs` hardlink、目录和 heal index 实测，不能只按文件数据为 0 估算。

## 7. Thin Arbiter 的一致性逻辑

Thin arbiter 不保存逐文件 namespace tree。它为每个 replica pair 保存 replica-id file/xattr，记录哪个 data brick 是 source/sink。

常态两个 data bricks 在线时，I/O 不经过 witness；首次失败后更新 witness。故障期只有一个 data brick + thin arbiter 时，根据 witness 和该文件自身 AFR 状态决定是否服务。

与普通 arbiter的关键区别：

- 普通 arbiter能按 file 记录 blame；
- thin arbiter把一个 data brick 上任一未 heal 事件提升为 brick-level 好/坏状态；
- 更小、更适合第三站点/高 RTT witness；
- 故障后更保守，可能让本来健康的其他 file 也失败。

## 8. Split-Brain 分类

### 8.1 Data split-brain

replicas 的 file content/size 不同，AFR blame graph 无法选唯一 source。常见原因：

- replica 2 在网络分区两侧写同一文件；
- 多故障顺序导致不同 bricks 先后成功；
- 人工直接修改 backend；
- 丢失/篡改 AFR xattr。

### 8.2 Metadata split-brain

mode、uid/gid、xattr、mtime 等互相冲突。值得注意的是，正确 data 可能在 brick A，而正确 metadata 在 brick B；粗暴“选整份文件覆盖”会丢一类正确状态。

### 8.3 Entry split-brain

同一 parent/name 在 replicas 上：

- GFID 不同；
- file type 不同（file vs directory 等）；
- rename/create/unlink 历史冲突。

目录 heal 可以对**不同名字**做 conservative union，但若同名对应不同 GFID/type，必须人工决定。union 也可能让一侧已删除的 entry 重新出现，不能等同于无损 merge。

## 9. Split-Brain 检测与处理

### 9.1 检测

```bash
gluster volume heal VOL info
gluster volume heal VOL info split-brain
gluster volume heal VOL statistics heal-count
```

还应关联：

- `/var/log/glusterfs/glustershd.log`；
- `glfsheal-<vol>.log`；
- client mount log；
- 对应 brick logs；
- 该路径/GFID 在所有 replicas 的 `getfattr -d -m . -e hex` 输出；
- 应用级 checksum/transaction log。

### 9.2 决策原则

1. 停止该 file/directory 的写入；
2. snapshot/块级复制全部 replicas，保留原始证据；
3. 分别确定 data、metadata、entry 的业务正确版本；
4. 使用 Gluster 提供的 split-brain resolution 命令/virtual xattr 指定 source；
5. 触发 heal，等待 backlog 清零；
6. 校验全部 replicas 的 GFID/type/content/xattr；
7. 复盘为何 quorum/failure-domain 没阻止脑裂。

### 9.3 `favorite-child-policy`

v11.2 支持：

- `none`（默认）；
- `size`；
- `ctime`；
- `mtime`；
- `majority`（超过一半 replicas 的 size+mtime 一致）。

自动策略的风险：mtime 最新不代表事务正确，size 最大不代表 append 已提交，时钟可能漂移，恶意/错误 backend 修改可能“赢”。只有 workload 语义能证明策略安全时才启用；否则保留 `none`，让冲突显式失败。

## 10. Self-Heal 如何选择 source/sink

heal 在对应 domain 获取 locks 后，大致执行：

1. lookup 全 replicas，收集 GFID/type/stat/xattr；
2. 构建各 child 的 accusation/pending matrix；
3. 检查 quorum、arbiter/thin-arbiter 与 split-brain；
4. 选 source 与 sinks；
5. metadata heal；
6. data full/diff heal；
7. entry heal/conservative merge；
8. 清除 pending/dirty 与 index entry。

若 source/sink graph 循环互相 blame 或没有唯一 source，heal 必须停下。自动复制“看起来最新”的副本会把可审计冲突变成静默数据丢失。

## 11. 多客户端与 POSIX 语义审计

### 11.1 同一文件并发写

AFR/EC internal locks 保证 replicas 上的 overlapping FOP 顺序一致；它不替应用决定两个无锁 writers 的业务顺序。两个 clients 写不重叠 ranges 可能并行，重叠 ranges 的最后结果取决于被序列化的顺序。

### 11.2 Advisory locks

应用 `fcntl/flock` 与 AFR internal locks 是不同 lock domains。brick connection 断开时 server 会释放该 connection 的 locks；重连后 fd reopen 不代表原 lock continuity。数据库或 HA active/passive 依赖 locks fencing 时，必须增加外部 lease/fencing 或把断连视为进程致命错误。

### 11.3 Cache coherence

quick-read、md-cache、kernel page/attribute cache 和 protocol upcall/invalidation 共同决定另一 client 何时看到更新。不能从“POSIX compatible”推导所有 mount option/旧 client/gateway 组合都具有即时 coherence。PoC 要覆盖：

- writer `fsync` 后 reader 已 open fd 的 read/stat；
- rename/unlink 后 stale dentry；
- mmap/shared write（若业务使用）；
- client partition/reconnect 后旧 cache；
- FUSE vs libgfapi vs NFS/SMB 混合访问。

### 11.4 Atomic rename 与 DHT

单本地文件系统的 rename 原子性，在 Gluster 中由 DHT entry/inode locks、跨 children FOP 和 rollback 模拟。健康路径目标是 POSIX-visible atomic operation，但 crash/rebalance/partial child failure 需要 self-heal。对依赖 rename-as-commit 的应用，必须在故障注入下确认“旧名/新名/双名/无名”的可观察窗口。

## 12. 一致性风险排序

| 优先级 | 风险 | 防线 |
|--------|------|------|
| P0 | replica 2 + 无有效 quorum 的网络分区 | 改 replica 3/arbiter/thin arbiter，故障域隔离 |
| P0 | 把 write/close 当 durable fsync | 应用显式 fsync + kill/power-loss test |
| P0 | 自动 favorite-child 选错 | 默认 none；保留证据，按业务日志裁决 |
| P0 | 直接修改 brick/.glusterfs/xattr | 网络/权限隔离 backend，变更审计 |
| P1 | heal backlog 期间继续多故障 | 告警、限流前台、优先恢复 redundancy |
| P1 | DHT layout/rebalance 与 rename/write 并发 | force-migration off，维护窗/专项测试 |
| P1 | lock 在 client reconnect 后失效 | strict behavior/外部 fencing/进程失败 |
| P2 | cache/gateway 组合出现 stale view | 版本矩阵与跨协议 coherence test |
