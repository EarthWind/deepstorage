# BeeGFS 高可用、故障切换与恢复

## 1. 技术摘要

BeeGFS 的内建 HA 由 Buddy Mirroring、management 目标状态机、客户端状态刷新和 resync 共同组成：

- metadata services/nodes 两两配对，保护命名空间对象；
- storage targets 两两配对，保护文件 chunks；
- 正常 mutation 由 primary 处理并复制到 secondary；
- management 监测 reachability/consistency，向客户端和服务端传播视图；
- primary 不可用时把 group 服务切到 secondary；
- 失联成员回来后从当前健康成员 resync。

它能处理常见单服务/单节点中断，但不是一个自包含的共识复制系统：management 本身是单 SQLite 权威；Buddy Group 只有两个成员，
没有多数派；降级期允许单副本写；状态传播和 `fsync` 有官方记录的数据丢失边界；镜像不保存历史版本。

正确的生产设计必须同时具备：Buddy 故障域、management 外部 HA/fencing、底层磁盘保护、监控、fsck、独立备份和恢复演练。

## 2. Buddy Mirroring

### 2.1 配对模型

Metadata 和 storage 各自建立两成员 Buddy Groups：

```text
Buddy Group ID G
  ├─ primary target P
  └─ secondary target S
```

文件/目录布局记录 `G`，不是永久记录当前物理 primary。切换时 management 更新 group role/target states，客户端继续使用 G，
因此无需扫描重写所有 inode。

配对必须由管理员确认：

- P/S 容量和性能相近；
- 不在同一服务器、HBA、机柜、电源、TOR 或故障域；
- 每个成员下层 RAID/ZFS 仍有本地磁盘容错，Buddy 不应成为替代本地 RAID 的唯一机制；
- 避免所有 primary 集中在一半主机造成正常/切换期负载不均。

新文件系统默认不开启 mirroring。Storage mirroring 可按目录 pattern 继承；metadata mirroring 的初始化/迁移流程更严格，详见 metadata 文档。

### 2.2 正常写

Storage：客户端请求当前 primary；primary 把数据流向 secondary 并写本地 chunk，等待 secondary response 后返回。

Metadata：`MirroredMessage` 在 primary 本地执行操作，再把请求及 sequence/session 信息发送 secondary，检查结果后返回。

正常健康状态可概括为同步二副本，但写的线性化点不是一个 quorum log index；两个本地文件系统分别执行操作，
错误时通过状态机而非 rollback/consensus 处理。

### 2.3 降级写

如果 secondary 已被判定 offline/needs-resync，primary 可继续服务，新的 mutations 只存在于 primary 并被 resync 机制跟踪。
此时：

- 可用性保留；
- 冗余降为一份；
- primary 再故障会造成不可用，且可能丢失降级期数据；
- 不应在未确认状态的情况下强制把旧 secondary 提升为权威；
- 恢复窗口越长，resync 数据量和风险越大。

运维上应把 `degraded` 视为紧急事故，不是正常容量模式。

## 3. 二维目标状态机

