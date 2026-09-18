# BeeGFS 一致性与并发语义

## 1. 为什么必须分层讨论

“BeeGFS 提供 POSIX 文件系统接口”说明应用能使用 Linux VFS/syscall，不自动等价于：

- 所有客户端对 metadata/data 的观察都是线性一致；
- `flock`/fcntl/`O_APPEND` 默认在全体客户端生效；
- `write` 或 `close` 返回时数据已到稳定介质；
- primary/secondary 任意故障都不会丢已确认写；
- 跨 metadata 操作具有数据库式分布式事务。

BeeGFS 把性能/一致性选择暴露为客户端缓存、全局锁、append lock、remote fsync、sync-on-close、ACL cache 等配置。
正确的评估方法是分别分析“权威操作顺序、其他客户端何时看见、冲突如何仲裁、故障后能否保留”四件事。

## 2. 语义总表

下表针对 8.4 默认配置；“强/弱”是工程概括，不是官方形式化证明。

| 操作/状态 | 权威协调点 | 默认跨客户端语义 | 主要窗口/代价 | 强化手段 |
|-----------|------------|------------------|---------------|----------|
| 同目录 create/unlink/rename | 单 metadata owner 的对象/name locks | 服务端串行权威变更；客户端 dentry cache 可能短暂滞后 | 默认目录 subentry TTL 1s | 缩短 TTL；8.4 invalidation（实验性） |
| 跨 metadata rename/mkdir | source/destination owners 的 RPC + 补偿 | 正常目标为文件系统语义，不是共识事务 | crash/通信中断后的孤儿、清理或重试窗口 | Buddy mirror、fsck、故障注入 |
| 文件属性 `stat` | metadata；必要时 fan-out storage | 服务端可刷新活跃写文件动态属性 | 客户端 inode/dentry cache；宽条带 fan-out | `tuneRefreshOnGetAttr`/TTL 策略，按 workload 验证 |
| 普通 read-after-write（同 fd/同 client） | 客户端缓存 + storage | 通常可按本客户端顺序观察 | buffered/page cache 交互 | `tuneCoherentBuffers=true`（默认） |
| 不同客户端并发覆盖写 | 各 storage target 的 range I/O | 不提供自动全文件互斥；重叠写是应用竞态 | 网络/target 到达顺序、缓存 | 应用分区写；显式全局锁/协议 |
| `flock`/fcntl range lock | 默认仅本客户端 | **默认不跨客户端互斥** | `tuneUseGlobalFileLocks=false` | 开启全局锁并验证性能 |
| 多客户端 `O_APPEND` | 默认每客户端本地 append lock | **默认不保证全局原子 append** | 两客户端都读取同一 EOF 后覆盖/交错 | `tuneUseGlobalAppendLocks=true` |
| `write` 成功 | storage `pwrite`/buffer | 已接受，不等于 stable media | server/RAID/device cache | 应用调用 `fsync` |
| `close` 成功 | flush 客户端缓存、关闭 sessions | 其他客户端之后较可能看到数据；默认不强制 disk sync | `sysSyncOnClose=false` | 应用 `fsync` 或谨慎启用 sync-on-close |
| `fsync` 成功 | 所有 stripe targets；镜像含 buddy | 默认 `tuneRemoteFSync=true`，调用本地 chunk fsync | 底层设备诚实性；已知 secondary fsync 边界 | PLP/BBU、故障测试、备份 |
| metadata buddy update | primary 本地执行后转发 secondary | 健康时双份；通信失败保留 primary 并标记 resync | 不是 quorum commit | 正确状态机/故障域/备份 |
| storage buddy write | primary 流水复制并等待 secondary | 健康时双份；已知降级可单副本继续 | 切换和状态传播窗口 | 监控、阻止第二故障、及时 resync |

结论：BeeGFS 默认对“独立文件、每个文件单 writer、显式 close/fsync”的 HPC 模式很友好；对共享数据库、并发 append 日志、
多客户端频繁覆盖同一 cache line 的场景，需要配置和应用协议共同保证正确性。

## 3. 命名空间一致性

### 3.1 权威服务端

同一目录的 create/unlink/rename 在单 metadata owner 上通过 directory ID、`(parent,name)`、file ID 等锁串行。
同一个 name 不会被两个独立 metadata shards 同时权威创建，因为目录不拆分。这是目录归属模型的重要一致性收益。

