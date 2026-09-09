# 分布式文件系统论文调研（2020 年之后）

> 调研日期：2026-08-15
>
> 范围：2020 年（含）之后发表的分布式文件系统及紧密相关领域的论文，以 FAST / OSDI / SOSP / ATC / EuroSys / NSDI / ASPLOS / SC / SoCC 等系统方向会议为主，辅以少量经核实的期刊、workshop 与工业界技术报告（非同行评审材料在文中均明确标注）。
>
> 视角：为 LightStore（manager/metaserver/dataserver 架构的自研 C++ 分布式文件系统）的设计与演进提供论文层面的参照。每篇论文均记录出处链接与"对 LightStore 的启示"。

## 1. 文档导航

按主题分为五个方向，每个方向一份文档：

1. [工业界大规模生产系统](industry-production-systems.md)：Meta Tectonic / Tectonic-Shift、Alibaba Pangu / Fisc、Baidu CFS、DeepSeek Fire-Flyer 与 3FS、Huawei FalconFS、Google Colossus（博客）与 CacheSack 等。看"真实生产规模下什么设计能活下来"。
2. [元数据扩展性](metadata-scalability.md)：InfiniFS、CFS、SingularFS、λFS、FileScale、Mantle、HMFS、FalconFS、MesaFS、SwitchFS 等。聚焦 namespace 分区、路径解析、rename 原子性、热点与弹性扩容，是 metaserver 设计最直接的参照。
3. [新硬件方向](new-hardware.md)：Assise、Octopus+、LineFS、DPFS、DAOS、Famfs、3FS 等。覆盖 persistent memory（含 Optane 停产后的格局）、RDMA、SmartNIC/DPU 卸载与 CXL。
4. [HPC 与 AI 训练存储](hpc-ai-storage.md)：HadaFS、DeltaFS、UnifyFS、GekkoFS、CHFS 等 burst buffer / 超算文件系统，Quiver、SHADE、SiloD 等训练缓存，以及 CheckFreq、Gemini、ByteCheckpoint 等 checkpoint 存储工作。
5. [客户端与通用技术](client-and-general-techniques.md)：FUSE 优化（XFUSE、RFUSE、FUSE-over-io_uring）、缓存一致性（DFUSE、Concordia）、纠删码（ECWide、wide LRC、Tiger、RepairBoost、ParaRC）、可靠性实证与 crash consistency（Perseus、EBS 演进、Metis 等）。

## 2. 跨文档重叠说明

部分论文同时涉及多个主题，会在多份文档中出现；下表标注主文档（详解所在），其余文档为交叉视角或简述：

| 论文 | 主文档 | 其他出现位置（视角） |
|------|--------|----------------------|
| Tectonic (FAST 2021) | 工业界生产系统 | 元数据扩展性（namespace 分层 KV 化视角） |
| Tectonic-Shift (ATC 2023) | 工业界生产系统 | HPC/AI 存储（训练 IO 视角，简述） |
| InfiniFS (FAST 2022) | 元数据扩展性 | 工业界生产系统、客户端与通用技术（客户端元数据缓存视角） |
| CFS (EuroSys 2023) | 元数据扩展性 | 工业界生产系统、客户端与通用技术（事务临界区视角） |
| Fisc (FAST 2023) | 工业界生产系统 | 新硬件（DPU 卸载视角）、客户端与通用技术（轻量客户端视角） |
| SingularFS (ATC 2023) | 元数据扩展性 | 新硬件（PM + RDMA 视角） |
| FalconFS (NSDI 2026) | 元数据扩展性 | 工业界生产系统、HPC/AI 存储（深度学习负载视角） |
| 3FS / Fire-Flyer (SC 2024 + 2025 开源报告) | 工业界生产系统 | 新硬件（RDMA+NVMe 视角）、HPC/AI 存储（AI 负载视角） |
| DPFS (SYSTOR 2023) | 客户端与通用技术 | 新硬件（DPU 视角） |
| DAOS (SCFA 2020) | HPC/AI 存储 | 新硬件（SCM/后 PM 演进视角） |

## 3. 论文总索引

### 工业界生产系统

