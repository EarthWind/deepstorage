# SeaweedFS 高可用、恢复、生产运维与安全

## 1. 技术总结

SeaweedFS 的 HA 不是一个统一 quorum：Master 用 Raft，Volume 用完整副本或 EC，Filer namespace 用选定的 Store，跨集群用异步日志。生产可用性取决于四个独立闭环：

1. Master leader 和 topology heartbeat；
2. Volume replica/shard health 与显式 repair；
3. Filer Store、metadata log 和 owner routing；
4. S3/Filer/mount 入口、认证、密钥与网络。

官方安全策略明确内部 Master、Volume 和 raw Filer API应位于可信网络；只支持最新 Release 的安全修复。默认部署不构成安全闭环：TLS/JWT需要启用，CORS 示例为 `*`，Volume read 在不配 read JWT 时依赖难猜 FID，4.41 Master 默认每天上报 telemetry。

## 2. 推荐生产拓扑

### 2.1 单 DC

```text
3 Master across failure domains
2+ Filer/S3 behind L7 LB
HA shared Filer Store (3+ DB nodes as required)
N Volume Servers across racks; one process/disk or explicit disk IDs
2 Admin/Workers with task ownership/dedup
Prometheus + logs + backup site
```

建议：

-Master odd peers，独立 `mdir`，固定地址；
-Volume `010` 跨 rack，或确保 `001` 真跨物理 host；
-Filer Store 用独立 HA/PITR；
-S3/Filer无状态进程分散；
-repair/EC/Vacuum限流；
-只暴露 S3/受控 gateway。

### 2.2 两 DC

选择必须明确：

| 模式 | 数据 | 元数据 | 写延迟/RPO | 结论 |
| --- | --- | --- | --- | --- |
| `100` 同步 volume replica | 每个 hot volume 跨 DC | Filer Store另行解决 | WAN RTT进入写；chunk RPO较低 | 不是完整站点 HA |
| active-passive `filer.sync` | 异步复制 chunk+metadata | change log/checkpoint | 非零 RPO | 推荐 DR 基线 |
| active-active `filer.sync` | 双向异步 | 冲突/顺序风险 | 低本地延迟、eventual | 只用于分区写 owner |
| backup/export | 周期 copy + meta snapshot | 离线/时间点 | RPO较大 | 防误删/勒索重要 |

不要把 Volume `100` 与 Filer Store 异步复制混成“零 RPO”。文件可恢复性取决于较弱的一层。

## 3. Master HA

-通常 3 或 5 peer；
-必须用一致的 `-peers` 和 `-ip`；
-Volume/Filer 配完整 Master list；
-动态增加 peer 的官方流程不灵活，Wiki 建议停现有 Master 后以新 peer set启动；
-备份 `mdir`，但恢复前防止旧/新 quorum同时运行；
-监控 Raft snapshot、leader change、topology warm-up；
-不要让同一批 Volume Server跨两个 topology id。

一台 Master 负载轻不意味着生产可接受单点；单 Master restart 可重建 topology，但 assign、管理和 cache miss 在窗口内受影响。

## 4. Volume HA

### 4.1 磁盘/进程映射

官方允许：

-一个进程多 `-dir`；
-每块盘一个 Volume Server进程；
-多个 server 同物理 host。

独立进程便于换盘和隔离，但 placement 仍把它们视为不同 server。必须用 rack/host/disk tag补充真实拓扑，最好由调度系统校验“同一 replication group 不共宿主机/电源/JBOD”。

### 4.2 Maintenance

`volumeServer.state --maintenanceOn`：

-sticky，重启后保持；
-读成功，写失败；
-用于换盘/网络/维护；
-需先 drain、确认副本健康；
-维护结束显式恢复 writable。

### 4.3 IO probe

4.41 有可选 disk IO probe 参数，默认关闭；Volume 还记录连续 EIO，达到阈值后 heartbeat把副本视为 broken。只靠请求触发 EIO 不够，生产应结合：

-SMART/NVMe health；
-kernel I/O error；
-latency window；
-定时 scrub；
-filesystem read-only；
-disk fullness/inode；
-hardware enclosure告警。