Mirrored metadata operation 还使用 per-client sequence number 保存已完成 response，识别重试/并发重复请求。
它解决 RPC 重发幂等的一部分，但不把所有跨服务操作放进全局日志。

### 3.2 客户端 dentry cache

客户端默认值（`client_module/source/app/config/Config.c:267-275`）：

```text
tuneDirSubentryCacheValidityMS  = 1000
tuneFileSubentryCacheValidityMS = 0
tuneENOENTCacheValidityMS       = 0
sysRemoteInvalEnabled           = false
```

目录 subentry 可缓存约 1 秒，普通文件 subentry 和 negative lookup 默认不长期缓存。这使默认行为较保守，但仍存在场景：

1. client A 已缓存目录项；
2. client B rename/unlink；
3. A 在 TTL 到期/主动 revalidate 前仍可能依据旧 dentry 进入后续流程；
4. 权威操作最终由 metadata 接受或返回 `NOTOWNER/PATHNOTEXISTS` 等错误。

应用不能把“另一个节点刚刚返回 rename success”与“本节点下一条无同步 lookup 必定不经过旧缓存”视为形式化线性化关系。

### 3.3 Rename 的两种原子性

- 同目录 rename 最终调用单 metadata service 的底层 FS rename，并在持有 name/directory locks 时更新表示；正常路径最接近单机原子操作。
- 跨 metadata rename 由源 owner 调度远端 insert、源端 complete、覆盖对象清理/父指针更新等步骤。代码有补偿和幂等处理，
  但没有全局 2PC/WAL；特定清理错误会在 rename 成功后仅记录日志。

8.4 源码还拒绝 directory rename 覆盖已存在的空目录，并留有待实现注释；依赖这一 Linux 行为的应用应将其作为明确兼容项测试。

因此应区分：应用在健康正常路径看到的 rename API 语义，与任意两个 metadata 服务在 crash 时保持事务原子持久性的能力。
后者必须用故障注入和 fsck 验证，不能由 POSIX syscall 名称推导。

### 3.4 Open-unlink

unlink 一个仍打开的文件时，name 立即从用户目录移除，inode 进入 disposal directory，最后 close/session cleanup 后再删 chunks。
其他已持有 handle 的客户端仍可访问对象。它满足典型 open-unlink 使用方式，但：

- 客户端 crash 可让 disposal 占用持续到 session auto-remove；
- metadata 与 chunk 删除不是单一原子事务；
- 同名新文件和旧 open inode 以不同 EntryID 并存；
- 监控必须计入 disposal/orphan 容量。

## 4. 文件属性可见性

### 4.1 Metadata 属性缓存

客户端 VFS inode、dentry 和 attribute cache 可以让 `stat` 不总是发 RPC。目录 entry TTL、file entry TTL、page-cache validity、
`tuneRefreshOnGetAttr` 等共同影响可见性。默认 file subentry TTL 为 0 并不表示所有 inode attributes 都绝不缓存；
Linux VFS 和 BeeGFS 各层必须结合具体调用路径理解。

若应用依赖“另一个客户端每次写后，本客户端轮询 `stat` 立即精确看到 size/mtime”，应把该模式独立纳入验收，而非引用默认值推理。

### 4.2 服务端动态属性刷新

Metadata 发现文件仍有 writer session 或 dynamic attrs outdated 时，会查询 storage targets，并按 per-target storage version
拒绝旧结果，然后重建 size/mtime。服务端因此能在不逐写更新 inode 的前提下获取较新事实。

这提供的是“请求真正到达 metadata 后的刷新机制”，不能主动消除另一个客户端的 cache。此外，一个 target 慢/离线会让 stat
延迟或失败，宽条带让准确属性查询 fan-out 更大。

### 4.3 8.4 长周期 metadata cache invalidation

