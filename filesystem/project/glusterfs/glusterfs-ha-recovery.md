# GlusterFS 高可用、恢复与灾备

## 1. 高可用模型

GlusterFS 没有一个统一 failover 状态机。不同层分别恢复：

- protocol/client 检测 brick connection 并重连；
- AFR/EC 根据剩余 children 与 quorum 决定 I/O；
- SHD 根据 index/xattr 恢复 replicas/fragments；
- DHT 通过 layout/linkfile/lookup-everywhere 维持 placement；
- `glusterd` 恢复 brick processes 和配置；
- rebalance/replace/remove-brick 处理永久 topology 变化；
- snapshot/geo-rep 处理本集群之外的回滚和灾备。

因此 RTO 不是单个“主备切换时间”，而是：

```text
故障检测 + client FOP 失败/重试 + quorum decision
+ 必要的 reconnect/reopen + 前台可服务时间
+ 后台 redundancy 恢复时间 + backlog 清零时间
```

前台恢复不等于冗余恢复；heal backlog 未清零时发生第二故障，风险显著升高。

## 2. 故障矩阵

| 故障 | 前台行为 | 后台动作 | 数据风险 |
|------|----------|----------|----------|
| 单 replica brick 进程宕机 | replica 3/arbiter 满足 quorum 时继续；replica 2 取决于配置 | child reconnect，index self-heal | pending 数据增长，第二故障风险 |
| 单 EC brick 宕机 | 缺失 ≤ R 时 degraded I/O | EC reconstruct/heal | CPU/网络/尾延迟增加 |
| 整节点宕机 | 该节点所有 bricks child-down | 按各 replica/disperse set 分别 heal | 若同 set 多 bricks 同节点，容错被同时击穿 |
| client 宕机 | 该 client 未完成 write-behind 丢失；locks 被清理 | 重挂载/重连后 lookup/heal | 应用未 fsync 数据与 lock continuity |
| client-brick 网络分区 | 不同 clients 可能看到不同 child-up 集合 | 恢复后 pending/heal | replica 2 无 quorum 可脑裂 |
| trusted-pool 管理分区 | 已有 I/O 可能继续，CLI transaction 失败；server quorum 可停 bricks | peer/config resync | 错误 server quorum 会扩大不可用 |
| 单 brick 磁盘永久损坏 | 对应 set degraded | replace-brick/新 brick + full/index heal | pure distribute 无恢复源 |
| silent content corruption | 默认可能直到 read/应用 checksum 才发现；bitrot 开启可 scrub 发现 | 标记 bad、从健康冗余恢复/人工介入 | 多副本同源损坏或无 checksum 时可能静默 |
| DHT layout/linkfile 损坏 | lookup/readdir/rename 异常、文件“消失” | layout/dir heal、rebalance、手工取证 | 错误 fix/删除 linkfile 可丢 namespace |
| near-full/full | 新 create/write/rebalance/heal 失败 | 扩容、迁移、释放空间 | heal 无工作空间会延长欠冗余 |
| 全站点故障 | 本地 replicas 同时不可用 | geo-rep secondary 提升/备份恢复 | RPO 取决于最后完成同步/checkpoint |

## 3. 故障检测

### 3.1 Client 到 brick

v11.2 protocol client 的重要基线：

- ping timeout 默认 42 s；
- per-FOP frame timeout 默认 1800 s；
- TCP keepalive/user timeout、应用超时和 gateway 超时还可能叠加。

42 s 不等于所有 I/O 都在 42 s 内失败：请求可能卡在 lock queue、server thread、磁盘、translator frame 或 gateway 层。故障演练必须用应用端 latency/error timeline，而不是从一个配置值推算 RTO。

### 3.2 Brick backend health

POSIX translator 可周期检查 brick filesystem；磁盘 I/O error、read-only remount、ENOSPC、inode exhaustion 和 process crash 都可能表现为 child failure。容量监控必须同时看：

- bytes free；
- inodes free；
- XFS/块设备错误；
- brick process online；
- client 视角 child-up；
- volume heal/rebalance 状态。

### 3.3 Management peers

