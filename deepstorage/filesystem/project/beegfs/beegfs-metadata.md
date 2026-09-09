# BeeGFS 元数据子系统

## 1. 结论先行

BeeGFS 元数据设计的核心不是“一个可水平切分的分布式 KV”，而是“多个彼此独立的本地文件系统分片”：

- 每个目录由一个 metadata service 或 metadata Buddy Group 独占管理，目录内不再分片；
- BeeGFS inode/dentry 被序列化到本地文件/xattr，利用底层目录、hardlink、rename 和 inode cache；
- 普通文件 inode 默认内联进 dentry，减少一次本地元数据 I/O；跨目录 hardlink 等场景再去内联；
- 目录间操作通过服务间 RPC、顺序操作和补偿完成，没有全局日志或共识事务；
- 文件动态 size/mtime 在写期间由 storage chunks 提供，close 时汇总回 metadata；
- 镜像以一个 primary/secondary pair 为复制单元，正常同步复制，异常时标记 `Needs Resync` 而非回滚。

这套设计对“许多目录、每个目录规模合理”的 HPC 命名空间非常有效。它的主要上限是单目录 owner、底层 inode 数、
metadata 本地设备延迟，以及跨 metadata 操作的错误恢复复杂度。

## 2. 逻辑对象模型

### 2.1 EntryID

BeeGFS 不以一个集中分配的 64-bit inode number 作为全局主键，而使用字符串 EntryID。8.4 的
`common/source/common/toolkit/StorageTk.h:212-238` 生成格式近似：

```text
<64-bit counter hex>-<timestamp hex>-<local node id hex>
```

进程启动时 counter 的高 32 位取当前秒级时间，低 32 位在本进程顺序递增；node ID 提供创建者域。
源码注释列出的唯一性假设包括：重启间隔/时钟不能回退到冲突窗口、单秒生成量不超过 `2^32`。
counter 放在字符串前部是为了让底层目录名尽早分散，避免大量共同前缀带来的比较成本。

工程含义：

- 无需调用全局 ID allocator，创建路径少一次协调；
- EntryID 可作为 metadata inode、dentry-by-ID 和 storage chunk 文件名之间的关联键；
- 它是协议/磁盘格式的一部分，不适合按纯递增整数做范围分片；
- 唯一性依赖节点 ID 管理和时间假设，克隆节点/错误恢复时必须保护身份配置。

特殊根对象在 `common/source/common/storage/Metadata.h:6-15` 中使用 `root`、`disposal`、`mdisposal`
等保留 ID，而非普通生成格式。

### 2.2 目录 inode、dentry、文件 inode

概念关系如下：

```text
DirInode(parent EntryID)
  └─ dentry name -> EntryID, owner, type, flags, [possibly inlined FileInode]
       └─ independent FileInode (only when de-inlined, e.g. multi-hardlink cases)
            └─ StripePattern(chunk size, target vector, mirror flag)
```

普通文件的 inode 序列化在 dentry 中，可让 lookup/open 在一次本地对象读取内拿到属性和条带布局。
当文件需要跨目录 hardlink 时，inode 从 dentry 去内联为独立对象，多个 dentries 指向同一 EntryID/owner；
因此多 hardlink 文件才额外付出远程 inode lookup 和锁成本。

目录 inode 与它所包含 dentries 由同一 metadata owner 管理。子目录的 inode owner 可以与父目录不同，父 dentry
记录其 owner，路径遍历因此可能在 metadata nodes 间跳转。

## 3. 磁盘布局

### 3.1 二级 hash 目录

`Metadata.h:17-25` 定义每层 `128` 个 hash 目录；metadata 初始化时创建 `128 × 128` 的分桶结构。
`MetaStorageTk.h:23-63` 根据 EntryID hash 计算 inode 和目录内容路径，避免把全部 BeeGFS 元对象塞入一个底层目录。

概念布局如下（实际常量名/层级以源码为准）：

