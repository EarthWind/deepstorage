# FastDFS 系统定位与总体架构

## 1. 产品定位

FastDFS 官方 README 将其描述为面向文件的轻量对象存储/分布式文件系统，主要解决文件存储、同步、访问、容量和负载均衡。这里的“文件系统”不能按 POSIX 共享文件系统理解：核心 API 是 upload/download/delete/set-metadata，返回值是 file ID，没有挂载 namespace、目录 inode、文件锁、用户/组权限、原子 rename 目录事务等通用语义。官方也明确把数据库、Kubernetes 和虚拟机等通用文件系统场景导向 FastCFS。

最准确的工程归类是：

- 文件内容由 storage 的本地文件系统保存；
- 应用以 opaque-looking file ID，而非路径或对象 bucket/key 访问；
- tracker 只维护组和节点级状态，不维护每个文件的权威目录；
- group 作为静态容量分片，组内做异步完整副本；
- 普通数据传输直接发生在 client 与 storage 之间；
- HTTP 下载是配套 Nginx 模块，不是核心协议中的 S3/HTTP 对象 API。

这使 FastDFS 比完整分布式文件系统更轻，也使 namespace、租户、事务、版本、生命周期和引用完整性落到应用层。

## 2. 组件职责

### 2.1 Tracker

tracker 的主要职责是：

- 接受 storage 注册、heartbeat、容量、统计、同步时间戳和状态报告；
- 维护 group、storage、读写模式、可用性和剩余容量视图；
- 按策略为上传选择 group、storage 和 store path；
- 解码文件名中的源 storage/时间信息，为读取、更新和删除选择节点；
- 协调 trunk server、storage 加入与同步源等控制动作；
- 给监控工具和 Prometheus exporter 提供集群状态。

tracker 不保存逐文件目录，也不代理正常文件内容。其资源消耗通常较低，官方建议常见集群部署两个 tracker 互备。client 配置多个 tracker 后，可以尝试连接可用实例。

### 2.2 Storage

storage 承担数据与复制：

- 在一个或多个 store path 中创建两级子目录和本地文件；
- 接收 upload/download/delete、metadata、append/modify/truncate 等协议；
- 为上传内容计算 CRC32，生成逻辑文件名；
- 写入本地同步 binlog；
- 运行到同组其他 storage 的同步线程，每个目标维护独立游标；
- 上报心跳、容量、I/O 统计、同步进度和状态；
- 可选运行 trunk slot 分配/容器文件逻辑；
- 可选通过恢复流程从同组幸存节点重建单个 store path。

每个 storage 实例属于一个 group。V6.16 起支持同一主机同组多个 storage 使用不同端口，但官方强调这主要用于开发测试，生产不应把同一故障域内多个进程误当作独立副本。

### 2.3 Client

官方 C client 的典型工作流分两步：

1. 连接 tracker，请求 upload、fetch 或 update 路由；
2. 连接 tracker 返回的 storage 地址，发送或接收文件内容。

客户端连接 tracker 失败可切换到其他配置实例；具体语言绑定的重试、连接池、超时和幂等语义不应从 C client 自动外推。应用必须保存返回的 file ID，并在请求超时时处理“不知道服务端是否已经成功”的不确定结果。

### 2.4 Nginx 下载模块

官方生产建议使用 `fastdfs-nginx-module` 处理 HTTP 下载。它编译进 Nginx，读取与 storage 一致的 store path/group 配置：

- 文件在本机时直接读取普通文件或 trunk slot；
- 本机缺失时可按 `response_mode=proxy` 从其他 storage 代理内容；
- 也可 `redirect` 到原 storage；
- 支持 Range/FLV 等下载处理；
- 可执行 FastDFS HTTP 防盗链 token 校验。

外部 HTTPS 可以由 Nginx 终止，但这不等于 storage/tracker 的自定义 TCP 协议具有 TLS。模块的 storage 间 HTTP proxy 也必须纳入东西向网络安全设计。

## 3. Group：分片与保护边界

### 3.1 组间关系

每个 group 是独立容量池：

- 上传时 tracker 选择一个 group；
- file ID 首段永久记录 group name；
- 其他 group 不保存该文件；
- 添加 group 只吸收未来写入；
- 删除/迁移 group 必须在应用或专用迁移流程中重写 file ID。

因此“多个 group”本质上是静态 shard，而不是一份文件的跨组冗余。一个 group 全部副本失效，其他 group 不能恢复它的数据。

