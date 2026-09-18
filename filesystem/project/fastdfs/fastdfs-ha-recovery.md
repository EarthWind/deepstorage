# FastDFS 高可用、扩缩容与故障恢复

## 1. 故障域模型

FastDFS 至少有六类故障域：

1. client/应用进程；
2. tracker 进程或主机；
3. 单 storage 进程或主机；
4. storage 的单个 store path/磁盘；
5. group 整体；
6. 机房、网络分区和外部业务数据库。

“两个 tracker + 每组两个 storage”只覆盖部分进程/主机故障。若两个 storage 在同一主机、机架、电源域或机房，不构成独立数据副本；若业务数据库丢失 file ID，FastDFS 数据仍在也难以恢复业务 namespace。

## 2. Tracker 高可用

### 2.1 客户端故障切换

client.conf 可配置多个 tracker。客户端尝试可用连接，tracker 负载低且不转发内容，因此常见部署两个实例。若一个 tracker 进程停止，已有 client→storage 传输通常继续，新的路由请求转向其他实例。

必须验证具体语言 SDK 是否：

- 启动时只解析一次 DNS；
- 按序或随机连接 tracker；
- 失败后是否有指数退避；
- 是否缓存 storage 路由；
- tracker 返回成功但 storage 失败时是否重查；
- 会不会无界 retry 导致放大故障。

### 2.2 状态同步不是共识复制

tracker 的 cluster files 与 storage report 最终汇聚集群状态。它没有统一 commit index，也没有对每次 group/storage 变更执行多数派复制。管理操作向 tracker 发起后，其他实例可能通过通知/文件同步逐渐收敛。

这带来两个操作要求：

- 管理面不能同时向不同 tracker 发冲突命令；
- 自动化必须读取所有 tracker 视图并检查一致，而不是只看一个健康端点。

### 2.3 Leader 失效

relationship 线程周期探测 leader。连续失败达到阈值后清除 leader 并重新选择。选择使用可达状态排序，而不是 quorum term。V6.17 storage 可以通知 tracker 重新选主，处理它观察到的 split leadership。

leader 主要影响：

- trunk server 选择/分发；
- tracker 间协调；
- 某些状态持久和管理流程。

普通文件字节仍在 storage，leader 失效不会自动停止所有读写；但 trunk 小文件写和控制操作更敏感。

## 3. Storage 状态机

V6.17 状态枚举：

| 状态 | 值 | 工程含义 |
| --- | ---: | --- |
| `INIT` | 0 | 初始加入 |
| `WAIT_SYNC` | 1 | 等待源节点进行历史同步 |
| `SYNCING` | 2 | 正在同步历史数据 |
| `IP_CHANGED` | 3 | IP 变化，旧身份隔离 |
| `DELETED` | 4 | 已从集群删除 |
| `OFFLINE` | 5 | 不提供正常服务/同步转换状态 |
| `ONLINE` | 6 | 已在线但未必可承载全部 client 流量 |
| `ACTIVE` | 7 | 正常可读写候选 |
| `RECOVERY` | 9 | 磁盘恢复中 |
| `NONE` | 99 | 无有效状态 |

状态命名不能仅靠字面解释。例如初始同步完成后代码可能从 `SYNCING` 报告为 `OFFLINE`，再由 tracker/心跳流程提升为 online/active。运维自动化应使用官方 monitor 逻辑和版本对应状态转换，不要自行把 `ONLINE` 当作“副本已完整”。

## 4. 新 Storage 加入

### 4.1 加入条件

新实例向 tracker 报告：

- group name；
- storage ID/IP/port；
- store path count；
- 版本、状态和同步密钥；
- tracker 列表、容量等。

同组 store path count 必须一致。启用 storage ID 后，ID/组/IP/端口来自 `storage_ids.conf`；IP 变化和 NAT/IPv6 更易管理。

### 4.2 初始同步

tracker 为新成员选择源 storage 和同步起点，新节点进入 `WAIT_SYNC`。源节点的同步线程：

1. 为目标打开 binlog reader/mark；
2. 以目标的 16 字节 sync key 完成 storage-to-storage join；
3. 将目标转为 `SYNCING`；
4. 扫描历史 binlog并复制旧文件/操作；
5. 追上后报告完成，经过离线/在线转换最终成为 `ACTIVE`。

这不是“从一个完整快照 + 一致增量 log”形式化恢复；历史可恢复性取决于源 storage 的 binlog 和文件仍完整可读。非常老的集群、被清理的日志、单文件同步错误或源磁盘问题都可能造成不完整加入。

