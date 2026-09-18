# FastDFS 部署、运维、监控与安全

## 1. 生产拓扑建议

官方常见建议是两个 tracker、每 group 两个 storage。工程上还应增加故障域约束：

```text
AZ / room A                         AZ / room B
+--------------------+             +--------------------+
| tracker-a          |             | tracker-b          |
| group1/storage-1a  | <- async -> | group1/storage-1b  |
| group2/storage-2a  | <- async -> | group2/storage-2b  |
+--------------------+             +--------------------+

Application DB/manifest: independent HA + backup
Public download: LB/CDN -> HTTPS Nginx gateways
FastDFS TCP ports: private storage network only
```

若两个可用区延迟或带宽不适合持续全量复制，应在单站内做 group 副本，另建独立 DR 集群。不要为了看起来“跨站双活”而让一个异步 group 在两站同时接受 mutation。

## 2. 硬件与文件系统

### 2.1 Storage

- 同组节点使用相同 CPU、内存、网卡、盘型、盘数和容量；
- 一个磁盘一个 mount point / store path，严格固定 path index；
- `base_path` 与数据盘分离并预留至少数十 GiB，避免 binlog backlog 占满；
- SSD/NVMe 要关注 TBW、PLP、firmware、media error、temperature；
- HDD 要关注 seek、重建时随机 I/O 和 inode 创建能力；
- 文件系统选择 XFS/ext4 后固定 mount 参数并做断电一致性测试；
- NTP/chrony 必须监控 offset 和 step，时间参与路由/同步判断。

官方建议不做 RAID，是为避免双重冗余并支持按 path 恢复；这不代表 JBOD 无保护。必须有同组独立副本、SMART 告警、spare、校验 scrub 和恢复演练。

### 2.2 Tracker

tracker 数据量和负载通常较低，可混部，但生产最好避免与会产生长 GC、CPU 饱和、FD 爆炸或磁盘打满的服务共享主机。其 `base_path` 保存控制状态，应在稳定文件系统并定期备份。

### 2.3 Network

- tracker 默认端口 22122、storage 23000，应只在可信网段开放；
- storage 间同步与 client 流量可分 VLAN/NIC/QoS；
- 公网用户不得直连 storage TCP；
- Nginx 对外走 HTTPS，内部也应评估 mTLS/service mesh 或独立隧道；
- 跨机房链路按峰值写带宽 + recovery 带宽容量规划；
- 监控 retransmit、RTT、drop、conntrack、ephemeral port 和 SYN backlog。

## 3. V6.17 样例配置审计

### 3.1 Tracker 关键值

| 参数 | V6.17 样例 | 评审 |
| --- | --- | --- |
| `bind_addr` | 空，绑定所有地址 | 生产应绑定私网服务地址 |
| `port` | 22122 | 防火墙仅放 client/storage/运维网段 |
| `max_connections` | 1024 | 官方建议线上至少 10240，配合 `nofile` |
| `work_threads` | 4 | 通常保持 4，不建议超过 16 |
| `store_lookup` | 2 | 最大 free group，不能替代热点均衡 |
| `store_server` | 0 | round-robin；trunk 开启时会被强制调整 |
| `download_server` | 0 | round-robin + lag heuristic |
| `reserved_storage_space` | 20% | 要与扩容 lead time、恢复预留统一 |
| `allow_hosts` | `*` | 不适合生产，应明确 allowlist |
| `use_trunk_file` | false | 开启是不可轻易回退的数据格式变更 |
| `storage_sync_file_max_delay` | 86400s | 不是 RPO，过大可能掩盖 backlog |
| `use_io_uring` | false | 仅在兼容内核/依赖和测试后开启网络路径 |

### 3.2 Storage 关键值

| 参数 | V6.17 样例 | 评审 |
| --- | --- | --- |
| `bind_addr` | 空 | 绑定私网地址 |
| `port` | 23000 | 禁止公网访问 |
| `heart_beat_interval` | 30s | 决定状态发现速度的一部分 |
| `stat_report_interval` | 60s | 容量/统计视图可能滞后 |
| `max_connections` | 1024 | 生产通常提高并校验 FD/内存 |
| `buff_size` | 256 KiB | 乘连接池计算内存上限 |
| `work_threads` | 4 | 网络线程，不等于磁盘线程 |
| `disk_rw_separated` | true | 分离读写队列 |
| read/write threads | 2/1 per path | 必须按盘型和混合负载压测 |
| `sync_min_threads` | 1 | 基线同步并发 |
| `sync_max_threads` | auto | 2×store paths，恢复时可能很激进 |
| `sync_wait_msec` | 10 ms | 低 backlog 延迟，增加轮询活动 |
| `subdir_count_per_path` | 256 | 65,536 个目录；设定后不可减小 |
| `fsync_after_written_bytes` | 0 | 固定源码数据路径未见生效，重大验证项 |
| `sync_binlog_buff_interval` | 1s | binlog durability window，不是数据 fsync |
| `allow_hosts` | `*` | 必须收紧 |
| access log | 默认 disabled | 生产宜开启并管控容量/隐私 |

