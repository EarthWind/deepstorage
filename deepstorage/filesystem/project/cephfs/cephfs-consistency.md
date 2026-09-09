# CephFS Capabilities 与一致性语义

## 1. 核心判断

CephFS 的多客户端一致性不是靠所有 I/O 经过 MDS，而是靠 **MDS 分发/撤销 Capabilities，客户端在 cap 范围内缓存或修改，MDS 分布式锁防止相互冲突，失联客户端通过 OSD blocklist + map epoch barrier 被 fencing。**

这使 CephFS 的跨客户端 cache coherence 通常强于 NFS close-to-open，但它不是本地文件系统语义的完全复制。工程评估必须分别审查 cache、write atomicity、durability、mmap、snapshot 与 failure fencing。

## 2. Capabilities 模型

caps 按 inode 的若干维度授权，常见 shorthand：

| cap | 作用 | 客户端可做什么 |
|-----|------|----------------|
| `PIN` | inode pin | 保持 inode/session 关联 |
| `AUTH_SHARED/EXCL` | owner/mode 等 auth metadata | 读或独占修改 auth attrs |
| `LINK_SHARED/EXCL` | link count | 读或独占 link state |
| `XATTR_SHARED/EXCL` | xattrs | 读或独占更新 xattrs |
| `FILE_SHARED` (`Fs`) | size/mtime 等 file metadata | 缓存共享 file attrs |
| `FILE_EXCL` (`Fx`) | loner 独占状态 | 单客户端更自由地缓存/更新 attrs |
| `FILE_RD` (`Fr`) | 文件读取 | 直接读 RADOS data objects |
| `FILE_CACHE` (`Fc`) | 文件数据缓存 | 缓存读取页/object data |
| `FILE_WR` (`Fw`) | 文件写入 | 直接写 RADOS data objects |
| `FILE_BUFFER` (`Fb`) | buffered write | 在客户端缓存脏数据后写回 |
| `FILE_WREXTEND` (`Fa`) | 扩展 file size | 在授权范围内扩展并更新 size |
| `FILE_LAZYIO` (`Fl`) | LazyIO | 应用自行维护 coherence，放松正常语义 |

当只有一个客户端访问文件时，MDS 可给它 `Fx/Fc/Fb` 等宽松组合，metadata 和 data 大量命中本地。出现第二个冲突读者/写者时，MDS recall 不兼容 caps，把 lock state 转到共享/混合模式，相关 I/O 变同步或少缓存。

所以“同一文件单写者很快、多个节点共享写突然变慢”不是偶然退化，而是协议从 loner cache 模式切换到协调模式。

## 3. dentry leases 与 metadata cache

MDS 也可以给客户端 dentry lease，使路径查找/negative dentry 在 lease 期内本地命中。目录 mutation、rename 或冲突访问需要撤销/使缓存失效。

客户端 cache 正确性依赖：

- 当前 MDSMap/authority；
- cap/lease sequence；
- MDS 发出的 recall/invalidate；
- 客户端及时 flush dirty data/metadata 并回复；
- session 没有被标 stale/evicted。

它不是只按时间过期的弱 TTL cache，而是服务端可撤销 delegation。

## 4. MDS locks 与 caps 冲突处理

一次 metadata mutation 的逻辑顺序是：

1. 定位 authoritative MDS；
2. auth MDS 确定需要的 inode/dirfrag locks；
3. 若其他 MDS 持有 read locks，执行 inter-MDS lock transition；
4. 若客户端 caps 冲突，发送 recall；
5. 等待客户端 flush dirty state、降级/归还 cap；
6. 执行 mutation 并 journal；
7. 重新授予适配新状态的 caps/leases。

cap recall 是一致性关键路径，也会成为尾延迟来源。客户端卡死、网络单向丢包、内核 bug、海量 caps 或慢 writeback 都可能让操作显示为 slow MDS op。

## 5. 数据缓存与共享写

### 5.1 单客户端/无冲突

MDS 可授予 file cache/buffer caps，读命中 page cache，写先缓存在客户端。size、mtime 等 inode attrs 也可由该客户端延迟回报。

