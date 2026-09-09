# 3FS 高可用、故障隔离与恢复

## 1. 故障域

生产设计至少区分：

- 进程：Client/FUSE、Meta、MgmtD、Storage、Monitor；
- 主机：CPU、内存、OS、PCIe；
- 设备：NVMe、RNIC；
- 网络：链路、交换机、RoCE lossless domain；
- 机架/PDU；
- FDB transaction/log/storage roles；
- ClickHouse（只影响监控，不应影响 I/O）；
- 配置和软件版本。

target 是逻辑单元，不自动等于物理故障域。多个 target 在同盘或同节点时必须由 placement 避免同 chain 共置。

## 2. MgmtD 主选举与 Lease

多个 MgmtD 竞争 FDB 中的 primary lease。主实例负责：

- 服务注册和心跳状态；
- 配置版本；
- target public state；
- chain table 及其 version；
- 故障目标移动与恢复协调。

默认/示例配置中可见：

- lease 约 60 秒；
- 周期延长约 10 秒；
- suspicious 窗口约 20 秒；
- heartbeat fail interval 约 60 秒；
- 启动 bootstrap 约 2 分钟；
- chain 更新轮询约 1 秒。

这些数字不是普遍最优。检测越快，误判和网络抖动造成的 fencing 越多；越慢，故障恢复和写暂停越长。

Lease 实现使用 FDB 事务保证竞争更新，包含 version/rollback 防护。它还使用 UTC/墙钟时间判断有效期，因此 MgmtD/FDB 周边应有可靠时钟同步和监控。时钟跳变必须进入故障注入。

## 3. 服务自我隔离

设计说明要求 Meta/Storage 在长时间无法与 MgmtD 取得联系时退出，示例为约 `T/2`。目标是避免网络分区一侧继续用旧 chain table 对外服务。

Storage 还会根据 MgmtD 下发的 target public state 自检：

- 如果本地目标被标记为 `lastsrv` 或 `offline`，旧进程不能继续提供服务；
- stale chain version 请求被拒绝；
- 进程退出/重启让客户端连接快速失败并刷新。

这是“fail-stop + version fencing”策略。安全性依赖：

- MgmtD 主 lease 唯一；
- chain table version 单调；
- Storage 确实检查 version；
- 分区旧进程无法绕过状态继续写；
- Client 不无限缓存旧路由。

## 4. Target 状态机

### 4.1 Public 状态

| 状态 | 可读 | 可写 | 含义 |
| --- | --- | --- | --- |
| `serving` | 是 | 是 | chain 中正常服务 |
| `syncing` | 否 | 是 | 正在追赶，接收线上写但不对外读 |
| `waiting` | 否 | 否 | 等待进入同步/操作 |
| `lastsrv` | 否 | 否 | 离线前可能是唯一 serving 成员，保留特殊恢复语义 |
| `offline` | 否 | 否 | 已从服务路径隔离 |

本地还可有 `up-to-date`、`online`、`offline` 等状态。Public 状态由 MgmtD 协调，本地状态反映 Storage 对自身数据的判断。

### 4.2 为什么需要 lastsrv

如果某 target 离线前是 chain 唯一 serving 成员，简单把它当普通 stale replica 丢弃可能导致没有权威副本。MgmtD 用 `lastsrv` 记录它的特殊地位；它重新出现并完成必要检查后，可恢复为 serving。

这降低“最后副本被错误放弃”的风险，但不能把 lastsrv 等同于数据一定正确。磁盘损坏、split-brain、version 回退仍需要 checksum、元数据比对和人工 runbook。

## 5. Storage/Target 故障时的 Chain 变化

当 chain 中成员失败：

1. MgmtD 通过心跳超时识别；
2. 将 target 调整到 chain 尾部或离线状态；
3. 生成更高 chain table version；
4. 客户端和 Storage 获取新路由；
5. 失败成员的前驱改向新 successor 重试；
6. 健康成员继续服务，副本数暂时下降。

将失败成员移动到尾部的好处是：健康前缀仍保留已排序提交关系，返回成员可从前驱同步。风险是：

