# Lustre 调研（四）：恢复、空间预留与一致性检查

> 基线：lustre-release commit `eadb94b`

Lustre 没有 Raft，没有副本共识。它的一致性建立在**单主 target + 事务序号 + 客户端重放**
之上。这套机制在 Raft 流行之前就已成型，思路与 Raft 正交，值得单独理解。

## 1. transno：全局事务序号

每个 target（MDT/OST）维护一个单调递增的 `transno`。每个修改性操作
在提交时被赋予一个 transno（`lustre/target/tgt_lastrcvd.c:1663`）：

```c
tti->tti_transno = ++tgt->lut_last_transno;
```

服务端在每个回复里带上两个数：
- 本次操作的 `transno`
- 当前的 `last_committed`（已落盘的最大 transno）

**客户端保留所有 `transno > last_committed` 的请求**——这些是"服务端说做了、
但还没落盘"的操作。服务端崩溃重启后，客户端把它们按 transno 顺序重放。

这就是 Lustre 不需要同步落盘也能保证不丢数据的原理：
**持久性由客户端的重放缓冲提供，而不是由磁盘同步提供。**

### 与 Raft 的对比

| | Raft | Lustre |
|---|------|--------|
| 冗余位置 | 多个副本的日志 | **客户端的重放缓冲** |
| 提交条件 | 多数派持久化 | 单机落盘（异步） |
| 崩溃恢复 | 从副本日志恢复 | **从客户端重放恢复** |
| 客户端全挂 | 无影响 | **数据丢失** |
| 写延迟 | 一轮网络 + 多数派落盘 | 内存即返回 |

最后两行是关键权衡：Lustre 的写延迟极低（不等落盘、不等副本），
代价是**恢复正确性依赖客户端存活**。这在 HPC 场景成立
（计算节点与存储在同一机房、同生同灭），在通用场景不成立。

**LightStore 用 Raft 是正确的**。但 transno + 客户端重放这个思路
在一个地方仍有价值：**SDK 的写入重试语义**。LightStore 的 SDK 攒批提交 extent，
如果 MetaServer 主切换导致提交丢失，SDK 应该能重放——这需要
SDK 侧保留"已发出但未确认已提交"的索引，与 Lustre 的机制同构。

## 2. last_rcvd：服务端的客户端状态表

每个 target 上有个 `last_rcvd` 文件，为每个客户端保留一个槽位
（`include/uapi/linux/lustre/lustre_disk.h:171`）：

```c
struct lsd_client_data {
	__u8  lcd_uuid[40];            /* 客户端 UUID */
	__u64 lcd_last_transno;        /* 最后完成的事务 ID */
	__u64 lcd_last_xid;            /* 最后事务的 xid */
	__u32 lcd_last_result;         /* 最后 RPC 的结果 */
	__u32 lcd_last_data;
	/* MDS_CLOSE 请求单独一组 */
	__u64 lcd_last_close_transno, lcd_last_close_xid;
	__u32 lcd_last_close_result, lcd_last_close_data;
	/* VBR：前置版本 */
	__u64 lcd_pre_versions[4];
	__u32 lcd_last_epoch;
	__u32 lcd_generation;
};
```

两个作用：

1. **幂等性**：记录每个客户端最后一次操作的 xid 与结果。
   客户端重发时，服务端发现 xid 已处理，直接返回缓存的结果，不重复执行。
   这对 `mkdir`、`create`、`unlink` 这类非幂等操作是必需的。
2. **恢复起点**：重启后知道每个客户端做到哪了。

注意 **close 单独存一组字段**——因为 close 可以与其他操作乱序，
需要独立的幂等追踪。这是个很实际的细节：**非幂等操作的去重槽位
可能需要按操作类别分开**，单一"最后一次操作"记录不够。

CubeFS 的 `uniqChecker`（见 [CubeFS 调研](../cubefs/cubefs-metadata.md) §6）
解决同一问题。LightStore 的 MetaServer 也需要等价机制——
**Raft 保证了操作只被 apply 一次，但不能防止客户端因超时重发而提交两次**。