官方 [Target States](https://doc.beegfs.io/latest/reference/target_states.html) 把状态拆成两个正交维度。

### 3.1 Reachability

| 状态 | 含义 | 调度行为 |
|------|------|----------|
| `Online` | 最近持续通信正常 | 可正常分配/访问 |
| `Probably Offline` | 超过中间阈值未通信，正在传播安全视图 | 避免草率访问/切换，等待各节点认知收敛 |
| `Offline` | 超过离线阈值或已完成切换判定 | 不应向该 target 发送正常 I/O |

BeeGFS 8 Rust mgmtd 默认 `node_offline_timeout=180s`（`mgmtd/src/config.rs:262-270`）。
`bee_msg/common.rs:288-329` 在 age 超过 timeout/2 时返回 `ProbablyOffline`，超过完整 timeout 时 `Offline`；
Buddy primary 在切换完成前不会简单报告成 Offline，而是停在中间态以避免各客户端在不一致视图下并发访问两侧。

客户端默认每 30 秒刷新 target states（C client `Config.c:297-301`）。实际故障时间线因此包含 heartbeat、mgmtd 判定、
状态推送/拉取、客户端请求重试和切换，不应把 180 秒直接当成唯一 RTO。

### 3.2 Consistency

| 状态 | 含义 | 运维动作 |
|------|------|----------|
| `Good` | 内容被认为与 Buddy 同步/可作为健康副本 | 正常服务 |
| `Needs Resync` | 可能缺失变更，不可作为等价最新副本 | 从权威 buddy resync |
| `Resyncing` | 正在复制/重放缺失状态 | 监控进度和前台影响 |
| `Bad` | resync 失败或状态不可用 | 停止冒险切换，诊断/重建 |

二维模型解决了一个常见错误：target 可以网络在线但内容过期，也可以暂时网络不可达但之前内容一致。
放置、读取、切换和修复必须同时看两个维度。

### 3.3 为什么需要 `Probably Offline`

两副本没有仲裁节点。若 P/S 与客户端对状态判断不同，可能一部分请求继续写旧 primary，另一部分已经切换到 secondary。
中间态给 management 时间把统一视图传播出去，再完成 switchover。它牺牲更快 failover，换取降低 split-brain 写入风险。

## 4. Management service 是 HA 的关键依赖

### 4.1 保存什么

BeeGFS 8 management 使用默认 `/var/lib/beegfs/mgmtd.sqlite`。Schema（`mgmtd/src/db/schema/1.sql`）保存：

- nodes、NICs、node IDs/last contact；
- metadata/storage targets、容量、inode、consistency；
- storage/metadata pools；
- buddy groups 的 primary/secondary 映射；
- root inode owner/group；
- quota defaults/limits/usage 等控制状态。

丢失它不是“节点重新注册就完全恢复”：root owner、Buddy 映射和 target identity 的错误重建可能把旧数据解释成别的拓扑。
官方 backup 文档明确称恢复这些映射困难且昂贵。

### 4.2 SQLite 可靠性参数

`beegfs-rust/sqlite/src/connection.rs:19-35` 为连接启用：

```text
journal_mode = WAL
synchronous  = FULL
```

WAL 改善读写并发，`FULL` 让每个事务按 SQLite 语义同步 WAL，降低单机掉电丢 DB commit 的风险。
但这只是单数据库本地持久性，不是跨 management nodes 复制。Schema 中只有一个默认 management node；没有 Raft term/index、
多数派日志或内建 active-active 写入。

### 4.3 Management 不在数据路径，为什么仍关键

已有客户端在全健康、缓存完整时可能继续一部分 I/O，但以下动作依赖 management：

- 新客户端挂载/注册、节点/target 注册；
- target/buddy/pool mapping 和状态更新；
- 自动故障切换与统一 split-brain 视图；
- 新文件 target 选择所需容量/健康信息；
- license/部分管理操作。

官方架构明确说明 Buddy failover 需要 management 正常运行。故“management 不转发数据”不能转述为“management 宕机无影响”。

### 4.4 外部 HA

生产通常用 Pacemaker/Corosync、共享 LUN/复制块设备、浮动地址或等价编排保护 management。正确性要求：

1. 任一时刻只有一个实例可写权威 DB；
2. 旧实例必须被可靠 fencing/STONITH 后才启动新实例；
3. DB、WAL、配置、`conn.auth`、TLS key/cert、license 必须作为一致单元迁移；
4. 地址/端口对所有 clients/services 稳定；
5. 恢复演练验证 root/buddy/pool/target IDs 完整，而非只看进程启动。

没有 fencing 的“双活 SQLite 副本”比单点更危险：两个 management 分区各自传播不同角色即可造成数据分叉。

## 5. 故障切换时间线

以 storage primary P 故障为例：

```text
t0        P 停止响应
t0..t1    请求 timeout/retry；mgmtd 根据 last_update 推进 Online -> ProbablyOffline
t1..t2    状态传播到 servers/clients，避免不同节点过早形成两套视图
t2        group switchover，原 secondary S 成为当前服务侧
t2..      I/O 恢复；旧 P consistency 标为 NeedsResync
trejoin   P 回来，不直接承接最新请求
tresync   从当前权威 S 向 P resync
tgood     两侧重新 Good；角色是否恢复由策略/操作决定
```

影响 RTO 的变量：

- management offline timeout 和 client message retries；
- TCP/RDMA failure detection；
- 客户端 target-state refresh；
- 请求是否跨多个 targets（一个慢 target 拖住整次 I/O）；
- 新 primary 的 cache warmup/负载余量；
- 应用自身 syscall timeout 和 retry 策略。

不应为了更快 RTO 盲目把 timeout 调到网络瞬时抖动也会触发切换；双成员系统误切换的正确性代价高。

## 6. Resynchronization

### 6.1 Storage resync：选择性复制

官方 [Resynchronization](https://doc.beegfs.io/latest/trouble_shooting/resynchronization.html) 描述：storage primary
记录最后成功与 buddy 通信时间，扫描本地 chunk 树，复制自该时间（减去 safety threshold）以来修改的 files/directories。

源码 `storage/source/components/buddyresyncer/BuddyResyncJob.cpp` 启动多类 workers：

- gather slaves 遍历目录并产生 sync candidates；
- file sync slaves 复制内容和属性；
- directory sync slaves 建立目录结构；
- 完成后向 buddy/mgmtd 报告新 consistency state。

`sysResyncSafetyThresholdMins` 向前扩大扫描窗口，容忍时间戳粒度、时钟和最后通信记录的不确定性。它不是 per-block dirty bitmap：
候选文件通常按文件复制，超大文件的一小处修改仍可能带来大流量。

### 6.2 Metadata resync：全量

Metadata resync 不使用 storage 那种 mtime 优化，而会复制完整 mirrored metadata。原因包括 metadata 对象小、关系复杂，
且仅凭 mtime 很难证明 dentry/inode/link/删除集合完整。

8.4 metadata resync 运行期间以 changeset/worker 机制跟踪并行 mutations，再将 bulk copy 期间变化同步给 secondary。
这允许在线恢复，但要监控：

- bulk scan 对底层 metadata IOPS 和 cache 的冲击；
- changeset 积压是否超过同步速度；
- resync 期间新的单点风险；
- 最终 consistency state 是否真正回到 Good。

### 6.3 Resync 不是 backup restore

Resync 的权威假设是“当前 primary 正确”。误删、应用覆盖、勒索、软件 bug 或 primary 静默损坏会被复制给 secondary。
如果运维选错 source，旧/坏副本还可能覆盖好副本。任何手工 target state/role 修改前都应保存证据并确认数据方向。

## 7. 已知镜像风险窗口

官方 [Mirroring](https://doc.beegfs.io/latest/advanced_topics/mirroring.html) 不回避以下边界。

### 7.1 手工改变 active target consistency

把活动 target 从 `Good` 手工设为 `Needs Resync` 不是瞬时全局事件。文档给出传播可达约 30/60 秒量级；
期间客户端可能仍访问被降级 target。如果此时发生 switchover：

- read 可能来自旧副本；
- write 可能在角色传播中丢失；
- 不同客户端的 target map 更新时间不同。

因此不能把手工改状态当作无停顿的“立即 fencing”。维护前应按官方流程停流量/确认状态收敛。

### 7.2 Secondary `fsync` error

若 secondary 本地 `fsync` 因磁盘错误失败，错误可能直到后续操作才使 target 进入 Needs Resync。若在检测前 primary 故障，
旧 secondary 被提升并作为 resync source，可能把缺少稳定写的数据反向同步给旧 primary，造成数据丢失。

这揭示同步双副本的根本限制：没有第三个副本/日志仲裁，也没有可靠 end-to-end checksum 来自动判断两份谁正确。

### 7.3 第二故障

Buddy Group 降级后只有一份最新数据。第二个节点/RAID/管理员错误可造成永久损失。监控必须对任何非 Good group 立即告警，
并限制高风险维护、重平衡和升级。

## 8. Split brain 与 fencing

官方 [General Questions](https://doc.beegfs.io/latest/trouble_shooting/general.html#what-happens-with-beegfs-in-a-split-brain-scenario)
说明：网络分区时只有 management 所在分区继续成为有效系统；另一分区服务阻塞/拒绝访问，持续过久后返回 I/O error，
目的是避免两边同时修改同一文件。

这个设计依赖两个前提：

- management 只有一个权威实例；
- 被隔离节点确实无法继续被部分客户端当成 primary。

外部 HA 若在两个站点同时启动各自复制的 mgmtd.sqlite，会破坏前提。任何跨机房方案都必须设计 quorum/fencing，
而不是简单 rsync DB + VIP。

## 9. File System Check

### 9.1 工作方式

`beegfs-fsck` 从所有 metadata/storage services 并行收集对象信息，在运行 fsck 的机器建立本地数据库，然后做交叉关系检查。
它能发现/处理的典型问题包括：

- dangling/missing dentry、inode；
- orphaned chunks；
- wrong owner/link count/attributes；
- disposal 与普通命名空间异常；
- stripe pattern 引用不存在 target/chunk；
- primary/secondary 或 target 内部结构问题（具体类型依版本）。

官方称数千万对象常可在一小时量级收集，但数亿对象会显著更久；这不是 SLA。速度取决于 metadata/storage 数、目录布局、
网络、本地 fsck DB 设备和前台负载。

### 9.2 在线模式风险

扫描时文件系统继续变化，会出现时间切片不一致：先看到 metadata，后扫 storage 时 chunk 已删除/新建，形成 false positive。
因此：

- 最可靠是一致性维护窗口；
- 在线首先 read-only 检查，保存报告并复核活跃对象；
- 不要对大批结果直接 `--automatic` repair；
- 修复前确认所有 targets 都 `Good` 且没有 resync；
- 对疑似 metadata 丢失尤其谨慎：自动删除“无 metadata 引用”的 storage chunks 可能把唯一数据删掉。

### 9.3 本地 fsck DB 容量

对十亿级 namespace，fsck 本地 DB、临时排序和扫描时间本身可能达到不可接受规模。上线前要用增长曲线外推：

- 每百万文件 DB bytes；
- scan objects/s；
- metadata/storage 网络读；
- 前台 p99 影响；
- repair journal/可回滚性。

“有 fsck”不等于“能在 SLA 内检查全量系统”。

## 10. 备份

### 10.1 Management DB

官方 [Backup](https://doc.beegfs.io/latest/advanced_topics/backup.html) 建议干净停止 management service 后复制
`mgmtd.sqlite`（以及 WAL/配置相关状态），避免拿到不完整文件级副本。应一起备份：

- management DB；
- service configs；
- `conn.auth`；
- TLS certificate/private key；
- license file；
- target/node identity files和 HA 编排配置。

恢复必须验证 target IDs、buddy mappings、root owner、storage pools、quota，而非仅做 SQLite integrity check。

### 10.2 Metadata stores

备份工具必须保留 xattr、hardlink、permissions、ownership、timestamps 和目录结构。只复制 0-byte metadata files 而漏掉
`user.fhgfs` xattr，相当于空备份。对 mirrored metadata，两份实时镜像不是两个独立历史 backup generations。

### 10.3 Storage targets

Storage chunks 是普通文件但使用 BeeGFS target-local 布局。按文件系统/volume snapshot 备份时要保持 target identity 和时间点。
逐文件备份不需要 metadata xattr 的同等要求，但仍需 mode/timestamps/sparse/content 完整。

### 10.4 全文件系统一致快照

BeeGFS 核心组件没有一个跨全部 metadata/storage targets 的全局 snapshot transaction。官方说明完整一致的全系统备份需要停止服务；
在线分别备份各 target 得到的是时间上不一致的集合，不能保证任意文件都处于同一 namespace/data epoch。

可以用应用 quiesce、LVM/ZFS snapshots 和编排缩小窗口，但仍需证明各节点 snapshot 的 barrier。对关键数据，优先用应用级 immutable
dataset/version/manifest，或在上层复制完成后发布。

## 11. Remote Storage Targets 的恢复边界

RST 可把文件异步同步到 S3-compatible provider，支持 object versioning 时能增强历史保护，但不能自动替代 backup：

- `remote status` 默认可只看 Remote 本地 job DB，不一定查询远端对象是否被外部修改；
- push 会覆盖同名远端对象，官方建议启用 snapshot/object versioning；
- 8.4 auto-sync 是 best-effort，cooldown queue 在 Remote service restart 后可丢；
- stub 前必须确认上传成功，永久删除本地前还要再次显式 verify/push；
- Remote DB 丢失会损失 job/路径同步历史，远端内容本身仍需重新发现/关联；
- RST 不是同步第三副本，最新本地 mutation 与远端之间存在 cooldown/job lag。

因此 RPO 由最后一次成功且验证的 push 决定，不是文件 close 时间。

## 12. 故障矩阵

| 故障 | 健康镜像下预期 | 数据风险 | 关键动作 |
|------|----------------|----------|----------|
| 单 storage service/host down | 目标状态传播后切到 buddy | 切换窗口；降级期单副本 | 确认 role/state，修主机，监控 resync |
| 单 metadata service down | 对 mirrored 树切到 buddy | 未镜像子树不可用；状态窗口 | 核验哪些目录实际 mirrored |
| Secondary down | Primary 可继续写 | 冗余丢失，第二故障危险 | 立即告警/恢复，不做无关维护 |
| Primary down during resync | 取决于当前角色/一致状态 | 可能只有 resync source 是完整副本 | 禁止手工强制错误方向，联系支持 |
| Management down | 稳态部分 I/O可能继续；自动切换/注册受阻 | 故障期间无法形成新权威视图 | 恢复单实例 DB/VIP，禁止双启 |
| Management DB lost | 服务拓扑/映射丢失 | 误重建可造成严重数据不可达/覆盖 | 从已验证备份恢复，不自动重新注册代替 |
| 客户端 crash | session 超时后清理 | buffered 未 flush 数据丢；disposal 暂留 | 观察 30m 类 timeout、回收和应用重试 |
| 单底层磁盘 error | 由 RAID/ZFS/Buddy 组合处理 | 静默损坏可能未检测；secondary fsync caveat | scrub/checksum、设备隔离、勿盲目 resync |
| 网络分区 | management 分区继续，另一侧停止 | 错误 HA 可形成 split brain | quorum/fencing，验证连接矩阵 |
| 误删/勒索 | 立即复制到 buddy | 镜像两份都被删除/加密 | 独立、不可变、离线/对象版本备份 |
| 全站点故障 | 核心 Buddy 不跨站点共识 | 站点级数据/管理面丢失 | 异地备份/RST/应用复制与恢复演练 |

## 13. RPO/RTO 结论

不能为“BeeGFS”给一个脱离配置的统一 RPO/RTO：

- 未镜像 target：节点/RAID 丢失可导致数据丢失，RPO 到最近备份；
- 健康 Buddy + 正常 fsync：常见单节点故障目标是保留已稳定写，但仍受记录的故障窗口和底层设备影响；
- Buddy degraded：RPO 取决于唯一 current primary，第二故障可能丢失降级期全部变更；
- RST：RPO 到最后一次验证的成功同步；
- Management：RTO 由外部 HA/DB restore 决定，DB 丢失可能远超服务进程重启时间；
- 全局一致恢复：若只有非一致在线 backups，恢复后的 fsck/人工决策可能主导 RTO。

SLA 应针对具体故障集合和数据类别分别定义，例如：

```text
单 storage host 故障：RTO <= X min，已 fsync 文件 RPO = 0（在已验证硬件/配置下）
management host 故障：RTO <= Y min，DB transaction RPO = 0（外部同步存储 + fencing）
双 buddy/机架故障：从 immutable backup 恢复，RPO <= Z h，RTO <= W h
```

## 14. 推荐运行手册

### 14.1 每日/持续

- `beegfs health check`，告警任何非 Online/Good、resync、容量池降级；
- 监控每 target free bytes + free inodes、I/O latency、network errors、session errors；
- 备份 mgmtd DB/config/auth/license 并做离线校验；
- 监控 disposal/orphan、resync backlog、Remote failed jobs；
- 底层 SMART/RAID/ZFS pool/scrub 告警与 BeeGFS target 告警关联。

### 14.2 故障时

1. 保存 health/target/buddy/node 状态、日志和时间线；
2. 确认谁是 current primary、哪侧包含最新写；
3. 不在未确认传播完成时手工反复切状态/角色；
4. 降级期间冻结升级、重平衡和高风险维护；
5. 恢复后监控 resync 到 Good，并运行针对性只读 fsck/应用 checksum；
6. 对数据丢失可能性保留旧设备/副本，不先做破坏性自动修复。

### 14.3 定期演练

- kill/断电 primary、secondary、management；
- 断 management 与一半节点网络，验证 split-brain 行为；
- 注入 local FS I/O/fsync error；
- 从空白 management host 恢复 DB/VIP/auth/license；
- 恢复一个 metadata store/service 和一个 storage target；
- 全文件系统从备份/RST 重建并用 fsck+manifest 校验。

## 15. 对 LightStore 的启示

1. 借鉴 `reachability × consistency` 二维状态，不把离线、落后、修复中、坏副本混成一个枚举。
2. LightStore Manager 已使用 Raft，应让 node/volume/placement epoch 进入一致日志，避免 BeeGFS management 外部 HA 的正确性负担。
3. 副本/EC repair 必须携带 source generation、commit index/checksum，防止“旧副本成为新 primary 后反向覆盖”。
4. 降级写策略应显式暴露当前 durability level，且在第二故障前阻止危险运维。
5. Storage selective repair 可借鉴“最后成功通信时间 + safety window”，但 LightStore volume/record 还应使用 mutation index/extent map，
   不只依赖 mtime。
6. 保留独立 fsck/reconciler：Raft 保证单组日志一致，不自动保证跨 Meta Range、Location、Data volume、EC shards 的引用闭环。
7. Backup 必须从第一天定义全局 checkpoint/manifest，而不是等规模上来后再用逐节点文件复制拼接。
