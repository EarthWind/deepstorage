# CephFS 生产运维、性能与安全

## 1. 核心判断

CephFS 的生产质量取决于整条依赖链，而不是 MDS daemon 是否 `up:active`。最低限度要同时治理：MON quorum、MDS active/standby、metadata pool 延迟与冗余、data pool 容量与 PG、客户端版本/caps、网络、Purge Queue、scrub/recovery、CephX 和备份。

性能优化的顺序应是：**定义 workload/SLO → 分离 metadata/data 指标 → 确认 cache/cap/PG 瓶颈 → 改 namespace/硬件/并发 → 最后调高级参数。** 直接修改 balancer、recall、purge 或 journal 阈值通常只会把压力移到另一个组件。

## 2. 生产拓扑基线

一个合理的起点：

| 层 | 建议 | 原因 |
|----|------|------|
| MON | 3 或 5 个，跨独立故障域，低延迟稳定网络/存储 | quorum、maps、认证与 failover authority |
| MGR | 至少 active + standby | 管理/监控/volumes/mirroring 模块可用性 |
| MDS | `max_mds` 个 active + 至少 1 个跨主机 standby；更高 SLA 按 rank 配 standby-replay/额外 spare | metadata service 接管 |
| metadata pool | replicated size≥3，独立 SSD/NVMe device class，容量 headroom | journal/cache miss/replay 的共享关键路径 |
| default data pool | 优先 replicated，保留 backtrace 小对象性能 | 每 inode 至少依赖 default pool 第一个 object/backtrace |
| bulk data pool | 按 workload 选择 replicated 或 EC，独立 CRUSH rule/容量 | 大文件容量效率与性能分层 |
| OSD failure domain | 至少 host，关键集群按 rack/room 设计 | 避免副本/shards 同故障域 |
| client network | 双链路/冗余交换、MTU/拥塞/丢包一致 | 客户端同时访问 MDS 与 OSD，单向异常会触发 caps/eviction |
| 备份/DR | 本地 snapshots + 独立集群 mirror + 离线/不可变备份 | 防误删、站点故障和凭据/软件共因 |

不要把 CephFS metadata pool 与高吞吐 RGW/RBD workload 混在同一慢盘/同一拥塞队列上。官方明确建议 metadata pool 使用专用 SSD/NVMe OSDs，避免客户端 data workload 影响 metadata latency。

## 3. MDS 资源规划

### 3.1 CPU

MDS 大部分工作单线程，官方指出繁忙实例通常只利用约 2–3 cores。优先：

- 高单核性能和稳定频率；
- 避免严重 CPU overcommit/steal；
- 为 messenger、finisher、后台任务保留额外 cores；
- 多 rank workload 可在同主机启多个 MDS，但应避免同一硬件故障清空全部 active/standby。

增加单 MDS 核数不会让主 metadata path 自动线性扩展；需要多个 active ranks 和可分区 namespace。

### 3.2 内存

`mds_cache_memory_limit` 是 cache target，不是进程 RSS hard limit。容量规划步骤：

1. 用目标 workload 预热到稳定 working set；
2. 记录 cache bytes、inodes/dentries、per-client caps；
3. 计算 bytes/hot inode 与 client state 固定成本；
4. 加 snapshot/hardlink/dirfrag/多 rank replication 和 failover warmup 余量；
5. 把 daemon 容器 memory limit 设置在 cache target 之上，避免 MDS 还在 recall 时被 OOM kill。

官方默认 4 GiB 仅适合起步；部署文档建议至少约 8 GiB，1000+ clients 常需更大 cache。具体数值必须实测，不能把 64 GiB 等经验值当保证。

### 3.3 metadata pool

MDS cache miss、journal append/flush、failover replay 都依赖该 pool。需观察：

- OSD op latency P50/P99/P999；
- metadata pool PG active+clean/degraded；
- RocksDB/BlueFS slow ops 与 device wear；
- network RTT/queue；
- recovery/scrub 对 latency 的影响。

