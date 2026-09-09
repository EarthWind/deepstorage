# 3FS 部署、运维、安全与灾备

## 1. 生产拓扑

官方 setup guide 给出一个六节点示例：

- 1 个 Meta 节点，约 128 GiB 内存；
- 5 个 Storage 节点，每节点约 512 GiB 内存；
- 每 Storage 节点 16 块约 14 TB NVMe；
- RoCE 网络；
- 每盘多个 target，三副本 chain。

该示例用于说明流程，不是高可用生产拓扑。官方文档同时建议生产把 FoundationDB 与 ClickHouse 部署到独立节点，Client 不与 Storage/Meta 混部。

推荐按故障域拆分：

| 节点池 | 建议 | 原因 |
| --- | --- | --- |
| MgmtD | 至少 3 实例，跨机架 | lease 主切换；实例本身无须同机 |
| Meta | 多实例，跨机架 | namespace RPC 横向扩展 |
| FDB | 独立集群，roles 跨机架 | 全部元数据权威状态 |
| Storage | 同构 NVMe/RNIC，按机架分布 | 性能、placement、恢复 |
| Monitor | 至少 2 实例或可快速重建 | 指标采集不能反压 I/O |
| ClickHouse | 独立、按保留期规划 | 指标写入与查询 |
| Client | 训练/推理计算节点 | 避免与服务端争用 CPU/RNIC |

小规模测试可将服务混部，不能据此推导生产资源隔离。

## 2. 软件和硬件前置

### 2.1 软件

官方基线要求/推荐包括：

- Linux；
- FoundationDB 7.1 或以上系列，client library 与 server 匹配；
- libfuse 3.16.1 或以上；
- Rust 最低约 1.75，推荐约 1.85；
- C++ 编译工具链、CMake/vcpkg 等构建依赖；
- XFS；
- RDMA userspace/driver；
- RocksDB/LevelDB；
- ClickHouse（指标）。

仓库提供 Docker 开发构建环境，但生产二进制仍需自行构建、打包、签名和分发。没有官方稳定 release 意味着平台方应保存：

- 完整 commit SHA；
- submodule/dependency lock；
- compiler 和 libc 版本；
- `SHUFFLE_METHOD`；
- 构建参数和 feature flags；
- image digest/SBOM；
- 配置 schema/version；
- 二进制 checksum。

### 2.2 Storage 硬件

每台 Storage 的关键路径：

```text
CPU/DRAM <-> PCIe root complex <-> RNIC
                    |
                    +-------------> NVMe x N
```

需要核验：

- RNIC 与 NVMe 是否跨 NUMA；
- PCIe lane/交换芯片是否过订阅；
- 每盘顺序读写和 4 KiB IOPS；
- drive write endurance、PLP、firmware；
- thermal throttling；
- 单盘掉线/重置时间；
- 整机内存能否容纳连接、metadata cache、registered memory；
- recovery 时读+写的混合上限。

## 3. 部署顺序

建议的依赖顺序：

1. 验证时钟、DNS/IP、MTU、RDMA 连通性、NUMA；
2. 部署 FDB，完成 redundancy、status、backup/restore 验证；
3. 部署 ClickHouse 指标库和保留策略；
4. 构建固定 SHA 的 3FS 包，记录 shuffle 方法；
5. 启动 Monitor；
6. 启动多个 MgmtD 并确认唯一 primary；
7. 用 admin 工具上传全局配置；
8. 启动 Meta；
9. 格式化/挂载 XFS，创建 Storage target；
10. 生成并审核 chain/data placement；
11. 上传 target、chain、chain table；
12. 启动 Storage，确认全 target serving；
13. 启动 FUSE Client；
14. 验证 FUSE 基础语义；
15. 注册并验证 USRBIO；
16. 运行性能、故障和长稳测试；
17. 打开认证并重新验证所有组件；
18. 完成备份、恢复、扩容和回退演练后上线。

MgmtD 管理服务配置，配置变更通常由 admin CLI 上传。不要绕过 MgmtD 手工修改部分节点本地文件，否则会造成漂移。

## 4. XFS 与 NVMe 初始化

官方部署示例使用：

- XFS；
- `noatime,nodiratime`；
- 4 KiB sector；
- 提高 `fs.aio-max-nr`（示例到 67108864）；
- 每 target 指向独立数据路径；
- 数据与 chunk metadata 路径按配置布局。

上线前要建立自动检查：

