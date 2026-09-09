# Lustre 调研（三）：数据布局与命名空间分布

> 基线：lustre-release commit `eadb94b`

Lustre 的布局系统是它 20 年演进中迭代最多的部分：从最初的固定条带，
到 PFL（渐进布局）、FLR（文件级冗余）、DoM（数据存 MDT）、SEL（自扩展布局），
最新还加了 EC 和压缩。这些都塞在**同一个 layout EA 结构**里，
因此它的演进方式本身就是一份很好的"可扩展元数据结构"教材。

## 1. 经典条带布局

最初的 LOV EA（`include/uapi/linux/lustre/lustre_user.h:928`）：

```c
struct lov_user_md_v1 {
	__u32 lmm_magic;
	__u32 lmm_pattern;        /* LOV_PATTERN_RAID0 等 */
	struct ost_id lmm_oi;
	__u32 lmm_stripe_size;    /* 条带大小，默认 1 MiB */
	__u16 lmm_stripe_count;   /* 条带数 */
	union { __u16 lmm_stripe_offset; __u16 lmm_layout_gen; };
	struct lov_user_ost_data_v1 lmm_objects[];  /* 每条带一个 OST 对象 */
};
```

文件按 `stripe_size` 轮转分布到 `stripe_count` 个 OST 上（RAID-0）。
`lmm_objects[]` 逐个记录每个条带对应的 OST 对象 FID 与 OST 索引。

**优点**：布局完全静态可推导——给定文件偏移，一次除法就知道落在哪个条带、
哪个 OST 对象、对象内偏移多少。**元数据是 O(stripe_count)，与文件大小无关**。
一个 100 TB 的文件和一个 1 MB 的文件，如果都是 8 条带，layout EA 一样大。

**这是与 JuiceFS/CubeFS 这类列表式索引最根本的模型差异**：

| | Lustre | 列表式索引（CubeFS 等） |
|---|--------|-------------------|
| 索引形态 | **公式**（条带映射） | **列表**（extent/Loc 数组） |
| 元数据量 | O(条带数)，与文件大小无关 | O(写入次数) |
| 空间分配 | 预先确定，写哪算哪 | 写时分配，位置随机 |
| 覆盖写 | **原地**（同一 OST 对象同一偏移） | 异地写 + 索引替换 |
| 碎片 | 无 | 有，需治理 |
| 灵活性 | 低（OST 满了很麻烦） | 高 |

Lustre 敢用公式，是因为它假定 OST 后面是 RAID，容量均衡由管理员保证，
且 HPC 场景文件数少、单文件大。**面向海量小文件的系统不适用这个模型**，
但它提醒了一件事：**当写入是纯顺序大块时，公式化索引能把元数据量压到近乎为零**。
采用 extent 列表式索引的系统可以借鉴这一点——见 [分析文档](lustre-analysis.md) §2.1。

## 2. 复合布局（PFL / FLR / EC 统一结构）

2017 年后，所有高级布局统一为**复合布局**（Composite Layout）：

```c
struct lov_comp_md_v1 {
	__u32	lcm_magic;
	__u32	lcm_size;
	__u32	lcm_layout_gen;
	__u16	lcm_flags;
	__u16	lcm_entry_count;
	__u16	lcm_mirror_count;   /* 实际镜像数 - 1，非 FLR 文件为 0 */
	__u8	lcm_ec_count;       /* EC 码组件数，非 EC 文件为 0 */
	...
	struct lov_comp_md_entry_v1 lcm_entries[];
};
```
（`include/uapi/linux/lustre/lustre_user.h:1164`）

每个 entry 描述一个**组件**（component）：

```c
struct lov_comp_md_entry_v1 {
	__u32			lcme_id;        /* 高 15 位是 mirror id，低 16 位是序号 */
	__u32			lcme_flags;
	struct lu_extent	lcme_extent;    /* 该组件覆盖的文件区间 */
	__u32			lcme_offset;    /* 组件 blob 在本结构内的偏移 */
	__u32			lcme_size;
	__u32			lcme_layout_gen;
	...
	__u8			lcme_dstripe_count;   /* EC 的 k */
	__u8			lcme_cstripe_count;   /* EC 的 p */
	__u8			lcme_compr_type;      /* 压缩类型 */
	__u8			lcme_compr_lvl:4;
	__u8			lcme_compr_chunk_lum_bits:4;
};
```
（`include/uapi/linux/lustre/lustre_user.h:1099`）