`gluster peer status` 只说明 glusterd peer connectivity，不说明每个 client 到每个 brick 的数据面可达。反过来，CLI peer disconnected 也不必然代表稳态 I/O 已中断。

## 4. Self-Heal 架构

### 4.1 Heal 触发者

Replicate/disperse 的 heal 可由：

- client lookup/open/read transaction；
- brick child-up 事件；
- 周期 SHD index crawl（默认基线 600 s）；
- `gluster volume heal VOL` 手工触发；
- `gluster volume heal VOL full` 全量 crawl；
- brick replacement/restore 后触发。

### 4.2 Index heal

正常 transaction 的 index translator 在 `.glusterfs/indices/xattrop/` 建立以 GFID 命名的 hardlink。成功 post-op 后清除；故障/崩溃留下 entry。

SHD index heal：

1. 每节点 SHD 枚举本地 index entries；
2. 对每个 GFID 在完整 replica set 做 lookup；
3. 获取 self-heal domain locks；
4. 判 source/sinks/split-brain；
5. 执行 metadata/data/entry heal；
6. 清 pending/dirty 和 index。

优点：工作量与故障期间 touched files 相关，不必每次扫描全 namespace。

限制：

- index entry 是“可能需要检查”，brick 在 post-op 后但删 index 前崩溃也会留下 false positive；
- parent directory 未 heal 时 child 可能跳过，留待下轮；
- split-brain 不会自动完成；
- index 本身损坏/丢失时会漏掉候选，需要 full crawl/外部清单。

### 4.3 Full heal

Full heal 从 volume root 递归 `readdir/lookup` 所有 entries，检查 AFR/EC 状态。它适合整块新盘替换或 index 不可信场景，但复杂度接近 O(namespace files × replica width)。

海量小文件下 full heal 的问题：

- 大量随机 metadata I/O，而非顺序复制数据；
- 目录扇出与 GFID lookup；
- heal locks 与前台 create/unlink/stat 竞争；
- 无可靠“固定分钟数”估算；
- 重启/再次故障可能反复扫描。

因此必须把 full-heal 完成时间作为容量设计输入，而不是事故后才测。

### 4.4 Data heal 算法

AFR 可选：

- `full`：从 source 完整复制；
- `diff`：比较分块 checksum，只复制差异 blocks；
- 未指定时按文件存在/大小等动态选择。

v11.2 默认单文件 self-heal window 为 8 个 128 KiB blocks，SHD 并行度和 queue 可调。增加并行数会缩短 backlog，也可能压垮同一磁盘并恶化前台 P99。

### 4.5 EC heal

EC 用任意 K 个健康 fragments 重建 missing/bad fragments：

- 读流量约来自 K 个 sources；
- 编码 CPU 在执行 heal 的 client/SHD；
- 新 fragment 写目标 brick；
- 需要 locks 保证与前台 write/truncate 不冲突；
- 缺片越多，source bandwidth 与容错余量越紧张。

EC heal 不是 RAID controller 内部过程，而是网络分布式 FOP，会与业务共享 clients、network 和 backend disks。

## 5. Heal Backlog 的生产解释

### 5.1 关键命令

```bash
gluster volume heal VOL info
gluster volume heal VOL info summary
gluster volume heal VOL info split-brain
gluster volume heal VOL statistics heal-count
gluster volume status VOL detail
```

不同版本/发行包输出字段会变化，上线前应固定解析器测试样例。

### 5.2 应看年龄，不只看数量

建议每个 replica/disperse set 监控：

- pending entries 当前值；
- oldest pending age；
- new pending rate；
- healed rate；
- split-brain count；
- failed/possibly-healing count；
- brick child-up 和 I/O error；
- SHD queue/threads；
- heal bytes 与前台 P99。

“backlog=1000”对 1 秒内产生且高速下降与持续 7 天是完全不同的风险。最老年龄比瞬时 count 更能表达冗余暴露窗口。

### 5.3 Admission control

当 heal 追不上写入：

1. 先停止 topology 变化、rebalance、bitrot scrub；
2. 限制新写或迁走 workload；
3. 保证 source brick 健康且不过载；
4. 小步增加 SHD threads/window，观察磁盘 latency；
5. 若 split-brain 增长，立即停止自动“修复”并保全证据。

