# Lustre 调研（一）：总体架构

> 基线：lustre-release commit `eadb94b`（2026-07-13）

## 1. 定位与历史包袱

Lustre 是**内核态的并行文件系统**，为 HPC 设计：少量超大文件、极高聚合带宽、
成千上万个客户端同时读写同一个文件的不同区域。它的一切设计都服务于这个场景。

三个必须先说清的前提，否则后面的取舍看不懂：

1. **客户端是内核模块**，不是用户态库。它直接实现 Linux VFS 接口，
   因此可以（也必须）提供完整 POSIX 语义——应用无法区分它和本地文件系统。
2. **原生不做数据冗余**。Lustre 假定底层是硬件 RAID 或 ZFS。
   OST 挂了就是挂了，靠后端存储的可靠性兜底。FLR（文件级冗余）是 2018 年
   才加的，且是显式的、用户手动管理的镜像，不是透明副本。
3. **强一致靠分布式锁**，不是靠版本或时间戳。这是它与本次调研另两个系统
   最根本的分野，也是 [LDLM 文档](lustre-ldlm.md) 的主题。

## 2. 组件拓扑

```
       ┌────────────────────────────────────────────────────────┐
       │        客户端（内核模块，直接实现 VFS）                  │
       │  llite ── VFS 适配                                      │
       │   ├─ LMV ── 元数据逻辑卷（多 MDT 路由）→ MDC × N        │
       │   └─ LOV ── 对象逻辑卷（条带化）      → OSC × N        │
       │  LDLM 客户端（持锁、响应 AST）                          │
       └───────┬────────────────────────────┬───────────────────┘
               │ 元数据 RPC                  │ 数据 RPC（bulk）
       ┌───────▼────────┐          ┌────────▼─────────┐
       │  MDS / MDT     │          │   OSS / OST      │
       │  mdt→mdd→lod   │          │   ofd→osd        │
       │  →osd(ldiskfs/ │          │   (ldiskfs/ZFS)  │
       │     ZFS)       │          │                  │
       │  + LDLM 服务端  │          │  + LDLM 服务端    │
       └───────┬────────┘          └────────┬─────────┘
               └────────────┬───────────────┘
                            ▼
                    ┌───────────────┐
                    │   MGS / MGT   │  配置管理（不在 IO 路径）
                    └───────────────┘
                     全部通过 LNet 通信
```

| 缩写 | 全称 | 说明 |
|------|------|------|
| MGS/MGT | Management Server/Target | 集群配置注册与分发，不参与 IO |
| MDS/MDT | Metadata Server/Target | 命名空间与 inode，一个 MDS 可挂多个 MDT |
| OSS/OST | Object Storage Server/Target | 数据对象存储，一个 OSS 可挂多个 OST |
| LNet | Lustre Networking | 自研 RDMA 友好的网络层，支持 IB/TCP/OPA |
| LDLM | Lustre Distributed Lock Manager | 分布式锁 |

注意 **Server 与 Target 是分离的概念**：Target 是一个后端存储设备（一块盘/一个 pool），
Server 是承载它的进程/节点。一个 Target 可以在节点故障时被另一个节点接管（failover），
这是 Lustre 的高可用模型——**不是副本，是共享存储 + 主备接管**。

## 3. 代码结构

| 目录 | 行数 | 职责 |
|------|------|------|
| `lustre/ptlrpc` | ~60k | RPC 框架：请求/回复、bulk 传输、重连、重放 |
| `lustre/llite` | ~43k | VFS 层适配（Linux Lustre Lite） |
| `lustre/obdclass` | ~43k | 对象设备框架、lu_object 缓存、设备栈 |
| `lustre/mdt` | ~33k | MDT 服务端：请求处理、意图（intent）、锁 |
| `lustre/osd-ldiskfs` | ~29k | ldiskfs（改造版 ext4）后端 |
| `lustre/lod` | ~23k | Logical Object Device：MDT 侧的条带分配与 DNE |
| `lustre/ldlm` | ~21k | 分布式锁管理器 |
| `lustre/quota` | ~16k | 配额 |
| `lustre/mdd` | ~16k | Metadata Device：元数据语义层 |
| `lustre/osd-zfs` | ~15k | ZFS 后端 |
| `lustre/osc` / `lustre/lov` | ~15k / ~12k | 客户端对象层：缓存、条带映射 |
| `lustre/osp` | ~14k | Object Storage Proxy：MDT 访问 OST/其他 MDT |
| `lustre/ofd` | ~13k | OST 服务端 filter device |
| `lustre/mgs` / `lustre/mdc` | ~11k / ~10k | 配置服务 / 元数据客户端 |
| `lustre/lmv` | ~6k | 多 MDT 路由与条带目录 |
| `lustre/lfsck` | — | 在线一致性检查修复 |
| `lustre/ec` | — | 纠删码（较新） |
| `lnet` | — | 网络层（独立子树） |