- chain route 收敛前写请求重试；
- surviving replica 负载上升；
- 多故障可能耗尽完整副本；
- version 管理错误会导致错误路由或数据分叉；
- 故障域相关失效可能一次打掉同 chain 多成员。

## 6. 返回目标的在线同步

### 6.1 启动门槛

返回 Storage 不应看到一个 target 就立即对外服务。设计要求等待 MgmtD 把其相关 target 识别为 offline/可恢复，再重新心跳和进入同步，避免旧进程与新进程同时服务。

### 6.2 同步流程

1. 返回 target 被放到 chain 尾端，状态为 syncing。
2. 它不对客户端读，但接收来自前驱的线上写。
3. 同步期间的正常写以完整 chunk replacement 转发，避免在未知基线应用 partial delta。
4. 前驱请求目标导出 chunk metadata。
5. 双方按 chunk 是否存在、chain version、committed/pending version 比较。
6. 缺失或旧 chunk 从健康前驱复制。
7. 多余/stale chunk 按规则清理。
8. 扫描和追赶完成后通知 MgmtD。
9. 本地标为 up-to-date，Public 状态切到 serving。

```text
normal traffic:  head -> healthy predecessor -> syncing target
                                      |
background scan: local metadata <----> remote metadata
                                      |
                              full chunk copy
```

### 6.3 恢复期间的一致性

让 syncing target 接收新写，避免“全量扫描永远追不上线上变化”。full-chunk replacement 让返回副本不依赖其旧 chunk 内容。

仍需关注：

- 扫描起点和线上写的版本竞态；
- committed/pending 双版本如何比较；
- chain version 变化时是否重启/续传；
- sync done 与最后在途写的 barrier；
- delete/tombstone 是否会被旧 chunk 复活；
- checksum mismatch 的源选择。

## 7. 恢复成本

恢复本质是全副本比较与拷贝，成本由以下因素决定：

- target chunk 数；
- dirty/missing 数据量；
- metadata dump/scan 吞吐；
- 源 SSD 读带宽；
- 目标 SSD 写和 COW/allocator；
- RDMA 带宽；
- 正常流量优先级；
- 并发恢复 target 数。

三副本没有 EC decode CPU 成本，但会复制完整 chunk。单盘/单节点恢复可以持续数小时，并消耗本应用于前台读的源副本。

建议设置：

- recovery 带宽/IOPS 上限；
- 前台 P99 触发的自动降速；
- 每 failure domain 最大并发；
- 最小空闲容量；
- 预估完成时间和无进展告警；
- checksum/bytes/chunks completed 指标；
- chain under-replicated duration SLO。

## 8. 故障矩阵

| 故障 | 预期行为 | 主要风险 | 必测项 |
| --- | --- | --- | --- |
| 单 Meta 崩溃 | Client 切换其他 Meta | in-flight RPC unknown | 幂等、连接重建、尾延迟 |
| 全 Meta 不可用 | 已有 layout 的数据 I/O 可能部分继续；namespace/open 失败 | token/config/session 过期 | 已开 fd 与新 open 差异 |
| primary MgmtD 崩溃 | lease 到期后新主接管 | 切换窗口、双主、时钟 | lease fencing、version 单调 |
| FDB 短暂不可用 | Meta/MgmtD 事务失败重试 | 全局控制面停顿 | 5 秒事务、重试风暴 |
| FDB 灾难 | namespace/config/lease 丢失 | 数据副本无法自描述完整 namespace | 备份恢复和数据对账 |
| 单 Storage 进程崩溃 | chain 降级并换路由 | 写暂停、连接风暴 | ACK 丢失、重复请求 |
| 单 NVMe 损坏 | 相关 targets 离线/同步 | 同盘多 target 相关失效 | placement 校验 |
| 单节点断电 | 多盘 targets 同时故障 | 多 chain 降级、恢复风暴 | 限速、公平性 |
| 中间 chain 成员断开 | 前驱切换 successor | in-flight pending | 版本收敛 |
| tail 变慢 | 写 P99/P999 上升 | 全 chain backlog | timeout、隔离阈值 |
| 客户端与 MgmtD 分区 | 旧 route 最终失败/进程退出 | stale 写 | T/2 fencing |
| Storage 与 MgmtD 分区 | 自我隔离 | 可用性损失 | 不得继续 stale serve |
| RoCE 拥塞/PFC storm | RDMA timeout/尾延迟 | 集群级相关故障 | ECN/PFC/CQ 指标 |
| Client 崩溃 | session 过期、GC 后续清理 | length 陈旧、资源泄漏 | session/length 收敛 |
| 磁盘满 | 新 COW/恢复失败 | serving 目标只读或故障 | 预留和 backpressure |
| checksum mismatch | 报错/从健康副本修复需验证 | latent corruption | scrub/repair runbook |

