# 分布式文件系统元数据扩展性与性能：论文调研（2020 年以后）

> 调研日期：2026-08-15
>
> 范围说明：本文调研 2020 年（含）之后发表于系统领域主要会议（FAST / OSDI / SOSP / ATC / EuroSys / ASPLOS / NSDI / SoCC 等）的、聚焦分布式文件系统（Distributed File System, DFS）元数据（metadata）扩展性与性能的学术论文。所有论文均通过 Web 搜索逐篇核实其真实存在、发表会议与年份；不确定之处显式标注"待确认"。调研目的：为分布式文件系统元数据服务的设计提供参考。

---

## 1. 问题综述：DFS 元数据面临的共性挑战

现代数据中心的 DFS 需要管理百亿甚至千亿级文件。多篇论文（InfiniFS、CFS、Mantle 等）的动机部分指出，元数据操作可占全部文件系统操作的约 50%–80%，元数据服务（Metadata Service, MDS）位于几乎所有请求的关键路径上，是 DFS 整体扩展性的第一瓶颈。共性挑战可归纳为五类：

### 1.1 Namespace 分区（partitioning）

层级目录树天然带有父子依赖，任何分区方式都在两个目标间权衡：

- **局部性（locality）**：子树分区（subtree partitioning，如 CephFS 动态子树）保留目录局部性，`readdir`、同目录操作代价低，但易负载倾斜；
- **负载均衡（load balancing）**：hash 分区（如 Tectonic 按 directory/file ID hash）均衡负载，但破坏局部性，路径解析与 `readdir` 需要跨分片多次交互。

2020 年后的主流思路是**解耦（decoupling）**：把 inode 元数据拆成不同职责的部分（access metadata / content metadata、attributes / namespace hierarchy、目录语义 / 索引结构），对不同部分采用不同的分区与索引策略（InfiniFS、CFS、Mantle、HMFS）。

### 1.2 路径解析（path resolution / lookup）

POSIX 语义要求逐级检查路径上每一级目录的存在性与权限。在分布式分区下，一次 `open("/a/b/c/f")` 可能触发 N 次跨网络 lookup（N 为路径深度）。优化方向：

- 客户端路径/目录项缓存（IndexFS 谱系；一致性维护是代价）；
- 推测式并行解析（InfiniFS 的 speculative path resolution）；
- 服务端解析 + namespace 复制到所有元数据节点（FalconFS 的 lazy namespace replication）；
- 单 RPC lookup 的专用索引节点（Mantle 的 IndexNode）；
- 网内（in-network）缓存/协调（Fletch/FMCache、SwitchFS，见后）。

### 1.3 rename 与跨目录原子性

`rename` 是元数据设计的"试金石"：跨目录 rename 涉及两个（可能位于不同分片的）目录项，且目录 rename 还要防止环（loop，即把祖先目录移入其后代）。分布式事务（2PC）可以解决，但代价高且与热点耦合。各论文的做法差异很大：单独的 rename service（CFS）、把环检测 offload 到集中组件（Mantle 的 IndexNode）、依赖底层事务 KV/DB（Tectonic、FileScale、HopsFS 谱系）、或干脆用单元数据服务器回避分布式事务（SingularFS）。

### 1.4 热点（hotspot）

近根目录（near-root）的目录元数据被几乎所有路径解析访问；训练类负载会对单个目录产生高并发 create/stat。缓解手段：客户端乐观缓存 + 版本失效（InfiniFS）、目录项 delta/out-of-place 更新减少锁冲突（Mantle、CFS 的 delta apply）、层级并发控制与原子指令更新目录时间戳（SingularFS）、异步化目录更新（SwitchFS）。

### 1.5 扩容与弹性（scaling & elasticity）

负载具有潮汐性。静态分区在扩缩容时需要迁移元数据并中断服务；λFS 用 serverless 函数把 MDS 做成按需弹性；FileScale 用三层缓存 + 分布式数据库使小规模时性能接近单机、大规模时线性扩展。此外，元数据持久化的 I/O 效率（一次操作写多少次 SSD/PM）也成为新焦点（MesaFS）。

### 1.6 挑战与论文的对应关系

| 挑战 | 代表性论文（本文覆盖） |
|---|---|
| namespace 分区（局部性 vs 均衡） | Tectonic、InfiniFS、CFS、FalconFS |
| 路径解析延迟 | InfiniFS、Mantle、FalconFS、Fletch/FMCache |
| rename / 跨目录原子性 | CFS、Mantle、Tectonic（取舍）、FileScale |
| 目录热点 / 争用 | InfiniFS、SingularFS、Mantle、SwitchFS |
| 弹性扩缩容 | λFS、FileScale、Tectonic |
| 持久化 I/O 效率 / 存储引擎 | MesaFS、HMFS、SingularFS、FalconFS |