## 6. Brick Replacement 与永久恢复

### 6.1 Replicated/Arbiter volume

安全流程的原则：

1. 确认故障 brick 和 replica set；
2. 检查其他 replicas 没有 split-brain、checksum/业务数据正确；
3. 新 brick 使用独立受支持 filesystem，容量/inode/xattr 足够；
4. 按官方版本流程 replace/add-remove；
5. 触发并监控 full/index heal；
6. backlog 清零后比较 GFID、data 和 xattr；
7. 再恢复正常冗余 SLO。

Arbiter replacement主要复制 namespace/xattr，不代表两个 data bricks 可同时丢失。

### 6.2 Pure distribute

没有 source 可恢复丢失 brick。若原盘仍可读，必须 add new brick + remove/migrate；原盘已永久丢失则该 brick 上文件只能从外部 backup/应用重建。

### 6.3 Disperse

只要同 set 存在至少 K 个正确 fragments，即可重建。开始前必须确认没有额外 silent corruption；否则“可用 K 个”不等于“K 个正确 fragments”。这也是内容 checksum/scrub 的价值。

## 7. BitRot Detection

### 7.1 工作方式

Bitrot 默认关闭。启用后：

- signer 对文件内容计算 SHA-256，结合对象 version 保存 signature；
- scrubber 周期读取内容并重新计算 checksum；
- scrub 前后检查 version，避免把并发修改误判为 corruption；
- mismatch 标记为 bad object 并记录日志/状态。

默认 scrub frequency 为 biweekly、throttle 为 lazy（仅在功能启用时有意义）。

### 7.2 它能与不能做什么

能做：

- 发现磁盘未报错但内容改变；
- 发现绕过 Gluster 直接修改 backend data；
- 给复制/EC 修复提供“这个 fragment 不可信”的信号。

不能保证：

- 默认就有端到端 checksum（因为默认关闭）；
- 自动知道哪份业务语义正确；
- 在所有副本同样损坏时恢复原数据；
- 替代应用 checksum、不可变 backup 和 media patrol；
- 没有扫描成本地即时发现所有 corruption。

### 7.3 上线建议

- 先在相同 file-size distribution 的 staging 测 signer/scrub IOPS；
- 错开 heal/rebalance/backup 窗口；
- 监控 unsigned queue、last scrub complete、bad objects；
- 对故意 bit-flip 做发现与从健康副本恢复演练；
- 明确 bad-file read 是失败、回退还是 heal，按 v11.2 实测。

## 8. Snapshot

### 8.1 实现边界

Gluster snapshot 不是在 translator 中为每个 inode 做 MVCC，而是依赖每个 brick 位于独立 LVM thin LV（v11 也扩展过其他 backend 支持，但部署必须按目标 backend 文档验证）。管理面在各 bricks 上创建 backend snapshots，并用 barrier/协调得到 volume 级 crash-consistent point。

前提包括：

- 每个 brick 独占受支持的 thin-provisioned volume/backend；
- thin pool 有足够 metadata/data space；
- 所有 peers/brick snapshot 操作成功；
- snapshot daemon/挂载路径与 `.snaps` 行为正常。

### 8.2 Crash-consistent 不等于 application-consistent

Snapshot 能提供类似突然断电后的文件系统一致性点，但不会自动：

- flush database buffer pool；
- 完成应用 transaction/checkpoint；
- 让 write-behind client queue 全部落盘；
- 让跨 volume 应用状态保持原子；
- 把 geo-rep primary/secondary 自动对齐。

数据库/VM 应用需要 freeze/quiesce、fsync、guest agent 或外部 orchestrator。

### 8.3 Thin pool 风险

- snapshot COW 增长耗尽 thin pool 会影响 origin；
- snapshot 数量增加 metadata 与写放大；
- 长期 snapshot 不是低成本 backup；
- restore 是破坏性切换，必须先备份当前 origin；
- 需要定期做真正 mount/read/checksum restore test。

## 9. Geo-Replication

### 9.1 数据路径

