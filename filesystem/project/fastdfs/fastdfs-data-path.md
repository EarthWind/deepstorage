# FastDFS 数据布局与 I/O 路径

## 1. 客户端路由模型

FastDFS 的主要请求都分为“问 tracker”和“直连 storage”两个阶段：

```text
Client                    Tracker                    Storage
  | query store/fetch/update |                          |
  |------------------------->|                          |
  |  group + server + path   |                          |
  |<-------------------------|                          |
  | upload/download/delete/modify custom TCP            |
  |---------------------------------------------------->|
  | file ID / bytes / status                            |
  |<----------------------------------------------------|
```

tracker 返回地址之后通常不参与当前数据操作。这个模型降低了 tracker 带宽压力，但 client 必须正确处理两段连接的独立超时和重试。

## 2. 普通上传完整路径

### 2.1 Tracker 选择

client 请求一个可写 storage。tracker：

1. 根据 `store_lookup` 选择 group；
2. 过滤没有可写 active storage 或低于预留空间的 group；
3. 根据 `store_server` 选择源 storage；
4. 根据 `store_path` 给出 path index；
5. 返回 group、storage IP/ID、port 和 path index。

当 client 指定 group 时跳过全局 group 选择，但仍受 group 状态、容量和读写模式限制。

### 2.2 Storage 接收

storage 收到文件长度、扩展名和字节流后：

- 在目标 store path 的 DIO writer queue 中打开临时/目标文件；
- 以普通 `write` 将网络 buffer 写入本地文件；
- 流式更新 CRC32，可选计算去重 hash/MD5；
- 生成包含 server ID、时间、大小和 CRC32 的名字；
- 选择二级目录并完成最终文件创建/rename；
- 若为 trunk 文件，先确认 slot 分配；
- 将 source-create 操作写入本地 sync binlog buffer；
- 更新运行统计，构造 `group + logic filename`；
- 向 client 返回成功和 file ID。

关键源码顺序是 `dio_write_file` 完成写并 `close`，调用 upload done callback；callback 完成文件名处理并调用 `storage_binlog_write`，然后才 `sf_nio_notify(...SEND)`。它保证“响应前已在源进程完成本地逻辑和 binlog append”，但没有等待同组 storage。

### 2.3 超时与幂等

如果 client 在最后响应前超时：

- storage 可能尚未写完；
- 也可能已经写完并产生 file ID，只是响应丢失；
- client 若直接重传会生成另一个 file ID；
- FastDFS 没有由应用 request ID 驱动的幂等 Put/CAS。

应用需要在协议外设计：上传事务表、内容 hash、临时业务状态、重试去重和 orphan 清理。不能只靠 client retry 假设“超时必然失败”。

## 3. 文件名与落盘布局

### 3.1 逻辑到物理路径

逻辑路径 `M00/HH/LL/name.ext` 映射为：

```text
<store_path0>/data/HH/LL/name.ext
```

`M00` 表示 store path 0，`M01` 表示 path 1。不同 storage 组内成员必须保持相同 `store_path_count` 和 path index 语义；交换 path 顺序可能让相同 file ID 指向错误磁盘。

`store_path#_readonly=true` 只禁止新文件写入该 path，已有文件仍可读。这不是把底层文件系统 remount 为只读，也不会自动迁移数据。

### 3.2 二级目录选择

storage 可以按轮询分发计数或哈希选择 `HH/LL`。最大每级 256 个目录。大量普通小文件时，即使有 65,536 个子目录，inode、目录项、备份枚举和 fsck 仍可能成为瓶颈；trunk 把多个逻辑文件放入容器，改变的是本地物理文件数量。

### 3.3 扩展名

文件扩展名最长 6 字节。内部为保持固定长度，无扩展或短扩展会用 `rand()` 生成数字填充。这是文件名格式的一部分，不应在应用侧解析为安全随机 nonce 或可靠 MIME 类型。

## 4. 下载路径

### 4.1 Tracker 解码

client 给 tracker group 和 logic filename。tracker 从固定位置解码 20 字节字段，得到源 storage 标识、上传时间和带标志的文件大小，并判断 normal/slave/appender/trunk 类型。