### 3.3 配置漂移

同组必须一致的项目包括 group、store path count/order、端口兼容规则、storage ID、trunk 参数、目录数量和协议相关开关。建议：

- 用配置管理生成，不手改；
- 启动前运行 validator，但不要盲信 validator 覆盖运行路径；
- 保存 effective config 和 SHA；
- 对所有 tracker/storage 做 hash diff；
- 发布前阻断组内差异；
- 配置变更先在新 group/canary 验证。

## 4. 部署与升级

### 4.1 构建制品

FastDFS 依赖 libfastcommon、libserverframe，Nginx module 还与 Nginx ABI/编译参数耦合。生产制品应包含：

- 源码 tag + commit；
- 依赖 exact version/commit；
- compiler、CFLAGS、OS/glibc；
- Nginx version 和全部 modules；
- SBOM、签名和可复现构建记录；
- 配置 schema/effective defaults；
- 数据格式兼容矩阵。

### 4.2 滚动升级顺序

一个保守方案：

1. 读 Release/HISTORY，验证跨版本 storage sync 协议；
2. 备份 tracker/storage base_path 与配置；
3. 升级非 leader tracker，验证视图；
4. 升级其他 tracker；
5. 每 group 一次只下线一个非 trunk storage；
6. 等其 ACTIVE、backlog=0、抽样校验后再升级下一台；
7. 最后升级 trunk server/高风险节点；
8. 升级 Nginx module 并测 normal/trunk/range/proxy；
9. 保留兼容回滚制品，但数据格式变更后不得直接回滚。

V6.15.5 Release 曾指出 libserverframe 从 V6.09 引入的问题可在高并发或不稳定网络下导致 storage crash，并强烈建议升级。这说明核心依赖必须与 FastDFS 一起进入版本风险和回归矩阵。

## 5. 可观测性

### 5.1 内置工具

- `fdfs_monitor`：group/storage 状态、容量、统计、last sync；
- `fdfs_tracker_stat`：V6.15.5 起 tracker 连接统计；
- `fdfs_storage_stat`：V6.16 起 storage 连接和 I/O 统计；
- `fdfs_volumn_stat`：volume/path 统计；
- `fdfs_test` / `fdfs_upload_file` / `fdfs_download_file`：基本功能；
- health checker 和 network diagnostics：辅助故障定位。

CLI 输出应进入结构化采集或定时审计，不能只在故障时人工运行。

### 5.2 Prometheus exporter

V6.17 仓库自带 exporter，默认端口 9898，可配置 basic auth。实现暴露的指标覆盖：

- tracker leader、连接池 alloc/current/max；
- group/storage total/free space；
- storage status；
- upload/download/delete/append/modify 次数和成功数；
- upload/download bytes；
- last synced timestamp 和 `synced_delay_seconds`；
- sync in/out bytes；
- storage connection pool。

注意：`synced_delay_seconds = now - last_synced_timestamp` 是时间进度，不是逐文件 RPO。exporter 本身也需要 TLS、认证、bind address、防火墙和可用性监控；basic auth 不能替代 HTTPS。

### 5.3 建议告警

| 告警 | 条件思路 |
| --- | --- |
| storage 非 ACTIVE | 持续 > 2 heartbeat intervals |
| 同步延迟 | 高于业务 RPO 且持续增长 |
| peer 间 file/byte count 漂移 | 超过正常统计延迟 |
| group free space | 低于扩容 lead-time 阈值，而非等到 reserved threshold |
| path free 不均 | max/min 差异持续扩大 |
| connection current/max | >80%，或 alloc 接近上限 |
| upload success rate | 5 分钟低于 SLO |
| P99 latency | 按操作、group、storage、path 分类 |
| binlog/base_path growth | backlog 或日志异常增长 |
| tracker view mismatch | leader、trunk server、active set 不一致 |
| clock offset | 超过路由/同步可接受范围 |
| media errors | SMART/NVMe critical warning/FS error |
| trunk fragmentation | live/allocated ratio 下降 |

### 5.4 Access log

V6.14+ 使用 `[access-log]` section，默认关闭；V6.16 支持微秒时间精度。线上建议开启，但要评估：

- 高 QPS 日志 I/O 和 rotation；
- file ID 可能属于敏感资源标识；
- client IP/URL 的隐私和保留期限；
- 错误码、latency、bytes 是否足够；
- storage 与 Nginx/CDN 日志关联 request ID。

## 6. 工具成熟度审计

V6.17 `tools/Makefile` 默认构建大量工具，包括 verify、migrate、batch-delete、backup/restore、repair/recover、benchmark、sync-check、quota、replication status、cluster manager、config validator 等。这比旧版本运维面丰富，但存在三个风险：

1. 某些源文件规模很大、注释宣称全面功能，却缺少对应测试/文档；
2. `fdfs_snapshot.c` 含 group snapshot/restore/compare placeholder，且未列入默认 `ALL_PRGS`；
3. `fdfs_rebalance.c` 明确创建 placeholder tasks，不能证明自动发现并透明重平衡真实文件。

