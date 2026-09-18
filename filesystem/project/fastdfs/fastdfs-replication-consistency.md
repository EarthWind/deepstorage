# FastDFS 复制、持久性与一致性

## 1. 一致性模型总览

FastDFS 组内复制是异步 primary-origin/eventual replication：每次操作在某一台 source storage 上先执行，本地 sync binlog 记录操作，后台线程再把日志和文件内容同步到每个 peer。它不是 primary-backup quorum、chain replication、Raft log 或 multi-Paxos。

对普通不可变文件，合理的外部语义是：

- 单个源 storage 成功创建后返回；
- 源节点上 read-after-write 通常成立；
- tracker 尝试避免把新文件读请求发给落后副本；
- 其他副本最终出现；
- 删除和更新最终传播；
- 没有“W 个副本持久后才返回”的配置语义。

对 appender/modify/truncate，系统还要复制操作序列而非一个不可变值，一致性更弱。应用不能假设多写者 serializability。

## 2. Sync binlog 模型

### 2.1 操作类型

源操作使用大写标志，主要包括：

| 标志 | 含义 |
| --- | --- |
| `C` | create normal file |
| `A` | append appender file |
| `D` | delete |
| `U` | update metadata/相关更新 |
| `M` | modify by offset |
| `T` | truncate |
| `R` | rename/内部重命名 |
| `L` | create link/slave relation |

副本执行后的对应记录使用小写，以区分 source 与 replica，避免操作在成员之间无限转发。初始全量同步对旧 replica 记录有特殊处理，以便新节点补历史，同时跳过会重复应用的某些 append/modify/truncate replica 操作。

binlog 是文本行，基本包含 timestamp、op、logic filename，部分操作带 offset/length 或源文件。它不是包含文件内容的 WAL；真正复制仍需到源 path 读文件/变更内容。因此“binlog 完整”与“源文件完整”缺一不可。

### 2.2 每目标游标

源 storage 为每个目标 storage 建立 reader/mark：

- 当前 binlog index；
- byte offset；
- scan/sync row count；
- 是否需要同步旧数据；
- 同步时间戳；
- 多线程任务状态。

mark 默认按一定行数批量写入（实现中的常用频率为 500 条）。进程崩溃后可能重复扫描一小段日志，复制端操作必须容忍一定重放；复杂 mutation 的幂等性比 create/delete 更难。

### 2.3 多线程同步

V6.15 起支持同步线程范围：

- `sync_min_threads=1`；
- `sync_max_threads=auto` 时为 store path 数量的两倍；
- 无待同步文件时按 `sync_wait_msec` 轮询；
- 每完成一个文件可按 `sync_interval` 限速；
- 可配置每日同步时间窗。

增加线程能缩短 backlog，但同时放大源磁盘随机读、目标写、网络和 inode 操作。它不会改变异步 ACK 语义，也不会形成多副本原子提交。

## 3. 上传 ACK 的精确边界

固定 V6.17.0 源码中，普通上传成功大致如下：

```text
receive chunks
  -> write data file through DIO writer
  -> calculate CRC32
  -> finalize filename / rename / trunk confirmation
  -> close(data_fd)
  -> append "C file" to in-memory sync-binlog buffer
  -> build file ID
  -> send success response

background:
  -> periodically write + fsync sync-binlog buffer
  -> peer sync thread reads log
  -> peer connects with sync key
  -> peer writes its local copy
```

响应不等待：

- 任意 peer 接收日志；
- 任意 peer 写入文件；
- peer 的文件 `fsync`；
- 外部备份/跨集群复制；
- tracker 获得逐文件副本确认（系统没有该结构）。

## 4. 数据文件持久性风险

### 4.1 V6.17.0 观察结果

`storage_dio.c::dio_write_file` 对文件调用普通写函数，完成后 `close`。全仓检索显示 `g_fsync_after_written_bytes` 在 global、配置解析和 dump/validator 中出现，但未在数据写路径使用。V6.17 样例又显式设置：

```ini
fsync_after_written_bytes = 0
```

