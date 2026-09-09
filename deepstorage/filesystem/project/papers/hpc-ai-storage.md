# 面向 HPC 与 AI/ML 训练负载的分布式存储论文调研（2020–2026）

> 调研日期：2026-08-15
>
> 范围说明：本文调研 2020 年（含）之后发表的、面向 HPC（burst buffer、checkpoint、超算 I/O）与 AI/ML 训练负载（数据加载、缓存、模型 checkpoint）的分布式文件系统与存储系统论文，来源以 FAST / SC / OSDI / SOSP / ATC / NSDI / EuroSys / IPDPS 等会议为主。所有论文均通过 Web 检索核实了真实性、出处与年份；个别未能二次确认的细节以"待确认"标注。工业界大规模生产系统（Tectonic、Colossus 等）由 `industry-production-systems.md` 覆盖，本文仅从 AI 训练 I/O 角度对 Tectonic-Shift 作简述并交叉引用。

---

## 1. 负载特征综述：HPC 与 AI 训练对 DFS 的不同要求

### 1.1 HPC 负载：checkpoint 突发写与 N-N/N-1 模式

传统 HPC 应用（MPI 科学计算）的 I/O 具有强突发性（bursty）：

- **Checkpoint/Restart 主导写入**：应用周期性地将全内存状态 dump 到存储，写入在数分钟内爆发，随后长时间静默。存储系统按峰值带宽而非平均带宽设计，利用率低。
- **N-N 与 N-1 两种模式**：N-N（每进程一个文件）在几十万进程规模下产生海量文件创建风暴，压垮集中式元数据服务；N-1（全部进程写共享文件）则带来锁竞争与 false sharing。
- **Burst Buffer（BB）分层成为标配**：在计算节点本地（local BB，如神威、Fugaku）或独立转发层（shared BB，如 Cori DataWarp）部署 NVMe/SSD 吸收突发写，再异步下刷到 Lustre/GPFS 等后端并行文件系统。local BB 扩展性好但共享难，shared BB 共享易但扩展和干扰是问题——这是 HadaFS、UnifyFS、GekkoFS、CHFS 等一批"临时/ad-hoc 文件系统"论文的共同出发点。
- **元数据要求**：作业内可放松 POSIX 语义（无需全局强一致目录树），换取元数据吞吐的线性扩展；但作业间数据共享和跨作业发布仍需要某种命名空间汇合机制（DeltaFS 的 "No Ground Truth" 即针对此）。

### 1.2 AI/ML 训练负载：海量小文件随机读 + 大文件 checkpoint 写

AI 训练的 I/O 模式与传统 HPC 明显不同：

- **读多写少、随机读主导**：训练数据集（图片、音频、样本文件）以海量小文件为主，每个 epoch 按随机 shuffle 顺序全量读取。文件级 LRU 缓存几乎失效（均匀随机访问下命中率≈缓存比例），这是 Quiver/SHADE 等"训练感知缓存"论文的核心观察。
- **元数据密集**：数亿~百亿小文件的 open/stat 开销可能超过数据读取本身；FalconFS、3FS 等系统的共同做法是弱化客户端缓存、强化服务端元数据路径，或直接用打包格式（FFRecord、TFRecord）绕开 per-file 元数据。
- **Checkpoint 是大文件顺序写**：LLM 训练的模型 checkpoint 达数 TB（如 405B 参数模型），写入频率受故障率驱动（GPU 集群万卡规模下 MTBF 以小时计），checkpoint 停顿直接损失 GPU 时间。存储层要求高聚合写带宽 + 异步化（CheckFreq、Gemini、ByteCheckpoint）。
- **可共享、可重复**：同一数据集被大量作业/用户反复读取（Quiver 的跨作业内容寻址缓存）；训练可容忍"替代命中"（substitutable hit：随机采样下读哪个样本先后无所谓），这是通用文件系统没有的语义空间。
- **推理期新增负载**：KVCache 分层存储（3FS 的 KVCache、Mooncake 等）呈现"写一次、近期读、可淘汰"的特征，介于缓存与文件系统之间。

### 1.3 对分布式文件系统设计的分野

| 维度 | HPC checkpoint/burst | AI 训练 |
|---|---|---|
| 主导操作 | 突发大块写（N-N/N-1） | 海量小文件随机读 + 周期大文件写 |
| 元数据压力 | 创建风暴（作业启动/checkpoint 时刻） | open/stat 持续密集 |
| POSIX 语义 | 作业内可放松，作业间需汇合 | 大幅放松（不需要锁、mmap 一致性） |
| 缓存价值 | 写缓冲（BB 吸收突发） | 读缓存但需训练感知（重要性/替代命中） |
| 容量层 | 并行文件系统（Lustre/GPFS） | 对象存储/HDD 数据湖 + flash 加速层 |
| 典型系统 | HadaFS、UnifyFS、GekkoFS、CHFS、DAOS | 3FS、FalconFS、Tectonic-Shift、Quiver/SHADE |

---

## 2. HPC 方向：burst buffer 与超算文件系统

### 2.1 HadaFS: A File System Bridging the Local and Shared Burst Buffer for Exascale Supercomputers