**一个结构同时表达了四个正交维度**：

| 维度 | 承载字段 |
|------|---------|
| 文件区间分段（PFL） | `lcme_extent` |
| 镜像（FLR） | `lcme_id` 高位的 mirror id + `lcm_mirror_count` |
| 纠删码 | `lcme_dstripe_count/cstripe_count` + `LCME_FL_PARITY` |
| 压缩 | `lcme_compr_*` |

### 2.1 PFL：渐进文件布局

问题：条带数该设多少？小文件设 1（避免分散），大文件设 64（要带宽）。
但创建时不知道文件会长多大。

PFL 的答案：**按区间分段设置不同条带数**。

```
[0, 1MiB)      → 1 条带    （小文件只用一个 OST）
[1MiB, 1GiB)   → 4 条带
[1GiB, EOF)    → 64 条带   （大文件全带宽）
```

组件是**延迟实例化**的（`LCME_FL_INIT` 标志）：文件只写了 100KB，
后两个组件根本不分配 OST 对象，不占空间。

**这解决了"一个策略适配所有文件大小"的问题，代价是布局结构复杂化。**
"写时按实际数据大小动态决定放置策略"（小文件打包、大文件独立存放）
本质是同一个问题的另一种解法——比 PFL 的预设区间更自适应，
但失去了"用户可显式指定"的能力。

### 2.2 SEL：自扩展布局

`LCME_FL_EXTENSION`（`include/uapi/linux/lustre/lustre_user.h:1017`）：
标记为"扩展组件"的段永不实例化，只作为占位——当前一个组件所在的 OST
快满了，就从扩展段切一块出来形成新组件。

**这是对"OST 空间不均衡"的补丁**：PFL 的固定区间遇到 OST 满了仍然会写失败。
SEL 让布局能在运行时按实际空间情况生长。

一个信号：**公式化布局在容量不均衡面前很脆弱**，Lustre 花了很多年不断打补丁
（PFL → SEL → OST pool → 空间均衡策略）。"写时选择存放位置"的模型天然回避了这类问题。

### 2.3 FLR：文件级冗余

```c
enum lov_comp_md_flags {
	LCM_FL_NONE		= 0x0,
	LCM_FL_RDONLY		= 0x1,   /* 所有镜像同步，文件只读 */
	LCM_FL_WRITE_PENDING	= 0x2,   /* 有写入，镜像即将不同步 */
	LCM_FL_SYNC_PENDING	= 0x3,   /* 需要重新同步 */
	...
};
```
（`include/uapi/linux/lustre/lustre_user.h:1154`）

FLR 是**延迟同步的镜像**，不是同步副本：

1. 文件初始状态 `RDONLY`，所有镜像一致
2. 有人要写 → 转 `WRITE_PENDING`，**其余镜像被标记 `LCME_FL_STALE`**
3. 只写主镜像
4. 事后由 `lfs mirror resync` 或后台任务重新同步 → 回到 `RDONLY`

**这不是透明的高可用**，而是"只读数据的多副本加速 + 手动管理的冗余"。
写入期间实际上只有一份数据。

对比 CubeFS 的 write-all 副本复制——**它提供的是真正的
写入时冗余，FLR 不是**。这是 Lustre 的历史包袱：它的可靠性模型建立在
"后端 RAID 不会丢数据"之上，FLR 是事后补的用户态特性。

**需要透明高可用的新系统不应该走 FLR 路线**，写入时同步复制
（副本或 EC）是更正确的选择。
FLR 唯一值得借鉴的是它的状态机（RDONLY / WRITE_PENDING / SYNC_PENDING）
和 `LCME_FL_PREF_RD` / `LCME_FL_PREF_WR` 标志——**允许把不同镜像标记为
读优选/写优选**，可用于把读流量导向 SSD 镜像、写流量导向 HDD 镜像。
做分级存储的系统可以借鉴这个标记方式。

### 2.4 DoM：Data on MDT

`LOV_PATTERN_MDT`（`include/uapi/linux/lustre/lustre_user.h:795`）：
把小文件的数据**直接存在 MDT 的 inode 里**，不分配任何 OST 对象。

配合 PFL 的典型用法：

```
[0, 64KiB)   → DoM       （小文件全部在 MDT，一次 RPC 拿到数据）
[64KiB, EOF) → 4 条带 OST（超过阈值的部分才落 OST）
```