### 4.3 上线门槛

不要只等待状态 `ACTIVE`。至少校验：

- group 文件计数/总字节趋势；
- sync backlog、last timestamp 和 error log；
- 从业务 manifest 抽样/全量 file ID 存在性；
- 内容 checksum；
- 普通文件、metadata、slave、appender、trunk 各类型；
- tracker 对该节点的 readable/writable 视图一致；
- Nginx 本地读和 Range 正确。

## 5. 单盘/Store Path 恢复

### 5.1 机制

`storage_disk_recovery.c` 的大致流程：

1. 选取同组可读源 storage；
2. 从 tracker 获取源节点 sync key；
3. 把本 storage 标记为 `RECOVERY`；
4. 向源 storage 请求某个 store path 的 recovery binlog；
5. 对 trunk 和普通记录做拆分/预处理；
6. 按多线程 recovery mark 逐条恢复文件；
7. 保存进度，完成后恢复原状态。

该机制重建的是指定 path 数据，不是通过 parity 计算。它依赖：

- 同组至少一个幸存、可读、内容完整的源；
- 源有足够完整的 path binlog/文件；
- path index 和配置与故障前一致；
- trunk header/binlog 格式兼容；
- 目标盘容量不小于源有效数据；
- 恢复过程中源没有被再次破坏。

### 5.2 恢复期间资源竞争

恢复会读取源磁盘、占用源网卡、写目标盘并进行大量文件操作。若 group 只有两副本，唯一幸存节点同时承担线上读、异步复制和恢复，形成最大风险时的最大负载。

应提供：

- bandwidth/IOPS 限速；
- 业务和恢复独立网络/队列优先级；
- 根据前台 P99 自动降速；
- ETA、bytes/files remaining；
- 二次故障处理；
- 恢复后 checksum scrub；
- 恢复源选择和切换策略。

## 6. 扩容与再均衡

### 6.1 添加新 Group

这是最简单的扩容：部署新组，tracker 依据 `store_lookup=load-balance` 把新上传逐步导向剩余空间更多的组。旧文件不移动，旧 group 压力不会立即下降。

影响：

- 容量分布按新增后的写入速率缓慢收敛；
- 热旧对象仍在旧 group；
- 业务若按时间保留，旧 group 可能长期接近满；
- group 数量增多增加配置、监控和故障域管理成本。

### 6.2 同组添加 Storage

新成员需要复制该组全部数据，不能增加逻辑容量，因为所有文件仍全复制；它增加读副本/冗余，也可能把组有效容量拉低到新节点容量。

### 6.3 跨组迁移

由于 file ID 含 group 和物理路由信息，跨组迁移通常是：

```text
read old file -> upload to target group -> get new file ID
-> validate -> atomically update application reference -> grace period -> delete old
```

这不是透明 rebalancing。仓库虽有 `fdfs_rebalance.c`，固定版本源码含“create placeholder tasks”注释，且对移动的对象身份/业务引用不可能在没有业务数据库参与时自动解决。不能把它作为成熟全局再均衡保证。

### 6.4 减容/删除节点

删除 storage 前要确认：

- 同组其他节点拥有完整数据；
- 没有 file ID 只在被删节点有效；
- 所有 tracker 同意目标状态；
- trunk server 已平稳迁移；
- sync backlog 为零并完成 checksum 对账；
- 业务流量已停止路由；
- 操作客户端 IP 满足 V6.17 管理校验。

删除整个 group 还需要完成所有业务引用迁移。FastDFS 不知道哪些 file ID 仍被业务使用。

## 7. 跨机房与读写分离

### 7.1 Storage rw mode

V6.13 相关能力允许在 `storage_ids.conf` 为实例设置：

- `both`：读写；
- `read`：只承担读；
- `write`：只承担当次写候选；
- `none`：不承接 client I/O，但可接收同步，适合灾备副本。

该能力需要 `use_storage_id=true`，修改配置后官方要求按顺序重启所有 tracker，再重启 storage。它能支持同组跨数据中心只读/备份节点，但复制协议仍是异步的。

### 7.2 跨地域风险

- WAN 延迟不在 upload ACK 路径，因此 RPO 等于异步 lag；
- source binlog backlog 可能快速增长，占满 `base_path`；
- 大文件复制与在线下载竞争出口；
- 时间戳路由在时钟偏差下更脆弱；
- 分区期间两地同时 update 同一 appender file 会冲突；
- tracker 状态和 leader 无多数派 fencing；
- 跨地域“同 group”会把组的容量/可用性与最慢成员耦合。