### 1.7 2020 年以来的演进脉络

粗略可分为四条并行路线：

1. **"下沉到事务存储"路线**（Tectonic 2021 → λFS 2023 → FileScale 2023，工业上还有 3FS/FoundationDB）：元数据服务无状态化，把分区、事务、复制全部交给成熟的分片 KV / 分布式数据库。工程确定性最高，天花板取决于底层数据库。
2. **"精细解耦 + 裁剪临界区"路线**（InfiniFS 2022 → CFS 2023 → Mantle 2025 → HMFS 2025）：不依赖通用分布式事务，通过元数据拆分、布局聚合、集中式轻量索引，把常见操作压成单分片/单 RPC。学术性能最强，复杂度也最高。
3. **"新硬件纵向扩展"路线**（SingularFS 2023 → MesaFS 2026，含 HMFS 的 PM 部分）：用 PM/RDMA/NVMe 把单机 MDS 推到十亿级，回避分布式问题；关注点从"怎么分"转为"单机引擎的每操作 I/O 次数"。
4. **"负载特化与网内协同"路线**（FalconFS 2026、SwitchFS 2026、Fletch）：针对 AI 训练等特定负载重排职责（服务端解析、异步目录更新），或借助可编程交换机做协调/缓存。

---

## 2. 论文详解

### 2.1 Tectonic: Facebook's Tectonic Filesystem: Efficiency from Exascale（FAST 2021）

- **作者/机构**：Satadru Pan 等，Facebook（现 Meta）
- **会议/年份**：USENIX FAST 2021
- **链接**：https://www.usenix.org/conference/fast21/presentation/pan
- **解决的问题**：Meta 内部多个 EB 级存储租户（blob storage、数据仓库）各自维护专用存储系统导致资源碎片化；需要单一 EB 级文件系统支撑多租户，元数据必须水平扩展。
- **核心设计**：
  - **namespace 划分**：元数据整体架构为"无状态元数据服务 + 事务性分片 KV 存储（ZippyDB）"。元数据分为三层：Name 层（目录→子项映射，按 directory ID hash 分区）、File 层（文件→block，按 file ID hash 分区）、Block 层（block→chunk 位置，按 block ID hash 分区）。**hash 分区**有效避免近根热点。
  - **路径解析**：逐级 lookup；由于 Name 层按目录 ID hash，同一目录的目录项在同一分片，`readdir` 单分片完成。
  - **事务/一致性**：依赖 ZippyDB 分片内事务；**不提供跨分片原子操作**——跨目录 rename 等跨分片操作不保证原子性（论文明确将其列为取舍）。
  - **存储引擎**：ZippyDB（线性一致、容错、分片 KV，底层 RocksDB）。
- **关键实验结果**：生产环境单集群管理 EB 级数据、数十亿文件，支撑 blob 与数仓两类租户的混合负载。
- **局限性**：放弃部分 POSIX 语义（跨分片原子 rename、递归属性）；逐级路径解析延迟随深度增长。
- **设计启示**：分层（name/file/block 三张表）+ 按各自 ID hash 分区是工业界验证过的可扩展底座；"元数据服务无状态、状态全部下沉到事务 KV"的模式使扩容与故障恢复大为简化。若不要求严格 POSIX rename，可采用同款取舍。

### 2.2 InfiniFS: An Efficient Metadata Service for Large-Scale Distributed Filesystems（FAST 2022）

- **作者/机构**：Wenhao Lv、Youyou Lu、Yiming Zhang、Peile Duan、Jiwu Shu，清华大学（合作单位含厦门大学/阿里巴巴，待确认）
- **会议/年份**：USENIX FAST 2022
- **链接**：https://www.usenix.org/conference/fast22/presentation/lv （PDF: https://www.usenix.org/system/files/fast22-lv.pdf）
- **解决的问题**：百亿～千亿文件规模下，目录树分区的局部性/均衡矛盾、路径解析长链延迟、近根热点三大问题。
- **核心设计**：
  - **namespace 划分**：把目录 inode 拆为 **access metadata**（name、ID、权限，用于路径解析）与 **content metadata**（entry list、timestamps）。access metadata 与父目录同分区（保证解析局部性），content metadata 与子项同分区（保证目录操作局部性）；以目录为粒度 hash 分组，兼顾局部性与均衡。
  - **路径解析**：**speculative path resolution**——利用"目录 ID 可由 (父 ID, name) 可预测生成"的设计，客户端并行地推测各级目录 ID 并发起并行 lookup，把 O(N) 串行往返压成近似 O(1)，失败时回退逐级解析。
  - **热点**：客户端 **optimistic access metadata cache**，用版本机制惰性失效，缓解近根热点。
  - **事务/一致性**：rename 与跨分片修改通过分布式事务处理（较重，是后续 CFS 攻击点）。
  - **存储引擎**：分片 KV 存储（论文实现基于内存 KV + RocksDB 持久化，细节待确认）。