- block device WWN/serial 与 target ID 一一绑定；
- 不用易变化的 `/dev/nvmeXnY` 名称作为唯一身份；
- filesystem UUID 无重复；
- mount options 符合基线；
- 磁盘未被系统盘/其他服务使用；
- discard/hole punch 行为与 SSD 固件匹配；
- XFS repair 工具版本固定；
- 容量水位为 COW、恢复和 GC 留足余量。

Storage 的“格式化/清空 target”属于高风险操作，runbook 必须先从 MgmtD 解析 target、chain、物理盘和当前副本健康度，禁止凭设备名手工操作。

## 5. Chain Table 生成与审核

自动求解后必须有独立审核器验证：

- 副本数正确；
- chain 内 failure domain 唯一；
- 每盘/每节点 chain 参与次数方差；
- head/middle/tail 角色分布；
- 任一节点失效后 surviving read load；
- 任意两节点共同失效后的数据风险；
- 扩容前后旧/新 table 共存；
- table version 单调；
- 文件 layout 引用的 table 永久可解释；
- batch/online exclusive table 确实不共享硬件。

建议把 chain table 作为受版本控制的配置制品，保存生成输入、solver 版本、随机种子和审核报告。

## 6. 配置治理

配置项影响正确性，不应只按性能参数管理：

| 配置类别 | 例子 | 风险 |
| --- | --- | --- |
| 数据格式 | shuffle method、chunk size、engine | 改错后旧数据不可定位/读取 |
| 一致性 | relaxed read、fsync length | 应用观察语义变化 |
| HA | lease、heartbeat、timeout | 误 fencing 或故障收敛慢 |
| 安全 | authenticate、token lifetime | 未授权访问 |
| 校验 | checksum type/verify | 静默损坏检测缺口 |
| GC | delay、batch、concurrency | 空间泄漏或前台抖动 |
| 恢复 | concurrency、bandwidth | 业务 P99 与恢复 RTO |
| 网络 | RDMA timeout、queue depth | 重试风暴、资源耗尽 |

配置发布建议：

1. schema 校验；
2. semantic diff；
3. canary 服务；
4. 自动观测错误率/P99；
5. 显式回滚条件；
6. 保存 MgmtD/FDB 中的上一版本；
7. 对不可逆项禁止在线修改。

## 7. 监控架构

服务将指标交给 Monitor，再写入 ClickHouse。ClickHouse 不是 I/O 可用性的同步依赖，但指标队列不能无限占用服务资源。

### 7.1 必要 Golden Signals

#### Client/FUSE/USRBIO

- read/write bytes、IOPS、size histogram；
- latency P50/P90/P99/P999；
- retry、timeout、stale chain version；
- pending read retry 与 relaxed read 数量；
- I/O ring depth、queue wait、completion lag；
- registered memory、QP/CQ 数；
- FUSE queue depth、4 KiB IOPS；
- Meta lookup/open/close/fsync latency。

#### Meta/FDB

- RPC success/error/timeout；
- FDB transaction latency、conflict、retry、too-old、too-large；
- create/rename/unlink/list 分操作 P99；
- open sessions、expired sessions；
- dynamic length backlog；
- GC queue depth、oldest age、retry；
- inode allocator block refill；
- FDB status、recovery state、storage/log queue、disk/free。

#### MgmtD

- current primary、lease remaining/renew failures；
- heartbeat missing/suspicious；
- config version；
- chain table version；
- target state counts；
- state transition duration；
- under-replicated chain count；
- clock offset。

#### Storage

- per target state/free bytes；
- committed/pending chunks；
- update/commit/read latency；
- RDMA transfer latency/error；
- SSD bandwidth/IOPS/latency/utilization；
- metadata DB WAL/compaction；
- COW allocation failure；
- checksum mismatch；
- unrecycled bytes；
- recovery chunks/bytes/rate/ETA；
- read-only/offline/lastsrv events。

官方 metrics 文档覆盖多项计数器和分位数，但部分说明仍留有“需要检查代码”之类占位。生产监控字典应从固定二进制的实际 metric registry 自动生成，不应只抄文档。

### 7.2 核心 SLO

建议分开定义：

- namespace availability；
- data read/write availability；
- read/write P99；
- stale route retry rate；
- chain under-replicated duration；
- target recovery RTO；
- GC backlog age；
- FDB transaction success/P99；
- data durability/backup restore 成功率；
- checksum error MTTR。

一个“3FS availability”无法解释 Meta 不可用但已开文件仍可读的状态。

## 8. 日志、审计与诊断

日志必须包含且可关联：

