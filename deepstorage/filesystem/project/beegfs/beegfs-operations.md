# BeeGFS 部署、运维与性能工程

## 1. 运维结论

BeeGFS 易于“把服务跑起来”，但生产可靠性高度依赖整套基础设施工程：metadata/storage 本地文件系统、RAID/ZFS、
management 外部 HA、网络/RDMA、客户端内核兼容、Buddy Group 故障域、license、备份和监控缺一不可。

推荐把它当成一个专用 HPC 存储平台，而非随手安装在通用虚机上的应用组件：

- 元数据用低延迟 NVMe/SSD 与 RAID1/10，优化 inode/xattr/journal；
- 存储按 target 隔离本地 RAID/XFS/ZFS，保留足够 free bytes/inodes 和重建余量；
- 数据网络与管理网络有清晰容量和故障域设计，RDMA 只在经过验证的软硬件组合上启用；
- Management DB 有单写者 HA、fencing、备份和恢复演练；
- 每个 Buddy Group 跨主机/机架，降级立即告警；
- 条带和缓存以 workload 目录配置，不能只有一套 root 默认值；
- IOR 峰值只是验收的一小部分，必须同时测 mdtest、fsync、failover、resync 和真实应用 p99。

## 2. 推荐生产拓扑

### 2.1 角色分离

中大型生产集群建议：

- management：两台候选主机 + 外部 active/passive HA；单一 DB 存储与可靠 fencing；
- metadata：偶数个 services/targets，两两 Buddy；低延迟本地介质；
- storage：多个服务节点，每节点一个或多个独立 targets；本地 RAID/ZFS；
- clients：计算/登录/数据传输节点，统一内核和 client module 发布流程；
- monitoring：独立时序后端/Grafana 与日志平台；
- fsck/administration：有足够 NVMe 临时空间的运维节点；
- Remote/Sync/Watch：使用 RST 时单独评估 CPU、DB 和对象存储网络，避免抢占核心 target 带宽。

小型集群可 colocate 服务，但故障域会耦合：一台主机宕机可能同时丢一个 metadata primary、多个 storage primaries 和 monitoring。
Colocation 还会竞争 page cache、NUMA、NIC、PCIe 和本地 FS queue。任何合并部署都要按“主机整体失效”校验 Buddy 配对。

### 2.2 Target 划分

一个 storage service 可管理多个 targets。常见做法是每个独立 RAID set/local FS 一个 target，而非把所有盘合成一个巨型 target：

- 较小故障/重建域；
- capacity pool 和性能问题可定位到具体 target；
- 多 targets 增加调度并行和文件分布选择；
- 但 targets 太多会增加连接、状态、fsck、stripe metadata 和运维对象数。

Metadata service/store 也应避免与它的 Buddy 共用同一底层 array/controller。只有两个目录的挂载点不同不等于不同故障域。

## 3. 本地存储设计

### 3.1 Metadata

