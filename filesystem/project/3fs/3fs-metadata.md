# 3FS 元数据架构

## 1. 总体模型

3FS 将权威文件元数据全部放在 FoundationDB。Meta 服务无状态，承担协议解析、权限校验和事务编排，任一健康 Meta 都可服务任一目录或 inode。好处是无需自己实现目录分片共识和主从复制；代价是整个 namespace 的一致性、容量规划、升级和灾备都与 FDB 绑定。

```text
Client
  |
  +-- lookup/stat/list ----------> Meta -- read transaction --> FDB
  |
  +-- create/link/unlink/rename -> Meta -- R/W transaction --> FDB
  |
  +-- read/write data -----------> Storage chain
```

## 2. Key 设计

### 2.1 inode

inode 使用 64 位单调 ID。inode key 由固定前缀加 inode 的 little-endian 字节组成。因为 FDB 按字典序切分 key range，little-endian 会把连续数值 ID 的低位变化放在 key 前部，避免所有新增 inode 只压到 key space 尾端。

普通文件 inode 包含：

- inode ID、类型、mode、uid/gid；
- link count、时间戳；
- 文件长度；
- chunk size；
- chain table 范围/标识；
- stripe size、shuffle seed；
- immutable 等标志。

目录 inode 包含父目录和默认文件布局；符号链接 inode 保存 target。具体字段会随版本演进，不能让离线工具依赖未版本化的内部编码。

### 2.2 dentry

dentry key 由目录前缀、parent inode 和 name 组成。同一目录的名称在连续 key range 中，便于 readdir 范围扫描；不同目录和不同名称可由 FDB 自动分裂到不同 storage server。

连续范围的两面性：

- 目录扫描高效；
- 极热目录仍可能集中到有限 key range；
- 单个名字热点和同名 create 冲突不能通过增加 Meta 消失；
- 大目录删除必须分页，不能塞进一个 FDB 事务。

## 3. inode 分配

若每次 create 都更新一个全局计数器，该 key 会成为冲突热点。3FS 的缓解策略是：

- 预留 4096 个 inode ID 的 block；
- 使用 32 个 allocator shard；
- Meta 在本地消费已取得的 ID block。

效果是把 FDB 分配事务的频率约降为每 4096 个 inode 一次，并把并发冲突分散到多个 shard。代价是：

- Meta 崩溃会留下未使用 ID 空洞；
- ID 仅要求唯一/单调分配区间，不保证完全连续；
- allocator shard 数是容量规划参数，不是无限扩展机制；
- 恢复与升级必须保持高水位不回退。

## 4. namespace 事务

### 4.1 create

create 在一个 FDB 读写事务中：

1. 读取父 inode 并加入冲突检查，防止并发删除父目录；
2. 检查目标 dentry 不存在；
3. 分配 inode；
4. 写入 inode 和 dentry。

实现不需要为每次 create 更新父 inode，因此同一目录中不同名字的创建可以减少互相冲突。相同名字仍正确冲突。

### 4.2 link/unlink

link 创建新的 dentry 并更新 inode link count。unlink 删除 dentry、减少 link count；当链接数归零时，不一定马上删 chunk：

- 若仍有 write session，需要等待；
- inode/chunk 清理进入异步 GC；
- 物理空间回收晚于 namespace 不可见时间。

这与本地文件系统“unlink 后仍由 open fd 使用”的目标相似，但 3FS 对 read-only fd 的追踪是有意简化的，边界见一致性文档。

### 4.3 rename

rename 可在 FDB 事务中原子更新 dentry。目录 rename 还要沿目标父目录向上检查，避免把目录移动到自己的子树。默认最大目录深度为 64，因此检查有界，但深目录会增加读集合、冲突面和事务时长。

FDB 的 5 秒事务上限意味着：

- 网络抖动或多次冲突重试会影响长事务；
- 不应把递归遍历、海量 dentry 更新放入单事务；
- 业务端应避免把超大目录改名与高频并发修改叠加；
- 压测要覆盖热目录和跨树 rename，而不只测空目录 create。

### 4.4 list/readdir

目录列举依赖 dentry key range，服务端分页。默认配置可见较小的单次 list limit（如 128），批处理上限另有约束。客户端必须正确处理 continuation，且不能假设一次 RPC 得到完整目录。

## 5. 文件长度与动态属性

数据写绕过 Meta 后，FDB 中的 inode length 无法在每次写入时同步更新，否则 Meta/FDB 会重新进入数据热路径。3FS 采用“周期汇报 + 精确收敛”：

- 写客户端维护最大写位置；
- 活跃写期间约每 5 秒汇报；
- Meta 侧使用 rendezvous hashing 分配动态属性任务；
- close 或需要时查询最后相关 chunk，得到更精确长度；
- fsync 是否强制长度收敛受客户端配置影响。

工程语义：