- **关键实验结果**：吞吐较 HopsFS 高 73×、较 CephFS 高 23×；目录树规模达 **1000 亿文件**仍保持稳定性能与近线性扩展。
- **局限性**：推测解析依赖 ID 生成规则，rename/迁移后推测失败率上升；跨分片操作仍需分布式事务；客户端缓存失效协议增加复杂度。
- **设计启示**：access/content 元数据解耦是元数据服务表结构设计的高价值模式：inode 表可拆为 `dentry(parent_id, name) -> {id, mode, uid...}` 与 `dir_content(id) -> ...` 两类 KV，分别按 parent_id 和自身 id 分区。可预测目录 ID + 客户端并行 lookup 能显著降低深路径 open 延迟。

### 2.3 CFS: Scaling Metadata Service for Distributed File System via Pruned Scope of Critical Sections（EuroSys 2023）

- **作者/机构**：Yiduo Wang、Yufei Wu、Cheng Li、Pengfei Zheng、Biao Cao、Yan Sun 等，中国科学技术大学 + 百度（Baidu CFS 团队；作者名单较长，以 DL 页为准）
- **会议/年份**：ACM EuroSys 2023
- **链接**：https://dl.acm.org/doi/10.1145/3552326.3587443 ；背景文章：https://cloud.baidu.com/article/320331
- **解决的问题**：分布式元数据的锁/临界区与分布式事务开销是扩展瓶颈；目标是千亿文件规模、完整 POSIX 语义。
- **核心设计**：
  - **namespace 划分**：**tiered metadata organization（分层元数据组织）**——文件属性（attributes）与其余 namespace 层级结构分开扩展：namespace 层级存入分布式表格系统 **TafDB**（按目录聚合布局），文件属性下沉到 FileStore 与数据一起管理；另设独立 **Rename Service** 处理复杂 rename。
  - **临界区裁剪**：通过数据布局把关联修改聚合到**单个分片**，将跨分片分布式事务简化为**单分片事务**；实现三种定制单分片事务原语，把多轮交互压缩为一次；属性更新冲突用 delta apply / last-writer-wins 自动合并，避免加锁。
  - **路径解析**：目录聚合布局下逐级解析，单级 lookup 单分片完成（客户端缓存细节待确认）。
  - **存储引擎**：TafDB（百度自研分布式表格存储）+ FileStore。
- **关键实验结果**：50 节点集群上，吞吐较 HopsFS 提升 **1.76–75.82×**，较 InfiniFS 提升 **1.22–4.10×**；平均延迟分别降低 91.71% 与 54.54%。生产目标规模为千亿级文件（百度沧海 CFS）。
- **局限性**：复杂 rename 走独立慢路径服务；架构与特定表格系统（TafDB）深度耦合；跨层（TafDB/FileStore）一致性协议复杂。
- **设计启示**：元数据服务的第一性原则应是"**让常见元数据操作落在单分片**"：通过布局（按目录聚合 + 属性与 dentry 分离）把 create/unlink/stat 变成单分片事务，只为 rename 保留昂贵路径。这比引入通用分布式事务框架代价小得多。

### 2.4 SingularFS: A Billion-Scale Distributed File System Using a Single Metadata Server（USENIX ATC 2023）

- **作者/机构**：Hao Guo、Youyou Lu、Wenhao Lv、Xiaojian Liao、Shaoxun Zeng、Jiwu Shu，清华大学
- **会议/年份**：USENIX ATC 2023（pp. 915–928）
- **链接**：https://www.usenix.org/conference/atc23/presentation/guo （PDF: https://www.usenix.org/system/files/atc23-guo.pdf）
- **解决的问题**：反向思路——与其分布式扩展，不如用新硬件（持久内存 PM + RDMA）把**单台元数据服务器**的性能推到十亿级文件规模，从根本上回避分布式事务与分区问题。
- **核心设计**：
  - **log-free metadata operations**：利用 PM 的 8 字节原子写与操作排序，使大多数元数据操作无需 journal/log 即可崩溃一致，消除写放大。
  - **hierarchical concurrency control**：按"目录 inode / 子项"层级设计并发控制，目录 timestamp 等共享字段用原子指令更新，最大化同目录并发（如高并发 create）。
  - **hybrid inode partition**：在服务器内部（多核/NUMA 间）混合划分 inode 以均衡负载（细节待确认）。
  - **存储引擎**：NVMM（Intel Optane PM）上的自研内存结构，RDMA 网络。