收益：小文件读写从"MDT 拿 layout + OST 读数据"两次 RPC 降到一次。
`MDS_INODELOCK_DOM` 是专门为它加的锁位。

**这是 Lustre 对小文件性能的主要答案**，但它是把小文件负载压到 MDT 上——
而 MDT 通常是集群里最贵的资源（要求低延迟 SSD）。

对照：Haystack 式的小文件打包把小文件聚合存放在数据节点的卷里，
不占用元数据节点资源，只是多一次 IO。**在万亿级小文件的目标下，
打包方案明显更可扩展**——DoM 方案下 MDT 容量会成为瓶颈。

## 3. DNE：分布式命名空间

多 MDT 支持，两个阶段：

- **DNE1（远程目录）**：整个子目录放在另一个 MDT 上
- **DNE2（条带目录）**：**单个目录**的条目分散到多个 MDT

条带目录的元数据（`include/uapi/linux/lustre/lustre_idl.h:2354`）：

```c
struct lmv_mds_md_v1 {
	__u32 lmv_magic;
	__u32 lmv_stripe_count;
	__u32 lmv_master_mdt_index;
	__u32 lmv_hash_type;       /* 决定 name → stripe 的映射 */
	__u32 lmv_layout_version;  /* 每次布局变化递增（迁移、重条带、LFSCK）*/
	__u32 lmv_migrate_offset;  /* 迁移中：此偏移前的条带属于目标，之后属于源 */
	__u32 lmv_migrate_hash;
	...
};
```

哈希类型（`include/uapi/linux/lustre/lustre_user.h:1226`）：

```c
LMV_HASH_TYPE_ALL_CHARS = 1,  /* 字符简单求和 */
LMV_HASH_TYPE_FNV_1A_64 = 2,  /* 默认 */
LMV_HASH_TYPE_CRUSH     = 3,  /* 双重哈希，优化迁移 */
LMV_HASH_TYPE_CRUSH2    = 4,
```

**CRUSH 的引入是为了让"增加条带数"时只需迁移一部分条目**，
而不是像模哈希那样几乎全部重排。这与一致性哈希解决的是同一问题。

### 3.1 迁移是在线的、有中间状态的

`lmv_migrate_offset` 这个字段值得注意：目录扩容/迁移过程中，
**部分条带已在新位置、部分还在旧位置**，靠这个偏移分界。
查找时按条目哈希落在偏移前后决定去哪个 MDT 找。

**这是"在线重分片"的一种实现范式**：不用停写、不用双写，
只在元数据里记一个进度水位，读路径按水位路由。

任何做元数据分片分裂/合并/迁移的系统都面临同样问题。这个"水位分界 + 读路径双向路由"
的手法比"迁移期间锁住整个分片"要好得多，值得参考。

### 3.2 条带目录的代价

- **readdir 要合并多个 MDT 的结果**，且要维持一个全局有序的游标
  （Lustre 用哈希值作为 `readdir` 的 offset，跨 MDT 归并）
- **rename 跨条带**需要分布式事务
- 用户必须**显式创建**条带目录（`lfs mkdir -c N`），不是自动的

最后一条是关键：**Lustre 没有自动分裂**。目录大到影响性能时，
需要管理员手动重条带（`lfs migrate`）。

对面向万亿文件规模的系统，分片随容量与负载自动分裂、合并、迁移
是必须的：这一规模下不可能靠人工运维分片。但要注意 Lustre 不做自动分裂
可能有它的道理：自动分裂在高负载下触发，会进一步加剧负载。
自动分裂策略需要有**滞回与限流**，避免抖动。

## 4. 布局与锁的配合

`MDS_INODELOCK_LAYOUT` 单独占一个锁位（见 [LDLM 文档](lustre-ldlm.md) §5）。
客户端拿到 LAYOUT 读锁后可以长期缓存布局，因为布局几乎不变。

布局改变（PFL 组件实例化、FLR 重同步、迁移）时撤销 LAYOUT 锁，
所有客户端重新拉取。`lcm_layout_gen` 是版本号，
OST 对象的 `filter_fid.ff_layout_version` 会与之比对——
**版本不匹配的写入被 OST 拒绝**，防止持有旧布局的客户端写到已被迁走的对象上。

这是一套完整的"布局版本 fencing"，与 CubeFS 的 `vuid.epoch` 同源，
但作用在文件布局层而非卷层。

---

上一篇：[LDLM](lustre-ldlm.md) ｜ 下一篇：[恢复机制](lustre-recovery.md)