### 4.2 正常文件副本选择

对于 normal file，round-robin 候选 storage 只有满足下列任一条件才会被选：

- 候选就是源 storage；
- 文件时间早于当前时间减 `storage_sync_file_max_delay`；
- 候选的 `last_synced_timestamp` 晚于文件时间；
- 候选进度几乎追到文件时间，且文件已超过 `storage_sync_file_max_time`。

V6.17 样例的最大同步延迟为 86,400 秒，`storage_sync_file_max_time` 代码默认约 300 秒。筛选用于降低刚上传文件被路由到尚未复制节点的概率，但仍是组级时间戳推断：

- 时间戳不等于每个 file ID 的副本提交记录；
- 时钟偏差、进度报告延迟和异常 binlog 可造成误判；
- 到达最大延迟后会放宽，即便特定文件因错误仍缺失；
- 最终还可能 fallback 到当前 store server。

因此读取正常文件可“多数时候分散到副本”，不能推导为读取线性一致或已验证副本存在。

### 4.3 Appender/slave 文件

对 appender、slave 等非 normal file，tracker 更倾向源 storage，因为其变更和派生关系更难用上传时间推断全副本状态。`download_server=source-first` 可让普通文件也优先源节点，换取更强的新写可见性和更低读扩展。

### 4.4 HTTP 路径

Nginx 模块先检查本地普通文件或 trunk header/slot。缺失时：

- `proxy`：模块选择远端 storage，以 HTTP/内部 client 方式流式代理给用户；
- `redirect`：返回 Location，引导客户端到源 storage，并带防循环参数。

proxy 隐藏物理拓扑但增加一次 storage 间传输；redirect 缩短网关路径但暴露节点地址、要求客户端可达并扩大 TLS/认证配置面。生产常在 storage 前另设域名、四层/七层负载均衡和 HTTPS。

## 5. 删除路径

删除操作先向 tracker 查询 update storage：

- 若文件名中的源 storage 仍是 active、writable，则优先返回它；
- 否则选择同组其他可写 storage；
- storage 删除普通文件或清理 trunk slot；
- 写 source-delete binlog；
- 其他 storage 异步执行 delete。

所以删除成功不是“所有副本立即不可读”。短窗口内：

- 直接访问滞后 storage 可能仍返回旧内容；
- CDN、Nginx proxy 或上层缓存可能继续服务；
- 重复 delete 需要接受 ENOENT 等结果；
- 删除后复用同一业务 key 上传新文件会得到新 file ID，上层发布顺序要明确。

严格删除、隐私擦除或 WORM/retention 不能仅依赖 FastDFS delete 返回值。需要全副本确认、缓存失效、磁盘加密密钥销毁或审计工作流。

## 6. Metadata sidecar

FastDFS 支持对 file ID 设置 key-value metadata：

- key 最大 64 字节；
- value 最大 256 字节；
- 支持 overwrite/merge；
- 序列化并排序后写入以 `-m` 为后缀的 sidecar；
- sidecar 创建/更新/删除也通过 binlog 异步同步。

它适合少量文件属性，不适合：

- 按 metadata 索引和查询；
- 多字段事务/条件更新；
- 大量标签；
- tenant ACL 权威状态；
- 与业务数据库的原子提交。

数据文件与 metadata sidecar 是两个本地对象，故障交错下需要考虑其可见时序。上层若把 metadata 当授权依据，应把权威副本放在事务数据库。

## 7. Appender、Modify 与 Truncate

Appender file 支持：

- append：在文件尾增加内容；
- modify：从指定 offset 覆盖；
- truncate：改变长度；
- 后续 metadata 或 delete。

每个操作写带额外 offset/length 参数的 sync binlog。复制端必须按源日志顺序执行。风险包括：

- 同一个 file ID 的多个客户端没有全局版本/CAS；
- 源 storage 故障后 tracker 可把 update 路由到其他 writable 节点；
- 若该节点落后，基于旧内容继续 append/modify 会形成分叉；
- 多源 binlog 到达顺序不是一个共识总序；
- replica 操作有避免循环/重复的特殊规则，增加恢复复杂度。

