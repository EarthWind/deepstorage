# Lustre 调研（二）：LDLM 分布式锁管理器

> 基线：lustre-release commit `eadb94b`

LDLM 是 Lustre 提供强 POSIX 语义的唯一机制。约 2 万行代码（`lustre/ldlm/`），
是理解 Lustre 的核心。它源自 VAX/VMS 的分布式锁管理器，概念在 1980 年代就定型了。

## 1. 基本模型

```
Namespace（每个 target 一个：MDT namespace、OST namespace）
  └─ Resource（一个被保护的对象，用 4×u64 的 res_id 标识）
       ├─ granted 队列    已授予的锁
       └─ waiting 队列    等待中的锁
```

`res_id` 是 `struct ldlm_res_id { __u64 name[4]; }`
（`include/uapi/linux/lustre/lustre_idl.h:2569`）——通常前两个字放 FID 的 seq/oid。

**锁由服务端授予、由客户端持有并缓存。** 关键在于：客户端拿到锁之后，
可以在锁的保护下**无限期地本地缓存数据和元数据**，不需要任何续约或轮询。
只有当别的客户端要拿冲突锁时，服务端才主动回调让它释放。

这是与 TTL 模型的根本区别：

| | TTL 模型（JuiceFS/CubeFS） | 锁模型（Lustre） |
|---|--------------------------|-----------------|
| 缓存有效性 | 到期即失效，无论有无变更 | 一直有效，直到被回调 |
| 无竞争场景 | 周期性重新验证（浪费） | **零开销** |
| 有竞争场景 | 最多陈旧一个 TTL | **立即一致** |
| 服务端状态 | 无 | **必须记住谁持有什么锁** |
| 客户端失联 | 自愈（TTL 到期） | **必须驱逐（evict），否则全局阻塞** |

最后一行是全部代价的来源，见第 6 节。

## 2. 九种锁模式与兼容矩阵

```
       NL  CR  CW  PR  PW  EX GROUP COS TXN
 NL     1   1   1   1   1   1   1   1   1
 CR     1   1   1   1   1   0   0   0   1
 CW     1   1   1   0   0   0   0   0   0
 PR     1   1   0   1   0   0   0   0   1
 PW     1   1   0   0   0   0   0   0   0
 EX     1   0   0   0   0   0   0   0   0
 GROUP  1   0   0   0   0   0   1   0   0
 COS    1   0   0   0   0   0   0   1   0
 TXN    1   1   0   1   0   0   0   0   1
```
（`lustre/include/lustre_dlm.h:135`，实现为 `lck_compat_array[]`，`lustre/ldlm/ldlm_lib.c:3466`）

| 模式 | 语义 | 典型用途 |
|------|------|---------|
| **EX** | 独占 | 创建文件前对父目录加 EX |
| **PW** | 保护写 | 客户端向 OST 请求写 |
| **PR** | 保护读 | 客户端向 OST 请求读；以执行方式打开文件 |
| **CW** | 并发写 | open 时 MDS 授予的写锁 |
| **CR** | 并发读 | 路径解析时对中间路径分量加的 inodebits 锁 |
| **NL** | 空 | 只占位、不保护，用于携带 LVB |
| **GROUP** | 组 | 同 group ID 的锁互相兼容（用于 SLURM 类作业协同） |
| **COS** | 提交共享 | 事务结束后 PW/EX 降级到此，见下 |
| **TXN** | 事务 | DNE 下未开启 COS 时的降级目标 |

### 为什么需要 CR/CW 这两个"并发"模式

关键在于**路径解析**。`open("/a/b/c/file")` 要遍历 a、b、c 三个目录。
如果对每个中间目录都加 PR 锁，那么任何人在 `/a` 下创建文件都会与所有
正在解析该路径的客户端冲突——`/` 和常用目录会成为全局热点。

CR 模式解决这个：**CR 与 CW 兼容**。解析路径拿 CR，创建文件拿 CW，
两者不冲突。只有真正要改这个目录项本身（rename、unlink 特定项）
才需要更强的模式。

**这是"锁模式细分"的价值**：不是简单的读写锁，而是按"我要保证什么"
精确划分。新系统若引入任何形式的分布式锁，这个矩阵值得作为起点，
而不是从读写锁开始演进。

### COS：Commit-on-Sharing

一个 Lustre 特有的巧思。问题背景：

事务提交到磁盘是异步的（为了性能）。若客户端 A 创建了文件，
客户端 B 立刻读到它并依赖它做了后续操作，而此时 A 的事务还没落盘——
服务器崩溃后 A 的操作丢了，B 的操作却在，出现**依赖倒挂**。

传统解法是每个事务都同步落盘，性能不可接受。COS 的解法是：