Geo-rep 是 primary volume 到 secondary volume 的**异步、增量、单向**复制：

1. primary brick changelog 记录 create/modify/rename/unlink；
2. `gsyncd` workers 消费 changelog；
3. 通过 SSH 调用 secondary 端 gsyncd/rsync/tarssh 等同步；
4. changelog 不足/初始同步可进入 directory crawl/XSync；
5. checkpoint 表示“checkpoint time 以前的变更是否已全部同步”。

Replica set 中通常只选一个 active worker，其他 passive；可用 `gluster_shared_storage` meta volume 做 worker lock，避免多个同组 workers 同时 active。

### 9.2 一致性与 RPO

- primary FOP 成功不等待 secondary；
- status `Active/OK` 不代表 backlog=0；
- checkpoint completed 才能证明该时间点以前的变更已到达；
- secondary 不应被应用并发写，否则冲突没有双向 merge；
- restart/config change 可能重复同步，协议应幂等，但 RPO 仍取决于 backlog。

推荐对外表达：

```text
DR protected through: <last completed checkpoint time>
current replication lag: <now - last synced/checkpoint>
```

而不是“geo-rep 正常，所以 RPO=0”。

### 9.3 Failover/Failback Runbook

1. 确认 primary 不会恢复并继续接受写，实施网络/电源 fencing；
2. 记录最后完成 checkpoint、各 worker last synced 与未完成 backlog；
3. 校验 secondary heal/split-brain/brick 状态；
4. 将 secondary 暴露给应用，建立新写入起点；
5. 记录潜在丢失时间窗并做业务 reconciliation；
6. failback 时创建新的单向复制关系或全量重同步，不把旧 primary 直接双向接回；
7. 在重新开放前比较业务 checksum/manifest。

### 9.4 与 snapshot 的组合

官方文档要求避免 primary/secondary snapshots restore 顺序错乱。常见流程是 pause geo-rep、分别对 secondary 和 primary 建对应 snapshots、再 resume。恢复时两边都要恢复到匹配点，再强制 resume。实际生产应由外部编排记录 session、checkpoint 与 snapshot UUID。

## 10. 灾难恢复层级

| 机制 | 保护对象 | RPO | 能否防误删/勒索 | 能否防站点故障 |
|------|----------|-----|---------------|----------------|
| replica/arbiter/EC | 当前在线数据 | 同步 FOP 边界 | 通常不能，删除也同步 | 只有故障域真正跨站且 RTT/SLO 可接受时 |
| self-heal | 暂时离线/缺片 | 恢复当前最新 source | 不能；错误 source 还可能扩散 | 否 |
| bitrot scrub | silent corruption detection | 取决于 scrub 周期 | 不能防逻辑删除 | 否 |
| local snapshot | crash-consistent point | snapshot 周期 | 能回滚部分逻辑错误，受同集群权限/容量影响 | 否 |
| geo-rep | 远端异步副本 | replication lag/checkpoint | 默认会复制删除；可配 ignore-deletes 但语义改变 | 是 |
| offline/immutable backup | 独立历史副本 | backup 周期 | 是，若权限和保留真正隔离 | 是 |

成熟方案至少需要在线冗余 + 可校验 snapshot/backup + 站点复制，不应让一种机制承担全部职责。

## 11. 恢复演练验收项

- kill 单 brick、单 node、半网 partition 后的应用 P50/P99.9/error timeline；
- replica 3/arbiter 每种两节点组合的读写结果；
- replica 2 故意双侧写，确认监控能发现 split-brain；
- client write-behind 中 kill -9 与 power-cycle 后的数据边界；
- 1%、10%、100% namespace dirty 时 index/full heal 完成时间；
- EC 缺 1..R fragments 的 degraded read/write 与 rebuild；
- bitflip 单副本后的 bitrot detection + repair；
- near-full 下 heal/rebalance 是否能推进；
- LVM thin snapshot 创建、挂载、restore 与 pool-full；
- geo-rep WAN 断开 24h 后 backlog catch-up、checkpoint 与 failover/failback；
- 所有演练结束后 GFID/xattr、heal count 和业务 checksum 一致。