## 3. VBR：版本化恢复

这是 Lustre 恢复机制里最巧妙的部分。

### 问题

服务端崩溃后进入恢复窗口，等所有客户端重连并重放。但如果有个客户端
**永远不回来了**（节点也挂了、被换了），怎么办？

朴素做法是等超时后放弃恢复，把所有未提交操作丢掉——但其他客户端的操作
可能已经重放了一半，且这些操作之间可能有依赖。粗暴中止会造成不一致。

### VBR 的解法

**每个对象携带一个版本号 = 最后修改它的 transno**
（`lustre/target/tgt_lastrcvd.c:1531`）：

```c
dt_version_set(env, dto, tti->tti_transno, th);
```

客户端重放请求时，带上它**当时看到的前置版本** `lcd_pre_versions[4]`。
服务端检查：这个对象现在的版本，是不是就是客户端说的那个？

- **匹配** → 中间没有别人改过，重放安全，执行
- **不匹配** → 中间有别的操作（可能来自那个再也回不来的客户端），
  这次重放被拒绝，该客户端被驱逐，**但恢复继续进行**

于是恢复不再是"全有或全无"。缺失的操作造成的 transno 空洞可以被跳过
（`lustre/ldlm/ldlm_lib.c:2251`）：

```c
} else if (queue_len > 0 && queue_len == atomic_read(&obd->obd_req_replay_clients)) {
    /** handle gaps occured due to lost reply or VBR */
    ...
    obd->obd_next_recovery_transno = req_transno;   /* 跳过空洞，继续 */
    wake_up = 1;
}
```

**判断条件很讲究**：`queue_len == obd_req_replay_clients`——
所有还在重放的客户端都已经把请求排进队列了，队首的 transno 仍然大于期待值，
说明中间那个 transno 确实没人能提供，可以安全跳过。

### 对 LightStore 的价值

LightStore 用 Raft，不存在"等客户端重放"的恢复窗口，所以 VBR 不直接适用。

但**"版本号 = 最后修改的事务序号 + 前置版本校验"这个模式**在另一个场景直接可用：
**SDK 攒批提交 extent 索引的冲突检测**。

设想：SDK A 和 SDK B 同时写同一个文件的重叠区间，各自攒批后提交。
如果 CommitExtents 只是无条件覆盖，后到的赢——但"后到"由网络决定，不是由写入顺序决定。

带上前置版本可以让 MetaServer 检测到冲突：**提交时校验 inode 的
extent 索引版本是否仍是我读到的那个**，不是则拒绝并让 SDK 重新拉取后重试。
这是乐观并发控制，成本很低（一个 u64），能把"并发覆盖写导致的索引错乱"
从"无声损坏"变成"可检测的冲突"。

## 4. Grant：写缓冲的空间预留

`lustre/target/tgt_grant.c:11` 的文件头注释说得很清楚：

> Grant is a mechanism used by client nodes to reserve disk space on a target
> for the data writeback cache. The Lustre client is thus assured that enough
> space will be available when flushing dirty pages asynchronously.
> Each client node is granted an initial amount of reserved space at connect
> time and gets additional space back from target in bulk write reply.

### 它解决的问题

客户端 `write()` 返回成功后，数据还在客户端内存里（脏页），稍后才刷回。
如果刷回时 OST 满了——**应用已经认为写成功了，此时才报 ENOSPC，无处可报**。
POSIX 语义下这是数据丢失。

Grant 的解法：客户端在**接受脏页之前**必须先持有足够的 grant（预留额度）。
连接时拿到初始额度，之后每次批量写的回复里带回新额度。
额度不够时，客户端要么同步写、要么阻塞等额度。

