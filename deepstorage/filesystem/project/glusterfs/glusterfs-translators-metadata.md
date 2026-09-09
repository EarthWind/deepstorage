# GlusterFS Translator、DHT 与元数据组织

## 1. 核心结论

GlusterFS 的“无中心元数据”不是把 metadata 消除，而是把它拆散为四类状态：

1. brick 后端的目录树、inode 和普通文件；
2. `trusted.gfid`、DHT layout、AFR pending/dirty 等扩展属性；
3. `.glusterfs` 中的 GFID handle、heal index、shard/linkfile 等隐藏对象；
4. 每个客户端内存中的 inode/fd/layout/read-child/translator graph cache。

常规文件 lookup 可以用 hash 直接定位，这是主要收益；目录创建/删除、目录遍历、rename、扩缩容和异常恢复则必须重建这个分布式视图，是主要成本。

## 2. Translator graph

### 2.1 FOP 的 wind/unwind 模型

每个 translator 实现一组 FOP，例如 `lookup`、`create`、`readv`、`writev`、`rename`、`fsync`、`setxattr`。请求沿 graph 向下 `STACK_WIND`，回调沿 graph 向上 `STACK_UNWIND`。translator 可以：

- 转换请求，如 shard 把逻辑 offset 映射到多个隐藏文件；
- 扇出请求，如 AFR 向多个 replicas 写；
- 选择 child，如 DHT 或 AFR read selection；
- 缓存/延后，如 quick-read、open-behind、write-behind；
- 插入一致性动作，如 locks、index、changelog、quota、bitrot；
- 终止/合并多个 child 的响应。

典型 distributed-replicated FUSE graph 可抽象为：

```text
FUSE
  └─ io-stats / quick-read / write-behind / open-behind / md-cache ...
      └─ DHT (distribute)
          ├─ AFR replica-set-0
          │   ├─ protocol/client -> brick-0 server graph -> POSIX -> XFS
          │   ├─ protocol/client -> brick-1 server graph -> POSIX -> XFS
          │   └─ protocol/client -> brick-2 server graph -> POSIX -> XFS
          └─ AFR replica-set-1
              └─ ...
```

graph 顺序非常重要。例如 write-behind 在 AFR 上层先向应用返回，并不等于 replicas 已经完成持久化；shard 在 DHT/AFR 上层把一个逻辑文件转换为多个独立 backend files；server-side locks/index 必须与 AFR 协议配套。

### 2.2 volfile 是可执行数据面配置

`glusterd` 根据 volume topology 和 options 生成 volfile。client bootstrap 后加载 `.so` translator、链接 parent/child、调用 init，再开始 FOP。其工程意义包括：

- client 必须理解该 graph 的 op-version 与 translator；
- 配置变化要传播到所有 client graph，旧 client 可能继续使用旧视图直到重连/刷新；
- volfile server 不在后续 I/O 热路径，但 volfile 错误可同时影响大量客户端；
- 自定义修改 volfile 会绕过管理面一致性，不应作为常态运维方式。

## 3. GFID 与 brick backend

### 3.1 GFID 是集群范围的对象身份

Gluster 为每个文件/目录分配 UUID 形式的 GFID，保存在 backend inode 的 `trusted.gfid` xattr。路径名可以 rename，GFID 仍用于：

- client inode identity；
- AFR/EC 比较同名 entry 是否为同一对象；
- changelog 与 geo-rep；
- self-heal index；
- `.glusterfs` 反向 handle；
- GFID-based lookup 和故障取证。

同一路径在不同 replica bricks 上必须具有相同 GFID。若相同 basename 映射到不同 GFID，就是 entry split-brain 的典型形式。

### 3.2 `.glusterfs` 不是垃圾目录

brick 根下 `.glusterfs` 保存 GFID fan-out handle 和内部索引。常见概念包括：

- 按 GFID 前两级字节分目录的 handle；
- `.glusterfs/indices/xattrop/`：可能需要 AFR heal 的 GFID hardlinks；
- `.glusterfs/indices/dirty/`：in-flight/dirty transaction 相关索引；
- shard、landfill、unlink 等内部状态目录（具体随 graph/版本变化）。

它使系统能从 GFID 找回 backend object，增量枚举 heal 候选，并支持 hardlink/rename 后的恢复。直接删除 handle 或仅复制可见目录树会破坏恢复闭环。

### 3.3 xattr 是分布式协议日志

| xattr/对象 | 作用 |
|------------|------|
| `trusted.gfid` | 全局对象 ID |
| `trusted.glusterfs.dht*` | 目录 hash layout、linkto 等 DHT 状态 |
| `trusted.afr.<child>` | data/metadata/entry pending blame/changelog |
| AFR dirty xattr | 标记 transaction 未完整结束 |
| quota/marker xattr | 目录累计用量与祖先传播 |
| bitrot signature/version | 内容签名和修改版本 |
| shard xattr/hidden entries | 逻辑文件大小、block 映射等 |