metadata pool 通常容量不大，但不能因“只有几 GiB”而使用慢盘或极低冗余。PG 数也不应机械设置；使用 autoscaler/实际 OSD 数与目标 ratio 规划，并验证 failover/recovery。

## 4. namespace 与应用设计

### 4.1 目录层次

- 根目录尽早按 tenant/project/job 分层，因为 root 不能 fragmentation。
- 避免单目录数百万/千万项，即使 dirfrag 支持；控制 `readdir`、排序与运维工具内存。
- 对天然多租户 workload 使用 ephemeral pin/export pin，但先监控 rank load，避免固定热点。
- 批量小文件优先应用打包、分层目录或对象接口；不要把 `find`/`ls -l` 当数据库索引。

### 4.2 shared write

- 尽量单 writer per file；多 writer 按非重叠、object-aligned 区域切分。
- 禁止依赖跨主机 shared writable `mmap` coherence。
- checkpoint/数据库调用 `fsync` 并检查错误；close 不等于 durable。
- `ls -l`/stat 正在被其他客户端扩展的文件会触发 flush 等待，应降低轮询频率或用应用指标。

### 4.3 大文件与 layout

- 默认 4 MiB/stripe_count 1 是基线，不盲目增加 stripe count/object size。
- replicated pool 测 latency/覆盖写；EC pool 测完整 stripe、大 sequential、small overwrite、truncate 和 degraded read。
- 用目录 layout 在文件创建前分流；已有文件需要显式复制/迁移，改父 xattr 不会移动数据。

## 5. 监控体系

### 5.1 集群级

| 指标/状态 | 告警含义 |
|-----------|----------|
| MON quorum/leader changes | map authority 与认证风险 |
| MDS rank state、laggy、failed/damaged | metadata 可用性/恢复阶段 |
| standby count/affinity/standby-replay coverage | 故障接管能力不足 |
| PG inactive/peering/degraded/undersized/inconsistent | RADOS 可用性和完整性 |
| metadata/data pool nearfull/full | 写入/metadata operation 风险 |
| OSD slow ops、commit/apply latency | data 与 metadata 共因尾延迟 |
| recovery/backfill/scrub throughput | 后台流量对前台 SLO 的干扰 |

### 5.2 MDS 级

- request rate/latency，按 op type 和 rank；
- cache bytes/inodes/dentries、hit/miss、reservation/oversized；
- per-client caps、cap hit/miss、recall/release、late clients；
- client sessions、reconnect/eviction/blocklist；
- journal segments/events、trim lag、replay position；
- subtree/dirfrag 数、imports/exports、balancer oscillation；
- lock/cap wait slow requests；
- Purge Queue：`pq_item_in_journal`、`pq_executing(_ops)`；
- scrub/damage table；
- CPU main thread saturation、RSS、allocator fragmentation。

### 5.3 客户端级

CephFS 可从 MDS 暴露 per-client metrics：read/write/metadata latency、ops/bytes、cap/dentry lease hit/miss、opened files/inodes、pinned caps。还需收集：

- kernel `dmesg`：caps stale、session reset、writeback errors、blocked requests；
- mount/client version 与 features；
- OSD/MDS RTT、retransmit/drop；
- application fsync latency/error；
- remount/eviction 次数。

只看集群平均 latency 会掩盖单 client 卡死、单 rank 热点和 PG tail。

### 5.4 mirror/backup

- last successful snapshot 和 age；
- last synced snapshot、sync queue wait/crawl/data duration；
- bytes/files、failure/recovery count；
- mirror daemon ownership/assignment；
- 远端容量、snapshot retention、实际 restore test age。

## 6. 关键健康告警处置思路

