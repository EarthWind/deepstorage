# SeaweedFS Filer、元数据后端与并发语义

## 1. 技术总结

Filer 给 SeaweedFS 增加目录树、POSIX 属性、大文件 chunk、S3 对象元数据和变更日志。它本身不是一个内置共识元数据数据库；真正的持久语义由 Filer Store 驱动决定。共享 HA Store 可让多个 Filer 看到同一 namespace；多个嵌入式 Store 依靠 metadata log 异步重放，只能最终一致。

4.41 的 owner routing、per-path lock、condition 和 `ObjectTransaction` 显著改善同对象并发，但需要精确理解：

- 本地锁只在 owner Filer 进程内；
- ring change 通过 prior-owner cooling、fail-close 和 warm-up降低双 owner 风险；
- mutations 顺序执行，中途失败不通用 rollback；
-普通 path API 是否经过同一 route key/owner，需要按调用者审计；
- Filer Store transaction 能力因驱动而异，LevelDB 实现是 no-op。

## 2. Filer entry

Filer Store 的主键通常由 parent directory + name 或 full path 变体生成，value 保存 entry。Entry 包含：

- path/name；
- directory flag、mode、uid/gid；
- mtime/ctime/atime、inode、file size；
- chunk list/manifest；
- inline content；
- MD5、MIME、extended attributes；
- hard link id/counter；
- TTL、WORM timestamp、quota；
- remote/tier/SSE metadata。

目录层级通常隐含在 key 中。这让 list directory 成为 prefix/range scan，也使目录 rename 不能只更新一个 inode pointer。

## 3. Filer Store 选择

官方支持 memory、LevelDB 系列、RocksDB、SQLite、MySQL/Postgres 及分表变体、Redis、MongoDB、Cassandra、HBase、FoundationDB、YDB、TiKV、CockroachDB 等。

生产不应只按“lookup 快慢”选择，应至少比较：

| 维度 | 需要确认 |
| --- | --- |
| HA | 单机嵌入式还是数据库集群；RPO/故障转移由谁保证 |
| Consistency | linearizable/serializable/read committed/eventual；读副本是否陈旧 |
| Transaction | Begin/Commit/Rollback 是否真实实现；跨目录/跨表范围 |
| Rename | 文件 rename 与递归目录 rename 是否原子，最大 transaction 大小 |
| List | 大目录 prefix scan、分页、热点 key/partition |
| TTL | native TTL、Filer 过滤还是后台删除 |
| Bucket delete | 能否 drop whole bucket/table，还是逐 entry 扫描 |
| Value size | chunk list/manifest/inline content/xattr 上限 |
| Backup | 一致 snapshot、PITR、跨 region、恢复校验 |
| Operations | schema migration、连接池、TLS、认证、监控、成本 |

### 3.1 嵌入式 Store

LevelDB/RocksDB：

- 低延迟、部署简单；
- 单个 Store 本地持久；
-默认 Filer scaffold 的 LevelDB2 只适合一个 Filer；
- transaction 方法对 LevelDB 返回原 context，commit/rollback 都 no-op；
- 多 Filer 可用日志互复制，但最终一致。

### 3.2 SQL Store

`AbstractSqlStore.BeginTransaction` 使用 `sql.DB.BeginTx`，隔离级别为 `ReadCommitted`。这至少能把同一数据库连接 context 中的多次 entry mutation放入 transaction，但：

- Read Committed 不自动避免所有 write skew/lost update；
-分 bucket table 的跨表 rename 可能受数据库限制；
-超大目录 rename 事务时间/row locks/WAL 会很重；
-后端方言与 retryable error 处理仍需验证。

### 3.3 FoundationDB/YDB/TiKV

这些驱动提供自己的 transaction API，更适合需要多 key 原子性的 namespace；代价是额外集群、transaction size/time 限制、冲突率和运维专业性。不能因为 Store 接口有 transaction 方法，就认为每个驱动语义相同。

## 4. Filer 写入顺序

普通大文件写：

1. 匹配 path-specific storage rule；
2. 向 Master assign 一个或多个 chunk FID；
3. 最多约 4 个 chunk buffer 并发上传；
4. 计算 MD5，检查请求 digest；
5. 合并/compact chunk view，必要时写 manifest；
6. `CreateEntry` 写入 Filer Store；
7. metadata 失败时删除未提交 chunk；
8. metadata 成功后删除旧/被覆盖 chunk。

### 4.1 为什么 data first

metadata first 会让读者看到尚不存在的 FID。data first 保证已提交 entry 指向至少已完成上传的数据，但引入孤儿。SeaweedFS 选择“引用完整性优先，空间用补偿/GC修复”。

### 4.2 请求取消