这些并非可选装饰。备份、迁移、rsync、tar、底层 dedupe 或安全扫描工具若不保留 trusted xattr/GFID/hardlink 关系，恢复出来的 brick 可能“文件内容都在，但 Gluster namespace 不可用”。

## 4. DHT placement

### 4.1 每目录独立 32-bit hash layout

DHT 为一个目录的 child subvolumes 分配不重叠的 32-bit hash ranges。布局存储在该目录各 backend 副本的 xattr 中，并被客户端缓存。创建 `/a/name` 时：

1. 客户端已有 `/a` 的 layout；
2. 对 basename `name` 计算 hash；
3. 找到包含该 hash 的 child subvolume；
4. 在该 child 内执行 create；若 child 是 AFR/EC，则继续复制/编码。

重要细节：

- hash 输入主要是 **basename**，不是完整路径；不同目录可有独立 layout；
- weighted rebalance 默认按 brick 容量分配 range；
- layout 是持久 metadata，不会因 client 重启重新随机计算；
- 普通文件通常只在一个 DHT child；目录则存在于所有 children。

### 4.2 为什么目录必须出现在全部 children

目录本身承载：

- 下一层文件的 hash layout；
- path traversal 所需 namespace；
- `readdir` 聚合边界；
- DHT/AFR directory heal；
- 跨 client 的 entry/inode lock anchor。

因此增加更多 DHT children 对不同文件的吞吐有利，却会放大 mkdir/rmdir/rename/readdir 和目录自愈成本。这是 Gluster 扩展曲线中最重要的非线性因素之一。

### 4.3 Lookup fast path 与 fallback

对文件 lookup：

1. 根据 parent layout 访问 hashed subvolume；
2. 找到正常文件则返回；
3. 找到 linkfile 则根据 linkto xattr 跳到实际 subvolume；
4. hashed subvolume 未命中时，是否广播其他 children 由 `lookup-optimize`、`lookup-unhashed`、layout/异常状态决定；
5. replica/EC child 内部再决定 read source、检查 heal/split-brain。

v11.2 默认 `lookup-optimize=on`，正常 negative lookup 可避免全子卷广播。但以下情况会失去 O(1) 路由优势：

- rebalance 中或遗留 linkfile；
- 目录 layout 缺失/不一致；
- 文件因低空间被放到非 hashed child；
- brick offline 导致 layout hole；
- rename/migration 异常需要查找真实对象。

### 4.4 Linkfile 解决“应该在哪”和“实际在哪”的差异

当文件因为 rebalance、空间水位或历史 topology 实际位于非 hashed child 时，DHT 可在 hashed child 放置一个特殊 linkfile，xattr 指向实际 child。它类似分布式 namespace 中的 forwarding pointer。

收益：旧文件不必在 layout 改变瞬间全部搬完，lookup 仍能从新 hash 位置转发。

代价：

- lookup 多一次 RPC；
- stale linkfile 会影响 unlink/rmdir/readdir；
- 手工把零长度内部文件当普通空文件处理会破坏路由；
- rebalance/rename 必须原子更新 data file 与 linkfile 状态。

## 5. Namespace 操作为什么困难

### 5.1 `mkdir`

目录需要相同 GFID 出现在所有 DHT subvolumes，并生成完整 layout。v11.2 设计文档描述的同步核心是：

1. 对 parent directory layout 取得 read `inodelk`；
2. 刷新 parent layout；
3. 在 basename 所 hash 的 child 上取得 `entrylk(parent, basename)`；
4. 向各 subvolumes 创建相同 GFID 目录；
5. 设置新目录 layout；
6. 释放 locks。

如果部分 child 失败，后续 lookup/self-heal 要补齐目录与 layout。一个“简单 mkdir”因此可能是 O(DHT children × replica/EC width) 的远端操作。

### 5.2 `readdir/readdirp`

目录条目分散在所有 DHT children，client 要：

- 分别读取各 child；
- 过滤 linkfile/重复/internal entries；
- 合并 offset/cursor；
- 对 `readdirp` 返回的 stat 选择正确 replica/read child；
- 处理 child 失败与目录 entry heal。

大目录 list 的瓶颈不是集中 MDS，而是最慢 brick、网络扇出、合并内存和小 inode stat IOPS。增加 bricks 可能让数据带宽上升，却让单目录 list 变慢。

### 5.3 File rename

若 source/destination hash 到不同 DHT children，rename 不是单个本地 `rename(2)`：需要锁 source/destination namespace、创建/更新 linkfile、移动真实文件、处理目标覆盖，并在失败时回滚。并发 rename 与 rebalance 是长期高风险组合，因此 v11.2 默认 `force-migration=off`，正在被写的文件会被 rebalance 跳过。

### 5.4 Directory rename