- **关键实验结果**：单 MDS 支撑 **10 亿级文件**；吞吐显著超过多节点部署的分布式 MDS 基线（具体倍数待确认，论文摘要称大幅优于现有系统）。
- **局限性**：容量与吞吐终有单机上限；依赖 Optane PM（已停产，需以 CXL 内存/高速 NVMe 替代验证）；单点容错依赖主备复制。
- **设计启示**：若目标规模 ≤ 数十亿文件，"单个高性能元数据服务器 + 主备复制"可能比分布式元数据简单一个数量级。log-free + 层级并发控制的思想在 DRAM+NVMe 组合下同样适用：能用原子指令/单点顺序写解决的，不要用锁和 journal。

### 2.5 λFS: A Scalable and Elastic Distributed File System Metadata Service using Serverless Functions（ASPLOS 2023）

- **作者/机构**：Benjamin Carver、Runzhou Han、Jingyuan Zhang、Mai Zheng、Yue Cheng；George Mason University、Iowa State University、University of Virginia（分工待确认）
- **会议/年份**：ACM ASPLOS 2023（Volume 4）
- **链接**：https://dl.acm.org/doi/10.1145/3623278.3624765 ；arXiv: https://arxiv.org/abs/2306.11877 ；代码：https://github.com/ds2-lab/LambdaFS
- **解决的问题**："serverful" MDS 要么不可扩展，要么难以同时兼顾性能、资源利用率与成本；面对潮汐负载无法快速弹性伸缩。
- **核心设计**：
  - 基于 **HopsFS**（NameNode 状态外置到 NDB/NewSQL 的 HDFS 变体）改造：把 NameNode 逻辑拆成**大规模并行的 serverless 函数**（OpenWhisk/Nuclio 平台），函数内缓存元数据、按负载自动增缩。
  - **namespace 划分**：按（目录）一致性 hash 把元数据操作路由到函数实例，实例内维护缓存亲和性。
  - **事务/一致性**：底层仍由 NewSQL 数据库（MySQL NDB）承担事务与持久化；函数层为缓存/计算层。
  - **存储引擎**：MySQL NDB Cluster（继承自 HopsFS）。
- **关键实验结果**：在真实与合成负载下显著优于 HopsFS（尖峰负载下延迟与成本均优；具体倍数随负载而异，详见论文），弹性伸缩无需人工扩容。
- **局限性**：serverless 平台冷启动与调用开销；依赖外部数据库的事务吞吐上限；工程栈（Java/OpenWhisk）与传统 C++ 存储栈差异大。
- **设计启示**："元数据 = 无状态计算层 + 有状态存储层"的分层让弹性成为配置问题而非架构问题。即使不用 FaaS，也可让元数据服务进程无状态化（缓存 + 路由），把持久状态收敛到复制状态机/KV 层，从而支持元数据节点快速增删。

### 2.6 FileScale: Fast and Elastic Metadata Management for Distributed File Systems（SoCC 2023）

- **作者/机构**：Gang Liao、Daniel J. Abadi，University of Maryland
- **会议/年份**：ACM SoCC 2023
- **链接**：https://dl.acm.org/doi/10.1145/3620678.3624784 ；PDF: http://www.cs.umd.edu/~abadi/papers/filescale.pdf ；代码：https://github.com/umd-dslam/FileScale
- **解决的问题**：用分布式数据库（DDBMS）存元数据可以扩展（HopsFS/CalvinFS 路线），但在小规模部署时比单机内存 NameNode 慢一个数量级——扩展性与小规模性能不可兼得。
- **核心设计**：
  - **三层架构（three-tier）**：在 HDFS 上实现——内存缓存层（保持单机快路径）→ 中间层 → shared-nothing DDBMS 持久层；小规模时请求几乎全部命中内存层，性能接近原生 NameNode；规模增长时由 DDBMS 水平扩展。
  - **事务/一致性**：跨分区操作（如 rename）由 DDBMS 的分布式事务保证 ACID。
  - **存储引擎**：shared-nothing 分布式数据库（基于确定性数据库技术，Abadi 团队 Calvin 谱系，具体实现待确认）。
- **关键实验结果**：小规模下与单机 HDFS NameNode 性能相当；元数据规模增长时呈线性扩展。
- **局限性**：三层缓存一致性协议复杂；写多负载下内存层收益下降；基于 Java/HDFS 生态。
- **设计启示**：多数新系统从小集群起步——"小规模不为扩展性交税"值得作为元数据服务的显式设计目标：单节点内存快路径 + 可插拔的分布式持久层，规模化时平滑切换，而不是一开始就承担分布式事务开销。

### 2.7 Mantle: Efficient Hierarchical Metadata Management for Cloud Object Storage Services（SOSP 2025）