官方 [Metadata Node Tuning](https://doc.beegfs.io/latest/advanced_topics/metadata_tuning.html) 的关键建议与原因：

| 项目 | 建议 | 原因 |
|------|------|------|
| 介质 | SSD/NVMe | 小随机 xattr/dentry/journal latency 决定 metadata p99 |
| RAID | RAID1/10 优先 | 避免 RAID5/6 小写 read-modify-write |
| 本地 FS | ext4 常见推荐 | 小文件、xattr、hardlink/目录表现成熟 |
| inode size | 常见 512 B；宽条带/ACL/xattr 可考虑 1024 B | 尽量把 `user.fhgfs` xattr 内联 |
| inode ratio | 按目标对象数预留，格式化前确定 | ext4 inode 数固定，可能先于 bytes 耗尽 |
| features | `dir_index`，极大目录还需 `large_dir` | 支持大目录索引；仍不建议单热大目录 |
| mount | `user_xattr`、`noatime/nodiratime` 等按支持建议 | 元数据存 xattr，避免无用本地 atime 写 |

不要盲目复制文档中的历史 sysctl/IO scheduler 数字。内核、NVMe、blk-mq、ZFS 和发行版演进很快；应把官方值作为起点，
用当前受支持系统的 mdtest/p99 和设备 telemetry 验证。

### 3.2 Storage

官方 [Storage Node Tuning](https://doc.beegfs.io/latest/advanced_topics/storage_tuning.html) 常推荐 XFS，尤其是 RAID 上持续流式吞吐。
设计要点：

- RAID stripe geometry 与 XFS `su/sw`、controller/cache 对齐；
- inode size/目录性能仍重要，因为每个 chunk 是本地文件；
- `noatime` 避免读放大；
- dirty page 比例不要大到造成数十秒 flush stall；
- hardware write-back cache 必须有 BBU/PLP，并验证 flush/FUA；
- ZFS 若使用 checksum/compression，应按真实 workload 评估 CPU/ARC，不能用可压缩数据跑虚高 IOR；
- 定期 RAID/ZFS scrub，Buddy Mirror 本身不发现所有 silent corruption。

### 3.3 空间预留

Target 不能跑到 100%：本地 FS journal、metadata 操作、resync 临时文件、rebalance 双份、disposal/orphan 和 RAID 重建都需要余量。
Capacity-pool 阈值应以“可操作空间”而非仅百分比设计。大 target 的 1% 可能很大，小 target 的 5% 又可能不足一次大文件迁移。

## 4. 容量规划

### 4.1 数据容量

无压缩、忽略 sparse/FS overhead 的粗略公式：

```text
RAID0 BeeGFS physical chunks ≈ logical data
BuddyMirror physical chunks  ≈ 2 × logical data

raw disk needed ≈ BeeGFS physical chunks
                  / local RAID usable ratio
                  / (1 - operational reserve)
```

还要加：

- chunk inode/dentry 和 local FS metadata；
- sparse/预分配差异；
- rebalance/resync/backup 临时空间；
- Remote/Sync job DB；
- 底层 snapshot（若启用）和对象版本历史。

BeeGFS 核心没有 EC，Buddy Mirror 的容量效率约 50%（再乘本地 RAID 损耗）。若冷数据成本由 EC 决定，BeeGFS 更适合作为热层，
再由 RST/外部 pipeline 进入对象存储；但必须接受异步 RPO。

### 4.2 Metadata 容量

不要用单一“每文件 X bytes”直接乘总文件数。用代表性 namespace 样本实测：

1. 建立真实文件名长度、目录深度、stripe count、ACL/user xattr、hardlink/RST 配置；
2. 记录用户 entries、底层 inode 使用、allocated blocks、journal/metadata FS 空间；
3. 分别测 mirrored/non-mirrored；
4. 加 disposal、fsck、升级和增长 reserve；
5. 对 ext4 在 mkfs 前确定 inode count/inode size。

宽条带会扩大 serialized stripe vector；ACL/xattr 和 RST 信息会增加 xattr 负担。Metadata mirror 再复制一份目标内容。

### 4.3 内存

主要消费者：

- client buffered/native cache、connections 和 RDMA buffers；
- metadata/storage worker stacks、sessions、open handles、inode/dentry/page cache；
- 8.4 remote invalidation watcher：默认规模可达约 5000 万 entries × 128 B，约 6 GiB/metadata service；
- 每客户端 invalidation queues；
- Linux/ZFS cache、monitoring 和 Remote/Sync DB cache；
- fsck 本地数据库和排序。

RDMA connection memory 约随 `clients × services/targets × connections × buffers` 增长。大集群不能只按单连接性能最大化 buffer，
必须计算最坏连接矩阵。

### 4.4 网络

健康 Buddy write 的 storage 网络至少包含：

```text
client -> primary: logical write traffic
primary -> secondary: approximately another logical write traffic
```

再加协议、metadata、resync、rebalance、backup/RST 和重试。每个 storage node 的东西向 buddy traffic 与南北向 client traffic
可能共享同一 NIC/TOR。Failover 后一个节点还可能同时承接更多 primary 负载。

容量目标不应超过链路理论值的高比例后才考虑故障；应在“一台 storage host/一个 rail/TOR 失效 + resync”下仍满足关键 SLA。

## 5. 网络与 RDMA

BeeGFS 支持 TCP 和 RDMA，并可基于接口过滤/优先级和 multi-rail 选择路径。RDMA 的优势是降低 CPU copy/协议开销和延迟，
但引入 HCA firmware、OFED/inbox driver、kernel ABI、PKey/GID、MTU、memory registration 和交换网络运维复杂度。

建议顺序：

1. 先让 TCP 在目标硬件达到稳定基线；
2. 使用官方 [RDMA Support](https://doc.beegfs.io/latest/advanced_topics/rdma_support.html) 对照支持组合；
3. 分别验证 client↔metadata、client↔storage、primary↔secondary；
4. 注入 rail/HCA/port failure，确认 failover 而非长时间 hang；
5. 计算 RDMA buffer memory，防止客户端数增长后 OOM；
6. 比较真实应用 CPU 与 p99，不只看大块吞吐。

多 rail 不是自动带宽翻倍保证；地址优先级不一致、非对称路由或某 rail 局部丢包会放大尾延迟。

## 6. 条带策略治理

按 workload 建目录模板，而不是让用户自由试错：

| 目录类型 | 倾向 | 需要验证 |
|----------|------|----------|
| 大 checkpoint | 多 targets、较大 chunk、可选 mirror | 单文件聚合带宽、fsync 时间、降级窗口 |
| 训练 dataset shards | 中等 targets，读优化 | 多客户端 cache、顺序/随机混合、元数据 open rate |
| 海量小文件 | 1 target 或很少 targets | metadata/storage inode、create/stat p99 |
| 临时 scratch | RAID0，可接受重算 | 故障时作业行为、容量回收 |
| 关键结果 | mirror + 显式 fsync + backup/RST | RPO、对象版本、恢复演练 |

对每种模板记录：storage pool、pattern、chunk size、target count、mirror、ACL/quota、cache/lock 需求、backup policy。
修改目录模板不会修正已有文件，变更记录必须包含“新旧数据如何迁移/识别”。

## 7. 监控与告警

### 7.1 必监指标

| 层 | 指标/状态 | 关键告警 |
|----|-----------|----------|
| Management | 进程、DB/WAL、transaction latency、license、last contact | mgmtd 不可达、DB/FS space、HA 双实例风险 |
| Target | reachability + consistency、role、resync | 任意非 Online/Good、频繁切换、resync 失败 |
| Capacity | free bytes、free inodes、capacity pool | Low/Emergency、Buddy 容量不对称 |
| Metadata | ops/s、queue/worker、latency、open sessions、cache/watch | create/stat p99、inode exhaustion、watch memory/overflow |
| Storage | read/write bytes/ops/latency、session errors、local FS | 慢 target、dirty flush stall、I/O/fsync error |
| Network | TCP retransmit、RDMA errors、rail utilization | 单 rail 拥塞、PFC/ECN/CRC/timeout |
| Client | retries、target-state age、cache/lock errors、module build | 大面积挂载/IO hang、版本漂移 |
| Data safety | RAID/ZFS/SMART/scrub、backup age | degraded RAID、checksum error、备份超 RPO |
| Background | fsck/rebalance/resync/RST jobs | backlog、不前进、前台 p99 受损 |

8.4 Monitoring 增加 metadata service/store 的 capacity/health 指标（release notes 称 metadata target metrics）；
可用官方 [Monitoring service](https://doc.beegfs.io/latest/advanced_topics/mon.html)、InfluxDB/Grafana/OTel
（不同组件能力不同）和企业监控系统组合。不要只看集群总吞吐：stripe request 由最慢 target 决定，
per-target heatmap 更有诊断价值。

### 7.2 告警原则

- `Needs Resync` 是 page，不是普通 warning；
- bytes 和 inodes 必须分别告警；
- 对 p99/p99.9、queue depth 和 retries 告警，不只看平均带宽；
- 把 BeeGFS target、主机、RAID member、NIC/rail、机架关系放进标签，能判断共同故障域；
- 任何 state 手工变更、buddy role 变更、license reload、rebalance/repair 都进入审计日志。

## 8. 基准与验收方法

官方 [Benchmarking](https://doc.beegfs.io/latest/advanced_topics/benchmark.html) 提供分层工具思路。推荐矩阵：

### 8.1 分层定位

1. **Local device/FS**：fio，测顺序/随机、sync、queue depth、降级 RAID；
2. **Network**：iperf/厂商 RDMA 工具和 BeeGFS network benchmark，测单流、多流、rail fail；
3. **Storage targets**：`beegfs benchmark`/StorageBench，隔离 client VFS/metadata；
4. **Metadata**：mdtest，分别测均匀多目录和单热目录；
5. **End-to-end**：IOR，包含 shared file/file-per-process、read/write、fsync；
6. **Application**：训练 dataloader、checkpoint、编译、仿真真实 trace。

### 8.2 不能省略的场景

- 空 cache 与 warm cache；
- 1/10/100/全部 clients 的扩展曲线；
- 文件大小分布，而非只有超大文件；
- Buddy on/off、一个 target slow/offline、resync 同时运行；
- 容量 70/85/95% 水位；
- TCP/RDMA、单/多 rail；
- `write` vs `fsync`、close storm；
- metadata create/stat/unlink/readdir/rename；
- p50/p95/p99/p99.9 和最大 hang，不能只报 aggregate GB/s。

### 8.3 数据质量

每次测试固定并记录：BeeGFS tag/package、client kernel/module、firmware/driver、配置 diff、target pattern、数据可压缩性、
cache drop 方法、作业拓扑和背景任务。否则不同测试结果不可比较。

## 9. 扩容、退役与重平衡

### 9.1 增加 target

新 target 注册并进入 pool/capacity pool 后，主要承接新文件。上线步骤：

1. 预建底层 RAID/FS，验证性能、inode、mount 和掉电语义；
2. 分配稳定 target identity，防止克隆旧 identity；
3. 加入正确 storage pool；
4. 若镜像，先设计 Buddy pair/failure domain，不长期留单 target；
5. 观察新分配和容量/性能倾斜；
6. 决定是否启动历史 rebalance。

### 9.2 重平衡

历史 rebalance 是在线数据迁移，需限速和变更窗口：

- 预留 source+destination 双份空间；
- 监控 metadata 更新与 chunk copy 失败；
- 限制与 resync/backup/RST 同时争抢；
- 按 storage pool/目录/文件大小分批；
- 每批后 health check + 应用 checksum/抽样读取；
- 有清晰 pause/rollback/旧 chunk cleanup 策略。

### 9.3 退役

不能只停止 daemon/删除 target mapping。先阻止新 allocation，迁移所有引用 chunks，验证没有 inode stripe pattern 指向目标，
再按官方节点管理流程删除。对 mirrored target 还要重建 Buddy Group，避免错误 role/source 引发反向覆盖。

## 10. fsck 与维护窗口

大型系统应定期做 read-only fsck 或抽样/分区一致性检查，并在以下事件后提高检查级别：

- 非干净 metadata/storage crash；
- 跨 metadata rename 大量失败；
- management DB/target mapping 恢复；
- buddy resync 失败/强制 state 变更；
- target 数据人工迁移；
- 大版本升级；
- 底层 FS repair/RAID corruption。

Fsck 节点需要高速本地盘容纳收集 DB。线上自动 repair 风险高，先保存报告、确认 targets Good、停止 resync，并对修复对象做备份。

## 11. Security

### 11.1 连接认证

`conn.auth` 是集群共享 secret，必须分发到 client、metadata、storage、management 等参与者。C/C++ 数据面把文件内容 hash 为一个
连接认证值并在 channel 建立时校验；没有配置且未显式禁用时服务会拒绝/警告不安全配置。

它解决“是否知道集群 secret”，不解决：

- 每个用户/服务独立身份与撤销；
- 网络 payload 加密；
- 被攻陷客户端伪造 UID/GID/发协议请求；
- 审计级 non-repudiation。

Secret 应以 root-only 权限存储、通过安全配置管理轮换；节点退役/泄露后按官方可中断流程轮换。

### 11.2 TLS 边界

8.x 新 gRPC 服务默认/支持 TLS，例如 `beegfs` CLI ↔ management、Remote ↔ Sync/management。
官方 [TLS](https://doc.beegfs.io/latest/advanced_topics/tls.html) 特别说明其中“client”指 CLI/服务客户端，
**不是 BeeGFS kernel client module**。核心 BeeMsg client↔metadata/storage 数据流不能因此宣称全链路 TLS。

对敏感数据应：

- 使用隔离、受控的存储网络/VLAN/VRF 和主机防火墙；
- 对跨不可信网络使用受支持的加密隧道/网络层加密并评估性能；
- at-rest encryption 交给 LUKS/ZFS/硬件或对象 provider；
- 保护 TLS private keys 并使用 CA 校验，不把自签名跳过验证当长期方案。

### 11.3 用户权限

BeeGFS 主要沿用 Linux UID/GID/mode，可选 POSIX ACL、xattr、SELinux；8.4 NFSv4 ACL 仍是企业实验特性。
客户端默认 `sysXAttrsEnabled=false`、`sysACLsEnabled=false`、`sysNFSv4ACLsEnabled=false`，不能只在 server 打开就认为挂载已启用。

所有客户端需统一身份源（LDAP/SSSD 等），避免相同数字 UID 代表不同用户。Kernel client 节点是高信任主体；多租户环境应限制谁能成为客户端，
而不是把共享 secret 当细粒度授权。

### 11.4 审计与数据治理

Filesystem Modification Events/Watch 可供异步索引、RST 自动同步和审计订阅，但事件流有队列/checkpoint/consumer ACK 运维问题，
不是强制访问控制日志。关键审计仍需安全日志平台、配置变更记录和不可变存储。

## 12. Quota、ACL 与多租户

Quota 依赖底层 targets 统计 user/group usage 并由 BeeGFS 聚合/执行；项目目录通常通过专用 group + setgid/grpid 建模，
不是独立 project-quota 计数器。使用前要在所有相关 local FS 正确启用 quota tracking。
配额更新和查询不是一个跨 targets 的每写全局事务；接近上限的并发写与报告周期需要压测。

Storage pools 可隔离介质/项目，但属于许可功能；Buddy pairs 要留在相同 policy pool 且跨故障域。配额、pool、ACL 同时启用会增加 metadata/管理复杂度。

BeeGFS 适合受信 HPC 用户共享，不天然等同公有云 hostile multi-tenancy。若要多租户，应补充网络隔离、客户端准入、统一身份、审计、
资源 QoS/作业调度和管理 API 权限。

## 13. Remote Storage Targets

### 13.1 架构

RST 把 BeeGFS 路径关联到一个或多个 S3-compatible targets：

```text
BeeGFS metadata (RST config per entry)
          |
Watch events / CLI push-pull
          v
Remote service (job coordination + BadgerDB)
          |
          +---- Sync worker 1 ---- S3 provider
          +---- Sync worker 2 ---- S3 provider
```

Remote target 设置和 cooldown 可从父目录继承；文件可 `push`/`pull`，或成功 push 后 `--stub-local` 截断本地内容并保存远端 URL/状态。
8.4 restore policy：

- `manual`：显式 pull 后才可访问；
- `auto`：open 触发恢复并等待；
- `delayed`：本次快速返回错误，同时后台恢复，稍后重试。

### 13.2 自动同步

设置 `remote-cooldown` 后，文件在 write-close 后等待 churn 冷却，再由 Watch modification events 触发 Remote dispatch。
需要部署 Watch，订阅全部 metadata services，并配置 Remote dispatch/rate limits/checkpoint/filter。

官方明确：auto-sync 是 best-effort；cooldown queue 不持久化，Remote restart 会丢尚未调度项。永久删除本地或退役集群前必须显式
`beegfs remote push/status` 并验证远端，而不是依赖“已开启自动同步”。

### 13.3 容量与成本

Remote 为每个同步路径保存 pending/active/history jobs。官方示例假设每 job 约 3 KiB、每文件保留 4 条历史，10 亿文件可需要约 11 TiB
Remote DB 容量。这对小文件系统极其重要：job metadata 可能比文件 payload 更昂贵。

还要计算 S3 request、multipart、list/head、egress/restore 和 object-version storage 成本。`remote status` 默认依据本地 job DB；
若远端可能被外部修改，应使用 provider verification/重新 push-pull，代价是 API 请求。

### 13.4 故障与正确性

- Remote/Sync 设计为服务重启后从 DB 恢复 active jobs，仍要备份 DB 和测试重放；
- 自动 dispatch queue 有非持久窗口；
- push 默认覆盖远端同名对象，建议开启 versioning/snapshot；
- stub 文件在恢复前不可普通读写，应用要能处理等待或 `EWOULDBLOCK`；
- ZFS storage size 可能需 `beegfs entry refresh` 后再同步；
- 8.4 Remote/Sync 要求 root 运行，扩大安全边界；
- RST 最新副本滞后于本地，不能作为同步 Buddy 第三票。

## 14. Licensing 与采购风险

根据 [Licensing](https://doc.beegfs.io/latest/advanced_topics/licensing.html)：

- BeeGFS 8.3+ 要求 enterprise、temporary 或 community license 以符合许可协议；
- community license 有容量/功能边界，不解锁 enterprise features；
- enterprise/temporary 解锁项和机器数由 license 决定；
- 8.4 无 license 时最多五个客户端挂载，额外挂载被拒；
- 8.4 每系统只能使用一次 trial，BeeOND 需要有效 community/enterprise license；
- enterprise license 到期后系统主体仍可运行，但 enterprise features 停止；temporary/community 到期视为未许可。

上线前形成“功能—许可—降级行为”表，至少核验 storage pools、quota、RST、NFSv4 ACL、rebalance、支持级别和机器计数定义。
不要到扩容或故障恢复时才发现目标命令/功能被 license gate。

## 15. 升级与变更管理

### 15.1 版本兼容

8.x 同 major 有组件语义兼容目标，但 8.4 新功能要求相关组件升级；7.x 与 8.x 因网络/磁盘格式变化不兼容。
从 7 升 8 需要 management DB import、组件顺序和完整维护计划，不能滚动混跑当普通 patch。

### 15.2 客户端内核

每次 OS/kernel update 先在 staging 编译/加载 client module，运行 mount、metadata、IOR、lock、mmap、failover 回归。
DKMS/autobuild 失败可能在计算节点重启后才暴露。应维护已批准 kernel+BeeGFS package matrix，并阻止未验证自动升级。

### 15.3 标准流程

1. 阅读目标 patch release notes/known issues；
2. 备份 mgmtd DB/config/auth/license 和关键 metadata；
3. 确保全部 targets Online/Good、无 resync/fsck/rebalance；
4. 在同构 staging 回放真实 workload 与故障；
5. 按官方组件顺序升级；
6. 运行 `beegfs health check`、版本检查、smoke I/O；
7. 观察一个完整业务周期后再清理 rollback artifacts。

## 16. 上线检查表

### 架构

- [ ] Management 单写者 HA、fencing、VIP/地址和 DB 存储已演练。
- [ ] 所有 metadata/storage Buddy 跨独立故障域且容量/性能对称。
- [ ] 未镜像目录/targets 被显式标记为可丢 scratch，而非误漏配置。
- [ ] Storage pools、quota、RST 与 license 匹配。

### 数据安全

- [ ] `tuneRemoteFSync`/`sysSyncOnClose` 与应用契约一致。
- [ ] 本地 RAID/ZFS、PLP/BBU、scrub 和 device monitoring 已验证。
- [ ] 有独立 immutable/versioned backup，已做全量恢复。
- [ ] fsck 容量/时间实测，repair 流程需要人工批准。

### 性能

- [ ] 真实目录/文件大小分布已测 mdtest+IOR+应用 p99。
- [ ] 条带模板按 workload 设置，已有文件迁移策略明确。
- [ ] 失去一个节点/rail并运行 resync 时仍满足关键 SLA。
- [ ] bytes、inodes、connections、RDMA buffers 和 network mirror traffic 均已建模。

### 一致性与安全

- [ ] 全局 file/append lock 开关与应用行为匹配并实测。
- [ ] cache/TTL/invalidation 配置纳入版本控制。
- [ ] `conn.auth`、TLS、网络隔离、UID/GID/ACL/SELinux 策略完整。
- [ ] Kernel client 节点被视为受信主体并限制准入。

### 运维

- [ ] 任何非 Online/Good、resync 失败、inode/space Low 都有有效告警。
- [ ] 有 primary/secondary/mgmtd/network partition 故障运行手册。
- [ ] 客户端 kernel/module 发布和回滚流水线已验证。
- [ ] 许可续期、功能失效和支持升级流程有 owner。

## 17. 推荐下一步

1. 用目标硬件部署最小 2×metadata + 4×storage + 2×management candidate 集群，先建立故障域和 HA。
2. 从真实数据采样文件大小、目录宽度、并发、lock/append/mmap/fsync 行为，生成四类 workload。
3. 完成健康、降级、resync、满容量、慢 target、management failover 全矩阵测试。
4. 输出每类目录的 pattern/cache/backup policy 和可接受 RPO/RTO。
5. 用同一 workload 与 LightStore/CubeFS/Lustre/对象存储方案对照 TCO、p99、恢复复杂度，而非只比较峰值 GB/s。