目录存在于所有 children，rename 必须在所有 copies 保持相同 path↔GFID。DHT 设计通过按 GFID 固定顺序取得 source/destination locks，避免 `rename(A,B)` 与 `rename(B,A)` 死锁，再跨 children 执行/回滚。

这不是严格的共识 transaction log；进程/网络在中间阶段故障时依赖 locks、backend 状态和后续 self-heal 恢复。因此目录 rename、lookup heal、mkdir/rmdir 之间的竞态是源码重点测试区域。

## 6. 扩容、缩容与 rebalance

### 6.1 Add-brick 不会自动迁移既有文件

既有目录的 layout 是静态持久状态。增加 bricks 后：

- 新创建目录会使用新 topology；
- 既有目录仍用旧 layout；
- `rebalance ... fix-layout` 只重写既有目录 layout；
- `rebalance ... start` 同时修 layout 并迁移既有 files。

只 add-brick 不 rebalance，会出现容量已加入但旧热目录继续写旧 bricks 的现象。

### 6.2 Rebalance 的逻辑阶段

```mermaid
flowchart LR
    A[Topology changes] --> B[Traverse directories]
    B --> C[Fix per-directory hash layout]
    C --> D[Find files no longer on hashed child]
    D --> E[Lock/check active writes]
    E --> F[Copy data/xattr/GFID to destination]
    F --> G[fsync destination]
    G --> H[Install linkfile / switch namespace]
    H --> I[Remove source and stale link state]
```

关键默认：

- weighted layout `on`；
- throttle `normal`，每节点通常 2 个迁移；
- `force-migration=off`，活跃写文件跳过；
- `ensure-durability=on`，目标迁移后 fsync。

### 6.3 空间与性能规划

Rebalance 同时需要 source 和 destination 临时存在，且不能在 near-full 集群才开始。建议：

- brick 达到业务高水位前扩容，而不是等 DHT 10% free threshold；
- 预留目标完整文件的临时复制空间和 heal/rebalance metadata；
- 限速并监控 skipped/failed files，而不只看命令 `completed`；
- rebalance 后做 namespace 抽样、文件 checksum、GFID/xattr 与 heal backlog 核验；
- sharding、hardlink、open file、rename-heavy workload 单独注入测试。

### 6.4 Remove-brick/replace-brick 不是对称操作

- pure distribute 没有副本恢复源，替换应通过 add + remove/migrate；
- distributed-replicated/dispersed 需要按完整 replica/disperse set 的倍数改变 topology；
- remove-brick `start` 触发迁移，只有 status 无失败且验证完成后才能 commit；
- replace-brick 主要用于 replicated topology，不能把它泛化为任意数据迁移工具。

## 7. 元数据扩展瓶颈

### 7.1 小文件固定成本

一个小文件可能产生：

- 每 replica/EC fragment 一个 backend inode/dentry；
- `trusted.gfid` 和 AFR/EC/quota/bitrot xattr；
- `.glusterfs` GFID hardlink；
- heal index entry（故障期间）；
- DHT/client inode cache；
- create/lookup/stat 对多个 bricks 的 RPC。

Gluster 不会为 1 KiB 文件预分配 64 MiB，但它仍是 **per-file native inode 模型**，与 LightStore 把许多小 records packing 到 volume 的模型完全不同。

### 7.2 大目录固定成本

目录在所有 DHT subvolumes 出现，目录数量本身会乘以 subvolume 数。几十亿目录比几十亿文件更不利，因为每个目录还带 layout、readdir 和 namespace heal 协调。

### 7.3 客户端状态规模

每个 native client 通常持有：

- 全 volume graph；
- 到 bricks 的 RPC clients/connections；
- inode/fd/cache/locks/read-child 状态；
- outstanding frames 与 event threads。

因此 `clients × bricks` 是网络 fd、内存和故障广播的重要规模变量。Gluster 去掉了中心 MDS，却没有消除全局 topology 对客户端的暴露。

## 8. Brick 级取证与禁止事项

### 8.1 安全的只读取证

- 先冻结/隔离写流量或使用 snapshot；
- 用 `getfattr -d -m . -e hex` 检查 trusted xattr；
- 用 GFID 工具/aux-gfid mount 反查路径；
- 比较 replicas 的 GFID、type、size、mtime 和 AFR xattr；
- 复制原始 brick/LVM snapshot 后再尝试修复。

### 8.2 禁止直接做的事

- 在一个 replica brick 上直接 `cp/rm/mv/chmod` 期待 Gluster 自动理解；
- 删除 `.glusterfs` 或 linkfile；
- 用不保留 xattr/hardlink 的文件复制工具“重建 brick”；
- 手工清零 `trusted.afr.*` 后立即恢复业务；
- 在未检查 hardlink 的情况下删除 GFID handle；
- 同时执行 rebalance、replace/remove-brick 和 split-brain 手工修复。

任何手工修复都应记录 source/sink 判定、原始 xattr、备份路径和可回滚点。
