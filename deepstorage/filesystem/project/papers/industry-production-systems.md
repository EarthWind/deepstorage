# 工业界大规模生产环境分布式文件系统论文调研（2020 年以后）

> 调研日期：2026-08-15
>
> 范围说明：本调研聚焦 2020 年（含）之后发表的、来自工业界大规模生产环境的分布式文件系统（DFS）论文，覆盖 Meta（Facebook）、Alibaba、Baidu、DeepSeek、Huawei 等公司的系统，以及 Google Colossus（无正式论文，仅官方博客/演讲，已明确标注）。每篇论文均通过 Web 搜索逐一核实了真实性、会议归属与年份；与常见传言不符之处（如 Tectonic-Shift、Fisc 的实际会议）已在文中更正说明。文末给出面向分布式文件系统设计者的总体设计启示汇总。
>
> 注意：调研过程中 USENIX 官网对自动抓取返回 403，论文摘要与细节综合自搜索引擎摘要、ACM DL、arXiv、官方博客与第三方技术分析文章；个别未能直接核实的细节已标注"待确认"。

## 目录

1. [Facebook's Tectonic Filesystem（FAST 2021）](#1-facebooks-tectonic-filesystem-fast-2021)
2. [Tectonic-Shift（ATC 2023）](#2-tectonic-shift-atc-2023)
3. [Alibaba Pangu: More Than Capacity（FAST 2023）](#3-alibaba-pangu-more-than-capacity-fast-2023)
4. [Alibaba Fisc（FAST 2023）](#4-alibaba-fisc-fast-2023)
5. [Baidu CFS（EuroSys 2023）](#5-baidu-cfs-eurosys-2023)
6. [InfiniFS（FAST 2022，清华 + Alibaba）](#6-infinifs-fast-2022)
7. [DeepSeek Fire-Flyer AI-HPC 与 3FS（SC 2024 / 开源项目）](#7-deepseek-fire-flyer-ai-hpc-与-3fs)
8. [Huawei FalconFS（NSDI 2026 / arXiv 2025）](#8-huawei-falconfs-nsdi-2026)
9. [Google Colossus（非论文：官方博客）与 CacheSack（ATC 2022）](#9-google-colossus-与-cachesack)
10. [其他相关工作简述](#10-其他相关工作简述)
11. [总体设计启示](#11-总体设计启示)
12. [汇总表](#12-汇总表)

---

## 1. Facebook's Tectonic Filesystem（FAST 2021）

- **论文标题**：Facebook's Tectonic Filesystem: Efficiency from Exascale
- **作者/机构**：Satadru Pan、Theano Stavrinos、Yunqiao Zhang、Atul Sikaria、Pavel Zakharov、Abhinav Sharma、Shiva Shankar P、Mike Shuey、Richard Wareing、Monika Gangapuram、Guanglei Cao、Christian Preseau、Pratap Singh、Kestutis Patiejunas、JR Tipton、Ethan Katz-Bassett、Wyatt Lloyd 等（Facebook / Princeton / USC / Columbia）
- **会议与年份**：USENIX FAST 2021（获 Best Paper 提名级关注，具体奖项待确认）
- **论文链接**：<https://www.usenix.org/conference/fast21/presentation/pan>（PDF: <https://www.usenix.org/system/files/fast21-pan.pdf>）

### 解决的问题

Facebook 此前为不同业务维护多套专用存储系统（Haystack/f4 存 Blob、HDFS 存数仓），导致资源孤岛、运维负担重、资源利用率低。Tectonic 的目标是用**单一多租户 exabyte 级文件系统**整合这些专用系统，同时达到与专用系统相当的性能。

### 核心架构设计

- **元数据组织**：将文件系统元数据抽象为 KV 模型，拆分为三层并独立分片（shard）水平扩展：
  - **Name layer**：目录树/命名空间（目录 → 子目录/文件映射）；
  - **File layer**：文件 → block 列表映射；
  - **Block layer**：block → chunk 及 chunk 位置映射。
  - 三层元数据服务本身**无状态**，持久化状态存于 **ZippyDB**（Meta 基于 RocksDB + Paxos 的分布式 KV 存储），由 ZippyDB 提供分片内事务与强一致；跨分片操作（如 rename 跨目录）不提供原子性，属于刻意的语义取舍。
- **数据路径**：Chunk Store 是扁平的 chunk 存储层，客户端直接读写存储节点；Client Library 承担大部分逻辑（副本/EC 编码选择、chunk 布局、故障处理），实现"胖客户端、瘦服务端"。
- **容错与冗余**：以 Reed-Solomon **纠删码为主**（冗余约 1.2–1.5x，对比三副本 3x 大幅省成本），可按租户/文件粒度选择副本或 EC、条带参数。
- **多租户资源管理**：将租户资源用量分为 ephemeral（如 IOPS，可瞬时借用，用改进的分布式令牌桶做全局公平共享 + 本地优化）与 non-ephemeral（如容量，配额管理）两类；租户可通过客户端侧配置定制优化（如数仓的全条带写 hedged quorum 写、Blob 存储的小写 append 优化）。

### 关键实验结果 / 生产规模

- 单集群承载 **exabyte 级**数据、**数十亿文件**、数千存储节点，同时服务 Blob 与数仓两大类租户；
- 整合后达到与原专用系统（Haystack、f4、HDFS 联邦）相当的性能，同时显著提升空间与 IO 资源利用率（原 HDFS 数仓需数十个联邦集群，Tectonic 用单集群承载）。

### 设计启示

- **元数据分层 + KV 化**是支撑超大规模命名空间的关键路径：元数据服务可以借鉴"Name/File/Block 三层解耦、各自独立分片"的思路，把目录树、文件-块映射、块位置三类元数据分开组织，避免单体元数据服务成为瓶颈；
- 元数据服务无状态化、状态下沉到带事务的 KV 引擎（如 RocksDB + Raft），能简化元数据服务的故障恢复与水平扩展；
- 客户端库承载 EC/副本策略与故障处理逻辑，可让存储节点保持简单；但要注意 Fisc 论文（见下）指出的胖客户端在云原生场景的资源与升级代价；
- 明确放弃跨分片原子 rename 这类"语义换扩展性"的取舍值得在设计文档中显式决策。

---

## 2. Tectonic-Shift（ATC 2023）

- **论文标题**：Tectonic-Shift: A Composite Storage Fabric for Large-Scale ML Training
- **作者/机构**：Mark Zhao（Stanford）等，与 Meta 合作（Stanford University + Meta）
- **会议与年份**：**USENIX ATC 2023**（注意：常被误记为 FAST 2023，经核实实际发表于 ATC 2023）
- **论文链接**：<https://www.usenix.org/conference/atc23/presentation/zhao>

### 解决的问题

Meta 的 ML 训练（推荐模型为主）对训练数据存储提出了海量带宽需求。纯 HDD 的 Tectonic 集群受限于 HDD 的 IOPS/功耗比，为满足训练带宽需要过度扩容（over-provision），功耗与成本不可持续。

### 核心架构设计

- **复合存储层（composite storage fabric）**：在 HDD 底座 Tectonic 之上加入 **Shift**——一个 flash 缓存层，二者组成面向训练数据的复合存储结构，目标是**最大化每瓦特有效带宽**；
- **应用感知的缓存策略**：Shift 不用通用 LRU，而是利用训练作业的数据集规格（dataset specification）**推断未来访问模式**，据此做准入与驱逐决策（训练数据访问是可预知的、按 epoch 扫描的）；
- 数据路径上训练数据读取先查 Shift flash 层，未命中回源 Tectonic HDD 层。

### 关键实验结果 / 生产规模

- 应用感知缓存策略比传统 LRU flash 缓存多吸收 **1.51–3.28x** 的 IO；
- 在 PB 级生产集群上使存储**功耗需求降低 29%**。

### 设计启示

- 面向 AI 训练类负载的系统，应考虑在存储节点之上/之内引入分层介质（NVMe 缓存 + HDD 容量层），并把"上层负载语义（数据集、epoch 访问模式）"作为缓存策略输入，而非只依赖通用 LRU；
- "每瓦特带宽"是大规模生产环境的真实优化目标，容量规划工具应把功耗建模纳入。

---

## 3. Alibaba Pangu: More Than Capacity（FAST 2023）

- **论文标题**：More Than Capacity: Performance-oriented Evolution of Pangu in Alibaba
- **作者/机构**：Qiang Li 等，Alibaba Group / Alibaba Cloud（作者列表庞大，含厦门大学 Qiao Xiang 等学术合作者）
- **会议与年份**：USENIX FAST 2023（Deployed Systems 类）
- **论文链接**：<https://www.usenix.org/conference/fast23/presentation/li-qiang-deployed>（PDF: <https://www.usenix.org/system/files/fast23-li-qiang_more.pdf>）

### 解决的问题

Pangu 是阿里统一存储底座（支撑 EBS、OSS、NAS、数据库、MaxCompute 等）。论文讲述 Pangu 从"容量导向"（HDD 时代）到"性能导向"（SSD + RDMA 时代）的两阶段演进，目标是提供 **100 µs 级 I/O 延迟** 与毫秒级 P999 SLA 的高性能存储服务。

### 核心架构设计

- **总体架构**：Client（胖客户端）+ PanguMasters（元数据/chunkserver 状态管理）+ ChunkServer（数据）。客户端负责与 chunkserver 的数据操作及与 master 的元数据交互，本地维护 LRU 元数据缓存减少 master 查询。
- **第一阶段（拥抱 SSD + RDMA）**：
  - 重构文件系统为**统一 append-only 持久层**（unified, append-only persistence layer），所有上层抽象（块、对象、文件）落到 append-only chunk 写入，天然利于 SSD 与 EC；
  - 自研**用户态存储操作系统 USSFS**（user-space storage file system）：绕过内核，run-to-completion 线程模型，用户态驱动直接操作 NVMe SSD，为不同硬件（含 SMR）提供 append 写引擎；
  - 网络侧大规模部署 RDMA（存算之间），配合自研 RPC 减少延迟抖动。
- **第二阶段（网络带宽从 25G → 100G/200G 的基础设施升级）**：围绕"性能/成本"持续优化——流量放大优化（EC/压缩：在线 EC + FPGA 压缩降低网络放大）、独立网络端口隔离前后台流量、动态流控（如 Fisc 中的 proxy 侧限流）等。
- **一致性与容错**：chunk 多副本/EC，master 管理 chunkserver 状态；通过快速故障检测与切换（配合客户端重试/backup read）实现毫秒级 P999。（论文级细节如 master 一致性协议，待确认。）

### 关键实验结果 / 生产规模

- 生产环境达到 **100 µs 级平均 I/O 延迟**、毫秒级 P999，支撑阿里云 EBS/OSS 等核心业务；
- 双十一等大促场景下的大规模验证；具体集群规模数字论文中有披露（如单集群万级节点，待确认精确值）。

### 设计启示

- **统一 append-only 持久层**是同时支撑多种上层语义（块/对象/文件）并简化 EC、SSD GC 友好性的经过验证的设计；存储节点的存储引擎可采用 append-only chunk + 后台整理的模型；
- 若追求极致延迟，存储节点端 run-to-completion + 用户态 IO（io_uring/SPDK）与 RDMA/自研 RPC 是工业界共识路径；
- 前后台流量隔离（用户 IO vs 迁移/修复流量）应在存储节点与控制面的调度中显式设计。

---

## 4. Alibaba Fisc（FAST 2023）

- **论文标题**：Fisc: A Large-scale Cloud-native-oriented File System
- **作者/机构**：Qiang Li 等，Alibaba Group，合作机构含复旦大学、南京大学、厦门大学
- **会议与年份**：**USENIX FAST 2023**（注意：常被误记为 SOSP 2023，经核实实际发表于 FAST 2023）
- **论文链接**：<https://www.usenix.org/conference/fast23/presentation/li-qiang-fisc>（PDF: <https://www.usenix.org/system/files/fast23-li-qiang.pdf>）

### 解决的问题

传统 DFS（Tectonic、Colossus、HDFS、Pangu 本体）的**胖客户端**在云原生容器环境中问题突出：占用容器内稀缺的 CPU/内存资源、与应用争抢、客户端版本升级困难、多租户隔离与安全边界模糊。Fisc 是面向云原生的"瘦客户端"文件系统（可视为 Pangu 面向云原生的客户端/接入层重构）。

### 核心架构设计

- **轻量客户端**：容器内只留极薄的 Fisc client，通过 **vRPC（virtual RPC）** 抽象与 virtio-Fisc 虚拟设备把请求穿过虚拟化边界交给基础设施层处理；vRPC 抽象亦可被 FaaS 等其他云原生服务复用；
- **DPU 卸载**：I/O 快路径下沉到 DPU（神龙 CIPU 类硬件）上的 Fisc agent，加速数据路径并把存储栈资源从租户容器中移出；
- **存储感知分布式网关 SaDGW（storage-aware distributed gateway）**：不走集中式网关，而是在每台计算服务器与其对应远端存储节点之间建立"直连高速路"；Fisc proxy 部署在存储节点侧，agent–proxy 之间共享连接、空闲连接回收、跨 region 只连接部分 proxy，以控制连接数规模；
- **容错/高可用**：代理层可快速切换后端，配合限流与故障规避，将客户端故障域从应用容器中剥离。

### 关键实验结果 / 生产规模

- 相比 on-premise Pangu 胖客户端，**CPU 消耗降低 69%、内存降低 20%**，可用性提升一个数量级；
- 生产 DCN 部署 **3 年**，服务阿里 **300 万+ CPU 核**上的应用；在线搜索查询业务平均延迟 **< 500 µs**、P999 **< 60 ms**。

### 设计启示

- 胖客户端与瘦客户端是一个真实的架构分岔：若目标场景含容器/多租户云环境，应尽早把"客户端逻辑放哪"作为一等设计问题——可行折中是：协议上支持胖客户端直连存储节点，同时提供可选的接入代理层（类似 Fisc proxy）供云原生部署；
- 客户端-服务端之间引入稳定的窄接口（类似 vRPC），可让客户端升级与服务端演进解耦；
- 连接数管理（共享连接、空闲回收）在大规模集群是必须提前设计的工程问题。

---

## 5. Baidu CFS（EuroSys 2023）

- **论文标题**：CFS: Scaling Metadata Service for Distributed File System via Pruned Scope of Critical Sections
- **作者/机构**：百度（Baidu AI Cloud）团队与合作高校（作者含 Yiduo Wang 等；百度官方发文确认为百度沧海·文件存储 CFS 的论文）
- **会议与年份**：ACM EuroSys 2023
- **论文链接**：<https://dl.acm.org/doi/10.1145/3552326.3587443>（百度官方解读：<https://cloud.baidu.com/article/320331>）

### 解决的问题

分布式文件系统中**元数据扩展性与 POSIX 强语义（原子性/隔离性）之间的根本张力**：瓶颈在于保证强一致所需的分布式协调（主要是锁）。CFS 目标是完全 POSIX 兼容的同时消除元数据管理瓶颈，支撑"千亿文件放进一个文件系统"。

### 核心架构设计

- **分层元数据组织（tiered metadata organization）**：把文件属性（attributes）与命名空间层级（namespace hierarchy）分开，用各自合适的分区与索引方法独立扩展，**消除跨 shard 分布式协调**；
- **单 shard 原子原语**：通过精简临界区（pruned scope of critical sections）缩短元数据请求生命周期、消除伪冲突，提升单元数据 shard 性能；
- **去代理层**：砍掉元数据 proxy 层，改为轻量、可扩展的**客户端侧路径解析**（client-side metadata resolving）。

### 关键实验结果 / 生产规模

- 在 **Baidu AI Cloud 生产环境运行 3 年+**；
- 50 节点集群评测：吞吐相对 HopsFS 提升 **1.76–75.82x**、相对 InfiniFS 提升 **1.22–4.10x**；平均延迟分别最多降低 91.71% / 54.54%；真实负载端到端吞吐提升 1.62–2.55x，尾延迟降低 35.06–62.47%。

### 设计启示

- 元数据服务的核心难题不是"存多少元数据"而是"锁与事务范围"：设计元数据操作时应逐操作分析其最小临界区，把 rename/mkdir 等复合操作尽量收敛到单 shard 原子原语上；
- "属性与命名空间分开分片"的思路可直接复用：inode 属性表按 inode id 哈希分片，目录项表按目录分片，二者独立扩展；
- 路径解析放客户端（带缓存与失效协议）可以砍掉一层转发延迟，但需要设计好缓存一致性协议。

---

## 6. InfiniFS（FAST 2022）

- **论文标题**：InfiniFS: An Efficient Metadata Service for Large-Scale Distributed Filesystems
- **作者/机构**：Wenhao Lv、Youyou Lu（清华大学）、Yiming Zhang（厦门大学）、Peile Duan（Alibaba Group）——高校与阿里合作，技术面向阿里生产场景（属"工业界深度参与"论文）
- **会议与年份**：USENIX FAST 2022
- **论文链接**：<https://www.usenix.org/conference/fast22/presentation/lv>（PDF: <https://www.usenix.org/system/files/fast22-lv.pdf>）

### 解决的问题

千亿（100 billion）文件规模下元数据服务的三大挑战：分片的**局部性与负载均衡矛盾**、**长路径解析**开销、**近根热点**（near-root hotspot）。

### 核心架构设计

- **目录的访问元数据与内容元数据解耦**（decouple access & content metadata of directories）：目录的权限/属性（路径解析用）与目录项内容分开放置，使局部性与均衡兼得；
- **推测式路径解析（speculative path resolution）**：利用可预测的目录 ID 生成规则并行化路径解析，避免逐级串行 RPC；
- **客户端乐观访问元数据缓存**（optimistic access metadata cache）：客户端缓存路径解析所需元数据，用乐观校验解决失效问题，压制近根热点。

### 关键实验结果 / 生产规模

- 在最高 **1000 亿文件**的目录树上保持稳定的元数据延迟与吞吐，明显优于 HopsFS 等对比系统（后被 Baidu CFS 作为 baseline 进一步超越）。

### 设计启示

- 路径解析是元数据服务的第一性能瓶颈；元数据服务应避免"每级目录一次 RPC"的朴素实现，可结合目录 ID 可预测生成 + 客户端乐观缓存；
- 近根目录（/、/home 等）天然是读热点，需要专门的缓存/复制策略而非均匀分片。

---

## 7. DeepSeek Fire-Flyer AI-HPC 与 3FS

### 7.1 Fire-Flyer AI-HPC（SC 2024）

- **论文标题**：Fire-Flyer AI-HPC: A Cost-Effective Software-Hardware Co-Design for Deep Learning
- **作者/机构**：Wei An、Xiao Bi 等 52 位作者，DeepSeek-AI（幻方/深度求索）
- **会议与年份**：SC 2024（International Conference for High Performance Computing, Networking, Storage and Analysis）；arXiv:2408.14158（2024-08）
- **论文链接**：<https://arxiv.org/abs/2408.14158>

#### 解决的问题

以 **1 万张 PCIe A100** 构建性价比导向的深度学习集群 Fire-Flyer 2，通过软硬协同设计（网络两层 Fat-Tree、HFReduce allreduce 加速、HaiScale 训练框架、**3FS 文件系统**）达到接近 DGX-A100 方案的性能，同时**成本减半、能耗降低 40%**。

#### 与存储相关的内容

论文将 3FS 作为集群存储底座描述（NVMe SSD + RDMA 网络的全闪分布式文件系统），承担训练数据读取与 checkpoint。3FS 的完整架构细节在论文中篇幅有限，更多见开源项目文档。

### 7.2 3FS（Fire-Flyer File System，开源项目，2025-02）

- **性质标注**：**截至本调研日期，3FS 本体没有独立的正式会议论文**，其权威技术资料为 GitHub 开源仓库与官方设计文档（design notes），发布于 2025 年 2 月 DeepSeek Open Source Week。相关系统描述另见 Fire-Flyer AI-HPC 论文（上）。
- **项目链接**：<https://github.com/deepseek-ai/3FS>

#### 核心架构设计（据官方仓库文档）

- **四组件**：cluster manager（集群管理/成员心跳）、metadata service、storage service、client；存算分离（disaggregated）架构聚合数千块 NVMe SSD 的吞吐与数百节点的 RDMA 网络带宽；
- **元数据**：**无状态 metadata service**，元数据存放于事务型分布式 KV 存储 **FoundationDB**，文件系统语义（目录树、inode）映射为 KV 事务，metadata 节点可任意水平扩展与替换；
- **数据路径与一致性**：数据分 chunk，采用 **CRAQ（Chain Replication with Apportioned Queries）** 链式复制实现强一致，写走链头到链尾、读可分摊到链上各节点（read scaling），语义上提供 strong consistency 简化上层应用；
- **接口**：提供 FUSE 挂载与原生高性能客户端（USRBIO 用户态异步 IO API），面向 AI 场景提供 FFRecord 数据格式与 **KVCache**（LLM 推理 KV 缓存下沉到 3FS，替代 DRAM 缓存）。

#### 关键性能数据（官方公布）

- 180 存储节点集群聚合**读吞吐约 6.6 TiB/s**（且伴随训练背景流量）；
- GraySort：110.5 TiB 数据 8192 分区 30 分 14 秒排完，均值 3.66 TiB/min；
- KVCache 读峰值 **40 GiB/s**。

### 设计启示

- 3FS 的 cluster manager / metadata service / storage service / client 四组件划分是分离式架构的典型形态，且 C++ 代码开源，是极佳的对标参考实现；
- "元数据下沉到事务 KV（FoundationDB）+ 无状态元数据服务"再次得到验证（与 Tectonic/ZippyDB 同构）；新系统的元数据服务可考虑架在嵌入式事务 KV + Raft 之上，而不是自造持久化格式；
- **CRAQ 是副本一致性协议的务实选择**：比 Raft-per-chunk 简单，读扩展性好，适合读多写少的 AI 负载；存储节点的副本协议选型可将 chain replication/CRAQ 与 Raft、主从复制一起纳入评估；
- 面向 AI 场景的增值特性（随机读 dataloader、并行 checkpoint、KVCache）说明 DFS 的竞争力越来越取决于"贴负载"的上层能力。

---

## 8. Huawei FalconFS（NSDI 2026）

- **论文标题**：FalconFS: Distributed File System for Large-Scale Deep Learning Pipeline
- **作者/机构**：Jingwei Xu、Junbin Kang 等，Huawei（与高校合作，具体分工待确认）
- **会议与年份**：已被 **USENIX NSDI 2026** 接收（<https://www.usenix.org/conference/nsdi26/presentation/xu>）；预印本 arXiv:2507.10367（2025-07）
- **论文链接**：<https://arxiv.org/abs/2507.10367>

### 解决的问题

深度学习流水线的海量小文件负载下，传统 DFS 依赖**客户端元数据缓存**的架构失效（DL 负载访问集过大、随机性强，缓存命中率低），导致小文件读写吞吐不足。

### 核心架构设计

- **无状态客户端（stateless-client）架构**：路径解析全部放在服务端完成，客户端不做元数据缓存；
- **混合元数据索引（hybrid metadata indexing）**：服务端高效解析路径；
- **惰性命名空间复制（lazy namespace replication）**：目录命名空间在元数据节点间懒复制，兼顾解析效率与写扩展。

### 关键实验结果 / 生产规模

- 对比 CephFS 与 Lustre：小文件读写吞吐最高 **5.72x**，深度学习模型训练吞吐最高 **12.81x**；
- 已在**华为自动驾驶系统生产环境**运行一年，规模 **1 万 NPU**，并已开源。

### 设计启示

- 与 InfiniFS/CFS 的"客户端缓存路径解析"路线相反，FalconFS 证明在 DL 小文件负载下"服务端解析 + 无状态客户端"更优——说明**元数据缓存策略必须按目标负载选型**，应先明确目标负载画像再定元数据服务与客户端的职责边界；
- 海量小文件是 AI 时代 DFS 的核心考题，数据面需要考虑小文件聚合存储（chunk 内打包）与元数据端优化联动。

---

## 9. Google Colossus 与 CacheSack

### 9.1 Colossus（**非论文**，官方博客/演讲）

- **性质标注**：Colossus（GFS 继任者）**至今没有正式学术论文**。公开权威资料为 Google Cloud 官方博客（2021 年《A peek behind Colossus, Google's file system》）及历次会议演讲（如 2010 Faculty Summit、2017 Google Cloud Next 等）。本节内容基于官方博客，非同行评审论文。
- **链接**：<https://cloud.google.com/blog/products/storage-data-transfer/a-peek-behind-colossus-googles-file-system>

#### 架构要点（据官方博客）

- **Client Library**：应用通过客户端库接入，软件 RAID/多种编码（副本、RS 纠删码）在客户端实现，按负载调节性能/成本；
- **控制面**：**Curators**（可水平扩展的元数据服务，处理文件创建等控制操作，客户端直连）+ **Custodians**（后台管家：磁盘均衡、RAID 重建、耐久性维护）；
- **元数据存储**：文件系统元数据存于 **BigTable**（而 BigTable 自身又跑在 Colossus 上，自举分层解决），相比 GFS 单 master 扩展性提升 **100x+**；
- **数据路径**："D" file servers（网络盘服务器），客户端与 D server 直连传输数据，最小化网络跳数；
- **规模**：单集群可扩展至 **exabyte 级**、数万台机器；支持 flash/HDD 混布与冷热分层，承载 YouTube、Gmail、Search 与 Google Cloud 各存储产品。

### 9.2 CacheSack（ATC 2022，Colossus Flash Cache 相关论文）

- **论文标题**：CacheSack: Admission Optimization for Google Datacenter Flash Caches
- **作者/机构**：Tzu-Wei Yang 等，Google
- **会议与年份**：USENIX ATC 2022（期刊扩展版：ACM Transactions on Storage 2023，《CacheSack: Theory and Experience of Google's Admission Optimization for Datacenter Flash Caches》）
- **论文链接**：<https://www.usenix.org/conference/atc22/presentation/yang-tzu-wei>；<https://dl.acm.org/doi/10.1145/3582014>

#### 内容与结果

CacheSack 是 **Colossus Flash Cache**（Colossus 的通用 flash 缓存服务）的准入算法：把缓存流量划分为不相交类别，对每类评估缓存收益，将"给每类分配何种准入策略"建模为背包问题求最优解，目标是最小化 HDD 磁盘 IO 与 flash 损耗两大主导成本。生产结果：**TCO 降低 7.7%、磁盘读降低 9.5%、flash 磨损降低 17.8%**。这是 2020 年后少有的透露 Colossus 生产细节的同行评审论文。

### 设计启示

- Colossus 的 Curator/Custodian 分离印证了控制面角色的正确定位：**控制操作（元数据路径）与后台维护（均衡、修复）应是两类独立组件/进程**，避免后台任务干扰前台延迟；
- "元数据存到另一个可扩展存储系统（BigTable）"与 Tectonic/3FS 的 KV 化殊途同归；
- flash 缓存准入用"成本建模 + 优化求解"替代启发式，是做分层缓存时可借鉴的方法论。

---

## 10. 其他相关工作简述

以下为 2020 年后与工业界 DFS 相关、但因主题（块存储/局部存储/GC）或时间关系不单独成节的论文：

- **What's the Story in EBS Glory: Evolutions and Lessons in Building Cloud Block Store**（Alibaba，FAST 2024）：阿里云 EBS 十年演进，构建于 Pangu 之上，讨论联邦 Pangu 集群、EC/压缩降流量放大等，与 Pangu 论文互补。链接：<https://dl.acm.org/doi/10.5555/3650697.3650714>（USENIX FAST 2024）。
- **Discard-Based Garbage Collection for Distributed Log-Structured Storage Systems in ByteDance**（ByteDance，FAST 2026）：针对字节跳动基础存储层 ByteStore（分布式 append-only 存储）的 GC 方案 DisCoGC，TCO 降低约 20%。链接：<https://www.usenix.org/conference/fast26/presentation/bian>。说明字节的 DFS 底座（ByteStore）尚无整体架构论文，待确认后续是否发表。
- **SingularFS: A Billion-Scale Distributed File System Using a Single Metadata Server**（清华，ATC 2023）：学术系统，用单元数据服务器支撑十亿级文件，可作为单机元数据服务性能上限的参考。
- **腾讯**：未检索到 2020 年后来自腾讯大规模生产 DFS 的顶会论文（其开源 DFS 相关工作如 CubeFS 的论文《CFS: A Distributed File System for Large Scale Container Platforms》发表于 SIGMOD 2019，出自京东，且在 2020 年前）——**待确认**。
- **Microsoft**：ADLS 论文（SIGMOD 2017）之后，未检索到微软 2020 年后发表的 DFS 整体架构后续论文（近年论文多集中于 blob/缓存/盘级研究）——**待确认**。

---

## 11. 总体设计启示

结合上述论文，对分布式文件系统设计的共性结论：

1. **元数据 KV 化 + 无状态服务层是主流共识**（Tectonic/ZippyDB、3FS/FoundationDB、Colossus/BigTable）：元数据服务建议实现为"无状态逻辑层 + 事务 KV 持久层（RocksDB + Raft 或嵌入 FoundationDB 类系统）"，天然获得水平扩展与快速故障恢复。
2. **路径解析与锁范围决定元数据性能上限**（CFS、InfiniFS、FalconFS）：按目标负载（通用 POSIX vs AI 小文件）选择客户端缓存解析或服务端解析路线；精简每个元数据操作的临界区。
3. **数据面 append-only + EC 是成本与性能的公约数**（Pangu、Tectonic）：存储节点的存储引擎建议 append-only chunk 布局，EC 作为一等公民（冗余 1.2–1.5x），副本一致性协议可评估 CRAQ（3FS 路线）。
4. **胖/瘦客户端要按部署形态显式选型**（Fisc vs Tectonic）：裸金属/专属集群用胖客户端直连；云原生容器场景准备代理/网关层。
5. **控制面职责拆分**（Colossus Curator/Custodian、Pangu master）：控制面应把"集群成员/放置决策"与"后台修复/均衡/GC"拆为独立模块，并对前后台流量做隔离与限流。
6. **面向 AI 负载的增值能力成为差异化点**（Tectonic-Shift、3FS、FalconFS）：分层 flash 缓存 + 负载感知准入、随机读 dataloader、并行 checkpoint、KVCache 等值得列入新系统的路线图。

---

## 12. 汇总表

| 论文 | 机构 | 会议年份 | 一句话核心贡献 |
|---|---|---|---|
| Facebook's Tectonic Filesystem: Efficiency from Exascale | Meta (Facebook) | FAST 2021 | 单一多租户 exabyte 级 DFS 整合 Blob 与数仓专用系统，三层 KV 化元数据 + 客户端定制化达到专用系统性能 |
| Tectonic-Shift: A Composite Storage Fabric for Large-Scale ML Training | Meta + Stanford | ATC 2023 | 在 HDD Tectonic 上叠加应用感知 flash 缓存层 Shift，IO 吸收提升 1.51–3.28x，功耗降 29% |
| More Than Capacity: Performance-oriented Evolution of Pangu in Alibaba | Alibaba | FAST 2023 | 统一 append-only 持久层 + 用户态存储 OS（USSFS）+ RDMA，实现 100 µs 级延迟的性能导向演进 |
| Fisc: A Large-scale Cloud-native-oriented File System | Alibaba | FAST 2023 | 云原生瘦客户端：vRPC + DPU 卸载 + 存储感知网关，客户端 CPU 降 69%，服务 300 万+ 核 |
| CFS: Scaling Metadata Service via Pruned Scope of Critical Sections | Baidu | EuroSys 2023 | 精简临界区 + 分层元数据组织，POSIX 语义下元数据吞吐大幅超越 HopsFS/InfiniFS，生产运行 3 年 |
| InfiniFS: An Efficient Metadata Service for Large-Scale Distributed Filesystems | 清华 + Alibaba | FAST 2022 | 目录访问/内容元数据解耦 + 推测路径解析 + 乐观客户端缓存，支撑千亿文件元数据服务 |
| Fire-Flyer AI-HPC: A Cost-Effective Software-Hardware Co-Design for Deep Learning | DeepSeek-AI | SC 2024 (arXiv 2408.14158) | 万卡 PCIe A100 集群软硬协同（含 3FS 存储底座），成本减半、能耗降 40% |
| 3FS（Fire-Flyer File System） | DeepSeek-AI | 开源项目 2025（非论文） | FoundationDB 元数据 + CRAQ 强一致链复制的全闪 RDMA DFS，180 节点 6.6 TiB/s 读吞吐 |
| FalconFS: Distributed File System for Large-Scale Deep Learning Pipeline | Huawei | NSDI 2026 (arXiv 2025) | 无状态客户端 + 服务端路径解析 + 惰性命名空间复制，DL 小文件吞吐最高 12.81x，万卡 NPU 生产验证 |
| Colossus（A peek behind Colossus） | Google | 官方博客 2021（非论文） | Curator/Custodian 控制面 + BigTable 元数据 + D server 数据面，单集群 exabyte 级 |
| CacheSack: Admission Optimization for Google Datacenter Flash Caches | Google | ATC 2022 | Colossus Flash Cache 的背包建模准入优化，TCO 降 7.7%、flash 磨损降 17.8% |
| What's the Story in EBS Glory（简述） | Alibaba | FAST 2024 | 基于 Pangu 的云块存储 EBS 十年演进与经验教训 |
| Discard-Based GC for Distributed Log-Structured Storage in ByteDance（简述） | ByteDance | FAST 2026 | ByteStore 分布式日志结构存储的 discard+compaction 混合 GC，TCO 降约 20% |