- **作者/机构**：Qiang Li（?）、Yiduo Wang、Cheng Li 等，中国科学技术大学 + 百度 + 清华大学等（完整名单待确认，以 DL 页为准）
- **会议/年份**：ACM SOSP 2025
- **链接**：https://dl.acm.org/doi/10.1145/3731569.3764824 ；PDF: https://madsys.cs.tsinghua.edu.cn/publication/mantle-efficient-hierarchical-metadata-management-for-cloud-object-storage-services/SOSP25-Li.pdf
- **解决的问题**：对象存储（BOS）上提供层级 namespace（供大数据/AI 以文件系统语义访问对象），要求单 namespace 百亿对象、高并发目录更新、跨目录 rename 防环。
- **核心设计**：
  - **两层架构**：共享的分片数据库 **TafDB**（保存完整元数据，可横向扩展）+ 每 namespace 一个单机 **IndexNode**（仅保存每目录约 80 字节的关键目录元数据，用于高效 lookup 与跨目录协调）。
  - **路径解析**：IndexNode 内存中完成整条路径解析，实现**单 RPC lookup**。
  - **热点/rename**：TafDB 中目录项采用 **out-of-place delta 更新**降低高争用目录的冲突；跨目录 rename 的**环检测 offload 到 IndexNode**（集中式防环，避免分布式协议）。
  - **存储引擎**：TafDB（与 CFS 同源的百度分布式表格系统）。
- **关键实验结果**：单 namespace 支撑 **100 亿对象/目录**；lookup 达 **180 万 ops/s**；高争用下 5.8 万目录更新/s；相比 Tectonic/InfiniFS/LocoFS 的元数据服务，延迟降低 6.6%–99.1%，吞吐提升 0.07–115×；在百度 BOS 生产环境部署超过 2 年。
- **局限性**：IndexNode 是每 namespace 的集中组件（容量与故障域受限，靠"只存 80B/目录"缓解）；两层间一致性维护复杂。
- **设计启示**："**大而全的分片存储 + 小而热的集中索引**"是极实用的混合架构：可让一个轻量 index 组件仅缓存目录骨架（id、parent、name、权限），承担路径解析与 rename 防环，元数据分片只处理平坦化的 inode/dentry 读写。目录骨架极小（百亿目录 ≈ 数百 GB，亿级目录 ≈ 数 GB），单机可承载。

### 2.8 HMFS: Accelerating Distributed Filesystem Metadata Service via Decoupling Directory Semantics from Metadata Indexing（SoCC 2025）

- **作者/机构**：Wenhao Lv、Hao Guo、Qing Wang、Youyou Lu、Jiwu Shu，清华大学
- **会议/年份**：ACM SoCC 2025
- **链接**：https://dl.acm.org/doi/10.1145/3772052.3772237
- **解决的问题**：现有元数据服务普遍依赖**有序索引**（如 LSM/B+ 树按 key 排序以支持 readdir 范围扫描），在高速网络 + persistent memory 时代，维护有序性的开销成为性能上限。
- **核心设计**：
  - **index-decoupled metadata organization**：用**无序索引**（hash）存元数据对象，目录语义（readdir 的遍历顺序）改由对象间的**直接链接（inter-object links）**维护——即目录项之间自组织成链，而不靠索引排序。
  - **lightweight crash-consistent updates**：两套独立结构（索引 + 链接）的一致更新协议，轻量崩溃一致。
  - **parallel directory listing**：沿链接并行遍历，加速大目录 readdir。
- **关键实验结果**：显著超越基于有序索引的元数据服务（具体倍数待确认，需查论文正文）。
- **局限性**：链接结构使范围/前缀查询之外的语义（如按序分页 readdir）需要额外设计；PM 依赖同 SingularFS。
- **设计启示**：元数据存储引擎选型不必默认 RocksDB/LSM："readdir 需要有序性"这一假设可以被打破——hash 索引 + 目录内链表（或分桶）既降低写放大又保留遍历能力。若使用 RocksDB，至少应把"目录扫描"与"点查"分开建模，避免为点查负载支付排序成本。

### 2.9 FalconFS: Distributed File System for Large-Scale Deep Learning Pipeline（NSDI 2026）

- **作者/机构**：Jingwei Xu、Junbin Kang、Mingkai Dong、…、Haibo Chen 等 13 人，华为 + 上海交通大学 IPADS（分工待确认）
- **会议/年份**：USENIX NSDI 2026（arXiv 2025 预印）
- **链接**：https://www.usenix.org/conference/nsdi26/presentation/xu ；arXiv: https://arxiv.org/abs/2507.10367 （已开源）
- **解决的问题**：深度学习流水线以海量小文件 + 巨量客户端为特征，客户端元数据缓存既低效（工作集太大、命中率低）又浪费训练节点内存。
- **核心设计**：
  - **stateless client**：客户端不做元数据缓存，路径解析全部在服务端完成。
  - **hybrid metadata indexing**：文件名 hash 分区到元数据节点（点查一跳直达），目录元数据集中/复制管理。
  - **lazy namespace replication**：目录 namespace 惰性复制到所有元数据节点，使每个 MNode 都能本地完成路径解析；目录变更惰性失效。
  - **concurrent request merging**：合并并发请求提升服务端吞吐；VFS shortcut 简化部署。
  - **存储引擎**：MNode = 定制扩展的 **PostgreSQL**（复用其表/事务/B-link 树/WAL/主备复制）。