```text
<meta-target>/
  inodes/<h1>/<h2>/<entry-id>
  dentries/<h1>/<h2>/<directory-entry-id>/
    <name>                    # dentry-by-name
    #fSiDs#/<entry-id>        # dentry-by-ID
  buddymir/...                # mirrored namespace counterpart
```

固定两级 hash 的优势是简单、可预测、可直接用本地文件系统工具检查；不足是顶层结构固定，元对象数量继续扩大时，
压力最终仍落在本地 FS inode、dentry cache、journal 和单 target IOPS 上，而不是自动切成新的 metadata shard。

### 3.2 xattr 与 hardlink 技巧

默认 `storeUseExtendedAttribs=true`。`meta/source/storage/MetadataEx.h:7-23` 定义 BeeGFS metadata xattr
`user.fhgfs`，序列化缓冲上限为 8 KiB；8.4 还定义 RST 相关 xattr。`DirEntry.cpp:16-103` 在启用 xattr 时
把序列化元数据写进 xattr，否则写进普通文件内容。

创建 dentry 的典型顺序是：

1. 在 `#fSiDs#` 下创建以 EntryID 命名的 dentry-by-ID；
2. 写入 dentry/内联 inode 序列化数据；
3. 用底层 hardlink 创建 dentry-by-name；
4. 去内联 inode 时，独立 inode 文件成为权威对象，相关 ID link 按语义调整。

使用底层 hardlink 能让 name 和 ID 两条索引指向同一 inode，减少自建索引/事务日志，但也带来要求：

- metadata 备份必须保留 xattr、hardlink、owner/mode 和精确目录结构；
- 随意用普通文件工具修改 metadata store 会破坏 BeeGFS 不变量；
- metadata 容量规划必须以底层 inode 数和 journal 写放大为一等指标；
- 8 KiB 序列化上限会约束极宽条带、ACL/xattr/RST 信息组合，官方调优建议宽条带时增大 ext4 inode。

### 3.3 为什么推荐 ext4 + 低延迟设备