- **作者/机构**：Xiaobin He、Bin Yang 等，国家超级计算无锡中心、清华大学、山东大学等（作者名单细节待确认）
- **会议年份**：USENIX FAST 2023
- **链接**：<https://www.usenix.org/conference/fast23/presentation/he>（PDF: <https://www.usenix.org/system/files/fast23-he.pdf>）
- **目标负载**：E 级超算（新一代神威）上数十万客户端的 burst buffer I/O：checkpoint 突发写、跨作业数据共享、BB 与后端存储间的数据迁移。
- **核心设计**：
  - **Localized Triage Architecture（LTA）**：在 shared BB 部署形态上提供 local BB 的扩展性——每个客户端的 I/O 被"分诊"到一个固定的 BB 服务端（bridge），数据先落本地化的服务端，再按需全局可见，避免全局条带化带来的全连接通信与干扰。
  - **全路径索引（full-path indexing）的扁平命名空间**：放弃目录树层级解析，文件元数据按全路径 hash 存放于各服务端本地 RocksDB（引擎细节待确认），消除跨节点的路径遍历。
  - **三级元数据同步策略**：按应用对共享一致性的需求选择不同强度的元数据同步（写者可见 / 定期同步 / 全局同步），把一致性开销交给应用按需付费。
  - **Hadash 数据管理工具**：提供 BB 内高效数据查询，并加速 BB 与传统 HPC 存储（Lustre 类后端）之间的数据迁移。
- **关键结果**：部署于新一代神威超算，服务数百个应用；支撑最多 **600,000 客户端**并发；聚合 I/O 带宽 **3.1 TB/s**。
- **局限**：面向超算专用互连与作业模型；放松 POSIX（弱化目录语义、rename 等）；元数据的全局视图需要显式同步，通用工作负载不适用。
- **对 LightStore 的启示**：
  - "客户端 → 固定服务端"的本地化分诊思路可借鉴到 LightStore 的写路径：客户端优先向少数固定 DataServer 的 OPEN volume 追加，天然避免全连接风暴，与现有 append-only Volume 模型契合。
  - 元数据一致性分级值得参考：LightStore MetaServer 是线性一致的 Range Raft，可考虑为 AI/HPC 场景提供"作业私有命名空间 + 延迟发布"的弱一致快速路径。

### 2.2 DAOS: A Scale-Out High Performance Storage Stack for Storage Class Memory

- **作者/机构**：Zhen Liang、Johann Lombardi、Mohamad Chaarawi、Michael Hennecke（Intel）
- **会议年份**：Supercomputing Frontiers Asia（SCFA）2020，Springer LNCS 12082
- **链接**：<https://doi.org/10.1007/978-3-030-48842-0_3>
- **目标负载**：HPC 与数据密集型负载的高 IOPS + 高带宽存储；为 Aurora 等 E 级系统设计的下一代存储栈。
- **核心设计**：
  - **全用户态、绕内核**：数据路径完全在用户态，SCM（Optane PMem，经 PMDK）存元数据与小 I/O，NVMe SSD（经 SPDK）存大块数据；无内核文件系统、无本地文件系统开销。
  - **事务化、多版本对象模型**：对象为 key-array 结构（dkey/akey/数组），支持 epoch 版本与分布式事务；元数据路径与数据路径分离。
  - **算法化放置**：对象按算法（无中心查表）分布到 storage target，副本/纠删码内建；端到端 checksum。
  - **丰富接入层**：原生对象 API 之上提供 POSIX（libdfs/dfuse）、MPI-IO、HDF5 等中间件适配。
- **关键结果**：论文给出 IO500 基准的初始性能；此后 DAOS 长期位居 IO500 榜单前列（如 SC21 期间 QCT 系统进入总榜第 16、10 节点挑战第 12），并成为 Argonne Aurora（EiB 级、待确认具体容量）的主存储，在 MLPerf Storage 中亦有领先表现。
- **局限**：深度绑定 Optane PMem（Intel 已停产 Optane，后续版本转向 "Metadata-on-NVMe" 架构，见 DAOS "Beyond Persistent Memory" 后续论文）；运维复杂度高；强依赖 RDMA 网络。
- **对 LightStore 的启示**：
  - 用户态数据路径 + SPDK 是 LightStore DataServer 追求 TB/s 级聚合带宽的可行路线；小 I/O 与元数据放低延迟介质、大 I/O 直下 NVMe 的分流思想与 LightStore "小文件打包进 volume" 互补。
  - DAOS 的教训：不要把持久化格式绑死在特定硬件（PMem）；LightStore 的 append-only volume 对介质假设弱，是更稳健的选择。

### 2.3 DeltaFS: A Scalable No-Ground-Truth Filesystem For Massively-Parallel Computing