- cluster ID；
- service ID/instance ID；
- client UUID/request ID；
- inode/chunk ID；
- chain ID/table version；
- target ID；
- committed/pending version；
- FDB transaction attempt/error；
- trace/span ID；
- config/build SHA。

避免在普通日志中输出 user token、FDB cluster file、RDMA key 或完整敏感路径。

admin 工具包含列举/更新 chain、offline target、dump metadata、查找 orphan chunk、checksum 等能力。建议为每个危险命令提供：

- read-only dry-run；
- 明确 cluster/target 参数；
- 当前健康度门槛；
- 双人审批；
- 操作日志；
- 可恢复步骤。

## 9. 安全模型

### 9.1 身份与认证

Meta/MgmtD 默认配置中的 `authenticate` 可为 false。生产必须显式开启并验证所有服务/客户端是否真的拒绝未认证连接。

用户 token 的公开实现包含：

- magic/格式；
- uid；
- secure random 值；
- CRC32；
- 编码/置换；
- FDB 中保存的 token 与有效期校验。

CRC32 是误码/格式校验，不是密码学 MAC。token 本质是 bearer credential；基线随机字段规模、轮换、撤销和分发要按攻击模型审查。建议：

- 短生命周期；
- 自动轮换；
- 不写日志/命令行；
- 用 secret manager 分发；
- root token 严格隔离；
- audit token create/revoke；
- 泄露演练。

### 9.2 授权

3FS 提供 uid/gid、mode、sticky/immutable 等基础 Unix 语义，root token 可代表其他用户。公开 FUSE 路径不支持通用 xattr，因此不能默认拥有 POSIX ACL/NFSv4 ACL 的完整表达力。

多租户使用前要验证：

- uid/gid 来源是否可信；
- group membership 的刷新；
- root squash 类边界；
- hardlink/symlink 越权；
- sticky directory；
- FUSE mount namespace；
- trash/GC 的跨用户隔离；
- admin API 是否独立鉴权。

### 9.3 网络与加密

固定基线的公开配置/设计没有给出明显的 3FS RDMA/TCP 数据面传输加密层。RDMA fabric 上的节点若能伪造连接或访问凭据，风险不能由 Unix mode 自动消除。

建议：

- 物理/逻辑隔离 storage fabric；
- 交换机 ACL/VLAN/PKey；
- host firewall 和 allowlist；
- 管理网与数据网隔离；
- FDB 使用受保护网络和 TLS（按其版本能力配置）；
- ClickHouse 开 TLS/认证；
- 跨不可信网络使用外部加密隧道，但先验证 RDMA 兼容与性能；
- 不把 RoCE 无损网络当作安全域本身。

静态数据也未见 3FS 自带透明加密承诺。可由自加密盘、dm-crypt、XFS 下层、机房密钥管理或应用加密提供，但每种方式都要测 O_DIRECT、trim、恢复与性能。

### 9.4 FDB 安全

FDB 官方指出，拥有 cluster file 并可连接集群的主体可访问 key space。保护措施：

- cluster file 最小权限；
- 不下发到普通 Client；
- 仅 Meta/MgmtD/运维节点可达端口；
- FDB TLS 与证书；
- 独立 OS 用户；
- 备份介质加密；
- 访问审计；
- 定期轮换和恢复演练。

## 10. 备份、快照与灾备

### 10.1 元数据

FDB backup 可做 point-in-time backup，FDB DR 可异步复制到另一个集群。注意：

- backup 数据默认静态加密能力要按部署确认；
- backup/restore 需要独立容量和带宽；
- 只恢复 FDB 不保证与 Storage 当前 chunk 集合一致；
- 恢复到旧时间点可能引用已经 GC 的 chunk。

### 10.2 文件数据

chain 副本用于在线高可用，不是离线备份。建议按数据价值增加：

- 上游对象存储/数据湖作为源；
- 数据集 manifest + file/chunk checksum；
- 跨 3FS 集群异步复制；
- immutable/air-gapped backup；
- Checkpoint 同步到第二存储；
- 定期随机恢复验证。

### 10.3 一致性备份协议

公开基线未提供全局 native snapshot 时，可在应用层：

1. 停止或 quiesce writer；
2. 等待 USRBIO completion、fsync/close；
3. 写入不可变 manifest；
4. 用 rename 发布 snapshot root；
5. 复制数据和 manifest；
6. 记录对应 FDB backup version/time；
7. 在隔离环境恢复并逐文件 checksum。

这仍不是瞬时全局快照，但比只复制目录树更可验证。

## 11. 扩容与缩容

扩容不能只“加盘然后改 hash”，因为旧 inode 保存布局。安全方法通常是：