## 5. Filer HA

### 5.1 共享 Store

Filer进程可视为可替换，但：

-owner lock/transaction state在内存；
-metadata log buffer有未 flush窗口；
-cache需 event invalidation；
-Store连接池/事务是关键依赖；
-S3 Gateway和Filer共进程可减少内部 HTTP，但耦合故障。

Load Balancer 应支持：

-health/readiness检查 Store、Master和log状态；
-长 gRPC/stream；
-请求 body大文件；
-S3 presigned host/forwarded headers；
-drain与优雅停机。

### 5.2 Embedded replication

只作为 eventual模式，不用于要求 read-after-write跨 LB 的主生产 namespace。若使用：

-sticky/hash；
-监控 peer offset；
-log retention > 最大停机；
-避免 active-active directory rename；
-恢复时先追平再接流量。

## 6. Admin/Worker

4.x 推荐：

-`weed admin -master=...`；
-`weed worker -admin=...`；
-Admin UI配置 script/plugin；
-任务proposal去重/dispatch到 worker。

运维风险：

-旧 master maintenance 与新 plugin 重复；
-多个 cron未拿 cluster lock；
-repair、balance、Vacuum、EC同时抢 I/O；
-任务默认 apply造成意外删除；
-worker权限等同存储管理员；
-UI/admin端口未鉴权暴露。

建议 maintenance scheduler 具备：

-全局/collection互斥；
-per-server MB/s、并发、时间窗；
-dry-run/plan审批；
-前置 health gate；
-可恢复 task id/checkpoint；
-审计 target/source/bytes/checksum；
-失败不自动做破坏性 cleanup。

## 7. 故障恢复 Runbook

### 7.1 Master leader丢失

1.确认多数 peer存活；
2.查看 leader/term/log/snapshot；
3.不要同时 bootstrap新 quorum；
4.等待 Volume heartbeat warm-up；
5.检查 writable count/replica count；
6.再恢复后台任务。

### 7.2 单 Volume Server/盘丢失

1.标记 maintenance/offline，确认不是网络闪断；
2.列出 affected normal volumes/EC shards；
3.检查每个 volume剩余健康副本/shard；
4. scrub source；
5. `volume.fix.replication -doDelete=false` 或 EC rebuild；
6.限流并监控前台；
7.达到目标 placement后再清 over-replica；
8.换盘节点作为空 target加入，避免带旧数据误注册。

### 7.3 Filer丢失

共享 Store：

-LB摘除；
-Store状态不变；
-新 Filer加入 ring，有 warm-up；
-mount/S3 retry；
-检查 metadata log gap/cache。

嵌入式 Store：

-先检查本地 Store备份；
-从 peer log/Store重新同步；
-追平 checkpoint前不接随机流量；
-确认 log未过期。

### 7.4 Filer Store故障

1.冻结 namespace mutation或入口；
2.确认 DB failover/read consistency；
3.不要让 read-only replica接受写；
4.恢复后检查 transaction/rename partial；
5.重放 metadata log；
6.扫描 dangling metadata/orphan chunk；
7.抽样/全量读取。

### 7.5 站点恢复

必须恢复：

-匹配版本的 binaries/config；
-Master cluster identity/volume ids；
-Volume `.dat/.idx/.vif` 和 EC全部文件；
-Filer Store snapshot；
-metadata log/checkpoint；
-S3 IAM/bucket config；
-JWT/mTLS CA、SSE KEK/KMS；
-topology dc/rack/disk labels。

之后：

-隔离网络启动，避免双写；
-载入 volume，等 topology；
-恢复 Store/metadata；
-`volume.fsck`、EC inventory/scrub；
-验证 object count、size、sample checksum、version/lock；
-才切流量。

## 8. 备份与灾备

### 8.1 `weed backup`

按 volume id做增量 needle对比/拉取到本地 volume。它是命令，不是完整持续 HA service。适合构建数据副本，但没有自动生成 Filer Store 同一时点 snapshot。

### 8.2 `fs.meta.save/load`

导出/导入 Filer metadata。官方镜像指南建议暂停写，使 volume和metadata匹配，并承认方案非 bullet-proof、仅小规模验证。