建议把 FastDFS 主路径约束为 immutable：新版本写新 file ID，再在业务数据库中原子替换指针。若必须使用 appender，应限制单写者、采用外部 lease/version、固定 source-first、记录长度/checksum，并对源故障做专项测试。

## 8. Slave 文件与去重

Slave file 可从 master file 派生带前缀/扩展的关联文件，常用于缩略图。其 ID 仍依赖 master 名称和 source 路由。删除 master 是否级联、应用如何枚举 slave，需要在业务层明确，不能把它当完整对象关系数据库。

可选重复文件检查依赖外部 FastDHT，默认关闭。storage 计算 hash/MD5，保存 signature 到 file ID 的映射并创建 link。采用时要额外评估：

- FastDHT 的可用性和一致性；
- hash 冲突与内容二次验证；
- 引用计数、并发删除和 orphan link；
- trunk 与 link 的组合恢复；
- 旧版本文档和依赖维护状态。

不要把“支持 dedup”理解成核心集群始终做端到端内容寻址。

## 9. 本地 I/O 与内存路径

### 9.1 网络与磁盘线程

storage 使用 network work threads 接收请求，再把磁盘操作分发到每个 store path 的 DIO 线程。读写分离时分别有 reader/writer 队列。优点是慢磁盘不直接阻塞所有网络事件线程；缺点是每 path 的小线程池成为队列和尾延迟控制点。

调优重点：

- 普通 HDD 通常不宜堆太多随机 I/O 线程；
- SSD/NVMe 可以增加线程，但要观测队列深度、CPU 和锁；
- 同步复制读取也会争用磁盘和网卡；
- Nginx 本地读可能绕过 FastDFS DIO 统计，OS page cache 行为很重要；
- `work_threads` 官方不建议超过 16，以免上下文切换增加。

### 9.2 Page cache 与 durable write

数据文件使用普通 buffered I/O。`close` 只释放文件描述符，不保证设备介质已持久。底层 page cache、文件系统 journal、磁盘 write cache 和 PLP 都影响断电结果。FastDFS 的 CRC32 在名字中并不会自动让每次读取都端到端重新校验内容；scrub 必须确认工具实际逐文件读取和比对。

### 9.3 多 store path

官方建议一个物理盘一个 mount point、一个 store path，不做 RAID。这样单盘故障可通过同组副本恢复对应 path，避免 RAID 重建和 FastDFS 复制叠加。代价是：

- 单盘数据保护完全依赖同组 storage；
- path 顺序和 mark 文件必须严格管理；
- 多盘容量不均会产生 path 级碎片；
- 恢复需扫描/回放大量文件，期间读写竞争；
- 不使用 RAID 不代表无需 PLP、SMART、介质巡检和 spare 策略。

## 10. 数据操作语义表

| 操作 | 成功响应前 | 成功后仍异步/外部 | 主要风险 |
| --- | --- | --- | --- |
| upload | 源 storage 写完、close、生成 ID、append sync binlog buffer | binlog fsync、组内复制、外部备份 | 源盘/电源故障窗口、超时重复 |
| download | tracker 选择节点，storage 返回字节 | 无全局 read repair | 滞后副本、内容静默损坏 |
| delete | 一台 writable storage 删除并写 binlog | 其他副本删除、缓存失效 | 短暂旧读、隐私擦除不完整 |
| metadata set | 一台 storage 写 sidecar/binlog | sidecar 复制 | 与主文件/业务 DB 非原子 |
| append/modify | 当前目标应用操作并写 binlog | 操作序列复制 | 多写者、failover 分叉 |
| truncate | 当前目标改变长度并写 binlog | 其他副本按序应用 | 落后副本和操作重排 |

## 11. 设计建议

应用对接 FastDFS 时，优先采用下列模式：

```text
1. Upload immutable bytes
2. Verify size + application checksum
3. Persist file ID in DB transaction
4. Publish business object / manifest
5. Async verify at least one remote replica or DR copy
6. Delete old file only after reference switch and grace period
```

这样可以把不可控的 in-place update 转化为新的不可变对象和数据库指针交换。file ID 仍是物理存储引用，不应直接暴露为长期授权 token；对外 URL 应经应用签名、短期 token 或网关 ACL。