## 9. Meta 和 FDB 高可用

Meta 无状态，所以可以：

- 多实例部署；
- 客户端负载均衡/重试；
- 无需复制本地 inode cache 的权威状态；
- 实例故障后快速替换。

但 FDB 是真正的元数据故障域。生产应：

- 让 transaction/log/storage roles 跨主机/机架；
- 使用适当 replication mode；
- 独立监控 recovery state、data distribution、process class；
- 定期做 backup 和 restore；
- 若需要 DR，配置异步 DR 并明确 RPO；
- 保护 cluster file、端口和证书/网络；
- 校验 FDB client library 与 server 版本兼容。

不能用“Meta 多副本”掩盖 FDB 单集群风险。

## 10. 数据灾备与恢复边界

FDB backup/DR 只覆盖元数据和管理状态，Storage chain 复制通常只在同一集群故障域内。公开基线没有完整说明：

- 全体数据与 FDB 的一致时间点快照；
- 跨集群异步复制；
- 任意时间点恢复；
- ransomware/误删隔离；
- 离线 immutable backup；
- 从只剩 Storage 数据重建完整 namespace。

因此 3FS 三副本是高可用，不自动等于备份或灾备。生产需要上层数据集复制、对象存储归档、manifest/checksum 或双集群流程。

## 11. 形式化模型

仓库 `spec` 使用 P 描述 CRAQ 与 RDMA 协议。公开 README 记录的测试计划包含多种 CRAQ/RDMA 场景和调度，验证目标包括：

- 已完成写入；
- chunk version 单调；
- 复制节点最终更新；
- RDMA 请求/响应故障交互。

价值：

- 状态机与不变量可执行；
- 能穷举部分消息重排/故障调度；
- 对 committed/pending/version 设计提供额外信心；
- 可作为后续修改的回归规范。

边界：

- 模型 README/TODO 明确尚未覆盖完整 leader election/target movement；
- 模型抽象了真实线程、存储、网络和持久化；
- 没有自动证明 C++/Rust 实现与 P 模型等价；
- FDB、GC、length、FUSE 和升级不在同一个整体证明中。

推荐将新发现故障先还原为 P 场景，再加入实现故障注入测试。

## 12. RTO/RPO 评估

不要给系统一个笼统 RTO。应分：

| 能力 | RPO | RTO 的主要组成 |
| --- | --- | --- |
| 单 target 故障继续服务 | 已 ACK chunk 目标为 0 | 检测 + chain version 下发 + Client 刷新 |
| 恢复副本数 | 0（有健康完整副本时） | metadata scan + 全量/增量 copy |
| MgmtD 切主 | 控制状态目标为 0 | lease 过期 + bootstrap + reload |
| Meta 故障 | FDB 已提交事务为 0 | Client retry/连接切换 |
| FDB 本地容灾 | 取决于 replication | FDB recovery |
| FDB backup 恢复 | 取决于备份/DR | restore + 与 Storage 对账 |
| 跨集群数据灾备 | 公开基线无统一承诺 | 由外部复制方案决定 |

## 13. 高可用结论

3FS 的单集群 HA 设计有明确的 fencing、状态机和在线同步路径，优于只依靠“副本数”的粗糙方案。其主要风险不在有没有恢复，而在恢复与在线流量竞争、相关故障域、chain version 正确性，以及 FDB 元数据与 Storage 数据的灾难级一致恢复。生产上线前必须用故障注入测量实际 RTO/P99，而不是只验证进程最终回来了。
