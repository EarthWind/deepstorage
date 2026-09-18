# SeaweedFS 系统定位与总体架构

## 1. 技术总结

SeaweedFS 用“少量大 volume 容器承载大量小 needle”的方式，避免把每个对象都映射成独立本地文件。Master 只需要知道 volume 在哪些 Volume Server 上、是否可写、属于什么 collection/replication/TTL/disk type；客户端拿到 FID 后直接访问 Volume Server。可选 Filer 把用户路径映射成一个或多个 chunk FID，S3 Gateway、FUSE、WebDAV、SFTP 等都建立在 Filer 之上。

这种架构把传统文件系统的一个“大元数据服务”拆成两层：

- **粗粒度控制面**：Master 管 volume，不管文件；
- **可选命名空间面**：Filer Store 管路径、属性、chunk 清单，不管 chunk 字节；
- **数据面**：Volume Server 管 needle、索引、复制、Vacuum、EC 和 tier。

它的收益是 Master 状态小、数据路径短、小文件元数据密度高；其复杂性来自三层状态的组合，而不是来自单一共识元数据系统。

## 2. 组件职责

| 组件 | 持久/主要状态 | 是否在数据字节路径 | 扩展方式 | 主要故障影响 |
| --- | --- | --- | --- | --- |
| Master | Raft 中的 max volume id、topology id 等；运行期 volume topology | 否 | 1 或通常 3 个 Raft peer | 暂停 assign/拓扑变更；已知位置的读可继续 |
| Volume Server | `.dat`、`.idx`/`.ldb`、`.vif`、EC shard/journal/checksum | 是 | 增加节点、磁盘、volume slots | 影响所持 volume/shard 的读写 |
| Filer | cache、元数据日志 buffer、owner/lock 内存状态 | 通常是代理/协调者，chunk 可直连 Volume | 多实例 | 路径/S3/mount 操作受影响；FID 直读可独立 |
| Filer Store | path、attr、chunk list、配置、kv/checkpoint | 否 | 取决于数据库 | namespace 的核心一致性和 HA 边界 |
| S3 Gateway | IAM/cache/routing 等运行期状态 | 协调或转发 | 多实例 | S3 endpoint 局部不可用 |
| Admin/Worker | plugin 配置、任务与执行状态 | 后台数据搬运时在路径外 | 增加 worker | repair/balance/EC/Vacuum backlog |
| mount | 本地 page/chunk cache、open handle、可选 POSIX lock session | 客户端数据路径 | 客户端横向增加 | 单客户端语义、缓存和锁恢复 |

## 3. 基本对象模型

### 3.1 Volume

Volume 是约几十 GB 的 append-only 容器，默认 Master `volumeSizeLimitMB=30000`。它通常包含：

- `<collection>_<vid>.dat`：needle 记录按时间追加；
- `.idx`：固定长度 needle id、offset、size 记录；
- `.vif`：volume 信息，如只读/远端 tier 元数据；
- 可选 `.ldb`、`.sdx` 等索引形式；
- Vacuum 临时 `.cpd/.cpx/.cpc`；
- EC 的 `.ec00 ... .ec13`、`.ecx`、`.ecj`、`.ecsum`。

Volume 是以下工作的共同粒度：

- replication placement 与完整副本；
- 可写/只读状态；
- balance/move/copy；
- Vacuum；
- cloud tier；
- EC encode/decode/rebuild。

这意味着一个 10 KB needle 的后台恢复可能要搬一个接近 30 GB 的 volume。SeaweedFS 以较低在线元数据开销换取粗粒度维护。

### 3.2 Needle

4.41 的 needle 结构包含：

- 32-bit cookie；
- 64-bit needle id；
- size/data size/data；
- flags、可选 name/MIME/pairs/TTL/last-modified；
- CRC；
- version 3 append timestamp；
- 8-byte 对齐 padding。

固定索引 entry 为 `NeedleIdSize + OffsetSize + SizeSize`，常见构建下是 `8 + 4 + 4 = 16 bytes`；内存 map 的对象/树/allocator 额外开销使官方运维文档估计约 20 bytes/needle。README 的“40 bytes metadata overhead”是更宽泛的磁盘/系统宣称，不应和索引 entry 长度混为一谈。

### 3.3 FID

外部 FID 把 volume id 和 `needle id + cookie` 编码为短字符串，例如 `3,01637037d6`。最长大约 33 个字符。读取时：

1. 从 FID 得到 volume id；
2. 从 Master 或本地 location cache 得到 volume server；
3. Volume Server 用 needle id 查 offset/size；
4. 读取 needle 并校验 cookie/CRC。