| 论文 | 机构 | 会议/年份 |
|------|------|-----------|
| Facebook's Tectonic Filesystem: Efficiency from Exascale | Meta | FAST 2021 |
| Tectonic-Shift: A Composite Storage Fabric for Large-Scale ML Training | Meta + Stanford | ATC 2023 |
| More Than Capacity: Performance-oriented Evolution of Pangu in Alibaba | Alibaba | FAST 2023 |
| Fisc: A Large-scale Cloud-native-oriented File System | Alibaba | FAST 2023 |
| CFS: Scaling Metadata Service via Pruned Scope of Critical Sections | 中科大 + Baidu | EuroSys 2023 |
| Fire-Flyer AI-HPC: A Cost-Effective Software-Hardware Co-Design for Deep Learning | DeepSeek-AI | SC 2024 |
| 3FS (Fire-Flyer File System) | DeepSeek-AI | 2025 开源报告（非论文） |
| FalconFS: Distributed File System for Large-Scale Deep Learning Pipeline | Huawei + 上交 IPADS | NSDI 2026 |
| A peek behind Colossus | Google | 2021 官方博客（非论文） |
| CacheSack: Admission Optimization for Google Datacenter Flash Caches | Google | ATC 2022 |
| What's the Story in EBS Glory | Alibaba | FAST 2024 |
| Discard-Based GC for Distributed Log-Structured Storage | ByteDance | FAST 2026 |

### 元数据扩展性

| 论文 | 机构 | 会议/年份 |
|------|------|-----------|
| InfiniFS: An Efficient Metadata Service for Large-Scale Distributed Filesystems | 清华 | FAST 2022 |
| SingularFS: A Billion-Scale DFS Using a Single Metadata Server | 清华 | ATC 2023 |
| λFS: Scalable and Elastic DFS Metadata Service using Serverless Functions | GMU 等 | ASPLOS 2023 |
| FileScale: Fast and Elastic Metadata Management for DFS | UMD | SoCC 2023 |
| Mantle: Efficient Hierarchical Metadata Management for Cloud Object Storage | 中科大 + Baidu + 清华 | SOSP 2025 |
| HMFS: Decoupling Directory Semantics from Metadata Indexing | 清华 | SoCC 2025 |
| MesaFS: An I/O-Efficient Metadata Service for DFS | 清华 | EuroSys 2026 |
| SwitchFS: Asynchronous Metadata Updates with In-Network Coordination | 上交 IPADS | EuroSys 2026 |

### 新硬件

| 论文 | 机构 | 会议/年份 |
|------|------|-----------|
| Assise: Performance and Availability via Client-local NVM | UT Austin 等 | OSDI 2020 |
| Octopus+: An RDMA-Enabled Distributed PM File System | 清华 | ACM TOS 2021 |
| LineFS: Efficient SmartNIC Offload of a DFS with Pipeline Parallelism | KAIST 等 | SOSP 2021（Best Paper） |
| DPFS: DPU-Powered File System Virtualization | IBM Research + VU Amsterdam | SYSTOR 2023 |
| DAOS: A Scale-Out High Performance Storage Stack for SCM | Intel | SCFA 2020 |
| Famfs（CXL 共享内存 fs-dax） | Micron | FAST 2025 poster + 内核 RFC |
| DPC: DPU-accelerated High-Performance File System Client | 重庆大学等 | ICPP 2024 |

### HPC 与 AI 训练存储

| 论文 | 机构 | 会议/年份 |
|------|------|-----------|
| HadaFS: Bridging Local and Shared Burst Buffer for Exascale Supercomputers | 无锡超算 + 清华等 | FAST 2023 |
| DeltaFS: A Scalable No-Ground-Truth Filesystem | CMU / LANL | SC 2021 |
| UnifyFS: User-level Shared File System for Distributed Local Storage | ORNL / LLNL | IPDPS 2023 |
| GekkoFS（期刊扩展版） | JGU Mainz / BSC | JCST 2020 |
| CHFS: Parallel Consistent Hashing File System for Node-local PM | 筑波大学 | HPC Asia 2022 |
| Quiver: An Informed Storage Cache for Deep Learning | MSR India | FAST 2020 |
| SHADE: Enable Fundamental Cacheability for Distributed DL Training | Virginia Tech | FAST 2023 |
| SiloD: Co-design of Caching and Scheduling for DL Clusters | MSR 等 | EuroSys 2023 |
| Fluid: Dataset Abstraction and Elastic Acceleration for Cloud-native DL | 南大 + Alibaba | ICDE 2022 |
| CheckFreq: Frequent, Fine-Grained DNN Checkpointing | UT Austin / MSR | FAST 2021 |
| Check-N-Run: Checkpointing for Training DL Recommendation Models | Meta / USC | NSDI 2022 |
| Gemini: Fast Failure Recovery in Distributed Training with In-Memory Checkpoints | Rice / AWS | SOSP 2023 |
| ByteCheckpoint: A Unified Checkpointing System for Large Foundation Models | ByteDance + HKU | NSDI 2025 |