- 新增 targets；
- 生成新 chain/table/version；
- 新目录/新文件使用新 table；
- 旧文件继续引用旧布局；
- 必要时通过离线/后台 rewrite 迁移；
- 长期保留旧 table 的解释能力。

需要衡量：

- 新旧池容量倾斜；
- 新文件热点；
- chain table 数量；
- 迁移时三副本额外空间；
- Client cache/version；
- 回退时旧 target 是否仍在。

缩容更危险：必须证明所有引用目标的数据已迁移、所有 inode 已切换，且回收后不会有离线客户端按旧布局写入。

## 12. 升级与回滚

公开仓库无 release/tag，也未提供完整 rolling compatibility matrix。生产平台必须自己验证：

- N 与 N+1 Client/Meta/MgmtD/Storage 协议互通；
- chain table/version 序列化；
- FDB schema migration；
- chunk metadata/disk format；
- 新旧 chunk engine；
- config default 变化；
- shuffle method；
- token/auth；
- metrics schema；
- admin CLI 与服务版本；
- P model/故障回归。

推荐顺序不是固定结论，应通过 staging 确认。一般先保证控制面向后兼容，再 canary Meta/Client，最后逐 target Storage。任何可能改变磁盘格式或布局算法的版本都要支持显式 preflight 和备份。

回滚条件：

- 未发生不可逆 schema/format migration；
- 旧二进制理解当前 chain table/config；
- 旧 shuffle method 相同；
- FDB transaction schema 兼容；
- 已验证 in-flight request/session；
- 可把 canary target 安全下线并重同步。

## 13. 日常 Runbook

### 13.1 Target Offline

1. 确认物理盘/节点和受影响 chains；
2. 确认每条 chain 至少一个健康完整副本；
3. 观察 MgmtD version 和 target state；
4. 限制并发恢复；
5. 更换/修复设备；
6. 让 target 进入 syncing；
7. 监控 bytes/chunks、前台 P99、checksum；
8. sync done 后确认 serving；
9. 对 chain 做抽样校验；
10. 记录 under-replicated duration。

### 13.2 FDB 异常

1. 冻结危险的配置/target 变更；
2. 查看 FDB status/recovery；
3. 区分 client network、coordinator、log、storage 故障；
4. 控制 Meta 重试风暴；
5. 恢复 quorum/roles；
6. 验证 MgmtD lease 唯一；
7. 检查 chain table version 未回退；
8. 抽查 namespace 与 Storage；
9. 必要时从 backup/DR 恢复并执行对账。

### 13.3 容量告急

1. 分开看 raw free、allocator free、unrecycled、trash、COW reserve；
2. 暂停大规模写/恢复；
3. 检查 GC/trash_cleaner；
4. 不直接手删 Storage 数据文件；
5. 加速安全 GC 或加 target；
6. 确认 chain placement 后再恢复流量；
7. 复盘容量模型和告警阈值。

### 13.4 Checksum 错误

1. 隔离具体 chunk/target/drive；
2. 禁止从可疑副本覆盖健康副本；
3. 比较所有 replica version/checksum；
4. 选择已提交健康源；
5. full-chunk repair；
6. 检查相同 drive/firmware 的关联错误；
7. 扩大 scrub；
8. 保存证据后更换设备。

## 14. 上线门槛

- [ ] 固定 SHA、工具链、shuffle method 和 SBOM；
- [ ] 三类故障域的 chain placement 审核通过；
- [ ] FDB backup + bare restore 演练通过；
- [ ] 单盘、单节点、MgmtD、Meta、FDB、网络分区注入通过；
- [ ] 72 小时以上目标混合负载稳定；
- [ ] recovery 时前台 P99 在 SLO 内；
- [ ] GC/trash backlog 可观测、可限速；
- [ ] 认证开启，未认证访问被拒；
- [ ] 数据/管理网络隔离；
- [ ] 静态/传输加密方案符合合规要求；
- [ ] 应用 syscall/POSIX 兼容矩阵通过；
- [ ] 升级、回滚、配置回滚演练通过；
- [ ] 数据灾备恢复按 manifest/checksum 验证；
- [ ] 所有危险 admin 操作有审批和审计。

## 15. 运维结论

3FS 不是“装几个 daemon 就能跑”的存储。其生产可靠性来自 FDB、RDMA、XFS/NVMe、chain placement、配置版本和恢复节流的共同正确。项目已有较丰富的 admin/metrics 基础，但 release 治理、滚动兼容、安全默认值、快照灾备和完整修复 runbook 仍需要采用方补齐。