assign、upload、metadata commit 多处使用 `context.WithoutCancel`，避免客户端断开造成半上传/半复制。这对服务端完整性有利，却使客户端超时后结果不确定：

-服务端可能最终成功；
-客户端重试产生新 version/FID；
-S3 conditional/idempotency 需要保护。

## 5. Create/Update concurrency

`CreateEntry`/`UpdateEntry` handler 在本 Filer 上获得 `entryLockTable` 的 exclusive path lock，锁覆盖：

-读取现有 entry；
-条件检查；
-chunk garbage diff；
-写 Store；
-metadata event。

这避免同一个 Filer 进程内的 read-modify-write 交错。多 Filer 下，只有调用者把同 key 路由到共同 owner，或后端数据库本身提供冲突控制，才能扩展为集群级串行。

4.41 的 `UpdateEntry` 支持 chunk-set write condition，防止陈旧客户端用旧 chunk 基线覆盖较新的 entry 并把新 chunk 错当 garbage。

## 6. ObjectTransaction

### 6.1 处理流程

请求含：

- `route_key`：确定 owner Filer；
- `lock_key`：本地路径锁；
-可选 `condition_key` + `WriteCondition`；
-有序 `mutations`；
-防循环 `is_moved`。

Filer：

1. 根据 LockRing 检查 owner；
2. 非 owner 时最多转发一 hop；
3. owner 获取 per-path exclusive lock；
4. 读取 condition entry 并检查；
5. 逐一执行 PUT/DELETE/PATCH_EXTENDED/RECOMPUTE_LATEST；
6. 第一个失败就停止后续 mutation；
7. 返回成功/错误。

用途包括：

- versioned PUT/Delete；
- null version/delete marker/latest pointer；
- If-Match/If-None-Match；
- Object Lock/WORM guard；
- lifecycle 条件删除。

### 6.2 它保证什么

在 owner 不分裂、所有相同对象写都使用相同 route/lock key 的前提下：

-同对象并发 writer 不会在 handler 内交错；
-condition 与后续 mutation 之间持有同一进程锁；
-mutation 顺序确定；
-batch 中每个对象独立。

### 6.3 它不保证什么

固定源码没有在 `ObjectTransaction` 外围调用 `filer.BeginTransaction`；`applyObjectMutation` 直接 Create/Delete/Update。若第 1 个 mutation 成功、第 2 个失败：

-第 1 个不会自动 rollback；
-已发 metadata event 也可能已进入日志；
-删除的 chunk/entry补偿依赖具体路径；
-后续 retry 必须幂等并能重算 latest。

因此官方注释的 “atomically with respect to other writers” 应翻译为“相对同一对象其他 writer 的串行原子区间”，不能翻译为“mutation list 具备数据库事务原子性”。

`ObjectTransactionBatch` 只是一个 round trip 执行多个独立 transaction；一个失败不回滚其他对象。

## 7. Owner Ring 变更

所有 Filer 从 Master 获得成员视图，构建 consistent hash LockRing。加入/退出时不同 Filer 看到新 snapshot 的时刻不同，可能短暂双 owner。防护：

-保留最近 snapshot，计算 `PriorOwner(key)`；
-新 owner 在 cooling window 向旧 owner做最多约 2 秒 probe；
-probe 错误/超时 fail-close，不冒险授权；
-Filer 启动后约 10 秒 warm-up，等待内存锁状态重建；
-请求转发 `is_moved` 限定一 hop，防止循环。

这降低并发双授予，却仍依赖：

- Master 成员广播及时；
-旧 owner 可访问；
-客户端/网关都使用 route key；
-进程内 lock state 不是 durable。

Filer 重启时 active object transaction 本身不会恢复；业务依赖幂等结构和 Store 中已写状态。

## 8. Rename

### 8.1 文件 rename

`AtomicRenameEntry`：

1. 按字典顺序锁 old/new path 防死锁；
2. 调用 Store `BeginTransaction`；
3.读取 old/target；
4.在 new path 插入 entry；
5.删除 old path；
6. commit；
7. commit 后才删除被覆盖 target 的 chunk；
8.发送 metadata event。

对真实 transaction Store，这可接近原子 rename。对 LevelDB no-op transaction，中途失败可能同时存在 old/new 或丢失某一侧；路径锁只防本 Filer 并发，不提供崩溃 rollback。

### 8.2 目录 rename

Filer 递归 list 最多 1024 entry 一批，将每个 descendant 搬到新 full path。复杂度：

```text
O(number of descendants)
```

后果：

-大目录树 rename 是长 transaction/长锁；
-后端 transaction size/time 可能超限；
-只有 old/new root path 被 entryLockTable 锁，descendant 并不逐一获得同类外部 fencing；
-日志会产生大量事件；
-跨集群 sync 必须保持 rename 顺序；
-嵌入式 no-op transaction 的 crash consistency 更弱。