- **作者/机构**：Qing Zheng、Chuck Cranor、Greg Ganger、George Amvrosiadis、Garth Gibson、Brad Settlemyer、Gary Grider 等，CMU 与 Los Alamos National Laboratory（LANL）
- **会议年份**：SC 2021
- **链接**：<https://sc21.supercomputing.org/proceedings/tech_paper/tech_paper_files/pap169s6.pdf>
- **目标负载**：超大规模并行作业的元数据风暴（如 N-N checkpoint 一次创建数亿文件），以及作业间的数据发布/共享。
- **核心设计**：
  - **无专职元数据服务器（serverless）**：文件系统元数据服务作为库运行在计算节点上，随作业启动、随作业消亡，元数据吞吐随作业规模线性扩展。
  - **"No Ground Truth" 原则**：不维护全局唯一的文件系统命名空间。每个作业把自己的命名空间变更自提交（self-commit）为日志/快照，发布到一个注册表；后续作业按需选择并合并前序作业发布的快照，避免全局同步。
  - 元数据以 LSM 结构（源自 IndexFS 系）打包成不可变 SSTable 存入共享底层存储，作业间以数据形式传递元数据。
- **关键结果**：在 LANL 超算上验证元数据吞吐随计算节点数近线性扩展，创建风暴场景相对传统全局文件系统有数量级加速（具体规模与倍数待确认）。
- **局限**：放弃全局命名空间对交互式/多租户场景不友好；快照合并把一致性责任推给应用与工作流层；主要适配批处理科学工作流。
- **对 LightStore 的启示**：
  - LightStore 走的是"全局命名空间 + 数千 Range Raft"的强一致路线，与 DeltaFS 相反；但 DeltaFS 证明了**元数据即数据（metadata as data）**的价值：可考虑支持"批量导入"接口——作业先在本地生成排序好的 KV SSTable，再整体 ingest 进 MetaServer 的 Range，绕开逐条 Raft 提交，服务 AI 数据集导入与 HPC 创建风暴。

### 2.4 UnifyFS: A User-level Shared File System for Unified Access to Distributed Local Storage

- **作者/机构**：Michael Brim、Adam Moody、Seung-Hwan Lim、Ross Miller、Swen Boehm、Cameron Stanavige、Kathryn Mohror、Sarp Oral（ORNL、LLNL）
- **会议年份**：IEEE IPDPS 2023（获 Best Open Source Software Award）
- **链接**：<https://ieeexplore.ieee.org/document/10177390>；项目：<https://github.com/LLNL/UnifyFS>
- **目标负载**：将计算节点本地 SSD/burst buffer 聚合为作业生命周期内的共享文件系统，服务 checkpoint（N-N/N-1）与作业内共享读写。
- **核心设计**：
  - **用户态透明拦截**：通过 GOTCHA 等机制拦截应用 I/O 调用，无需改应用、无需内核模块；每计算节点一个 server 进程（基于 Mochi/Margo RPC，细节待确认）。
  - **写本地、读全局**：写入落在写者的节点本地存储（日志式追加），元数据记录 extent 归属；读者经分布式元数据定位到数据所在节点拉取。
  - **lamination（层压）语义**：文件在显式同步点之前只保证写者可见，laminate 之后变为全局只读可见——用放松的可见性语义换取无锁的高并发写。
- **关键结果**：在 Summit/Frontier 级系统上验证了聚合带宽随节点数近线性扩展、N-1 共享写显著优于并行文件系统直写（具体数字待确认）。
- **局限**：作业生命周期文件系统，数据持久性依赖显式下刷到后端 PFS；放松语义要求应用遵守"写完再读"的模式。
- **对 LightStore 的启示**：
  - lamination 与 LightStore volume 的 `OPEN → SEALED` 生命周期在理念上同构（密封后永久只读）；可把这一语义上提到文件层：为 checkpoint/训练产物提供"追加期私有、密封后共享"的文件状态机，简化一致性协议。

### 2.5 GekkoFS：临时 burst buffer 文件系统（2020 后续期刊论文）

- **作者/机构**：Marc-André Vef、Nafiseh Moti、Tim Süß、Markus Tacke、Tommaso Tocci、Ramon Nou、Alberto Miranda、Toni Cortes、André Brinkmann（美因茨大学 JGU、巴塞罗那超算中心 BSC 等）
- **会议年份**：Journal of Computer Science and Technology（JCST）2020, 35(1): 72–91（题为 "GekkoFS — A Temporary Burst Buffer File System for HPC Applications"，是 CLUSTER 2018 原始论文的扩展版；期刊版标题细节待确认）
- **链接**：<https://link.springer.com/article/10.1007/s11390-020-9797-6>（DOI 待确认）；项目：<https://storage.bsc.es/gitlab/hpc/gekkofs>
- **目标负载**：单作业/短期 campaign 的 ad-hoc 文件系统：把作业分到的计算节点本地 SSD 聚合成临时命名空间，吸收元数据风暴与突发 I/O。
- **核心设计**：
  - **完全去中心化**：目录项、inode、数据块全部按 hash 均匀分布到所有节点，无专职元数据服务器；放弃目录遍历语义（readdir 代价高、不支持复杂 rename），换取元数据操作单跳定位。
  - 客户端以 syscall 拦截库接入；数据按固定 chunk 切分 hash 分布。