- 并发 writer 存在时，stat 的 length 可能滞后；
- 数据已经写入不代表 FDB length 同一时刻可见；
- close/fsync 会增加跨 stripe 查询成本；
- 客户端崩溃后需要 session 超时/后台任务帮助收敛；
- 应用若以 size 作为“所有 writer 已完成”的同步信号，必须做专项验证。

为了避免对小文件查询生产配置中的全部 chain，长度查询可从较小 hint（例如 16）开始，再指数扩大，直到覆盖必要范围；生产 stripe size 可以达到约 200。

## 6. Open session

3FS 对可写 fd 建立 session，主要解决：

- writer 存活时延迟删除底层 chunk；
- 崩溃客户端 session 过期后允许回收；
- 动态长度和 write lease 类状态的归属。

read-only fd 出于扩展性没有同等追踪。这意味着不能机械套用本地 POSIX 的所有 unlink-open 行为，特别是：

- 只读打开后另一个客户端 unlink；
- inode/link count 归零后的长时间读取；
- mount daemon 重启后的 fd 延续；
- stale fd 与重建 inode 的隔离。

生产验证应明确 read-only fd 在 unlink、rename、Meta 切换、mount 重启和 GC 时间窗内的行为。

## 7. 垃圾回收

删除分为三层：

1. namespace 中 dentry 消失；
2. inode/link/session 满足回收条件；
3. Storage chunk 删除并最终释放物理块。

Meta GC 默认可启用，文件删除有延迟窗口（默认配置可见 5 分钟量级），并通过 FDB 队列、scan、batch 和并发任务分解工作。递归删除不能依赖一个巨大 FDB 事务，项目提供虚拟目录/rename 到 trash 的批量删除入口，并有独立 Rust `trash_cleaner` 扫描用户 trash。

必须监控：

- GC queue depth 与最老任务年龄；
- session 超时数量；
- chunk delete 成功/重试率；
- unrecycled bytes 和本地 hole-punch 进度；
- FDB transaction conflict/timeout；
- trash_cleaner 是否存活及用户隔离。

GC backlog 会造成“df 看似没有回收”“SSD 实际空间持续下降”。逻辑删除成功不能作为物理容量已释放的判据。

## 8. FDB 的收益与边界

### 8.1 收益

- namespace 事务不需要 3FS 自研 consensus；
- Meta 无状态，扩缩容和故障切换简单；
- dentry/inode/key range 可由 FDB 自动分布；
- 配置、lease、session 和 GC queue 可复用同一事务层；
- 备份和 DR 有成熟工具基础。

### 8.2 边界

| FDB 约束 | 对 3FS 的影响 |
| --- | --- |
| 事务约 5 秒上限 | 深目录检查、冲突重试、超大批操作受限 |
| affected data 最大 10 MB | 递归删除、批量元数据更新必须拆分 |
| 大事务不推荐 | namespace API 应控制 batch size |
| hot key/range | inode allocator、热目录、热门 dentry 需专项测量 |
| 全局外部依赖 | Meta 全部健康也无法绕过 FDB 故障 |
| 连接者可访问 key | FDB 网络与 cluster file 必须严格保护 |

FDB 备份只能恢复 FDB 中的元数据。若 Storage 数据没有同一时间点的一致快照，单独恢复旧元数据可能引用不存在/版本不匹配的 chunk，或漏掉已存在数据。3FS 公开资料未给出把 FDB 与全体 Storage 原子冻结到同一时间点的完整方案。

## 9. 元数据容量与性能估算方法

PoC 不能只测 create/s。建议至少建模：

- inode + dentry 平均 key/value 字节；
- 每文件平均 chunk 数和 Storage chunk metadata 数；
- 目录数量、平均/最大 children；
- hardlink 与 symlink 比例；
- 每秒 create/stat/open/close/rename/unlink/readdir；
- write session 数与心跳量；
- GC 队列写放大；
- FDB replication、日志、备份保留和预留容量。

压测维度：

| 场景 | 目的 |
| --- | --- |
| 多目录均匀 create | 测 Meta/FDB 横向吞吐 |
| 单热目录随机名字 create | 测 key range 与冲突 |
| 同名 create/delete | 测冲突重试和尾延迟 |
| 64 层目录 rename | 测祖先检查和事务上限 |
| 百万级目录 readdir | 测分页、客户端内存和公平性 |
| 大量 writer 崩溃 | 测 session 清理与 length 收敛 |
| 批量 rm-rf | 测 GC backlog 和物理回收 |
| FDB failover/DR | 测 namespace RTO/RPO |

## 10. 设计评价

FDB + 无状态 Meta 是 3FS 最简洁的部分：它把难解的一致性问题交给成熟事务系统，使开发团队专注数据面。但这不是“元数据无限扩展”。热点、事务边界、FDB 运维和跨数据/元数据恢复仍必须由系统级设计解决。对 10^12 级以上小文件目标，必须用真实 key/value 尺寸、FDB 节点规模和 GC 写放大证明，而不能只根据无状态 Meta 推导可扩展性。