### 8.3 `filer.backup/replicate`

消费 metadata log复制到外部 sink，可持续，但：

-延迟/offset是RPO；
-sink能力不同；
-rename可能 create+delete；
-SSE解密/skip行为不同；
-4.41刚修复 sink write前过早 ack。

### 8.4 3-2-1

复制不是备份。建议：

-3份数据；
-2种故障边界/介质；
-1份离线或不可变；
-Filer Store PITR；
-密钥单独托管；
-季度全站恢复演练；
-Object Lock/backup retention防勒索和误删。

## 9. 升级

`SECURITY.md` 只支持最新 Release 的安全修复，推动快速升级；4.41 Release 同时修复 S3 versioning、Filer log、replication offset、Volume index、EC delete/source cleanup、Raft snapshot、volume.merge corruption等，说明升级本身也高风险。

生产纪律：

1. 固定 tag/digest，不用 `latest`；
2.阅读每个版本 release notes；
3.先备份 Store/volume/config/key；
4.测试旧数据格式、新旧节点混部；
5.顺序：工具/控制面/网关/数据面按兼容说明；
6.先 canary读、再写；
7.暂停 destructive maintenance；
8.验证 rollback能否读新写格式；
9.回归 versioning/EC/Vacuum/repair；
10.升级后全量 inventory与抽样 checksum。

Rust Volume Server虽宣称格式/API兼容，同 tag的 missing-features audit仍列 deferred项，且4.41持续修复 Go+Rust parity。生产首选 Go Volume；Rust只在独立兼容/故障测试后 canary。

## 10. 可观测性

SeaweedFS 支持 Prometheus push gateway和pull metrics端口，提供 Grafana JSON。应构建四层面板。

### Control

-Raft leader/peer、heartbeat、topology warm-up；
-volume server/filer/broker count；
-writable/crowded/full/readonly volume；
-assign latency/error/retry；
-location cache。

### Data

-read/write QPS/bytes/P50/P95/P99；
-replication targets/failure/duration；
-disk latency/error/fullness；
-index load/memory；
-checksum/corruption；
-HTTP/gRPC code。

### Metadata/S3

-Filer Store latency/error/pool；
-metadata log buffer/flush/lag/gap；
-owner forwarding/warm-up/condition failure；
-S3 API/error/IAM deny；
-Multipart orphan、Lifecycle lag；
-mount cache/event/lock session。

### Maintenance

-under/over-replica；
-repair bytes/age；
-Vacuum candidates/running/reclaimed；
-EC encode/rebuild/balance/scrub；
-tier bytes/GET/error/cost；
-backup checkpoint/RPO/restore drill。

## 11. Security threat model

官方策略：

-Master、Volume、raw Filer内部 API在可信网络；
-除非明确启用并绕过一个 control，否则内部端口不是认证边界；
-直接暴露内部端口是部署错误；
-有效安全问题包括未认证访问、S3跨身份、普通用户提权、Object Lock绕过、远程数据损坏。

工程含义：SeaweedFS不是默认 zero-trust storage fabric。必须用网络隔离和配置加固建立边界。

## 12. 认证与传输

### 12.1 gRPC mTLS

`security.toml`：

-`[grpc] ca`；
-`[grpc.master/volume/filer/s3] cert/key`；
-`[grpc.client] cert/key`。

证书需 serverAuth + clientAuth EKU；官方建议每个 SeaweedFS cluster使用专用 intermediate CA，不能直接信任企业广泛 root CA。

### 12.2 HTTPS

gRPC和HTTP是两套独立面：

-`[https.master/volume/filer/s3/admin]` server；
-`[https.client] enabled` 让内部客户端用 HTTPS。

只启 server HTTPS不启 client会导致内部调用用 HTTP 打 HTTPS端口。CA默认启动加载一次；leaf cert/key可约每5小时热刷新，可用 `WEED_TLS_CERT_REFRESH_INTERVAL` 调整。CA轮换仍需 rolling restart。

### 12.3 JWT