> 事务结束后，把持有的 PW/EX 锁**降级为 COS 模式**。
> COS 只与 NL 和 COS 兼容——也就是说，**只要没有第二个客户端来碰这个对象，
> 什么都不会发生**；一旦有人来拿冲突锁（说明发生了"共享"），
> 就先强制把前面的事务同步提交，再放行。

**只在真正发生跨客户端共享时才付同步落盘的代价。** 无共享的场景（HPC 的典型模式：
每个进程写自己的文件）零开销。

这个思路——**用锁冲突作为"需要加强保证"的触发信号**——非常值得借鉴，
详见 [分析文档](lustre-analysis.md) §2.3。

## 3. 三种 AST 回调

锁的生命周期由三个回调驱动（`lustre/include/lustre_dlm.h:988-1006`）：

```c
/** Lock completion handler pointer. Called when lock is granted. */
ldlm_completion_callback l_completion_ast;

/** 通知：有冲突锁在排队（一次）；或锁正在被取消（一次）*/
ldlm_blocking_callback   l_blocking_ast;

/** Glimpse handler：服务端向客户端索取 LVB 更新 */
ldlm_glimpse_callback    l_glimpse_ast;
```

### 3.1 Completion AST（CP）

锁被授予时调用。因为 enqueue 可能要排队等待，授予是异步的。

### 3.2 Blocking AST（BL）

**这是整个机制的关键。** 服务端发现新请求与某个已授予的锁冲突时，
向持锁的客户端发 BL AST：「有人要用，请释放」。

客户端收到后：
1. 把该锁保护范围内的脏数据刷回服务端
2. 丢弃对应的缓存
3. 释放锁

**注意方向：服务端主动调用客户端。** 这要求服务端保存每个客户端持有的每个锁，
且网络必须双向可达。这也是 Lustre 难以跨广域网、难以穿越 NAT 的原因。

### 3.3 Glimpse AST（GL）—— 解决"正在被写的文件有多大"

这是 Lustre 最优雅的机制之一，也是 JuiceFS/CubeFS 明确做不到的事。

场景：客户端 A 正在往文件尾部追加写，持有 `[0, EOF]` 的 PW 锁并在本地缓存脏数据。
客户端 B 执行 `stat()` 想知道文件多大。

- 让 B 读磁盘：不对，A 的数据还没落盘
- 让 A 释放锁：太粗暴，A 还在写，一次 stat 就打断一个正在跑的作业
- TTL 模型的做法：返回一个可能错的值

Lustre 的做法：服务端向 A 发 **Glimpse AST**——「不用释放锁，
只把你当前的文件大小/mtime 告诉我」。A 在回复里填入 **LVB（Lock Value Block）**：

```c
struct ost_lvb {
	__u64	lvb_size;
	__s64	lvb_mtime, lvb_atime, lvb_ctime;
	__u64	lvb_blocks;
	...
};
```
（`include/uapi/linux/lustre/lustre_idl.h:1568`）

服务端把 LVB 转给 B。**B 得到精确的文件大小，A 的写入完全不受打断。**

对任何采用"客户端写缓冲 + 异步提交元数据"的系统：`stat` 一个正在被写的文件，
客户端缓冲里的数据尚未反映到元数据中，返回的长度必然偏小。
如果目标场景包含"一边写一边有人监控进度"
（日志、训练 checkpoint、数据管道），这是个真实的语义缺口。
Glimpse 提供了一条不牺牲写性能的解法，但前提是要有回调通道。

## 4. Extent Lock：区间锁与乐观扩张

数据锁按**字节区间**授予（`lustre/ldlm/ldlm_extent.c`），用区间树管理。
这让多个客户端可以并发写同一个大文件的不同区域——HPC 的核心需求。

真正精妙的是**乐观扩张策略**（`lustre/ldlm/ldlm_extent.c:184` 的注释）：

> Return the maximum extent that:
> - contains the requested extent
> - does not overlap existing conflicting extents outside the requested one
>
> This allows clients to request a small required extent range, but if there
> is no contention on the lock the full lock can be granted to the client.
> This avoids the need for many smaller lock requests to be granted in the
> common (uncontended) case.

**客户端请求 `[4096, 8192)`，但如果这个文件没人竞争，服务端直接授予 `[0, EOF]`。**
后续所有写入都不再需要任何锁 RPC。

有竞争时自动收缩（`ldlm_extent_internal_policy_fixup`，`lustre/ldlm/ldlm_extent.c:137`）：

```c
if (conflicting > 32 && (req_mode == LCK_PW || req_mode == LCK_CW)) {
    if (req_end < req_start + LDLM_MAX_GROWN_EXTENT)
        new_ex->end = min(req_start + LDLM_MAX_GROWN_EXTENT, new_ex->end);
}
```