- **关键结果**：元数据操作（create/stat/remove）吞吐随节点数近线性扩展，512 节点规模达到数千万 ops/s 量级（具体数字待确认）；是欧洲 ADA-FS/NEXTGenIO 项目的核心成果，后续衍生大量 ad-hoc FS 对比研究（如 FGCS 2025 的比较研究）。
- **局限**：hash 分布使目录局部性丢失；临时性质，不管持久化与容错；一节点故障即数据不完整。
- **对 LightStore 的启示**：
  - GekkoFS 代表"hash 扁平命名空间"极端，LightStore 的 Range 分片保留了目录局部性（一个目录的 dentry 连续），对 `ls`/遍历更友好；但 GekkoFS 提示：对 AI 训练这类"只按已知路径 open"的负载，可提供 hash 直达的 fast-path（跳过逐级路径解析），与 FalconFS 的结论互相印证。

### 2.6 CHFS: Parallel Consistent Hashing File System for Node-local Persistent Memory

- **作者/机构**：Osamu Tatebe、Kazuki Obata、Kohei Hiraga（筑波大学）、Hiroki Ohtsuji（富士通研究所）
- **会议年份**：HPC Asia 2022
- **链接**：<https://dl.acm.org/doi/10.1145/3492805.3492807>；项目：<https://github.com/otatebe/chfs>
- **目标负载**：利用计算节点本地持久内存（PMem）构建 ad-hoc 并行文件系统，服务 HPC 突发 I/O。
- **核心设计**：
  - **整个文件系统 = 一个分布式 KV 存储**：基于一致性 hash 的 KV（节点本地用 pmemkv，RPC 用 Mochi/Margo + RDMA），文件切 chunk 后与元数据一起作为 KV 对分布。
  - **三个"消除"**：消除专职元数据服务器、消除关键路径上的顺序执行、消除中心化数据管理——节点加入/退出仅影响一致性 hash 环上相邻区间。
- **关键结果**：元数据与数据访问性能随节点数扩展性优于对比系统（GekkoFS 等，具体数字待确认）；后续有基于 CHFS 的缓存文件系统等衍生工作（待确认）。
- **局限**：依赖 PMem（同样受 Optane 停产影响）；一致性 hash 的负载均衡在倾斜负载下弱于按需分裂的 Range 分片；语义放松。
- **对 LightStore 的启示**：
  - 印证了"文件系统 KV 化"的大方向（LightStore 已采用：inode/dentry/extent 全 KV 化）；差异在于 LightStore 选择 Range+Raft（强一致、可分裂）而非一致性 hash（最终一致、静态均衡），前者更适合作为持久共享存储而非临时 BB。

---

## 3. AI 训练方向：面向 AI 负载的分布式文件系统

### 3.1 3FS（Fire-Flyer File System, DeepSeek）

- **作者/机构**：DeepSeek-AI（幻方/High-Flyer 血统）；相关正式论文为 "Fire-Flyer AI-HPC: A Cost-Effective Software-Hardware Co-Design for Deep Learning"（An 等，作者列表待确认）
- **会议年份**：Fire-Flyer AI-HPC 发表于 SC 2024（arXiv:2408.14158，其中描述 3FS 在整体软硬件栈中的角色）；3FS 本身于 2025-02 开源并发布设计文档（无独立会议论文，属技术报告/开源设计说明）
- **链接**：<https://dl.acm.org/doi/10.1109/SC41406.2024.00089>；<https://arxiv.org/abs/2408.14158>；<https://github.com/deepseek-ai/3FS>
- **目标负载**：AI 训练与推理的全链路存储：训练数据随机读、checkpoint 读写、KVCache 分层。设计上**几乎只为随机读带宽优化**，明确放弃读缓存。
- **核心设计**：
  - **分离式（disaggregated）架构**：大量 NVMe SSD + RDMA 网络聚合为共享存储层；计算节点经 RDMA 零拷贝直读远端 NVMe。
  - **元数据放外部事务 KV**：元数据服务无状态，落在 FoundationDB（SSI 事务）上，元数据服务本身可水平扩展、随意重启。
  - **数据用 CRAQ 链式复制**：Chain Replication with Apportioned Queries 提供强一致读写分离，读可打散到链上任意副本，适配读多写少。
  - **接口分层**：FUSE 便利接入 + 原生异步 API（USRBIO）绕 FUSE 获取全性能；训练数据用 FFRecord 打包格式，规避海量小文件的 per-file 开销。
  - 明确不做读 cache（数据集远大于内存、随机访问缓存无益），把内存留给应用。
- **关键结果**：生产部署 **180 个存储节点**（每节点 16×14 TiB NVMe、2×200 Gbps InfiniBand），聚合读带宽 **6.6 TiB/s**（另有资料称峰值 7.3 TB/s）；GraySort 基准 25 节点 3.66 TiB/min（待确认）；KVCache 读峰值 40 GiB/s（待确认）。支撑 DeepSeek-V3/R1 的训练与推理。
- **局限**：强依赖 RDMA 与高端 NVMe；FoundationDB 元数据路径的延迟与吞吐上限（每操作事务开销）在元数据密集场景可能成为瓶颈；FUSE 路径性能损失明显（官方以 USRBIO 弥补）；无会议论文，公开性能数据多为自述。
- **对 LightStore 的启示**：
  - **与 LightStore 架构高度可对话**：3FS 的"无状态元数据 + 外部事务 KV"对应 LightStore 的 MetaServer（区别：LightStore 自研 Range Raft，避免了外部 FoundationDB 依赖，但要自己解决跨 Range 事务）。
  - CRAQ 的"读打散到全部副本"值得 DataServer 借鉴：LightStore volume 密封后永久只读，天然可以任意副本读、无需读主，应在读路径明确利用这一点。
  - 原生异步 API 优先、FUSE 只做兼容层的接口策略，与 LightStore "C++ SDK 为一等公民、FUSE 后置"的规划一致，可坚定该路线。