不能按传统 inode-based filesystem 的 O(1) directory rename 估算。

## 9. Metadata log

每个 Filer 把 Create/Update/Delete event 写入 LocalMetaLogBuffer：

-内存 buffer 按时间/offset 组织；
-flush 后作为 SeaweedFS 文件/metadata chunk 持久；
-subscriber 可从时间戳/position 重放；
-signature 防止同一 cluster update ping-pong；
-MetaAggregator 汇总 peer event。

用途：

- FUSE cache invalidation；
-嵌入式 Filer Store replication；
-`filer.sync`；
-`filer.backup/replicate`；
-lifecycle/notification 等消费。

4.41 修复了 oversized flush 卡住 feed、flush queue 内存边界、subscription gap 跳过未 flush event、failed event offset 被越过等问题。说明 metadata log 是关键但复杂的异步子系统，需要监控：

-buffer/flush queue bytes；
-last flushed/evicted timestamp；
-subscriber lag/gap；
-persisted log TTL；
-failed replay；
-checkpoint age。

## 10. 多 Filer 模式

### 10.1 共享 Store

```text
Filer A --\
Filer B ---- shared HA SQL/KV Store
Filer C --/
```

优点：

-持久 namespace 单一；
-任一 Filer 可读同一提交状态；
-Filer 进程易横向扩展/重启。

限制：

-本地 entry cache 需要 metadata event invalidate；
-owner lock/route 仍是内存协调；
-数据库成为性能、HA、备份、事务和容量中心；
-跨 Filer raw API 若不路由，local lock 不共享。

### 10.2 独立嵌入式 Store

```text
Filer A(leveldb) <--- metadata log ---> Filer B(leveldb)
```

官方明确最终一致。可能出现：

-新文件 metadata 尚未同步；
-负载均衡下一请求到另一 Filer 后 404；
-Multipart upload session/condition state不一致；
-并发更新 last-writer/order 差异；
-目录 rename loop 导致不一致。

只能用 sticky session/hash routing 缓解，不等价于共识。

## 11. 跨集群 filer.sync

`filer.sync` 读取两端 change log，复制 chunk 和 metadata，保存 source signature/checkpoint。4.41 已确保：

-failed event 不把 watermark 推过去；
-sink write 成功后再 ack；
-进程优雅退出保存 checkpoint。

仍是异步复制：

-并发在两地快速修改同一文件可能冲突；
-变化速率超过带宽会积压；
-full mesh 环路中同一 event 可经不同邻居重复到达；
-大多数 event 幂等，但 directory rename 有顺序依赖，官方要求避免 loop；
-RPO 是 last applied checkpoint，不是日志到达时间；
-目标需使用相同 SSE key/KMS，否则 ciphertext 可复制却无法解密。

Active-active 应只用于冲突可接受、路径可分区的 workload；严格 DR 优先 active-passive。

## 12. 元数据备份

至少同时保护：

- Filer Store snapshot/PITR；
-metadata change log 和 retention；
-`filer.store.id`/signature；
-sync/backup checkpoints；
-volume chunk 数据；
-`filer.toml`、path rules；
-S3 IAM/config、KEK/KMS；
-版本一致的二进制/schema。

官方集群镜像指南要求暂停写，再分别备 volume 和 `fs.meta.save`，承认缺少内建跨层一致 snapshot。若在线备份：

1. 记录 metadata snapshot timestamp/DB LSN；
2. 保留覆盖该点前后的 metadata log；
3. 确保所有 snapshot entry 引用的 FID 已在 backup 数据集中；
4.恢复后跑 `volume.fsck`/抽样全读；
5.演练 point-in-time 和全站丢失。

## 13. 生产建议

- 生产多 Filer 优先选共享 HA Store，不用嵌入式 eventual replication 冒充强一致；
- 对 rename/versioning/Object Lock 做与实际 Store 相同的 transaction failure 测试；
-为大目录设置规模门槛，限制递归 rename；
-所有 S3 object write 强制 route 到 owner，审核 raw Filer API 旁路；
-把 metadata log lag 和 flush failure 作为 page-level 告警；
-配置 metadata log TTL 前先匹配最大停机/复制 lag；
-备份时将 Store、volume、log、key 做同一恢复点；
-跨集群采用无环拓扑，active-active 按目录分配单写 owner。

## 14. 小结

Filer 不是自动获得强一致性的“无状态前端”。它是 namespace logic，而 Filer Store 是持久语义。4.41 的 serialization 机制值得肯定，但它解决的是同对象写者交错，不是把任意后端升级为 ACID。生产结论必须绑定“哪个 Store、什么隔离级别、是否 owner routing、失败在哪个 mutation、如何恢复”。