cookie 的注释是“mitigate brute force lookups”。它不能提供用户身份、bucket policy、吊销、审计或传输保密；知道 FID 且能访问未受保护的 Volume HTTP endpoint 仍是风险。

### 3.4 Collection

Collection 是 volume 的逻辑隔离组。不同 collection 不共享 volume 文件；文件 FID 不直接携带 collection，Volume Server 通过本地文件名/volume metadata 管理。

典型用途：

- S3 bucket 映射为独立 collection；
- 不同租户/业务使用不同 replication/TTL/disk type；
- 按 collection 做删除、EC、tier、balance、统计。

风险是 collection 过多会形成大量稀疏 volume。官方 S3 文档指出一个 collection 默认可能一次增长 7 个 volume；大量小 bucket 应把 `volumeGrowthCount` 降低并缩小 volume size，否则 slots 和预留空间会被迅速耗尽。

### 3.5 Filer entry 与 chunk

Filer entry 保存：

- full path / parent+name；
- mode、uid/gid、mtime/ctime/atime、inode、size、TTL；
- xattrs/extended metadata、MD5、MIME；
- 一个或多个 `FileChunk`：FID、文件 offset、size、mtime、ETag、cipher/SSE metadata；
- 可选 inline `Content`，用于非常小的文件；
- hard link、remote storage、quota 等字段。

大文件由多个 chunk 组成。chunk 列表过大时可折叠为 manifest chunk，因此逻辑文件一次读取可能需要：

```text
path lookup -> entry -> manifest chunk -> data chunk locations -> range reads
```

这和直接 FID 的“一次索引 + 一次数据读”不是同一个成本模型。

## 4. 控制面与数据面

### 4.1 写 Blob API

```text
Client -> Master /dir/assign
       <- fid + target + replicas + short-lived write JWT
Client -> one Volume Server
         local append -> remote replica fan-out
       <- 201/204 or 5xx
```

Master 不接收文件数据，也不记录这个 FID 后来是否真正提交。客户端必须自己保存 FID。

### 4.2 写 Filer/S3

```text
Client -> Filer/S3
          assign chunk FID
          upload one or more chunks -> Volume Server(s)
          build/manifestize chunk list
          write path entry -> Filer Store
          delete superseded/uncommitted chunks as compensation
       <- response
```

数据与元数据是两次提交。这个顺序避免 metadata 先指向不存在的数据，但会产生：

- chunk 成功、metadata 失败：孤儿/未引用 chunk；
- metadata 成功、旧 chunk 删除失败：垃圾空间；
-客户端超时但服务端继续 `context.WithoutCancel`：客户端观察到不确定结果。

### 4.3 读 Filer/S3

```text
Client -> Filer/S3: path/object key
Filer  -> Filer Store/cache: entry + chunks
Filer/client -> location cache/Master: vid -> servers
Filer/client -> Volume Server: chunk range
```

mount 和部分客户端能缓存 volume map，避免每次读都问 Master；不同访问模式还可选择直接访问、public URL 或 Filer proxy。

## 5. Master 轻状态的真实含义

官方生产文档称单 Master 也可工作，因为 Master 负载轻、volume server 重启后会重新上报软状态。这是架构事实，但不意味着生产应忽略控制面 HA：

- Master leader 仍负责 assign、volume growth、topology 视图和管理命令；
- Raft 保证 volume id 不复用、topology id 等少量状态；
- leader 切换后需要等待 volume heartbeat 补齐 topology；
- warm-up 期间未上报的 volume 暂不可写；
- 错误的 peer 变更、两套 Master 使用同一批 volume server 可能导致 split-brain 风险；4.41 增加 topology id 检查，发现冲突会 fatal 防止损坏。

因此“Master 可重建”降低的是持久拓扑数据库成本，不是让控制面 HA、网络隔离和备份变得不重要。

## 6. 存储布局的设计收益

### 6.1 小文件密度

传统本地文件系统每对象需要 inode/dentry、目录树更新、journal 和随机元数据访问。SeaweedFS 把很多 needle 顺序追加到 `.dat`，索引固定紧凑，使：

- 写入以 append 为主；
- lookup 不需要扫描目录；
- 一个 volume 只对应少数本地文件描述符；
- 迁移可复制连续大文件；
- Master 无逐对象状态。

### 6.2 故障域数量

Master 管 volume 数，不管文件数。若每个 volume 30 GB：

```text
volume 数 ≈ 原始数据量 / 平均 volume 有效占用
```

一 PB 数据约数万 volume，而其中可包含数十亿 needle。这是 Master 能保持轻量的根本原因。

### 6.3 顺序后台工作