冲突锁超过 32 个时，扩张被限制在 `LDLM_MAX_GROWN_EXTENT` 内——
**从"贪心扩张"退化为"按需授予"**，避免在高竞争文件上反复授予-撤销大区间。

还有页对齐处理：授予的区间必须对齐到服务端页大小，
`否则一个服务端页可能被两把写锁覆盖`——这是正确性要求，不是优化。

### 这条设计规律值得单独提炼

> **乐观粗粒度 + 竞争时自动细化。**
> 默认按最粗的粒度授予（省 RPC），检测到竞争才退化到细粒度（保并发）。

这个模式对分布式存储的多个子问题都适用：空间分配、租约粒度、索引提交批次大小。
详见 [分析文档](lustre-analysis.md) §2.2。

## 5. Inodebits Lock：元数据锁的位拆分

元数据锁不是"一个 inode 一把锁"，而是按**用途拆成独立的位**
（`include/uapi/linux/lustre/lustre_idl.h:981`）：

| 位 | 保护内容 |
|----|---------|
| `MDS_INODELOCK_LOOKUP` | 命名空间、dentry |
| `MDS_INODELOCK_UPDATE` | size、links、timestamps |
| `MDS_INODELOCK_OPEN` | 打开状态 |
| `MDS_INODELOCK_LAYOUT` | 布局（条带信息） |
| `MDS_INODELOCK_PERM` | 权限 |
| `MDS_INODELOCK_XATTR` | 非权限扩展属性 |
| `MDS_INODELOCK_DOM` | Data-on-MDT 的数据 |

一个客户端可以持有某个 inode 的 `LOOKUP|PERM` 读锁（用于路径解析和权限检查），
同时另一个客户端持有 `UPDATE` 写锁（正在改大小和时间戳）——**互不冲突**。

如果只有一把 inode 锁，那么任何一个客户端写文件（改 size/mtime）
都会撤销所有其他客户端对该文件的路径解析缓存。对于 `/` 或热点目录，
这是灾难性的。

**LAYOUT 位单独拆出来尤其重要**：布局几乎从不改变（只在 PFL 实例化、
FLR 重同步、迁移时才改），所以 LAYOUT 读锁可以被所有客户端长期持有，
零撤销。而 size/mtime 变化频繁，走 UPDATE 位，不影响 LAYOUT。

**设计启示**：如果引入任何客户端元数据缓存的失效机制，
不要用 inode 粒度。至少要区分：
- **不变/罕变部分**（数据位置索引、权限）——可长期缓存
- **高频变化部分**（size、mtime）——短周期或按需获取

否则会出现"写一次文件，全集群的路径缓存全失效"。

## 6. 代价：客户端驱逐（Eviction）

锁模型的致命弱点：**服务端等一个 BL AST 的响应时，是阻塞的**。

如果持锁的客户端网络断了、卡死了、或者干脆挂了，服务端等不到响应，
所有排队等这把锁的其他客户端都被卡住。

Lustre 的唯一解法是**驱逐**：超时后服务端单方面宣布该客户端失效，
强制回收它的所有锁。被驱逐的客户端上，所有未刷回的脏数据**直接丢弃**，
正在进行的 IO 返回 EIO，应用可能崩溃。

这是 Lustre 运维的头号痛点。生产集群里 "client eviction" 是最常见的故障告警，
根因可能是网络抖动、客户端内存压力、慢盘——任何让客户端来不及响应 AST 的东西。

**一个慢客户端可以拖垮整个集群的某个热点文件/目录。**

对照 TTL 模型：客户端失联是自愈的，最坏情况是缓存陈旧一个 TTL，
没有任何全局影响。这就是 JuiceFS/CubeFS 选择弱一致的真正原因——
**不是做不到强一致，是不愿意承担驱逐机制带来的可用性耦合。**

### 缓解手段

- `ldlm_pool.c`（1464 行）：动态调整每个 namespace 的锁数量上限（SLV，
  Server Lock Volume），在服务端内存压力下主动收缩客户端锁配额
- `ldlm_reclaim.c`：锁数量超限时主动回收
- 客户端侧 LRU：主动释放长期不用的锁，减少被 BL AST 打扰的概率

这三个文件的存在本身说明：**锁的数量管理是个持续的工程负担**。
服务端必须为每个客户端持有的每把锁分配内存，锁数量随
「客户端数 × 活跃文件数」增长，需要专门的配额与回收子系统。

---

上一篇：[总体架构](lustre-overview.md) ｜ 下一篇：[数据布局](lustre-layout.md)