- **关键实验结果**：对比 CephFS/Lustre，小文件读写吞吐最高 **5.72×**，模型训练吞吐最高 **12.81×**；在华为自动驾驶生产环境（**10,000 NPU**）稳定运行一年。
- **局限性**：面向"目录数远小于文件数"的 AI 负载假设；namespace 复制在目录频繁变更的通用负载下失效开销大；rename 语义细节待确认。
- **设计启示**：若目标场景含 AI 训练（海量小文件、超多客户端），"服务端解析 + 目录树全复制 + 文件按名 hash"是经生产验证的组合；且"用成熟单机数据库（PostgreSQL/RocksDB）当分片引擎"能省去自研存储引擎的大量工程量。

### 2.10 MesaFS: An I/O-Efficient Metadata Service for Distributed File Systems（EuroSys 2026）

- **作者/机构**：Hao Guo、Jiwu Shu、Youyou Lu，清华大学
- **会议/年份**：ACM EuroSys 2026
- **链接**：https://dl.acm.org/doi/10.1145/3767295.3803573
- **解决的问题**：元数据服务的持久化 I/O 效率——现有系统一次元数据更新往往触发多次 SSD 写（journal、索引、有序性维护），SSD 带宽利用率仅 8%–37%。
- **核心设计**：
  - **invariant-aware ordered updates**：把一次元数据更新拆分后允许**部分完成**——只要目录不变式（invariants）最终满足或可在崩溃恢复时修复，即可省去为原子性追加的额外写，使多数元数据更新**只需一次 SSD 写**。
  - **semi-ordered metadata layout**：半有序布局，避免为维护全序而产生的搬移/合并写放大。
- **关键实验结果**：达到裸 SSD 性能的 **62.0%–95.1%**（对比：按 InfiniFS 方案模拟仅 8.4%–37.2%）。
- **局限性**：崩溃恢复逻辑更复杂（需修复不变式）；面向 SSD 单机引擎层，不解决分区/rename 等分布式问题。
- **设计启示**：元数据落盘路径的写放大值得量化：如果使用 RocksDB，一次 create 实际写了 WAL + memtable flush + compaction 多份。可借鉴"以不变式而非全量原子性为目标"的思路设计精简 journal，或按 MesaFS 方式定制半有序布局。

### 2.11 SwitchFS: Asynchronous Metadata Updates for Distributed Filesystems with In-Network Coordination（EuroSys 2026）

- **作者/机构**：Jingwei Xu、Mingkai Dong、Qiulin Tian、Ziyi Tian、Tong Xin、Haibo Chen，上海交通大学 IPADS（早期 arXiv 版本名为 AsyncFS）
- **会议/年份**：ACM EuroSys 2026
- **链接**：https://dl.acm.org/doi/10.1145/3767295.3769349 ；arXiv: https://arxiv.org/abs/2410.08618
- **解决的问题**：同步元数据更新（如 create 需同步更新父目录）在动态倾斜负载下造成目录争用与长尾延迟。
- **核心设计**：
  - **异步元数据更新**：操作提前返回，目录更新**推迟到读取时**批量应用（batching + consolidation），既隐藏延迟又摊薄开销；关键在于仍维持同步 POSIX 语义可见性。
  - **可编程交换机协调**：用 programmable switch 的片上资源跟踪目录状态（哪些目录有未应用的 delta），以近乎零开销做全局协调。
- **关键实验结果**：显著降低目录争用下的延迟并提升吞吐（具体数字待确认，需查论文正文）。
- **局限性**：依赖 P4 可编程交换机硬件；交换机资源极有限，状态管理复杂；部署门槛高。
- **设计启示**：硬件不必照搬，但"**目录统计/时间戳等派生元数据延迟到读时物化**"的思想可直接借鉴：create/unlink 只写 delta 记录，`stat`/`readdir` 时合并——把写热点转化为读时少量额外工作。

---

## 3. 其他相关工作与候选核实说明