因此在这个固定 tag 上，不能依据参数名称声称“设置为某个正数即可保证每 N 字节 fsync”。生产采用前应：

1. 对实际构建产物做调用级确认；
2. 在目标文件系统上做掉电测试；
3. 若需要 durable ACK，修复/增加 `fdatasync` 并明确目录项/rename 顺序；
4. 或在协议上等待一个独立故障域副本确认；
5. 让发布版本和故障测试绑定，防止升级回归。

这不是说所有成功文件必然丢失，而是说 ACK 时数据可能只在 kernel page cache/设备易失缓存，持久性取决于后续 writeback、文件系统和硬件。

### 4.2 Binlog 持久性

`storage_binlog_write_ex` 先把文本记录追加到进程内 buffer；只有 buffer 接近满或后台定时函数触发时，才执行：

```text
write(binlog_fd, buffer)
fsync(binlog_fd)
```

V6.17 样例 `sync_binlog_buff_interval=1` 秒，部署文档也建议 1 秒，而内部缺省历史上更长。成功响应可能发生在这次 fsync 之前。因此可能出现：

- 数据文件存在但 create binlog 丢失：peer 永远不知道应复制；
- 文件数据 page cache 与 binlog buffer 同时丢失；
- binlog 已持久但数据或目录项未持久，恢复时 source 读不到内容；
- peer 已复制成功，但 tracker/应用不知道具体副本状态。

只把 binlog 间隔调到 1 秒减少窗口，不将其降为零，也不解决数据文件 fsync。

### 4.3 故障窗口表

| 故障时点 | 可能结果 | 应用观察 |
| --- | --- | --- |
| 文件写完前 storage crash | 上传失败/连接断开，可能有临时文件 | 可重试，但需清理残留 |
| 文件 close 后、binlog append 前 | 本地 orphan，client 通常未获成功 | 重试生成新 ID；旧文件需扫描清理 |
| binlog append 后、响应前 | 文件可能成功但 client 超时未知 | 重试会重复；需幂等事务 |
| 响应后、binlog fsync 前进程/主机断电 | 文件/同步意图均可能丢 | file ID 已发布但不可读 |
| binlog fsync 后、peer 完成前源盘永久损坏 | peer 若未复制则丢失 | 异步复制 RPO 窗口 |
| 一个 peer 已复制后源故障 | 可从 peer 读/恢复 | tracker 视图和新文件路由仍需收敛 |
| 所有同组副本损坏 | 组内无法恢复 | 依赖外部备份/DR |

## 5. 读取一致性

### 5.1 时间戳路由启发式

tracker 不维护 per-file replica bitmap。它用 file ID 的 timestamp 和 storage 上报的 `last_synced_timestamp` 判断候选副本是否“应该”拥有文件。对 normal file，这在健康时能分散读取，同时避开明显落后节点。

其正确性依赖：

- storage 和 tracker 时钟合理同步；
- binlog 操作顺序与 timestamp 单调关系不被严重破坏；
- `last_synced_timestamp` 准确、及时上报；
- 特定文件没有独立同步错误；
- 最大延迟阈值足够覆盖 backlog。

这是优化，不是一致性证明。故障期间出现 404/ENOENT 时，client 或网关可以尝试 tracker 返回的 fetch-all 列表/源 storage，但重试必须有界并记录异常，不能无限掩盖数据缺失。

### 5.2 Read-after-write

可以分层描述：

| 读路径 | 预期 |
| --- | --- |
| 直连刚才的 source storage | 进程存活且文件可见时通常读到 |
| tracker `source-first` | 通常保持 read-after-write，但源失效时降级 |
| tracker round-robin | 对新文件仍有源/同步时间筛选，但不是严格保证 |
| 任意 storage URL | 复制前可能 404 |
| CDN/cache | 受缓存和负缓存 TTL 影响，独立于 FastDFS |

若业务需要“上传成功立即从公共域名读取”，网关应在短期内粘滞 source、对 404 尝试其他副本，并避免缓存新对象的临时 404。

### 5.3 内容校验