-`jwt.signing.key`：Master签发、Volume验证 write；
-`jwt.signing.read.key`：Volume read；
-`jwt.filer_signing.key/read.key`：Filer HTTP。

默认 Volume read若未配 read JWT，官方 Wiki描述为“unprotected, URL not guessable”。这不是可接受的互联网安全模型；生产必须配置 read auth或完全隔离 Volume。

### 12.4 S3

使用 SigV4/IAM/Bucket Policy/STS，外层 HTTPS；禁止开发 Allow All。Admin、shell、IAM management action需要更强网络/RBAC。

## 13. 静态加密

-Filer `-encryptVolumeData` 可客户端侧生成 cipher key并把 ciphertext存 Volume，key在 Filer metadata；
-S3 SSE三种模式；
-Cloud Tier保存 volume ciphertext；
-底层盘仍建议 LUKS/云盘加密防介质丢失；
-Filer Store、metadata log、backup也要加密。

密钥丢失等同数据丢失。备份必须包含 KEK/KMS配置但与数据隔离，定期做恢复。

## 14. 默认风险

| 项 | 默认/样例 | 生产动作 |
| --- | --- | --- |
| Internal ports | trusted network assumption | NetworkPolicy/firewall deny external |
| gRPC TLS | 可选 | 全组件 mTLS |
| HTTP TLS | 可选 | 外部/跨主机 HTTPS |
| Volume read JWT | 可选 | 启用或仅 proxy |
| Filer JWT | 可选 | 启用，禁 raw untrusted |
| CORS example | `*` | 精确 origin |
| `weed mini` S3 | 无 key时 Allow All | 禁生产 mini |
| telemetry | 4.41默认 true，每24h | 合规审批或显式 `-telemetry=false` |
| security support | 仅 latest release | 建立快速升级和回归 |

### Telemetry fields

leader Master 在启动约61秒后、之后每24小时向默认 `https://telemetry.seaweedfs.com/api/collect` 发送：

-topology id；
-version、OS/arch、timestamp；
-Volume Server count；
-total disk bytes、volume count；
-Filer/Broker count。

源码注释称匿名，但 topology id 是稳定 cluster identifier。合规/离线环境应关闭并阻断 egress。

## 15. 安全加固清单

- [ ] 固定 4.41+镜像 digest并订阅安全 Release
- [ ] Master/Volume/Filer/Admin仅内网
- [ ] Kubernetes NetworkPolicy/主机 firewall按流向 allowlist
- [ ] gRPC mTLS，专用 intermediate CA
- [ ] HTTP HTTPS与 `https.client` 一致
- [ ] Volume read/write JWT、Filer read/write JWT
- [ ] S3只用强随机 credentials/OIDC/STS，禁 Allow All
- [ ] Bucket policy explicit deny insecure transport
- [ ] Admin/UI/shell单独 RBAC与审计
- [ ] SSE KEK/KMS进 secrets manager；轮换/恢复演练
- [ ] Filer Store TLS/auth/least privilege/PITR
- [ ] CORS精确配置
- [ ] `-telemetry=false` 或完成审批
- [ ] NTP、audit log、集中日志、防篡改保留
- [ ]禁止用户直接访问 FID/Volume endpoint绕过 Object Lock/IAM
- [ ]备份离线/不可变，恢复验证 SSE/Object Lock

## 16. PoC 与演练

每季度至少：

-Master quorum loss/restore；
-Volume盘丢失与 repair；
-EC 4-shard loss/bitrot；
-Filer owner crash和Store failover；
-metadata log gap；
-S3 Gateway rolling restart；
-mTLS leaf/CA轮换；
-JWT/KEK错误配置；
-站点 active-passive切换；
-从离线备份恢复完整 bucket/version/lock；
-升级/rollback；
-内部端口外部扫描确保不可达。

## 17. 小结

SeaweedFS 可以构建高可用、安全的生产系统，但这些属性来自显式组合，不来自默认进程。最重要的架构纪律是：Master quorum、Volume durability、Filer Store、跨站复制和安全边界分别设 SLO/Runbook；内部端口默认不可信暴露；任何破坏性维护都先检查副本/EC/备份健康。