- **Metis（FAST 2024）**：核实结果为 *Metis: File System Model Checking via Versatile Input and State Exploration*（Stony Brook 等），是**文件系统模型检测/测试**工作，与元数据扩展性无关。任务候选中的"Metis / 元数据 KV 化"应指别的工作——2020 年后未检索到以 Metis 命名的元数据 KV 化论文（待确认）；元数据 KV 化的代表性谱系是 2020 年前的 TableFS/IndexFS/LocoFS，此处不展开。
- **TafDB**：并非独立论文，而是百度自研分布式表格系统，作为 CFS（EuroSys 2023）与 Mantle（SOSP 2025）的 namespace 存储层出现，已在上文两节覆盖。
- **DPFS: DPU-Powered File System Virtualization（SYSTOR 2023，IBM Research 等）**：将 virtio-fs/NFS 客户端 offload 到 DPU 的文件系统虚拟化工作，主要贡献在数据面与客户端卸载，元数据扩展性不是其核心主题，故不单列（venue 与定位已核实）。
- **3FS（DeepSeek，2025 开源）**：工业系统而非同行评审论文——元数据服务无状态、持久化于 FoundationDB（事务 KV），链式复制 CRAQ 做数据面。与 Tectonic/λFS 同属"元数据下沉到事务 KV"路线，可与 [industry-production-systems.md](industry-production-systems.md) 中的 3FS 小节互参。
- **Fletch / FMCache: File-System Metadata Caching in Programmable Switches（arXiv 2510.08351，2025）**：网内元数据缓存，处理路径依赖的在交换机内缓存失效问题；截至调研日未确认正式会议收录（待确认）。
- **Xfast: Extreme File Attribute Stat Acceleration for Lustre（SC 2023）**：面向 Lustre 的 stat 加速，HPC 场景元数据读优化（https://dl.acm.org/doi/10.1145/3581784.3607080）。
- **SwitchDelta（arXiv 2511.19978）**：SwitchFS 同一路线的后续/关联工作，网内数据可见性驱动的异步元数据更新（待确认 venue）。

---

## 4. 横向对比