复制修复、move、tier upload 和 EC encode 可按大文件顺序读写，容易获得磁盘/网络吞吐；代价是恢复放大和完成时间与 volume size 成正比。

## 7. 设计代价

### 7.1 粗粒度恢复

一个副本丢失通常复制整个 volume；一个 EC shard 重建读取整组 shard 数据。volume 越大：

- 索引/FD 数越少；
- 顺序效率越高；
- 单任务恢复时间、临时空间、风险暴露窗口越大。

### 7.2 Garbage 与空间放大

overwrite/delete 不原地覆盖旧 needle。逻辑空间立即下降，物理 `.dat` 不下降，直到 Vacuum。写热点 volume 会积累垃圾，产生：

```text
物理占用 = live data + overwritten versions + tombstones/padding + temporary compaction
```

### 7.3 多层语义

Blob API、Filer HTTP、S3、mount 并非只是不同协议皮肤：

- Blob FID 没有路径事务；
- Filer path 有 Store 语义；
- S3 versioning/Object Lock 依赖额外隐藏 entry 和 owner serialization；
- mount 又加入客户端 cache/open handle/lock。

同一份 chunk 通过不同入口访问时，权限、缓存、可见性和删除规则必须统一设计。

### 7.4 后端数据库外置复杂度

共享 Filer Store 能让 Filer 横向扩展，但会把元数据延迟、事务隔离、备份、容量、热点和 HA 交给 MySQL/Postgres/CockroachDB/YDB/FoundationDB 等后端。SeaweedFS 本身不能消除这些系统的约束。

## 8. 部署形态

### 8.1 `weed mini`

适合本地学习/开发。官方明确不保证其内部数据布局跨版本兼容，不应作为生产编排；未提供 AWS key 时可启动 Allow All 的 S3。

### 8.2 单机 all-in-one

`weed server -filer -s3` 可启动 Master、Volume、Filer、S3。适合开发、边缘或非关键单节点容量，不具备主机故障容忍；Master/Filer/Volume 的端口和资源仍相互竞争。

### 8.3 生产对象存储

- 3 Master；
- 多 Volume Server，每块盘一个进程或同进程多 `-dir`；
- 明确 dc/rack/physical host；
- Admin + Worker 执行后台维护；
- 只暴露经过鉴权的 S3/应用入口。

### 8.4 生产文件/S3

在上述基础上增加：

- 2+ Filer/S3；
- 一个真正 HA 的共享 Filer Store；
- S3 IAM、mTLS/JWT/HTTPS、统一 KEK/KMS；
- Filer metadata log、Store、volume 数据和密钥的联合备份。

### 8.5 嵌入式多 Filer

多个 Filer 各自 LevelDB/RocksDB，通过 metadata log 聚合/重放形成完整副本。适合某些边缘/低成本场景，但官方明确为最终一致；负载均衡需要 sticky/hash，不能当共享 ACID Store 的等价物。

## 9. 默认端口与网络面

| 服务 | HTTP | gRPC | 默认用途 |
| --- | ---: | ---: | --- |
| Master | 9333 | 19333 | assign、topology、管理、心跳 |
| Volume | 8080 | 18080 | needle 数据和 volume 管理 |
| Filer | 8888 | 18888 | 文件 API、元数据 gRPC |
| S3 | 8333 | — | S3 API |
| Admin | 23646 | 33646（通常按 +10000） | UI、plugin/task 协调 |

端口表不是暴露清单。官方 `SECURITY.md` 把 Master、Volume 和 raw Filer API 定义为可信网络内部接口；生产防火墙应默认阻止外部直连。

## 10. 进一步问题

采用前仍需回答：

1. 目标 workload 的平均/分位对象大小、覆盖写比例和 bucket 数量是多少？
2. 是否只提供 S3，还是还允许 FUSE 与 Blob FID 绕过同一权限模型？
3. Filer Store 选择哪个数据库，期望的隔离级别、备份和热点上限是什么？
4. volume size 在目标恢复 RTO 下应设为 1 GB、8 GB 还是 30 GB？
5. 需要何种 ACK durability：进程级、本地断电级还是全副本断电级？
6. 跨机房是 placement 完整副本、异步 `filer.sync`，还是独立备份集群？

## 11. 小结

SeaweedFS 的核心竞争力是 volume packing、轻 Master 和直接数据路径。它不是把复杂性消失，而是把复杂性重新分配到 volume 粗粒度维护、Filer Store、补偿清理和显式后台运维。正确的采用方式是先明确使用哪一层 API、需要哪一级语义，再分别为 Master、Volume 和 Filer Store 设计故障与恢复，而不是只部署一套进程后宣称获得统一强一致文件系统。