### 3.2 FalconFS: Distributed File System for Large-Scale Deep Learning Pipeline

- **作者/机构**：Jingwei Xu 等，上海交通大学 与 华为（含华为自动驾驶业务）
- **会议年份**：USENIX NSDI 2026（arXiv:2507.10367，2025-07 公开）
- **链接**：<https://www.usenix.org/conference/nsdi26/presentation/xu>；<https://arxiv.org/abs/2507.10367>；<https://github.com/falcon-infra/falconfs>
- **目标负载**：深度学习数据管道的海量小文件：数据采集、预处理、训练全流程的高并发小文件读写与元数据密集访问。
- **核心设计**：
  - **无状态客户端（stateless client）**：核心观察是 DL 管道中客户端缓存（dentry/元数据缓存）命中率极低还白耗内存——于是干脆取消客户端状态，路径解析全部推到服务端。
  - **服务端混合元数据索引（hybrid metadata indexing）**：文件名 hash 分布 + 目录路径的服务端解析，单次 RPC 完成 lookup，避免逐级路径遍历。
  - **惰性命名空间复制（lazy namespace replication）**：目录结构在元数据节点间按需惰性复制，使各节点能本地完成路径解析，同时保持目录变更代价可控。
- **关键结果**：对比 CephFS 与 Lustre：小文件读写吞吐最高 **5.72×**，DL 模型训练吞吐最高 **12.81×**；已在华为自动驾驶生产环境（**10,000 NPU** 集群）运行一年，已开源。
- **局限**：面向"路径已知、直接 open"的负载，目录枚举/rename 类操作非重点；hash 分布对超大目录/热点目录的均衡有代价（细节待确认）。
- **对 LightStore 的启示**：
  - 最直接相关的近期工作。LightStore 的 Range 分片按 key 范围保目录局部性，路径解析仍需逐级（父目录 → dentry → inode）；FalconFS 证明 AI 负载下**单 RPC lookup** 收益巨大——可在 MetaServer 增加"全路径 → inode"的辅助索引或服务端路径解析代理，作为 AI 场景 fast-path。
  - "无状态客户端"提示 LightStore SDK：对训练负载默认关闭元数据缓存、改为服务端批量 lookup（如 open 一个 manifest 内全部文件），比在客户端堆缓存更有效。

### 3.3 Tectonic-Shift: A Composite Storage Fabric for Large-Scale ML Training（简述）

- **作者/机构**：Mark Zhao（Stanford/Meta）等，Meta 与 Stanford
- **会议年份**：USENIX ATC 2023（注意：非 FAST 2023）
- **链接**：<https://www.usenix.org/conference/atc23/presentation/zhao>
- **AI 训练 I/O 角度简述**：Meta 生产 ML 训练的数据存储原先由 HDD 为主的 Tectonic 承担，但训练读的 IOPS 需求使 HDD 的 IO-per-watt 成为扩展瓶颈。Tectonic-Shift 在 Tectonic 之上加一层 flash 缓存层 Shift，用 I/O 高效的 flash 吸收训练读流量，降低对 HDD 容量/主轴数的需求，从而提升整个存储 fabric 的功耗效率。其缓存准入/放置利用训练作业的数据集访问可预测性（训练计划已知即将读什么）。这一"HDD 容量层 + flash 训练读加速层 + 训练感知预取"的分层模式是工业界共识。Tectonic 本体与该论文的完整分析见 [industry-production-systems.md](industry-production-systems.md)。
- **对 LightStore 的启示**：LightStore 面向 EiB 级低成本（EC + HDD 可行）时，AI 训练读负载不应直接压容量层；应预留"训练读缓存层"位置（独立 flash 缓存集群或 DataServer 内分层），并利用训练侧的访问计划做预取——接口上值得为"数据集即将被顺序/随机全量读"暴露 hint API。

---

## 4. AI 训练数据加载与缓存系统（与文件系统紧密相关者）

> 本节系统均为"文件系统之上的训练感知缓存/调度层"，与 DFS 的接口和语义设计强相关；纯数据管道类工作（tf.data、Deep Lake、RINAS 等）与文件系统弱相关，仅在此一笔带过。Alluxio 本身 2020 年后无新的系统顶会论文，其在 AI 场景的角色主要经由 Fluid（下文）与工业实践体现。

### 4.1 Quiver: An Informed Storage Cache for Deep Learning