文件名携带 upload 时计算的 CRC32，但下载主路径并不天然提供强加密校验或每次端到端验证。CRC32 不能抵抗恶意修改，且 metadata/file name 也可能一起损坏。建议应用另存 SHA-256/BLAKE3，后台 scrub 随机/全量读取并比对，再从健康副本修复。

## 6. 更新、删除和多写者

### 6.1 Update storage 选择

tracker 优先返回 file ID 编码的源 storage；源不可写时选择另一个 writable storage。这个 failover 提升操作可用性，但会允许落后副本成为新 mutation source。

### 6.2 没有全局 version/CAS

FastDFS 协议没有为同一 file ID 暴露类似：

- expected generation；
- compare-and-swap ETag；
- lease/epoch；
- quorum read/write；
- 全局单调 sequence number。

因此两个 client 并发 modify 或源故障后的 append，最终内容依赖操作抵达哪个节点、该节点此前同步进度和后续 binlog 重放顺序。即使单节点内部文件写加锁，集群层仍无全局事务。

### 6.3 最佳使用模式

- normal file 一次写入后不可变；
- 版本更新创建新 file ID；
- 业务数据库用版本/CAS 原子切换引用；
- 旧对象经过 grace period 和引用对账再删；
- append 日志放入专门日志/对象分段系统，而非共享 appender file；
- 必须原地更新时使用外部单写者 lease，并在 failover 前验证副本长度/checksum。

## 7. 副本恢复与反熵边界

FastDFS 的正常同步按 source binlog 推送/拉取操作。它不是定期对所有 file ID 建 Merkle tree 并比较的通用反熵系统。若某次复制因磁盘/协议错误被跳过，而游标推进，后续只看时间进度可能无法自动发现单文件缺失。

仓库有 verify/sync-check/repair 等工具，但必须分别验证：

- 是否枚举完整文件集；
- 是否验证内容还是只验证存在/size；
- 是否支持 trunk slot；
- 是否处理 metadata/link/appender；
- 是否在在线写入时得到一致视图；
- 修复方向是否有版本/源选择保护。

生产需要建立独立 manifest 或业务 ID 清单，按 group/path 做周期 existence + checksum scrub，并把修复动作设计为显式审批和审计流程。

## 8. 一致性级别建议

不要仅写“最终一致”，应按操作定义 SLO：

| 能力 | 建议承诺 |
| --- | --- |
| 普通上传可见性 | source 上 session read-after-write；公共域名 P99 在 X 秒内可读 |
| 副本 RPO | P99/X 秒内至少另一个故障域校验成功，而非只看 binlog delay |
| 删除收敛 | 所有 FastDFS 副本、Nginx/CDN cache 在 X 时间内不可读 |
| 更新语义 | immutable new-ID + DB CAS；禁止 in-place 多写 |
| 内容完整性 | 上传后 SHA-256 验证，后台 scrub 周期和覆盖率 |
| 断电持久性 | 定义 ACK 后允许丢失的最大窗口，并用 power-cut test 验证 |

## 9. PoC 必测故障

1. 在上传返回前后毫秒级 kill storage 进程；
2. 上传返回后立即切断源节点电源/拔除源盘；
3. binlog interval 分别为 1 秒和默认值，测 orphan/缺失；
4. 源与目标之间丢包、断流、重连、重复 replay；
5. 新文件刚返回时轮询所有 storage 直连 URL；
6. tracker 时钟偏差、storage 时钟偏差和 NTP step；
7. backlog 超过 `storage_sync_file_max_delay` 后访问仍缺失的文件；
8. concurrent append/modify/truncate 与 source failover；
9. delete 与 CDN/Nginx negative cache/positive cache；
10. 数据文件存在但 binlog 丢失、binlog 存在但数据文件丢失的注入测试。

## 10. 结论

FastDFS 的复制模型很适合不可变内容和可以接受秒级/更长 RPO 的业务，但“同组两台 storage”本身并不建立 durable quorum。最核心的采用条件，是业务方愿意把成功 ACK、源节点可读、binlog 持久、远端副本完成和外部灾备完成视为五个不同阶段，并为每个阶段定义指标、超时和补偿。