**分层非常深**：一个元数据操作要穿过 `llite → lmv → mdc → ptlrpc → 网络 →
ptlrpc → mdt → mdd → lod → osd → ldiskfs`。这是 Lustre 可读性差的主要原因，
但也带来了后端可替换（ldiskfs / ZFS / 新增的 wbcfs）。

## 4. FID：全局唯一对象标识

```c
struct lu_fid {
	__u64 f_seq;   /* FID sequence，迁移单位：同一 sequence 的所有对象在同一服务器 */
	__u32 f_oid;   /* sequence 内编号 */
	__u32 f_ver;   /* 版本（快照用，当前未启用）*/
} __attribute__((packed));
```
（`include/uapi/linux/lustre/lustre_user.h:362`）

128 位，**永不复用**。注释里点明了关键设计：

> FID sequence. Sequence is a unit of migration: all files (objects)
> with FIDs from a given sequence are stored on the same server.

**路由靠 sequence，不靠哈希也不靠范围表。** 每个服务器从 SEQ 服务申请一段 sequence，
在本地分配 oid。客户端通过 **FLD（FID Location Database，`lustre/fld`）**
查询 `sequence → target` 的映射。FLD 表很小（O(sequence 数)，不是 O(文件数)），
可以完整缓存在客户端。

### 设计启示：ID 分段与位置解耦

"高位为分配段（按分片划拨），低位段内自增"是分布式文件系统分配 inode ID
的常见手法——**与 Lustre 的 seq + oid 是同一思路**：把 ID 空间切段发给各个分片，
段本身就编码了位置信息。

Lustre 多做了一步：把段（sequence）与位置的映射独立成 FLD 服务，
因此**段可以迁移**（改 FLD 映射即可），而 ID 不变。采用按 ID 段分片的新系统
若要支持分片分裂后 inode 不重编号，需要等价机制——尤其当分片分裂是按
key 范围切的时候，inode ID 的高位段与分片的对应关系在分裂后如何维持，
是设计早期就应明确的问题。

## 5. 文件 = MDT inode + OST 对象集合

```
MDT 上的 inode
  └─ layout EA（扩展属性，存 LOV EA）
       ├─ 条带大小 lmm_stripe_size
       ├─ 条带数   lmm_stripe_count
       └─ lmm_objects[]  每个条带对应一个 OST 对象的 FID + OST 索引
```
（`include/uapi/linux/lustre/lustre_user.h:928` 的 `lov_user_md_v1`）

**MDT 不存任何数据，只存"数据在哪"**。读一个文件：先向 MDT 拿 layout，
再直接向各个 OST 并发读——客户端与 OST 直连，MDS 不在数据路径上。

反向指针存在 OST 对象的 `filter_fid` 属性里
（`include/uapi/linux/lustre/lustre_user.h:444`）：

```c
struct filter_fid {
	struct lu_fid		ff_parent;       /* 父 MDT 对象的 FID，f_ver 复用为条带号 */
	struct ost_layout	ff_layout;
	__u32			ff_layout_version;
	__u32			ff_range;        /* 允许写入的 layout version 范围 */
};
```

**这个反向指针是 LFSCK 在线修复的基础**：扫描 OST 对象就能知道它属于谁，
不需要反查全局索引。在数据记录头部保存"所属文件 + 文件内偏移"这样的反向指针，
是可扩展一致性检查与垃圾回收的通用前提，此处是成熟系统的印证
（见 [恢复文档](lustre-recovery.md) §5）。

注意 `ff_layout_version` 和 `ff_range`：**OST 对象自己知道它属于哪个版本的 layout**，
写入时版本不匹配会被拒绝——这是针对 FLR/迁移场景的 fencing，
与 CubeFS 的 `vuid.epoch` 是同类机制。

## 6. 三条路线的对比

| 维度 | JuiceFS | CubeFS | Lustre |
|------|---------|--------|--------|
| 客户端 | 用户态胖客户端 | 用户态 SDK + FUSE | **内核模块** |
| 一致性 | close-to-open | TTL 弱一致 | **强 POSIX，锁驱动** |
| `stat` 正在写的文件 | 可能陈旧 | 可能陈旧 | **精确**（glimpse AST） |
| 多客户端写同一文件 | 无冲突检测 | 无冲突检测 | **extent lock 串行化** |
| 数据冗余 | 对象存储负责 | 副本 + EC | **后端 RAID + 主备接管** |
| 元数据分片 | 无 | inode ID 区间 | **FID sequence + FLD** |
| 空间保证 | 无 | 无 | **grant 预留** |
| 故障恢复 | 客户端重试 | 换址重写 | **transno 重放 + VBR** |

**Lustre 提供的语义强度是另外两个系统做不到的，代价是复杂度高一个量级。**
LDLM 两万行、ptlrpc 六万行，都是为这个语义强度付的账。

---

下一篇：[LDLM 分布式锁管理器](lustre-ldlm.md)