- **作者/机构**：Abhishek Vijaya Kumar、Muthian Sivathanu，Microsoft Research India
- **会议年份**：USENIX FAST 2020
- **链接**：<https://www.usenix.org/conference/fast20/presentation/kumar>
- **目标负载**：GPU 集群中深度学习训练作业的共享数据集读取。
- **核心设计**：① 基于内容 hash 的寻址，使同一数据集可跨作业、跨用户安全共享缓存；② 与训练框架（PyTorch）协同的 **substitutable cache hits**——随机采样下任何未用过的样本都可替代命中，小缓存也能持续供给命中而不 thrash；③ 按作业对缓存的边际收益动态分配缓存容量。
- **关键结果**：PyTorch 原型显著提升训练吞吐（论文报告多作业场景下明显加速，具体倍数依负载而异）。
- **局限**：需要框架配合（改 DataLoader）；只覆盖读缓存，不管元数据与写路径。
- **对 LightStore 的启示**：内容寻址与 LightStore 的 Loc（volume_id+offset+cookie）思路兼容——可在 SDK 层提供"数据集打包 + 内容 hash 清单"的读取模式，让缓存层跨作业去重；"替代命中"这类语义只能在 SDK/缓存层做，不应侵入 DFS 核心。

### 4.2 SHADE: Enable Fundamental Cacheability for Distributed Deep Learning Training

- **作者/机构**：Redwan Ibne Seraj Khan、Ali R. Butt 等，Virginia Tech（合作者含其他机构，名单待确认）
- **会议年份**：USENIX FAST 2023
- **链接**：<https://www.usenix.org/conference/fast23/presentation/khan>
- **目标负载**：分布式 DNN 训练的样本读取缓存。
- **核心设计**：观察到样本对训练的**重要性（importance）不均匀**且随训练动态变化；SHADE 以 rank-based 方式在 minibatch 间捕捉样本相对重要性，动态更新重要性分数，优先缓存高重要性样本——把缓存决策从"访问频率"换成"训练价值"。
- **关键结果**：小缓存下命中率相对 LRU 最高提升 **4.5×**，训练吞吐显著提升（CV 模型验证）。
- **局限**：依赖重要性采样类训练法的适用性；与训练框架深度耦合。
- **对 LightStore 的启示**：进一步说明训练缓存策略属于框架/缓存层；LightStore 要做的是把随机读路径做到足够便宜（密封 volume 任意副本读、Loc 直达免索引），让上层缓存失效时代价也可接受。

### 4.3 SiloD: A Co-design of Caching and Scheduling for Deep Learning Clusters

- **作者/机构**：Hanyu Zhao 等，Microsoft Research 与高校合作（北京大学等，名单待确认）
- **会议年份**：EuroSys 2023
- **链接**：<https://dl.acm.org/doi/10.1145/3552326.3567499>
- **目标负载**：深度学习集群中缓存容量与远端存储 I/O 带宽的分配。
- **核心设计**：把**缓存和远端 I/O 当作与 GPU 同级的一等资源**纳入集群调度：建立"分配多少缓存/带宽 → 作业吞吐"的性能估计模型，统一框架下适配多种调度策略，使调度器联合决策计算与存储资源。
- **关键结果**：相对存储无感知的调度器显著提升集群聚合吞吐（论文报告最高数倍提升，具体数字待确认）。
- **局限**：依赖作业吞吐模型准确性；主要针对数据并行训练。
- **对 LightStore 的启示**：DFS 应向上暴露可观测与可配额的接口：per-tenant/per-job 的带宽配额、缓存命中率与后端 I/O 计量，使上层调度器可以做 SiloD 式联合优化。LightStore Manager 不在 IO 路径上，配额执行应放在 DataServer/SDK。

### 4.4 Fluid: Dataset Abstraction and Elastic Acceleration for Cloud-native Deep Learning Training Jobs（简述）

- **作者/机构**：Rong Gu（南京大学）、Yang Che、Bin Fan（Alluxio）等，南京大学与阿里巴巴等
- **会议年份**：IEEE ICDE 2022；项目现为 CNCF Incubating（2026-01 晋级）
- **链接**：<https://ieeexplore.ieee.org/document/9835158>；<https://github.com/fluid-cloudnative/fluid>
- **简述**：Kubernetes 上的"数据集"抽象与弹性缓存编排：把 Alluxio/JuiceFS 等缓存系统包装为可观测、可弹性伸缩、自愈的缓存服务，训练作业以统一方式访问异构底层存储并获得透明加速。与 DFS 的关系是**编排层**而非文件系统本体，故仅简述。
- **对 LightStore 的启示**：LightStore 若进入云原生 AI 场景，应提供 CSI 驱动与 Fluid runtime 对接点，把自身定位为 Fluid 之下的高性能持久层。

---

## 5. Checkpoint 存储方向

### 5.1 CheckFreq: Frequent, Fine-Grained DNN Checkpointing