| 告警/症状 | 先查 | 避免 |
|-----------|------|------|
| `MDS_CACHE_OVERSIZED` | 哪些 clients/caps 无法 recall，cache pinned 原因 | 只降低 limit 或立刻重启 |
| `MDS_HEALTH_CLIENT_RECALL` | client 网络/内核、release rate、per-client caps | 无上限提高 recall 形成风暴 |
| `MDS_HEALTH_TRIM` | journal segment 被何种 dirty/lock/RADOS latency 阻塞 | 在长 journal 时盲重启 |
| slow metadata ops | 等 cap、MDS lock、RADOS op 还是 CPU | 只加 active MDS |
| `MDS_DAMAGE` | damage table、OSD inconsistent/lost PG、MDS logs | 在线直接 reset journal/table |
| purge backlog | 删除速率、object count、PG latency、池水位 | 把 purge 并发调得过高压垮前台 |
| client session reset | eviction/blocklist、OSDMap epoch、dirty data | 手工 unblock 后继续使用旧 mount |
| data pool nearfull | capacity trend、purge/snapshot、recovery headroom | 等 full 后依赖应用重试 |

## 7. 容量治理

至少分开计算：

```text
logical namespace bytes
+ sparse-hole accounting bias
+ replica/EC amplification
+ BlueStore/object metadata
+ snapshots/COW retained bytes
+ purge backlog
+ recovery/backfill temporary headroom
+ pool/PG imbalance headroom
```

`du`、CephFS recursive stats、subvolume quota used 和 RADOS pool used 含义不同。计费/告警应明确事实源：

- 用户逻辑使用：目录 recursive stats，但了解 holes/snapshot exclusion；
- 物理资源：pool/OSD used，包含冗余、snapshot、backlog 与内部对象；
- 可回收：Purge Queue + deleted snapshots pending reclaim；
- 安全 headroom：触发 nearfull/full 前的不可分配保留。

## 8. 性能验证方法

### 8.1 不使用单一总分

至少分四条曲线：

1. metadata ops/s 与 latency；
2. file data bandwidth/IOPS 与 fsync latency；
3. recovery/scrub/purge 干扰下的前台 SLO；
4. failover RTO 和 error/retry 行为。

### 8.2 workload 矩阵

| 维度 | 取值示例 |
|------|----------|
| namespace | 多目录均匀、单热目录、root hot、10M entry dir、deep tree |
| metadata | create/stat/unlink/rename/hardlink/readdir、open-close |
| clients | 1、16、128、1000+；每 client threads/caps |
| data | 4 KiB–1 MiB small files、1–100 GiB files、sequential/random |
| sharing | 单 writer、多 reader、多 writer、跨对象写、mmap negative test |
| pools | replicated、EC、不同 stripe/layout |
| cache | warm working set、cold/超 cache、MDS restart cold cache |
| durability | buffered write、O_SYNC/O_DSYNC、fsync per op/batch |
| faults | MDS kill、client partition、OSD down、degraded PG、nearfull/full |
| background | scrub、recovery/backfill、snapshot delete、mass purge、mirror |

工具可用 mdtest/IOR/fio/fsx、Linux fstests 的适用子集和应用 replay，但必须记录完整参数、client/kernel/Ceph version、CPU/内存/网络/OSD media、pool/PG/CRUSH、cache warm state。

### 8.3 结果要求

- P50/P95/P99/P99.9，不只平均；
- 每 rank/PG/client 分布；
- 失败率、重试、EIO/ENOSPC、stale session；
- logical/physical write amplification；
- failover 各阶段时间；
- 24–72 小时 steady-state，覆盖 cache churn、journal trim 和 purge backlog。

## 9. 安全基线

### 9.1 CephX 最小权限

- 每租户/服务独立 entity/key，短生命周期与轮换；
- MDS caps 限定 `fsname`、`path`、`r/rw`，需要时 `root_squash`；
- 只有管理 layout/quota 的实体有 `p`，只有 snapshot 管理者有 `s`；
- OSD caps 用 CephFS application tags/pools，禁止泛化 `allow *`；
- 管理/MDS/OSD keyrings 不下发普通客户端；
- gateway 后端 identity 与最终用户 ACL/身份映射分开审计。