### 3.2 组内关系

同组 storage 的目标状态是拥有相同文件集合。文件首先落到一个源 storage，再通过同步 binlog 复制到其他成员。若 group 有 N 台独立 storage，原始容量开销约 N 倍；不存在数据/校验片分布或 EC 重建。

同组容量不是节点容量之和。由于每个文件最终完整复制到所有节点，组的可用逻辑容量受最小 storage、最小 store path 自由空间和预留阈值约束。tracker 计算 group free space 时关注可写成员中的最小值，这也解释了官方为何强烈建议同组软硬件尤其磁盘容量一致。

### 3.3 编译期上限

V6.17 固定源码在 `tracker_types.h` 中定义：

| 项目 | 上限 |
| --- | ---: |
| group 名长度 | 16 字节 |
| group 数量 | 512 |
| 单 group storage 数量 | 32 |
| tracker 数量 | 16 |
| 单 storage store path 数量 | 协议 join 校验 1—256 |

这些上限进入静态数组和协议缓冲区。它们表示可表达的最大值，不是已经证明可在极限值下稳定运行的推荐规模。容量规划应留出运维和升级余量。

## 4. 上传选择策略

tracker 的核心选择项包括：

| 配置 | 取值 | 含义 |
| --- | --- | --- |
| `store_lookup` | 0 | group round-robin |
|  | 1 | 固定 `store_group` |
|  | 2 | 选择最大剩余空间 group；V6.17 样例为此值 |
| `store_server` | 0 | 同组上传 storage round-robin；样例值 |
|  | 1 | 按 IP/ID 排序第一台 |
|  | 2 | 按上传优先级选择 |
| `store_path` | 0 | store path round-robin；样例值 |
|  | 2 | 选择最大剩余空间 path |
| `download_server` | 0 | 可读节点 round-robin；样例值 |
|  | 1 | 源 storage 优先 |
| `reserved_storage_space` | 容量或比例 | group/path 到达预留阈值时停止上传；样例为 20% |

使用 trunk 时 tracker 会把 round-robin 的 `store_server=0` 强制改成按 IP 第一台，以建立稳定的 trunk 协调节点/写入关系。这个行为表明 trunk 会收缩写入调度自由度。

负载均衡主要依据 free space、节点状态和轮询索引，不是基于单文件热度、磁盘时延、队列深度、机架故障域或全局最优 placement。上层仍需做热点隔离和容量分组。

## 5. 文件 ID 与无元数据路由

### 5.1 组成

典型 file ID：

```text
group1/M00/00/00/<27-char-base64><fixed-extension-field>
```

分解如下：

```text
group1 / M00 / HH / LL / encoded-name + ext
  |       |     |    |          |
 group   path  two-level dir    source/time/size/crc32
```

- `group1`：复制/容量 shard；
- `M00`：store path index 的十六进制表示；
- `HH/LL`：两级子目录，每级数量由 `subdir_count_per_path` 决定；
- 27 字符 base64：20 字节二进制字段；
- 固定扩展字段：扩展名最长 6 字节，无扩展时用随机数字填充。

### 5.2 20 字节编码内容

固定源码生成逻辑为：

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 4 | 源 storage 的 IPv4/数值 server ID |
| 4 | 4 | 上传时间戳 |
| 8 | 8 | 带随机高位和 appender/trunk 标志的文件大小 |
| 16 | 4 | 内容 CRC32 |

它让 tracker 能从文件名恢复源节点和文件时间，进行无逐文件索引的下载/更新路由。好处是 metadata plane 不随文件数一比一扩容；代价是 placement 写进稳定 ID，源节点/组迁移会影响身份和兼容性。

文件大小的高位和扩展字段使用 C `rand()` 混淆，上传文件名碰撞再靠 storage 内部检查规避。这不是密码学不可预测 ID。CRC32 适合偶发损坏检查和命名，不提供抗篡改认证。

### 5.3 应用数据库仍是元数据系统

FastDFS 没有替应用保存以下关系：

- 业务对象 → file ID；
- owner/tenant/ACL；
- MIME、业务版本、保留期限；
- 引用计数和删除状态；
- 多文件事务/manifest；
- 迁移前后 ID 映射。

应用数据库事实上是权威 namespace。FastDFS metadata API 只是与文件相邻的 key-value sidecar，不足以替代可查询、可事务的业务数据库。