- **作者/机构**：Jayashree Mohan（UT Austin）、Amar Phanishayee（Microsoft Research）、Vijay Chidambaram（UT Austin/VMware）
- **会议年份**：USENIX FAST 2021
- **链接**：<https://www.usenix.org/conference/fast21/presentation/mohan>
- **目标负载**：DNN 训练的高频 checkpoint（迭代粒度而非 epoch 粒度）。
- **核心设计**：① 在线 profiling 自动确定 checkpoint 频率并动态调节以限定开销；② **两阶段 checkpoint**：先在 GPU/CPU 内存快照（snapshot），再异步持久化（persist），与计算流水线化；③ 可恢复数据迭代器，checkpoint 数据加载器状态以保持"每 epoch 每样本恰好一次"的不变式。
- **关键结果**：恢复时间从小时级降到秒级，运行时开销控制在 **3.5%** 以内。
- **局限**：单机/数据并行为主，未处理大模型多维并行的分片 checkpoint；存储侧只当黑盒。
- **对 LightStore 的启示**：checkpoint 写是"快照后异步刷"的顺序大写，与 LightStore append-only volume 完美匹配；应保证 OPEN volume 的追加写延迟稳定（尾延迟影响训练停顿），并考虑为 checkpoint 提供预留卷/预分配（写入方 hint 即将写入 N GB）。

### 5.2 Check-N-Run: A Checkpointing System for Training Deep Learning Recommendation Models（简述）

- **作者/机构**：Assaf Eisenman 等，Meta（Facebook）与 USC
- **会议年份**：USENIX NSDI 2022
- **链接**：<https://www.usenix.org/conference/nsdi22/presentation/eisenman>
- **简述**：针对推荐模型 TB 级 embedding 表的 checkpoint：**差分 checkpoint**（只写每轮被更新的 embedding 部分）+ **量化压缩**，在不影响精度前提下将所需写带宽降低 **6–17×**、容量降低 **2.5–8×**。启示：DFS 无需理解差分逻辑，但要善于处理"高频中等大小追加写 + 版本化对象"模式；LightStore 的 record 追加 + extent 覆盖提交天然支持这种部分更新落盘。

### 5.3 Gemini: Fast Failure Recovery in Distributed Training with In-Memory Checkpoints

- **作者/机构**：Zhuang Wang、T. S. Eugene Ng（Rice University）与 Amazon Web Services 合作者
- **会议年份**：SOSP 2023
- **链接**：<https://dl.acm.org/doi/10.1145/3600006.3613145>
- **目标负载**：LLM 分布式训练的快速故障恢复。
- **核心设计**：checkpoint 到**主机 CPU 内存**（聚合带宽远高于远端存储）：① 近似最优的 checkpoint 副本放置策略，最大化故障后能从 CPU 内存恢复的概率；② checkpoint 流量与训练通信共享网络，设计流量调度算法交织传输、消除对训练吞吐的干扰；远端持久存储仍作兜底层。
- **关键结果**：故障恢复比既有方案快 **13× 以上**；实现**每迭代一次** checkpoint；对训练吞吐无可见开销。
- **局限**：CPU 内存 checkpoint 不抗大面积同时故障（机房级），仍需存储层兜底；占用主机内存与网络。
- **对 LightStore 的启示**：定位启示——训练系统会把最热的 checkpoint 路径留在计算集群内存里，DFS 承接的是**次频、持久兜底**的 checkpoint 写；LightStore 应优化的是大并发顺序写的聚合带宽与恢复读（restart 时全员并发读同一 checkpoint,密封卷多副本读又一次关键）。

### 5.4 ByteCheckpoint: A Unified Checkpointing System for Large Foundation Model Development

- **作者/机构**：Borui Wan（香港大学）、Mingji Han、Yanghua Peng、Haibin Lin、Xin Liu、Chuan Wu 等，字节跳动与香港大学
- **会议年份**：USENIX NSDI 2025（arXiv:2407.20143）
- **链接**：<https://arxiv.org/abs/2407.20143>；<https://github.com/ByteDance-Seed/ByteCheckpoint>
- **目标负载**：大模型（LFM）开发全流程的 checkpoint：万卡级训练、跨并行策略的 checkpoint 迁移（resharding）、多训练框架、多存储后端。
- **核心设计**：① **与并行策略解耦的 checkpoint 表示**，加载时高效 resharding（换并行度重启不需离线转换）；② 统一的保存/加载工作流适配多框架与多存储后端；③ 全栈 I/O 优化（异步流水、去重、负载均衡，细节待确认）＋大规模监控工具。
- **关键结果**：相对既有开源 checkpoint 系统，运行时 checkpoint 停顿平均降低 **54.2×**，保存最快提升 **9.96×**，加载最快提升 **8.80×**。生产部署于字节跳动。
- **局限**：checkpoint 框架层工作，存储后端仍为 HDFS/对象存储等黑盒；停顿数字依赖对比基线。
- **对 LightStore 的启示**：ByteCheckpoint 这类框架就是 LightStore 的直接上游客户——它需要的后端接口是：高并发分片写（数千 rank 各写自己的 shard）、原子提交/manifest（一次 checkpoint 的全部分片可见性一致）、按分片并行读。LightStore 可提供"目录级批量提交"或 manifest 文件原子发布的原语，避免框架自己用 rename 技巧拼装原子性。

---

## 6. 对 LightStore 的总体启示汇总