### 客户端与通用技术

| 论文 | 主题 | 会议/年份 |
|------|------|-----------|
| XFUSE: Running Filesystem Services in User Space | FUSE 优化 | ATC 2021 |
| RFUSE: Scalable Kernel-Userspace Communication | FUSE 优化 | FAST 2024 |
| FUSE-over-io_uring | FUSE 优化（内核工程，非论文） | Linux 6.14 (2025) |
| DFUSE: Strongly Consistent Write-Back Kernel Caching | 缓存一致性 | SoCC 2025 |
| Concordia: DSM with In-Network Cache Coherence | 缓存一致性 | FAST 2021 |
| ECWide: Exploiting Combined Locality for Wide-Stripe Erasure Coding | 纠删码 | FAST 2021 |
| Practical Design Considerations for Wide LRCs | 纠删码 | FAST 2023 |
| Tiger: Disk-Adaptive Redundancy Without Placement Restrictions | 纠删码 | OSDI 2022 |
| RepairBoost: Boosting Full-Node Repair in Erasure-Coded Storage | 纠删码修复 | ATC 2021 |
| ParaRC: Sub-Packetization for Repair Parallelization in MSR Codes | 纠删码修复 | FAST 2023 |
| Perseus: A Fail-Slow Detection Framework for Cloud Storage | 可靠性实证 | FAST 2023 |
| Failure Recovery and Logging of High-Performance Parallel File Systems | 可靠性实证 | ACM TOS 2021 |
| Understanding and Finding Crash-Consistency Bugs in Parallel File Systems | crash consistency | HotStorage 2020 |
| Metis: File System Model Checking | 测试/验证 | FAST 2024 |

## 4. 阅读建议

- **设计 metaserver / namespace**：先读[元数据扩展性](metadata-scalability.md)全篇，再对照[工业界生产系统](industry-production-systems.md)中 Tectonic 与 FalconFS 的取舍。
- **设计 dataserver / 数据路径**：读[工业界生产系统](industry-production-systems.md)中 Pangu、Fisc，[新硬件](new-hardware.md)的 RDMA/用户态栈部分，以及[客户端与通用技术](client-and-general-techniques.md)的纠删码章节。
- **面向 AI 训练负载选型/优化**：读[HPC 与 AI 训练存储](hpc-ai-storage.md)的负载特征综述与 3FS/FalconFS/Tectonic-Shift 相关小节。
- **设计客户端（FUSE vs SDK）**：读[客户端与通用技术](client-and-general-techniques.md)第 1-2 章，对照 Fisc 的轻量客户端路线。
- **评估可靠性工程**：读[客户端与通用技术](client-and-general-techniques.md)第 4 章（Perseus、故障注入研究、Metis）。

## 5. 总体观察

2020 年之后的分布式文件系统研究呈现几条清晰主线：

1. **元数据服务成为主战场**。FAST/SOSP/EuroSys 上 DFS 论文的多数创新集中在 namespace 分区、路径解析与 rename 原子性上；共识是"目录树语义与元数据索引解耦"（InfiniFS、HMFS、FalconFS、Mantle 均属此路线的不同切法）。
2. **工业界论文从"容量导向"转向"性能与成本导向"**。Pangu 的演进论文直接以 100Gbps+ 网络与 SSD 为前提重写数据路径；Fisc 把客户端做薄并卸载到 DPU。
3. **AI 训练负载重塑设计目标**。2023 年后新系统（3FS、FalconFS、Tectonic-Shift）普遍以"海量小文件随机读 + 大文件 checkpoint 写 + 读多写少"为第一负载假设，FFR（fast failure recovery）与吞吐密度优先于 POSIX 完备性。
4. **Optane 停产使 PM 路线转向**。Assise/Octopus+/SingularFS 的 PM 假设需重新评估，社区转向 CXL（Famfs）与 NVMe 用户态栈（DAOS 演进、3FS）。
5. **FUSE 不再被默认接受**。XFUSE/RFUSE/io_uring 改造内核通道，Fisc/DPFS 干脆绕开，自研 SDK + 薄客户端成为生产系统主流。

各文档内的具体数字、链接与"待确认"标注以各文档正文为准。