### 9.2 传输与静态加密

- 显式把 msgr2 cluster/service/client modes 限制为 `secure` 并验证协商；默认普通连接优先 `crc`。
- MON v2 端口、旧 v1 兼容与不支持 secure 的老客户端必须列入迁移计划。
- OSD 使用 dm-crypt，密钥/KMS、启动解锁、盘替换和备份流程需演练。
- BlueStore checksum 发现损坏但不加密；CephX 认证也不加密数据内容。
- 需要租户级 crypto-erasure/独立密钥时，在应用/gateway 层加密，不能只依赖共享 OSD dm-crypt。

### 9.3 网络与管理面

- 分离/隔离 public 与 cluster traffic，限制 MON/MGR/dashboard/admin sockets；
- Dashboard/Prometheus/cephadm 凭据使用 RBAC 与审计；
- SSH/orchestrator bootstrap key、container registry 和 image digest 纳入供应链治理；
- 时间同步是 auth ticket、日志关联和故障排查基础。

## 10. 升级与变更

1. 阅读目标 patch release notes，特别关注 MDS/session/scrub/OSDMap 修复。
2. 确认 `ceph versions`、health、PG clean、无长 journal/oversized cache/damage。
3. 备份配置/maps/keyrings，验证 snapshot/异地备份。
4. 先升级 standby MDS，减少 active failover；按官方 orchestrator 顺序滚动各 daemon。
5. 多 active MDS 大版本升级时，官方手工流程可能要求临时降 `max_mds=1`、关闭 standby-replay，再恢复配置；以目标版本文档为准。
6. 验证 kernel/FUSE clients 的 `min_compat_client` 与 feature bits，旧客户端不能只看 mount 成功。
7. 变更后执行 metadata/data/fsync、failover、snapshot/mirror smoke tests，观察一完整 journal/purge/scrub 周期。

不要在 `MDS_TRIM`/`MDS_CACHE_OVERSIZED` 时把重启当常规修复；官方命令会要求额外确认，因为重启恢复可能更慢。

## 11. 上线门槛

上线前必须有：

- 明确的 POSIX/不支持语义清单；
- 真实 workload 72h 压测和 P99.9；
- MDS/OSD/client 故障注入结果；
- nearfull/full、purge backlog 与 snapshot delete 容量演练；
- backup restore 和 mirror promotion 的 RPO/RTO；
- CephX path/pool negative tests 与 secure mode 抓包/配置验证；
- dashboard/alerts/runbooks/on-call owner；
- metadata disaster recovery 专业支持升级路径。

## 12. 推荐后续工作

1. 在 6–12 节点 PoC 集群按 [技术评估](cephfs-analysis.md) 的矩阵建立基线。
2. 用目标业务的对象大小/目录分布生成器对比 CephFS replicated 与 EC 的物理成本，必要时与候选的打包式小文件存储横向对比。
3. 对 1/2/4 active MDS 做相同 workload scaling efficiency，记录 subtree/dirfrag 实际分布。
4. 定义业务 durability contract，并验证 write/close/fsync/rename/snapshot 的断电结果。
5. 形成 MDS failover、client eviction、lost PG、metadata damage 和 mirror promotion 五份 runbook。

## 13. 仍需回答的问题

- 实际业务 metadata working set 每 inode/dentry/cap 占多少内存？
- 单热目录能否稳定 fragment 并分散到多个 ranks，P999 是否满足 SLO？
- 目标 kernel/distribution 的 CephFS client 有哪些已知问题和支持期限？
- EC profile 在小覆盖写与 degraded recovery 下的 CPU/网络/延迟成本？
- snapshot/mirror retention 的最坏物理容量和删除时间？
- 站点级 DR 是否接受 snapshot 间隔 RPO，还是需要应用日志级复制？
- 不可信多租户需要 subvolume 还是独立 FS/pools/gateway？