1. **读路径**：密封 volume 永久只读是 LightStore 的结构性优势——学习 3FS/CRAQ，把"任意副本读、读打散"做成默认行为，服务 AI 随机读与 checkpoint 恢复的读风暴。
2. **元数据 fast-path**：FalconFS/HadaFS/GekkoFS 共同指向"AI/HPC 负载不需要逐级路径解析"——在保留全局强一致目录树的同时，提供服务端单 RPC lookup（全路径索引或解析代理）与批量 lookup。
3. **批量导入与创建风暴**：借鉴 DeltaFS 的 metadata-as-data，为 MetaServer 提供 SSTable 级批量 ingest，吸收 N-N checkpoint 与数据集导入的创建风暴。
4. **语义分级**：UnifyFS 的 lamination、HadaFS 的三级元数据同步说明：给作业私有数据提供弱一致快速通道 + 显式发布点，是 HPC/AI 场景的通用模式。
5. **checkpoint 接口**：为上游 checkpoint 框架（ByteCheckpoint 类）提供并发分片写 + manifest 原子发布原语；保证追加写尾延迟稳定。
6. **缓存边界**：训练感知缓存（Quiver/SHADE/SiloD/Fluid）应留在 SDK/缓存层与编排层，DFS 提供内容寻址友好的 Loc、hint API（预取/即将全量读）与 per-job 配额计量即可。
7. **成本分层**：Tectonic-Shift 模式下，LightStore 的 EC+HDD 容量层之上应预留 flash 训练读加速层的位置。

---

## 7. 汇总表

| 论文/系统 | 会议 年份 | 目标负载 | 核心思路 |
|---|---|---|---|
| HadaFS | FAST 2023 | E 级超算 burst buffer | Localized Triage 架构桥接 local/shared BB；全路径索引 + 分级元数据同步 |
| DAOS | SCFA 2020 | HPC 高 IOPS/带宽存储 | 全用户态栈，SCM+NVMe 分流，事务化对象模型，算法放置 |
| DeltaFS | SC 2021 | 超大规模元数据风暴 | 无元数据服务器，作业自提交命名空间快照，No Ground Truth 按需合并 |
| UnifyFS | IPDPS 2023 | 节点本地存储聚合 / checkpoint | 用户态拦截，写本地读全局，lamination 可见性语义 |
| GekkoFS（JCST 扩展版） | JCST 2020 | 单作业 ad-hoc burst buffer | 元数据/数据全 hash 去中心分布，放松目录语义换线性扩展 |
| CHFS | HPC Asia 2022 | 节点本地 PMem ad-hoc FS | 文件系统完全构建于一致性 hash 分布式 KV 之上 |
| 3FS / Fire-Flyer AI-HPC | SC 2024 + 2025 开源报告 | AI 训练/推理全链路存储 | RDMA 直读 NVMe，FoundationDB 无状态元数据，CRAQ 链复制，随机读优先、放弃读缓存 |
| FalconFS | NSDI 2026 | DL 管道海量小文件 | 无状态客户端，服务端混合元数据索引 + 惰性命名空间复制，单 RPC lookup |
| Tectonic-Shift | ATC 2023 | Meta ML 训练数据读 | HDD 容量层上加训练感知 flash 缓存层，优化 IO-per-watt（详见 industry 文档） |
| Quiver | FAST 2020 | 训练数据集共享缓存 | 内容 hash 跨作业共享 + 可替代缓存命中 + 收益感知分配 |
| SHADE | FAST 2023 | 分布式训练样本缓存 | 按样本训练重要性（而非访问频率）做缓存决策 |
| SiloD | EuroSys 2023 | DL 集群资源调度 | 缓存与远端 I/O 作为一等资源与 GPU 联合调度 |
| Fluid | ICDE 2022 | 云原生训练数据编排 | K8s 数据集抽象 + 弹性缓存运行时（Alluxio/JuiceFS）编排 |
| CheckFreq | FAST 2021 | DNN 高频 checkpoint | 迭代粒度、两阶段（快照+异步持久化）流水线，开销 <3.5% |
| Check-N-Run | NSDI 2022 | 推荐模型 checkpoint | 差分 checkpoint + 量化，写带宽降 6–17× |
| Gemini | SOSP 2023 | LLM 训练故障恢复 | checkpoint 进主机 CPU 内存，近优放置 + 流量交织，恢复快 13× |
| ByteCheckpoint | NSDI 2025 | 大模型全流程 checkpoint | 并行策略无关表示 + 加载时 resharding + 全栈 I/O 优化 |

---

## 参考来源（部分）

- USENIX FAST/ATC/NSDI 论文页（usenix.org，各论文条目见上文链接）
- SC21/SC24 proceedings（supercomputing.org / dl.acm.org）
- ACM DL：SiloD（EuroSys'23）、CHFS（HPCAsia'22）、Gemini（SOSP'23）、DAOS（SCFA'20）
- arXiv：2408.14158（Fire-Flyer AI-HPC）、2507.10367（FalconFS）、2407.20143（ByteCheckpoint）
- 开源仓库：deepseek-ai/3FS、falcon-infra/falconfs、LLNL/UnifyFS、fluid-cloudnative/fluid、ByteDance-Seed/ByteCheckpoint、otatebe/chfs