注释里还有一段很实在的工程细节：服务端要为不同能力的客户端做额度**膨胀**——
块大小不是 4KB 的后端，客户端按 4KB 计算的额度要按块大小放大；
不支持 `OBD_CONNECT_GRANT_PARAM` 的老客户端一律膨胀 100%。
**预留必须按最坏情况算，而不是按理想情况。**

### 对 LightStore 的直接适用性 ★★★

这是本次调研中**最容易被忽略、但对 LightStore 最实际的一个点**。

LightStore 的 SDK 设计里有写缓冲（"每累计 64 MiB 或 Sync()/Close() 时批量提交"）。
这意味着同样的问题存在：**`write()` 返回后数据还在 SDK 内存里，
真正落卷时如果卷满了/集群满了怎么办？**

目前设计文档没有涉及这一点。可选方案：

1. **Grant 式预留**：SDK 从 Manager 或 DataServer 领取空间额度，
   额度不足时阻塞或降级为同写。语义最强，实现最复杂。
2. **写前分配**：`write()` 时就向 DataServer 预留卷内空间（不写数据），
   Sync 时才真正写入。折中方案。
3. **接受语义弱化**：明确文档化"只有 Sync/Close 返回成功才保证持久"，
   把问题推给应用。这是 JuiceFS/CubeFS 的实际做法。

**至少要显式做出选择并写进文档**，而不是默认第 3 种。
对于 POSIX 语义敏感的场景（数据库、需要 write() 成功即可信的应用），
第 3 种是会出事的。

## 5. LFSCK：在线一致性检查

`lustre/lfsck/`：在文件系统在线时扫描并修复不一致。

检查项：
- `lfsck_namespace.c`：dentry 与 inode 的对应、nlink 计数、孤儿目录
- `lfsck_layout.c`：MDT 的 layout EA 与 OST 对象的双向一致性
- `lfsck_striped_dir.c`：条带目录的完整性

**核心依赖是反向指针**：OST 对象的 `filter_fid.ff_parent` 记录了它属于哪个
MDT 对象的第几个条带（见 [总体架构](lustre-overview.md) §5）。
因此 LFSCK 可以：

- 扫 MDT → 检查每个 layout 引用的 OST 对象是否存在
- 扫 OST → 检查每个对象的 parent 是否还引用它，不引用的就是孤儿

**双向可验证，且每一边都是本地扫描，不需要全局 join。**

对照三个系统的孤儿数据清理：

| | 机制 | 规模特性 |
|---|------|---------|
| JuiceFS | `juicefs gc` 全量扫描对象存储比对元数据 | **O(全局)，EiB 级不可行** |
| CubeFS | ExtentKey 定向删除 + Master 侧比对 | O(局部)，但 Master 缓存 per-extent 状态 |
| Lustre | 反向指针 + 双向本地扫描 | **O(局部)，可并行** |
| LightStore | record 头部 `owner=(inode, file_offset)` + 卷内 compaction | **O(卷)，可并行** |

**LightStore 的方案与 Lustre 同源且更彻底**（回收在卷内闭环，
不需要独立的检查工具）。此处是印证。

## 6. Imperative Recovery：缩短恢复窗口

传统恢复：服务端重启后等一个固定的恢复窗口（`obd_recovery_time_hard`，
默认 `obd_timeout * 9`，`lustre/include/obd_support.h:77`），让客户端自己发现并重连。

Imperative Recovery：MGS 在 target 重启时**主动通知**所有客户端，
客户端立即重连，恢复窗口可以大幅缩短
（`lustre/target/tgt_mount.c:2686` 打印 "recovery window shrunk from %d-%d down to %d-%d"）。

**规律：靠超时发现故障永远是最慢的路径，能主动通知就主动通知。**
LightStore 的 Manager 已经在维护成员表和心跳，具备主动通知的条件——
Range 主切换、卷密封、DataServer 下线都应该走主动通知路径，
而不是让 SDK 靠 RPC 失败去发现。

---

上一篇：[数据布局](lustre-layout.md) ｜ 下一篇：[设计评估](lustre-analysis.md)