官方 [Metadata Node Tuning](https://doc.beegfs.io/latest/advanced_topics/metadata_tuning.html) 推荐 SSD/NVMe、
RAID1/10 和 ext4，原因与上述布局一致：工作负载主要是小随机读写、xattr、hardlink、rename 和 journal commit。
建议的 ext4 大 inode（通常 512 B，宽条带/ACL 时可能 1024 B）让 xattr 尽量内联，减少额外数据块访问。

这不是“metadata daemon 自己保证持久性”的替代品。底层 FS mount/barrier、RAID cache、掉电保护和设备错误语义
直接进入 BeeGFS 的 durability envelope。

## 4. 放置：目录 owner 选择

### 4.1 新目录

`meta/source/net/message/storage/creating/MkDirMsgEx.cpp:116-138` 从 metadata capacity pools 和
preferred nodes 中选择一个 owner。若 owner 是远程节点，源码在 `:241-263` 先远程创建目录 inode，再在父目录
创建 dentry；后一步失败时尝试补偿删除远端 inode。

因此创建子目录可能涉及两个 metadata owners：

```text
client -> parent owner
parent owner -> selected child owner: create DirInode
parent owner: create parent dentry pointing to child owner
failure -> best-effort remove remote DirInode
```

这是按目录实现横向扩展的关键，也是孤儿/缺失引用需要 fsck 交叉检查的来源之一。

### 4.2 新文件

文件 dentry/inode 归属于父目录 owner；创建时从目录的 storage pool/default pattern 与当前 capacity pools 选择
storage target vector。元数据 owner 和数据 targets 完全解耦。目录的 mirror/storage-pool/stripe 默认值向新对象继承，
已存在文件不会因父目录设置变化自动重写布局。

### 4.3 热点与规模

目录 owner 模型可把 `/project-a`、`/project-b`、`/project-c` 分到不同 metadata services，适合项目/用户天然分层的
HPC 命名空间。它无法把 `/flat/` 内一亿个文件的 create/stat 分散到多个 owners。

需要同时评估四个上限：

1. **单 owner CPU/worker/网络**：该目录的请求汇聚到一个 metadata service；
2. **底层目录算法**：ext4 htree/large_dir 不是无限扩展；
3. **底层 inode 总量**：metadata 可先耗尽 inode 而非 bytes；
4. **客户端缓存命中率**：缓存能降低读 lookup，但不能分散 create/unlink 的权威写入。

官方提示超过一千万 entries 的底层目录需 `large_dir`，同时明确建议用户把文件拆到多个子目录。这应被视为数据模型约束，
不是单纯调参建议。

## 5. 核心操作

### 5.1 lookup / readdir

lookup 先由客户端解析缓存，再向父目录 owner 读取 name dentry。dentry 已包含常见文件的内联 inode 和条带信息，
所以通常无需再访问独立 inode。跨目录 hardlink 导致 inode 去内联且可能由远程 owner 管理，此时需要额外 RPC。

`readdir` 的全部 entries 位于单 owner，本地读取可保持良好顺序局部性；但大目录枚举不能在多个 metadata nodes 上并行。
应用对“列举整个目录”的频率往往比总文件数更决定尾延迟。

### 5.2 create / mkdir

create 需要父目录 name 锁/目录写锁，生成 EntryID、选择 stripe targets、创建 ID/name 两条本地表示并更新目录属性。
mirrored directory 下，primary 完成本地变更后把操作转发给 buddy；sequence-number/session 状态抑制重复请求。

mkdir 还需建立可能位于远端的 child DirInode。如上所述，它是带补偿的多步骤操作，并非原子提交到一个分布式事务日志。

### 5.3 rename

rename 的成本和故障面取决于位置：

| 情形 | 主要机制 | 工程属性 |
|------|----------|----------|
| 同目录 | owner 获取有序 name/inode locks，调用底层目录 rename | 最接近单机原子 rename；覆盖目标的后续 chunk 清理仍可失败 |
| 同 metadata、跨目录 | 两个本地目录锁 + 移动/属性更新 | 无网络 owner 跳转，但锁序和覆盖清理更复杂 |
| 跨 metadata 的文件 | 序列化 inode/布局 → 远端插入 → 源端完成/清理 | 多 RPC；需要处理覆盖目标、hardlink owner、失败补偿 |
| 跨 metadata 的目录 | 远端插入/父指针更新/源 dentry 删除 | 涉及命名空间多个对象和 metadata mirror |

`RenameV2MsgEx.cpp:50-219` 按 EntryID 和 `(parent,name)` 的字典序获取本地相关锁，避免 metadata worker 间死锁；
源码还特别处理“dentry 在当前节点但去内联 inode 位于远端”的 hardlink 情形。

`MetaStoreRename.cpp:339-430` 显示远端文件移动会先处理目标 dentry，再反序列化/创建新 inode+dentry；
错误路径中存在“restore overwritten entry/dentry”的 TODO。`RenameV2MsgEx.cpp:598-608` 还明确接受“rename 已成功，
但覆盖文件的 storage chunks 删除失败”，记录错误而不把失败返回用户。

另一个需要做兼容性测试的源码事实是：`MetaStoreRename.cpp:299-325` 的 overwrite 检查会拒绝 directory 覆盖任何已存在
directory，并留有“目标为空目录时应允许”的 TODO；这与常见 Linux `rename()` 允许替换空目录的预期存在差异。

由此可以得出的严谨结论是：

- 正常 API 目标仍是 Linux rename 语义；
- 实现不是跨 metadata 的 2PC/共识事务，部分执行后的收敛依赖补偿、幂等、disposal 和 fsck；
- 不能从一次成功返回推导“被覆盖对象的所有 chunks 已物理回收”；
- crash/network fault 下的可见性和泄漏窗口必须按版本做故障注入，源码不能替代应用验收。

### 5.4 hardlink

8.x 支持跨目录 hardlink。关键做法是将 inode 从 dentry 去内联为独立 inode，并在各 dentry 中保存 EntryID/owner。
这避免复制 inode 状态，但让 lookup、rename、unlink 和锁逻辑都要区分“dentry owner”与“inode owner”。

工程上应限制异常高 link count 和大范围跨 owner hardlink：这不是功能不支持，而是它破坏目录局部性并增加远程元数据操作。

### 5.5 unlink 与 open-unlink

如果文件未打开，unlink 删除 dentry/inode，并向 stripe targets 发送 chunk 删除；chunk 删除失败可能形成可由 fsck 发现的孤儿。

如果文件仍被打开，BeeGFS 使用特殊 disposal directory：命名空间名字立即消失，inode 被移到 disposal，最后一个 close
再删除 chunks/inode。客户端异常退出后，management/client session 超时和服务端清理最终处理遗留对象；官方架构文档给出的
默认客户端清理量级约 30 分钟，与 8.4 management `client_auto_remove_timeout=30m` 一致。

这与本地 POSIX open-unlink 体验一致，但会制造暂时不可见的容量占用。容量告警不能只统计用户命名空间。

### 5.6 stat 与动态属性

文件 inode 保存一组持久化动态属性，但写期间各 storage chunk 的真实 length/mtime 才是最新事实。
`FileInode.h:581-596` 在存在写 session 时把动态属性视为 outdated；`MsgHelperStat.cpp:19-255` 对过期状态并行查询
全部 stripe targets（镜像只查当前 primary），然后 `StatData.cpp:19-158` 按 chunk size、target index 和各 chunk length
重建逻辑文件 size，并聚合时间戳。

为了拒绝乱序旧响应，每个 chunk dynamic attribute 带 storage version，metadata 只接受单调更高版本。
close 路径也会收集 chunks 属性并持久化回 inode。

权衡：

- 写路径不必为每次扩展文件同步更新 metadata，吞吐更好；
- 活跃写文件的精确 stat 是 `O(stripe targets)` 网络 fan-out；
- target 不可达时，size/mtime 的完整性和错误返回受 target state/retry 影响；
- metadata TTL 仍可能让其他客户端短期看到缓存属性，服务端“能算准”不等于调用端总是立刻查询。

## 6. 并发控制

### 6.1 服务端对象锁

Metadata 通过 `EntryLockStore` 对 hash dir、directory ID、`(parentID,name)`、file ID 等键加锁。
涉及多个对象时严格排序，避免本节点 worker deadlock。锁保护一个 metadata service/Buddy Group 内的对象操作，
不是跨集群全局事务锁。

### 6.2 客户端 advisory locks

应用可使用 `flock`/fcntl range locks，但默认 `tuneUseGlobalFileLocks=false` 时只在本客户端生效；全局模式才由 metadata
协调跨客户端锁，并在 lock/unlock 边界刷新相关缓存。默认与应用语义的差距详见
[beegfs-consistency.md](beegfs-consistency.md)。

### 6.3 镜像幂等和顺序

`meta/source/net/message/MirroredMessage.h:55-218` 为 mirrored metadata operations 维护 client session、
sequence number 和 response state：

- 同 sequence 的已完成重试可返回已保存 response；
- 正在处理的重复请求返回 `TRYAGAIN`；
- primary 先执行本地操作，再把可观察变更转发 secondary；
- secondary 通信/结果异常时保留 primary 成功结果并标记 secondary `Needs Resync`。

源码 `:311-336` 解释了不回滚的原因：部分操作已把状态移动到另一 metadata server，完整回滚需要 2PC 且删除对象需要
长期保留。这个选择提高正常路径效率和异常时 primary 可用性，但说明 Buddy Mirroring 不是多数派提交日志。

## 7. 元数据镜像与继承

Metadata mirroring 默认不自动覆盖既有整个命名空间。执行 `beegfs mirror init` 时必须停客户端和多数服务，确保 root owner
位于正确 Buddy Group；root 及其直接内容启用后，新对象从 mirrored parent 继承。既有其他目录不会自动转为 mirrored，
官方建议通过递归 copy 重建树。

两个容易误判的点：

1. 移动普通文件进入 mirrored 目录会迁移/启用相应 metadata mirroring；移动目录不自动递归改变其整个子树属性。
2. Metadata mirroring 只保护 BeeGFS metadata 的第二份实时副本，不能恢复误删、逻辑损坏或历史版本，绝不是 backup。

## 8. 失败一致性与 fsck 关系

BeeGFS 元数据与 chunks 分属不同服务，又没有跨组件 WAL，因此一致性检查需要验证多类双向关系：

- dentry-by-name ↔ dentry-by-ID；
- dentry ↔ inode 及 link count；
- inode stripe pattern ↔ storage chunk；
- directory dentry ↔ child inode/parent owner；
- disposal 对象 ↔ open/session 状态；
- primary ↔ secondary 的镜像内容。

正常错误路径会尽量补偿，但源码中明确存在“用户操作成功、物理清理失败”的容忍策略，fsck 不是可有可无的遗留工具，
而是这类无全局事务架构的修复闭环。自动 repair 可能把“暂时缺失/损坏一侧”解释为应删除另一侧，必须先读模式审查，
详见 [beegfs-ha-recovery.md](beegfs-ha-recovery.md)。

## 9. 容量模型

做 metadata sizing 时至少记录：

```text
metadata objects ≈ directories
                 + dentries / underlying ID links
                 + de-inlined inodes
                 + disposal/orphan temporary objects
                 + mirror copy
```

底层实际 inode 数与 BeeGFS 用户 inode 数不是简单 1:1，且受内联状态和 hardlink 表示影响。容量评估应从样本树实测
`df -i`、metadata store bytes、journal IOPS 和 xattr external blocks，而非只用“每文件若干字节”的理论乘法。

宽条带会扩大 inode 序列化信息；ACL、用户 xattr、RST 元数据也增加 inode/xattr 负载。ext4 的 inode 数在格式化时固定，
耗尽后即使还有大量 byte capacity 也无法继续创建。

## 10. 对 LightStore 的直接启示

### 值得借鉴

- **控制面不进入数据路径**：客户端缓存布局并直连 DataServer，方向与 LightStore 一致。
- **明确的 EntryID 贯穿元数据和物理对象**：有利于 fsck、日志和孤儿定位。
- **动态属性带单调 version**：可用于拒绝乱序 storage response，适合 LightStore 的异步元数据汇总。
- **disposal 语义**：为 open-unlink/延迟回收建立显式状态，而不是把特殊情况散落在 GC。
- **双维 target state**：reachability 与 consistency 分离，避免把“在线但需 resync”压成一个布尔值。

### 不应照搬

- LightStore 的目标是 `10^12–10^13` 文件，不能让单目录固定落在一个 metadata shard；需要 Range split、目录 hash shard
  或显式限制/自动分桶。
- 本地“一文件一对象”与 LightStore append-only volume packing 的小文件目标相反。
- 主副本本地成功后异步标记副本 resync 的模型弱于 Raft committed state；LightStore metadata 不应退回该模型。
- 依赖底层 hardlink/xattr 虽开发高效，但把磁盘格式、备份和校验强绑定到单机 FS，不适合 LightStore 自定义全局 metadata engine。

## 11. 建议验证用例

1. `mdtest`：多目录均匀、单热目录、跨目录 rename/hardlink 三组分别测吞吐和 p99。
2. inode 压力：以真实文件名、ACL/xattr、stripe count 建样本，测底层 inode/xattr block 放大。
3. rename 故障注入：远端 insert 前后 kill source/destination metadata，核验可见性、泄漏和 fsck 报告。
4. open-unlink：客户端崩溃、management 中断、session timeout 后验证 disposal 回收时间。
5. 活跃写 `stat`：不同 stripe count、一个 target 慢/离线时测延迟与返回语义。
6. metadata buddy：在本地提交后、secondary ACK 前断网，验证客户端结果、target state 和 resync。