### 5.2 多客户端读写

MDS 通过 caps 冲突矩阵保证不同客户端不会同时保有互斥的缓存权限。读者出现时可能要求 writer flush/降级；另一 writer 出现时通常不再给 `Fc/Fb`，I/O 更直接、更同步。

强 coherence 不等于所有复合 write 原子：对象边界仍是重要物理边界。

### 5.3 LazyIO

LazyIO 明确放松 coherence，让应用控制 propagate/flush。只有知道所有访问者且应用实现了同步协议时才适用。把 LazyIO 当通用性能开关会让应用观察到陈旧/冲突数据，应视为另一套 API 契约。

## 6. write、close 与 fsync

| 操作/事件 | 至少说明什么 | 不保证什么 |
|-----------|--------------|------------|
| buffered `write()` 成功 | 数据已进入客户端写路径/缓存 | 不保证 OSD durable；ENOSPC/EIO 可能延迟出现 |
| `close()` / `fclose()` 成功 | 关闭本地 handle；可能触发部分 flush | 官方明确不保证数据已落盘 |
| `fsync()` 成功 | 相关数据已可靠到达存储，metadata/错误按客户端实现报告 | 不使一个跨多个对象的大 write 变成全有或全无事务 |
| cap recall 完成 | 客户端已按要求 flush/归还对应状态 | 不等于应用执行了跨文件事务 |
| metadata early reply | namespace 结果可见，客户端保留 unsafe request | 当时未必 journal durable |
| metadata safe reply/unsafe cleared | 对应 journal request 已 durable | 后台 backing-store flush/trim 仍可稍后完成，但 replay 可恢复 |

空间耗尽尤其说明异步错误模型：OSD full 可能在 `write()` 返回后才被发现；`fsync()` 是应用确认持久化是否成功的必要边界。现代 Linux（4.17+）会向当时打开的每个 file description 各报告一次 writeback error，并把打开前未报告的错误也交给后续 `fsync`。

## 7. 官方列出的 POSIX 差异