8.4 引入实验性、默认关闭的 remote invalidation，目标是允许比 1 秒 TTL 更长的 cache 同时降低陈旧窗口。
官方 [Client Metadata Caching](https://doc.beegfs.io/latest/advanced_topics/client_meta_caching.html) 描述：

1. Metadata server 的 `InvalWatch` 在内存跟踪哪些客户端 watch 哪些 inode；
2. 每客户端/per metadata server 的队列累积 invalidations；
3. 客户端 `InvalReader` 长轮询/拉取并失效 inode cache；
4. 服务端可按毫秒量级 batch，降低每次 mutation 都同步推送的成本；
5. 队列 overflow/连接故障会触发更粗粒度失效和重新同步；反复错误可回退，直到 remount。

容量默认值值得重视：服务端最多约 5000 万 watch entries，按约 128 B 估算约 6 GiB；每客户端 invalidation queue
默认约 4 MiB。总内存不仅与 inode 热集有关，还与“客户端 × 被 watch inode”组合有关。

官方明确记录一个窄竞态：客户端 concurrent refresh 与 invalidation 交错时可能丢失某次 invalidation，陈旧持续时间没有严格上界；
negative dentry/ENOENT 仍主要依赖 TTL。故该功能不能作为分布式锁或数据库 cache-coherence 的替代品。

## 5. 数据可见性

### 5.1 同一客户端

同一 file descriptor 的顺序 syscall 受进程/内核执行顺序和本客户端缓存保护。默认 `tuneCoherentBuffers=true` 会在普通 I/O 与
page cache 混用时 flush/invalidate，减少延迟回写覆盖新数据。

源码承认在没有全局锁、发生 racy access 时无法总保持所有 cache coherent。因此同一主机多个进程若绕过共同应用锁、混用 mmap
和 write，也不能把该开关当作严格序列化。

### 5.2 不同客户端、非重叠 range

BeeGFS 的典型高性能模式是每个客户端写不同文件或同一文件的不重叠 range。条带映射把 range 送到各 targets，彼此不需 metadata
锁；应用用 MPI-IO/任务分片约定所有权。此时能获得最高并行度，且冲突语义简单。

但文件 size/mtime 汇总、读方 cache invalidation和“完成屏障”仍需应用同步。常见安全阶段切换是：所有 writers flush/close，
MPI barrier/作业调度 barrier 后 readers 再 open/read；必要时显式 `fsync`。

### 5.3 不同客户端、重叠 range

若两个客户端同时写同一 logical range，请求可能被拆到同一或多个 targets，最终内容取决于到达顺序和本地 write 粒度；
不存在默认全文件分布式写锁。大 write 又会拆成多个 messages，不能推断整次 syscall 在远端是不可分割事务。

应用必须使用：

- 不重叠 range ownership；或
- 启用/使用全局 advisory lock；或
- 外部协调服务/租约；或
- 上层 copy-on-write + atomic rename 发布完整结果。

不要在共享数据库文件、WAL 或并发更新索引上假定本地 ext4 的 cache/locking 语义原样跨网络成立。

### 5.4 Read-after-write / close-to-open

Writer 的 buffered data 在 flush/close 时被送往 storage；随后 reader 真正向 storage 发起 read 通常能看到最新内容。
但 reader 若已有 page/buffer cache、inode size 或 dentry cache，仍可能先使用缓存；`sysSyncOnClose=false` 又说明 close 不等价于 stable media。

所以可把 BeeGFS 常用编程模型概括为“应用同步下的 close-to-open 友好”，而非无条件的全局 read-after-write linearizability。

## 6. Advisory Lock

### 6.1 默认本地锁

`tuneUseGlobalFileLocks=false`。`FhgfsOpsFile.c:693-793` 在该模式下让 `flock` 只通过 Linux 本地锁机制协调同一客户端；
fcntl range locks 同样不会默认送到 metadata。另一个挂载节点不会感知这把锁。

这是高风险默认值，因为很多应用只检查 `flock()` 是否成功，并不知道底层文件系统把范围缩小到了单客户端。

### 6.2 全局锁模式

开启后，客户端向 metadata 请求 distributed advisory lock，并在 lock/unlock 周围刷新缓存。代价包括：

- metadata RPC 和锁状态；
- contended lock 队列与失败恢复；
- cache flush/invalidate；
- metadata owner 故障/切换时的 session 重建；
- 大量细粒度 range locks 的内存与调度开销。

全局模式仍是 advisory：不使用锁的进程可以直接读写。应用准入需要确认所有参与者遵守同一协议。

### 6.3 `F_GETLK`

源码注释指出远端 PID 在本地命名空间中容易混淆，`F_GETLK` 等查询存在本地/远程可见性差异。依赖精确锁 owner/PID 诊断的应用
应专门测试，不能只测 lock acquisition。

## 7. `O_APPEND`

### 7.1 默认路径

`tuneUseGlobalAppendLocks=false`。`FhgfsOpsFile.c:1087-1199` 的本地 append 路径：

1. 获取本客户端 inode append lock；
2. flush 本地相关 cache；
3. remote stat 获取 EOF；
4. 以该 offset 发 write；
5. 更新本客户端 file position/size。

两个客户端可同时读到相同 EOF，随后对相同/相邻 range 写入。因此默认配置不能承诺多客户端 append records 的全局原子性。

### 7.2 全局 append lock

开启 `tuneUseGlobalAppendLocks=true` 后，客户端使用 metadata 协调的 append lock，并以特殊 offset 让远端路径参与 EOF 分配。
它改善多客户端 append 正确性，但增加每次 append 的 metadata 串行化，日志型小 append 吞吐可能急剧下降。

专业建议：

- 不用共享 append 文件作为高并发消息队列；
- 优先每 writer 独立文件，阶段结束后 merge/manifest 发布；
- 必须共享时启用全局 append lock，并验证 record 大小超过 message/chunk boundary 时的原子范围；
- 以 crash 后日志 parser 实际可恢复性作为验收，不只看 syscall 返回。

## 8. `mmap`

`native` cache/mmap 依赖 Linux page cache。单客户端内常规 page fault/writeback 能工作，但远端客户端修改不会像本机 coherent shared memory
那样天然使所有已映射页面即时失效。Remote metadata invalidation 也主要解决 inode metadata，不是分布式 page invalidation 总线。

适用模式：只读模型/数据集映射、单 writer 阶段后 barrier 再只读。谨慎模式：多个节点同时修改同一 mmap 区域并期待 cache-line coherence。

## 9. Durability 与一致性不是同一维度

### 9.1 返回点

| API | 典型返回前完成 | 不应默认假设 |
|-----|----------------|--------------|
| `write` | 客户端/服务端路径接受并写入本地 FS/page cache；健康镜像确认副本请求 | 掉电可恢复、metadata size 已永久更新 |
| `flush` | 客户端 buffer/page dirty data 已送远端 | storage disk 已 `fsync` |
| `close` | flush + session close/动态属性处理 | 因默认 `sysSyncOnClose=false` 而 stable media |
| `fsync` | 默认请求所有 chunks 执行远端 fsync，镜像含 buddy | 底层设备绝不谎报、全局 metadata/data 原子事务 |

### 9.2 Metadata/data 原子持久性

一次文件创建+写入跨 metadata 和 storage targets；每个本地 FS 有自己的 journal，Buddy members 又有各自设备。
系统没有一个覆盖所有参与者的 commit record。Crash 后可能出现 metadata 引用缺 chunk、孤儿 chunk、动态 size 落后等状态，
靠请求幂等、session cleanup、resync 和 fsck 收敛。

这不意味着每次 crash 都会损坏文件，而是 durability contract 不能表述成数据库事务。重要数据仍需备份/版本化和恢复演练。

## 10. 镜像一致性

### 10.1 Metadata Buddy

正常 mutation：primary 本地执行 → 转发 secondary → 等待/处理 response → 返回客户端。
若 secondary 通信失败或返回与 primary 不同，`MirroredMessage.h:311-368` 标记 `Needs Resync`；因为 primary 本地操作已成功且
部分操作不可安全回滚，仍返回原操作结果。

这是“同步复制正常路径 + 降级状态机”，不是“两个副本都提交才永远成功”的严格规则。

### 10.2 Storage Buddy

正常 write 把 buffer 同时推进 secondary 和本地，最终等待 secondary response。已知 secondary offline 时允许单 primary 继续。
官方 [Mirroring](https://doc.beegfs.io/latest/advanced_topics/mirroring.html) 记录两个关键 caveats：

- 手工把活跃 target 从 `GOOD` 改为 `NEEDS_RESYNC` 的状态传播可能需要数十秒，期间切换/访问可能读旧数据或丢写；
- secondary 上的 fsync disk error 可能晚到下一操作才被识别，若此前发生 failover，错误旧 secondary 成为新 primary 后反向 resync，可能丢数据。

因此 Buddy Mirror 降低常见单节点中断影响，但不能替代备份、checksum 或 quorum。

## 11. 网络分区与 split brain

BeeGFS 依赖 management 所在分区形成唯一可继续服务的系统视图。官方 split-brain 说明：只有包含 management service 的分区保持在线；
被隔离分区中的服务拒绝/停滞访问，持续过久后产生 I/O error，以避免两侧同时写同一文件后无法合并。

这是合理的 fencing 倾向，但前提是 management 自身只能在一个位置运行且数据库不会被两个实例同时以分叉状态启动。
若用 Pacemaker/shared LUN 等外部 HA，STONITH/lease/fencing 是正确性条件，不只是可用性配置。

## 12. 应用准入矩阵

| 工作负载 | 默认配置评价 | 建议 |
|----------|--------------|------|
| 每任务独立 checkpoint 文件 | 良好 | close 前 fsync（若需 RPO=0），完成后 atomic rename/manifest |
| 多节点只读训练集 | 良好 | 写入阶段结束后 barrier；选择 native/buffered 并实测 cache |
| MPI-IO 不重叠 range | 良好 | 明确 collective sync/close，验证 stripe 参数 |
| 多客户端覆盖同一 range | 高风险 | 应用 range ownership 或全局锁 |
| 多客户端 append 单日志 | 默认不安全 | 全局 append lock，或每 writer 独立日志 |
| SQLite/嵌入式 DB 共享文件 | 高风险 | 核验锁、mmap、fsync、rename、故障恢复；通常不建议 |
| 软件构建树/大量小文件 | 可用但需压测 | 多目录分散、metadata NVMe、少条带、关注 inode/p99 |
| 只凭轮询 stat 做协调 | 风险 | 使用显式 barrier/通知；调 TTL 并验收 |
| 跨节点共享 mmap 写 | 不适合默认路径 | 改用应用级分区/消息/数据库 |

## 13. 配置评审清单

上线前必须把以下值纳入版本控制和变更评审：

- `tuneFileCacheType`、buffer/page cache validity；
- dir/file/ENOENT metadata TTL；
- `sysRemoteInvalEnabled` 及服务端 watch/queue 容量；
- `tuneCoherentBuffers`；
- `tuneUseGlobalFileLocks`、`tuneUseGlobalAppendLocks`；
- `tuneRemoteFSync`、`sysSyncOnClose`、session check/early close；
- target-state refresh/offline timeout；
- xattr/POSIX ACL/NFSv4 ACL revalidation；
- 应用是否使用 mmap、direct I/O、MPI-IO、shared append。

任何一致性增强都可能降低性能；任何性能调优都可能扩大陈旧/丢失窗口。应以应用 invariant 和故障测试决定，而非复制通用模板。

## 14. 设计启示

1. 在客户端/SDK API 文档中把 **visibility、ordering、atomicity、durability、failure recovery** 分成五个契约，不用“强一致”一词代替全部。
2. 全局锁/append 若不是产品目标，应明确返回不支持或提供独立原子 append API，避免 BeeGFS 式“syscall 成功但默认仅本地”的惊讶。
3. 即使元数据分片使用 Raft 等共识协议提供线性化基础，跨分片操作仍需定义 transaction/intent/compensation 和 fsck，不应假设共识协议自动解决跨组原子性。
4. 数据服务写 ACK、replica ACK、EC commit、volume fsync 和 device flush 应有可观测 commit stage，用户可选择 durability level。
5. 缓存 invalidation 若引入，必须有 epoch/overflow 后全量失效和有界 staleness；不要发布带已知 lost-invalidation race 的“强一致 cache”。
6. 为异步 GC/compaction 涉及的数据位置增加 generation/version，与 BeeGFS storage version 拒绝乱序动态属性的思路一致。

## 15. 必做一致性测试

- 两客户端 rename/unlink/lookup 循环，覆盖所有 TTL/invalidation 模式；
- 多客户端重叠 4 KiB/1 MiB 写，记录 torn/interleaved 结果；
- 100 个客户端 `O_APPEND` 固定 checksum records，分别测试全局 append lock 开关；
- `flock`/fcntl lock acquisition、blocking、owner crash、metadata failover；
- mmap reader + remote writer，测可见时间和失效；
- write/close/fsync 每个阶段 kill client/storage/secondary/metadata；
- metadata primary 本地完成后切断 buddy ACK；
- 手工 `GOOD -> NEEDS_RESYNC` 与立即 failover，复现官方 caveat；
- 慢/离线一个 stripe target 时 stat、close、fsync 的返回与延迟。

只有应用 invariant 在这些测试中成立，才可把对应配置组合视为生产一致性契约。