任何工具进入生产必须经过：dry-run、只读代码审计、百万/十亿对象规模测试、trunk/appender 覆盖、失败恢复、幂等、并发写一致性和备份。尤其禁止把运行 shell `rm -rf` 或临时文件处理不严谨的辅助工具直接以 root 对生产数据执行。

## 7. 安全模型

### 7.1 默认暴露面

样例 tracker/storage：

- `bind_addr` 为空，可监听主机所有地址；
- `allow_hosts=*`；
- 核心 TCP 协议未见 TLS 配置/握手；
- 普通 upload/download/delete 没有用户 token、tenant、RBAC；
- file ID 可直接定位/访问文件；
- HTTP anti-steal 默认关闭；
- 样例 secret 是公开字符串 `FastDFS1234567890`。

直接按样例上线会把安全边界等同于网络可达性。

### 7.2 V6.17 安全增强的边界

正式发布新增：

- storage→tracker 使用注册 IP/server identity 校验；
- storage→storage 文件同步使用 16 字节 sync key；
- key 由 storage 生成，报告给 tracker，再由 tracker 给同组 peer；
- 删除 storage、删除 group、设置 trunk server检查 client IP。

它们显著减少伪造 storage、任意拉取恢复 binlog和远程管理命令风险，但没有提供：

- 普通业务 client 身份；
- per-file/per-tenant 授权；
- mTLS 和证书轮转；
- 传输机密性；
- 静态加密；
- audit principal；
- 强防重放/细粒度 capability。

### 7.3 HTTP 防盗链

anti-steal token 由 secret、file ID 和 timestamp 派生，默认 TTL 900 秒，固定实现使用 MD5 风格 token。它适合阻止 URL 被长期外链，不能承担完整认证：

- 共享 secret 泄露影响全部对象；
- URL/query 可能进入日志、Referer、缓存；
- MD5 token 不是现代租户授权协议；
- 不绑定 method、client identity、range 或业务 ACL；
- 不加 HTTPS 时 token 可被窃听。

应由统一网关基于业务身份发短期签名 URL，secret 放 KMS 并支持 key ID/轮转；FastDFS token 可作为兼容层而非唯一防线。

### 7.4 File ID 不是凭据

官方说明曾把文件名理解为访问凭据，但其生成结构可解析，随机填充用 `rand()`，扩展名和 group 公开。安全上最多把它视为“难以人工猜中的资源定位符”，不能视为不可伪造 capability。对敏感对象必须通过应用 ACL/网关授权。

## 8. 安全加固基线

### Network

- tracker/storage 只绑定专用私网 IP；
- `allow_hosts` 明确枚举 client、storage、monitor 子网；
- host firewall/security group 双向最小开放；
- 公网入口只到 WAF/LB/Nginx gateway；
- 跨区同步经专线、IPsec/WireGuard 或 mTLS proxy；
- 管理命令从独立 bastion/automation identity 发起。

### Identity and authorization

- 业务 API 完成用户/租户认证和对象 ACL；
- file ID 不直接作为公开永久 URL；
- 签名 URL 短 TTL、绑定 path/method，可撤销；
- upload/delete 必须在服务端代理或受控 SDK，不能向不可信客户端暴露 storage；
- 管理操作双人审批、审计命令和来源 IP。

### Encryption

- 外部 HTTP 强制 TLS；
- 敏感内容在应用侧 envelope encryption，file ID 对应密文对象；
- 数据盘全盘加密并管理 recovery key；
- backup/DR 独立 key；
- key rotation 与对象重加密流程测试。

### Software supply chain

- 固定 FastDFS、依赖和 Nginx module SHA；
- 编译器 hardening、ASLR、RELRO、stack protector；
- 非 root 运行，最小文件权限；
- SBOM、漏洞扫描、Release/HISTORY watch；
- fuzz client protocol/file ID/trunk header；
- canary 和快速回滚制品。

## 9. Runbook 最小集合

必须形成并演练：

- tracker failover/split view；
- storage offline/backlog；
- path 低空间与只读切换；
- 单盘恢复；
- 新节点初始同步；
- trunk server 切换；
- checksum mismatch 修复；
- group 扩容和 file ID 迁移；
- emergency reserved-space adjustment；
- 证书/签名 secret 轮转；
- 版本升级与数据格式回退限制；
- 业务 DB 与 FastDFS orphan/missing 对账；
- 整组灾难恢复。

每个 runbook 要写前置条件、只读检查、精确命令、预期状态、回滚、校验和停止条件，避免在生产故障中临时组合危险工具。

## 10. 结论

FastDFS 的日常运维不复杂，但安全和灾备不能只靠默认配置。V6.17 已开始强化节点间身份，说明历史可信内网假设正在补课；普通客户端协议仍应放在受控服务后面。生产就绪的关键是收紧网络、固定制品、打开可观测性、建立业务 manifest/checksum，并把辅助工具当作需验证代码而非成熟控制面。