| 论文 | 元数据分区策略 | 路径解析 | rename 处理 | 底层存储 | 规模数据 |
|---|---|---|---|---|---|
| Tectonic (FAST'21) | 三层（name/file/block）各按 ID hash 分区 | 逐级 lookup，目录项同分片 | 跨分片不保证原子（语义取舍） | ZippyDB（分片事务 KV / RocksDB） | EB 级数据，数十亿文件，生产 |
| InfiniFS (FAST'22) | access/content 元数据解耦，按目录 hash 分组 | speculative 并行解析 + 客户端乐观缓存 | 分布式事务 | 分片 KV（待确认细节） | 1000 亿文件；73× vs HopsFS |
| CFS (EuroSys'23) | 属性与 namespace 分层：TafDB（按目录聚合）+ FileStore | 逐级，单级单分片 | 独立 Rename Service（慢路径） | TafDB + FileStore | 千亿级目标；50 节点 1.22–4.10× vs InfiniFS |
| SingularFS (ATC'23) | 不分区（单 MDS，机内 hybrid inode partition） | 单机内存解析 | 单机事务，无分布式协调 | NVMM（Optane PM）+ RDMA | 10 亿级文件 / 单服务器 |
| λFS (ASPLOS'23) | serverless 函数一致性 hash 路由 + 函数内缓存 | 函数内缓存解析，未命中查 DB | 底层 NewSQL 分布式事务 | MySQL NDB Cluster | 弹性伸缩；优于 HopsFS（负载相关） |
| FileScale (SoCC'23) | 三层：内存缓存 + DDBMS shared-nothing 分区 | 内存层快路径 | DDBMS 分布式 ACID 事务 | 分布式数据库（Calvin 谱系，待确认） | 小规模≈单机 HDFS；线性扩展 |
| Mantle (SOSP'25) | TafDB 分片（全量）+ 每 namespace 单机 IndexNode（目录骨架） | IndexNode 单 RPC lookup | 环检测 offload 至 IndexNode；delta 更新 | TafDB | 100 亿对象/namespace；1.8M lookup/s；生产 2 年 |
| HMFS (SoCC'25) | 无序（hash）索引 + 对象间链接维护目录语义 | hash 点查 | 待确认 | PM 上无序索引 + 链接结构 | 显著超有序索引方案（数字待确认） |
| FalconFS (NSDI'26) | 文件按名 hash 分区；目录 namespace 惰性全复制 | 服务端本地解析（stateless client） | 惰性失效 + 服务端协调（细节待确认） | 定制 PostgreSQL（每 MNode） | 万卡 NPU 生产 1 年；训练吞吐至 12.81× |
| MesaFS (EuroSys'26) | 单引擎层工作（不改分区） | — | —（不变式感知恢复） | SSD 半有序布局，单次写更新 | 62–95.1% 裸 SSD 性能 |
| SwitchFS (EuroSys'26) | 常规分区 + 交换机跟踪目录状态 | 常规 | 异步 delta，读时合并 | —（协调面创新） | 争用下延迟/吞吐显著改善（待确认） |

---

## 5. 元数据服务设计的总体启示

面向新的分布式文件系统元数据服务设计，归纳为六条原则与一个演进路径。

### 5.1 设计原则

1. **规模先行判断**：若目标 ≤ 数十亿文件，SingularFS/Mantle-IndexNode 路线表明"单个强元数据服务器（或集中目录骨架）+ 分片平坦数据"就足够，不要过早引入分布式事务。
2. **解耦是共识**：dentry（解析用）与 inode 属性（stat 用）分表、分区键分别取 parent_id 与 self_id，是 InfiniFS/CFS/Mantle 反复验证的模式。
3. **rename 单独设计**：常见操作单分片化（CFS），rename 走集中防环组件（Mantle）或独立服务；不要让 1% 的 rename 决定 99% 操作的架构。
4. **热点用 delta 化解**：目录时间戳/统计等派生元数据延迟物化（SwitchFS、Mantle），create 风暴下不更新父目录本体。
5. **存储引擎务实选型**：事务 KV（RocksDB/ZippyDB 路线）或嵌入成熟数据库（FalconFS 的 PostgreSQL）皆可；同时量化落盘写放大（MesaFS 视角），必要时定制精简 journal。
6. **弹性靠无状态化**：元数据服务进程无状态 + 状态收敛到复制存储层（λFS/Tectonic/3FS），扩缩容即改路由。

### 5.2 建议的表结构（借鉴 InfiniFS/CFS/Tectonic 分层）

```
dentry 表：  key = (parent_inode_id, name)      -> {inode_id, type}         # 按 parent_id 分区
inode 表：   key = inode_id                     -> {mode, uid, gid, times…} # 按 inode_id 分区
dir_stat 表：key = inode_id                     -> {entry_count_delta…}     # delta 记录，读时合并
extent 表：  key = (inode_id, block_index)      -> {数据块位置…}          # 按 inode_id 分区
```

- 同目录 create/unlink/readdir 落在 dentry 表单分片；stat 点查 inode 表单分片；
- 跨目录 rename 涉及两个 dentry 分片 + 防环检查，由集中式索引组件（或独立 rename 路径）裁决（Mantle 模式）；
- 目录 mtime/nlink 等写入 dir_stat delta，`stat`/`readdir` 时合并物化（SwitchFS 模式）。

### 5.3 演进路径

- **阶段一（单元数据服务器）**：内存目录树 + RocksDB 持久化，实现 SingularFS 式层级并发控制；控制面只管租约、心跳与故障切换（主备）。
- **阶段二（目录骨架集中 + inode 分片）**：目录骨架（约百字节/目录）留在主元数据服务器或集中索引组件内存中做单 RPC 路径解析与 rename 防环；inode/dentry 数据按上表 hash 分片到多个元数据节点（Mantle 模式）。
- **阶段三（可选，全分布式）**：仅当目录骨架本身超出单机（约对应 >10^10 目录）时，才考虑 InfiniFS 式推测解析 + 客户端乐观缓存，或将骨架也分片。

多数论文的经验表明：阶段二足以覆盖百亿文件规模，阶段三在生产中极少真正需要。

---

## 6. 参考链接汇总

| 论文 | 主要链接 |
|---|---|
| Tectonic (FAST'21) | https://www.usenix.org/conference/fast21/presentation/pan |
| InfiniFS (FAST'22) | https://www.usenix.org/conference/fast22/presentation/lv |
| CFS (EuroSys'23) | https://dl.acm.org/doi/10.1145/3552326.3587443 |
| SingularFS (ATC'23) | https://www.usenix.org/conference/atc23/presentation/guo |
| λFS (ASPLOS'23) | https://dl.acm.org/doi/10.1145/3623278.3624765 · https://github.com/ds2-lab/LambdaFS |
| FileScale (SoCC'23) | https://dl.acm.org/doi/10.1145/3620678.3624784 · https://github.com/umd-dslam/FileScale |
| Mantle (SOSP'25) | https://dl.acm.org/doi/10.1145/3731569.3764824 |
| HMFS (SoCC'25) | https://dl.acm.org/doi/10.1145/3772052.3772237 |
| FalconFS (NSDI'26) | https://www.usenix.org/conference/nsdi26/presentation/xu · https://arxiv.org/abs/2507.10367 |
| MesaFS (EuroSys'26) | https://dl.acm.org/doi/10.1145/3767295.3803573 |
| SwitchFS (EuroSys'26) | https://dl.acm.org/doi/10.1145/3767295.3769349 · https://arxiv.org/abs/2410.08618 |
| Fletch/FMCache (arXiv) | https://arxiv.org/abs/2510.08351 |
| Xfast (SC'23) | https://dl.acm.org/doi/10.1145/3581784.3607080 |

---

*本文所有结论基于 2026-08-15 检索到的公开资料；标注"待确认"处需进一步阅读论文原文核实。*