## 6. Tracker 集群的真实语义

### 6.1 状态来源

每个 tracker 从 storage 周期报告中构建 group/storage 状态，并把 group、storage、同步时间戳等保存为本地系统文件。新 tracker 可从其他 tracker/存量 storage 获得视图，但这不是一个逐请求复制、带全局 log index 的共识数据库。

storage 状态枚举包括：

```text
INIT -> WAIT_SYNC -> SYNCING -> OFFLINE/ONLINE -> ACTIVE
                    RECOVERY
IP_CHANGED / DELETED / NONE
```

`ACTIVE` 才表示正常服务；`ONLINE` 和 `OFFLINE` 在同步完成、心跳和 tracker 决策中有专门含义，不应简单映射为 TCP 可达/不可达。

### 6.2 Leader 的范围

tracker relationship 代码会收集可达 tracker 的运行状态，排序因素包括：

- 是否已是 leader；
- 累计运行时间；
- 距离上次重启的间隔；
- IP 和端口。

最高排序节点成为候选，随后向其他 tracker 通知/提交。代码没有 quorum term、majority log commit、lease fencing 或持久化选票。V6.17 的 storage→tracker `NOTIFY_RESELECT_LEADER` 用于发现/处理多个 tracker 都认为自己是 leader 的情况。

因此正确表述是：tracker 多实例提供路由可用性和最终状态汇聚，leader 协调 trunk 等操作；不能表述为“tracker 是强一致无单点集群”。

### 6.3 网络分区影响

网络分区时可预期的工程风险：

- tracker 对 active/offline、free space、last synced time 的视图不同；
- client 从不同 tracker 得到不同 storage 路由；
- trunk server/leader 信息可能暂时不一致；
- 分区双方仍能与各自 storage 通信时，可能同时接受控制动作；
- 文件数据不会因为 tracker 分区立即丢失，但新写位置、可读性和管理操作会受影响。

生产网络应确保 storage 与所有 tracker 的连通性高度一致，并把 tracker 分区测试作为上线门槛，而不是只做进程 kill。

## 7. 本地目录与存储线程

每个 store path 下预创建两级目录。V6.17 样例 `subdir_count_per_path=256`，即每 path 65,536 个目录；官方建议启用 trunk 且小文件极多时可降到 32，即 1,024 个目录。该值可增大但不能安全调小，因为已有文件路径取决于它。

storage 网络线程负责协议和任务调度，本地磁盘 I/O 交给按 store path 分配的 DIO reader/writer 队列。样例配置为：

- `disk_rw_separated=true`；
- 每 path 2 个 read thread；
- 每 path 1 个 write thread；
- `work_threads=4` 处理网络 I/O；
- `buff_size=256 KiB`。

`use_io_uring` 在官方部署说明中明确针对网络 I/O，相比 epoll 略有提升，并要求内核 >= 6.2 和依赖编译支持；它不是本地数据文件的 io_uring/direct-I/O 引擎。磁盘性能仍由普通文件 I/O、page cache、DIO 队列和底层文件系统决定。

## 8. 设计收益与代价

### 收益

- 不维护逐文件分布式 namespace，控制面规模与文件数弱相关；
- client→storage 直达，tracker 不按数据吞吐扩容；
- 普通文件就是本地文件，调试和恢复路径直观；
- group 提供粗粒度扩容和故障隔离；
- file ID 自描述，路由无需全局 object index；
- C 实现和简单协议适合低开销内网服务。

### 代价

- file ID 固化 placement，在线跨组迁移/再均衡困难；
- group 保护域静态，容量碎片和冷热不均难自动消除；
- 完整副本成本高，没有 EC；
- 异步复制和非共识控制面降低一致性/故障边界；
- 业务 namespace、权限、事务和生命周期需要另建系统；
- 本地文件数量与 inode 压力直到 trunk 才被缓解，而 trunk 又引入中心协调；
- 无统一强校验索引，完整 scrub/反向引用对账需要外部清单。

## 9. 本章判断

FastDFS 不是“小型 CephFS”，也不是完整 S3。它是一套把内容存储做窄、把 namespace 交给应用、把 placement 编入 ID、用最终一致完整副本换取实现简单的文件对象服务。若业务正好接受这些约束，架构非常直接；若需求依赖强控制面、动态 placement 或多租户对象语义，继续叠加网关和脚本很快会超过采用更合适系统的成本。