推荐把远端 `rw=none` 作为异步 DR 复制目的地，并禁止双向业务写。更强的灾备可使用独立 FastDFS 集群 + manifest/消息驱动复制，显式记录 generation/checksum 和 RPO。

## 8. Tracker/Storage 网络分区矩阵

| 分区 | 可能行为 | 风险 |
| --- | --- | --- |
| client↔一个 tracker | client 切换其他 tracker | SDK 重试风暴、视图差异 |
| tracker↔tracker | 各自继续服务本地视图 | leader/trunk 状态分歧 |
| storage↔部分 tracker | 状态在 tracker 间不一致 | 不同 client 得到不同路由 |
| source↔peer storage | 本地上传继续，复制 backlog | RPO 扩大、磁盘 binlog 增长 |
| source↔all tracker | 已建立的数据连接可能继续，新的路由/状态异常 | source 被判 offline，其他节点接管 update |
| 两个 storage 双向隔离但都可见 tracker | 两边可能各接收读写候选，视 tracker 状态而定 | mutation 分叉 |
| DR storage↔主站 | 主站继续 ACK，远端 lag | 跨站 RPO 不受 ACK 保护 |

对不可变 upload，分叉主要体现为文件只在某一侧；对 appender/update/delete，则是内容冲突。网络测试应同时包含 existing TCP 半开、单向丢包和 asymmetric partition，而不只是 iptables 双向 drop。

## 9. 备份与灾备

### 9.1 必须备份的层次

1. **业务数据库**：file ID、owner、ACL、业务版本、引用状态；
2. **tracker system files/config**：group/storage/sync 状态，便于恢复控制面；
3. **storage base_path**：sync binlog、mark、stat、trunk metadata；
4. **store paths**：普通文件和 trunk containers；
5. **部署制品**：FastDFS/Nginx 模块源码 SHA、依赖、编译参数、配置；
6. **独立业务 manifest/checksum**：用于恢复后对账。

只 rsync store path 不够：可能丢失业务引用和 trunk/sync 系统状态；只备 tracker 也不包含文件内容。

### 9.2 一致备份难题

没有全局 snapshot barrier 同时冻结业务数据库、所有 storage 文件和 binlog。在线复制/备份会遇到：

- 文件已写但 DB 未发布；
- DB 已引用但远端副本未完成；
- delete 传播中；
- trunk slot 修改中；
- appender 长度持续变化。

推荐用不可变对象 + manifest generation：先完成对象和远端验证，再原子发布 manifest；备份按已发布 generation 捕获，恢复时只承诺该 generation 之前对象。

### 9.3 恢复演练

至少季度执行：

- 丢失单 tracker 从空节点恢复；
- 丢失所有 tracker，由 storage/备份重建路由；
- 丢失单 store path；
- 丢失整个 storage 主机；
- 丢失整个 group，从独立 DR 重建并更新 file ID；
- 丢失业务 DB，使用备份/manifest 恢复 namespace；
- trunk 容器损坏和 sync mark 不一致；
- 恢复后全链路随机 checksum 与业务访问验证。

## 10. 恢复目标

建议把指标拆开：

| 指标 | 示例定义 |
| --- | --- |
| tracker RTO | 一个 tracker 故障后新请求成功率恢复时间 |
| storage failover RTO | source 失效后 file ID 可从健康副本读取的时间 |
| replication RPO | ACK 到至少一个异故障域校验副本完成的时间分布 |
| DR RPO | 主站 ACK 到远端独立集群/副本校验完成的时间 |
| disk recovery RTO | path 进入 recovery 到完整 scrub 通过 |
| group disaster RTO | 新 group 恢复、业务 ID 切换、流量恢复 |
| namespace RPO | 业务数据库/manifest 最后可恢复 generation |

FastDFS 自带 `last_synced_timestamp` 只能近似其中一部分，不能替代 file-level verification 和 DR manifest。

## 11. 结论

FastDFS 对单进程和单节点故障有直接的互备/副本路径，但它把复杂度转移给恢复纪律：tracker 视图是最终收敛、storage 复制依赖历史 binlog、跨组迁移会改变 ID、业务 namespace 在外部数据库。真正的高可用必须同时覆盖数据、路由、业务引用和灾备四个平面。