官方 [Differences from POSIX](https://docs.ceph.com/en/tentacle/cephfs/posix/) 给出以下不能忽略的边界：

1. 客户端在一个大 `O_SYNC write()` 中崩溃，写可能只部分应用。
2. 两个 writer 同时写跨 object boundary 的范围，结果可能撕裂；例如 `aa|aa` 与 `bb|bb` 可能得到 `aa|bb`。
3. sparse file 不跟踪真实 allocated extents，`st_blocks` 和 recursive size 会把 holes 算进去，`du` 高估。
4. 同一文件在多主机 shared writable `mmap` 时，一台机器修改不会一致地 invalidates 另一台缓存页。
5. `.snap` 是隐藏虚拟目录，不出现在普通 `readdir`，但占用名字。
6. CephFS 当前不自动维护 `atime`，虽然可通过 `setattr` 设置。

官方自己的相对定位是 `HDFS < NFS < CephFS < XFS/ext4`。这是一种工程概括，不是形式化一致性证明。

## 8. 客户端失联、eviction 与 fencing

客户端持有 `FILE_BUFFER` 时可能有未刷脏数据。若 MDS 直接把相同写权限给别人，旧客户端恢复网络后仍向 OSD 写，会破坏一致性。因此 eviction 分两层：

1. MDS 关闭 client session、回收 caps；
2. 将客户端地址加入 RADOS OSD blocklist，使旧连接不能继续访问 OSD。

仅 blocklist 还不够：新的客户端/MDS 必须看见包含 blocklist entry 的最新 OSDMap 后，才能接触旧客户端可能操作的对象。CephFS 用 **osdmap epoch barrier**：后续 caps 携带最低可接受 OSDMap epoch，客户端必须更新到该 epoch 才能继续。

epoch barrier 也用于 OSD full：客户端可能取消旧 epoch 的在途 ops，其他访问者必须跨过 full flag epoch，防止取消/重试与新写相撞。

### 8.1 默认超时

- MDS session idle/失联自动关闭默认约 300 s；
- failover reconnect 等待默认 45 s；未及时 reconnect 的客户端会被驱逐；
- cap revoke eviction timeout 默认 0，即因单次 cap revoke 不响应自动驱逐默认关闭，可按风险显式配置；
- MDS beacon 每 4 s，MON 默认 15 s 未收到后标 laggy 并可替换。

手工从 blocklist 移除客户端可能造成数据完整性风险；官方建议 unmount 后重新 mount。eviction 还可能丢失该客户端未刷的 buffered data，这是 fencing 正确性与可用性之间不可避免的取舍。

## 9. failover 中的 exactly-once 近似

metadata request 使用 client/session + transaction ID 跟踪：

- early reply 后请求留在 client unsafe list；
- 新 rank replay journal，恢复已 durable 的 request 状态；
- reconnect 时客户端重发 unsafe/旧请求；
- `up:clientreplay` 重放并识别已处理请求，避免普通重试重复 create/rename 等副作用；
- safe reply 后客户端移除 unsafe state。

这是有状态 session replay，不是任意应用 RPC 的通用 exactly-once。客户端 session 被强制关闭、table 损坏或灾难修复 reset journal/session 时，应用仍需处理 `EIO`、重挂载和不确定结果。

## 10. snapshot consistency 不是同步 freeze

CephFS snapshot 创建很快，因为客户端脏数据可在 snapshot 创建后异步 flush。MDS 分发新 SnapRealm/SnapContext，客户端生成 CapSnap；有旧脏数据时先按旧 snapshot context 写回，再允许新写。最终 snapshot 能形成不可变时点视图，但 `mkdir .snap/name` 返回不应被解释成“所有客户端脏页都已同步刷盘、应用事务也已 quiesce”。

需要应用级一致 checkpoint 时，应先停止写入/执行应用 flush+fsync，再创建快照，并验证快照/镜像完成状态。

## 11. 安全权限与一致性权限不是同一概念

“capability”有两层容易混淆：

- **CephX/MDS auth caps**：某 client entity 可访问哪个 FS/path、可读写/快照/设 quota/layout；是安全授权。
- **运行时 inode caps**：MDS 给某个已认证 session 的缓存/读写 delegation；是一致性协议状态。

只有前者不能保证 cache coherence，只有后者也不能阻止未授权访问；生产设计要同时配置。

## 12. 应用设计建议

1. 数据库、checkpoint、manifest 发布必须显式 `fsync` 并检查返回值；不要把 close 当 durable commit。
2. 避免多主机 shared writable `mmap`。
3. 共享 writer 尽量把写区间对齐且不跨 4 MiB 默认 object boundary；更可靠的是应用级单写者/record protocol。
4. 需要原子发布时写临时文件、`fsync(file)`、rename，并根据目录持久语义做额外验证；用真实故障注入验证，不凭本地 FS 经验假定。
5. 监控 cap recall 和 slow clients，把 eviction/data-loss policy 写进业务 SLO。
6. 对 snapshot 前的应用一致性实施 quiesce，而不是只调用 `mkdir .snap`。

## 13. 对 LightStore 的启示

### 值得吸收

- writer/read lease 应包含 owner、generation、expiry、placement epoch 和可撤销状态。
- lease 失效必须与 DataServer fencing 联动；仅在 MetaServer 删 lease 不够。
- 新 owner 获权前必须确认所有 DataServers 跨过 block/fence epoch，类似 OSDMap barrier。
- ACK 明确区分 accepted、replica/EC durable、metadata committed，不让应用猜测。
- 客户端 retry 使用 operation ID，服务端保存有界 dedup/replay 状态。

### 不应照搬

- LightStore 非完整 POSIX，不必实现每 inode 多维 caps/lock state；优先少数清晰 API：immutable put、single-writer append、CAS metadata、atomic publish。
- 不暴露无法跨客户端正确实现的 `flock`/shared `mmap`；明确 `ENOTSUP` 比弱语义更安全。
- 避免把海量客户端的细粒度缓存状态全部 pin 在 MetaServer 内存；可使用短租约、versioned read cache 和服务端无状态 token 降低恢复状态量。
