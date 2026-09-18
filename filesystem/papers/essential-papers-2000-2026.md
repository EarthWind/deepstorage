# 分布式文件存储重要论文清单（2000 – 2026.08）

> 整理日期：2026-09-09
>
> 覆盖范围：2000 年 1 月至 2026 年 8 月发表的分布式文件系统、对象/Blob 存储及其直接依赖的基础设施论文。以 SOSP / OSDI / FAST / ATC / NSDI / EuroSys / SC / SIGMOD / VLDB / SoCC / ASPLOS 等会议为主，少数具有奠基意义的期刊文章、技术报告和官方文档单独标注为"非同行评审"。
>
> 选取标准：满足以下至少一条——(1) 定义了一条被后续系统反复采用的架构路线；(2) 描述了真实大规模生产系统并公开了关键设计与数据；(3) 给出了被广泛引用的实证研究或理论结果；(4) 是理解现代分布式存储必须掌握的基础组件（共识、复制、纠删码）。
>
> 2020 年之后的论文在本仓库另有逐篇详解，见 [../project/papers/](../project/papers/README.md)；本清单对这部分只做索引与一句话定位。

## 0. 使用说明

- 每张表按年份升序排列，"为什么重要"一栏是本清单的定位判断，不是论文摘要。
- 第 1 节是从全部条目中挑出的 25 篇核心必读，适合作为入门路线；其余各节按主题展开。
- 文末第 12 节给出按年份的总索引，便于查漏。
- 截至整理日，2026 年 7 月举办的 OSDI / ATC 2026 论文尚未纳入核实范围，后续需补充。

## 1. 核心必读 25 篇

按建议阅读顺序排列，覆盖架构路线、元数据、数据路径、可靠性与基础组件。

| # | 论文 | 会议 / 年份 | 一句话定位 |
|---|------|-------------|------------|
| 1 | The Google File System | SOSP 2003 | 单 master + chunkserver + 大块追加写，定义了此后二十年数据中心文件系统的默认形态 |
| 2 | Ceph: A Scalable, High-Performance Distributed File System | OSDI 2006 | 用 CRUSH 计算放置替代中心映射表，元数据与数据彻底分离 |
| 3 | The Hadoop Distributed File System | MSST 2010 | GFS 路线的开源实现，工业界使用最广的分布式文件系统 |
| 4 | Finding a Needle in Haystack: Facebook's Photo Storage | OSDI 2010 | 小对象打包进大文件 + 内存索引，海量小文件存储的标准解法 |
| 5 | Windows Azure Storage: A Highly Available Cloud Storage Service with Strong Consistency | SOSP 2011 | 流层 / 分区层分离的云存储架构，强一致对象存储的样板 |
| 6 | f4: Facebook's Warm BLOB Storage System | OSDI 2014 | 热 / 温分层，用 EC 换容量效率的生产实践 |
| 7 | Facebook's Tectonic Filesystem: Efficiency from Exascale | FAST 2021 | 把 Haystack、f4、HDFS 合并成单一 EB 级文件系统，元数据 KV 化分片 |
| 8 | More Than Capacity: Performance-oriented Evolution of Pangu in Alibaba | FAST 2023 | 100 Gbps 网络 + SSD 前提下重写数据路径，性能导向的生产演进 |
| 9 | Dynamic Metadata Management for Petabyte-scale File Systems | SC 2004 | 动态子树分区，Ceph MDS 的理论基础 |
| 10 | Scale and Concurrency of GIGA+: File System Directories with Millions of Files | FAST 2011 | 单目录内可分裂的哈希分片，解决超大目录问题 |
| 11 | IndexFS: Scaling File System Metadata Performance with Stateless Caching and Bulk Insertion | SC 2014 | 元数据落 LSM 树 + 无状态客户端缓存 + 批量插入 |
| 12 | HopsFS: Scaling Hierarchical File System Metadata Using NewSQL Databases | FAST 2017 | 把 HDFS NameNode 状态迁入分布式数据库，元数据横向扩展 |
| 13 | InfiniFS: An Efficient Metadata Service for Large-Scale Distributed Filesystems | FAST 2022 | 目录元数据拆分 + 推测式路径解析，千亿级文件元数据服务 |
| 14 | Chain Replication for Supporting High Throughput and Availability | OSDI 2004 | 链式复制协议，强一致复制的基础之一 |
| 15 | Object Storage on CRAQ: High-Throughput Chain Replication for Read-Mostly Workloads | ATC 2009 | 链式复制的读扩展版本，3FS 等系统直接采用 |
| 16 | In Search of an Understandable Consensus Algorithm (Raft) | ATC 2014 | 现代存储系统元数据/控制面共识的事实标准 |
| 17 | ZooKeeper: Wait-free Coordination for Internet-scale Systems | ATC 2010 | 分布式协调服务，HDFS 等系统 HA 的基础 |
| 18 | Erasure Coding in Windows Azure Storage | ATC 2012 | 本地重建码（LRC）的生产引入，纠删码工程化的起点 |
| 19 | Network Coding for Distributed Storage Systems | IEEE Trans. IT 2010 | 再生码理论，定义了修复带宽下界 |
| 20 | Availability in Globally Distributed Storage Systems | OSDI 2010 | Google 大规模存储可用性实证，相关故障与副本放置的定量依据 |
| 21 | Redundancy Does Not Imply Fault Tolerance | FAST 2017 | 单个错误 / 损坏如何击穿分布式存储的冗余，故障注入研究的代表 |
| 22 | Fail-Slow at Scale: Evidence of Hardware Performance Faults in Large Production Systems | FAST 2018 | 慢故障比宕机更常见也更难处理 |
| 23 | File Systems Unfit as Distributed Storage Backends: Lessons from 10 Years of Ceph Evolution (BlueStore) | SOSP 2019 | 为什么分布式存储最终会绕开本地文件系统直接管理裸盘 |
| 24 | To FUSE or Not to FUSE: Performance of User-Space File Systems | FAST 2017 | FUSE 开销的系统性量化，客户端路线选择的依据 |
| 25 | Using Lightweight Formal Methods to Validate a Key-Value Storage Node in Amazon S3 (ShardStore) | SOSP 2021 | 生产存储系统引入轻量形式化验证的范例 |

## 2. 大规模生产系统与架构路线

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2000 | PVFS: A Parallel File System for Linux Clusters | Clemson / ANL | Annual Linux Showcase | 早期开源并行文件系统，条带化 + I/O 节点模型 |
| 2002 | GPFS: A Shared-Disk File System for Large Computing Clusters | IBM | FAST | 共享磁盘 + 分布式锁的并行文件系统，商业 HPC 存储的代表 |
| 2002 | FARSITE: Federated, Available, and Reliable Storage for an Incompletely Trusted Environment | Microsoft Research | OSDI | 无服务器、部分可信环境下的分布式文件系统，副本 + 拜占庭容错目录 |
| 2003 | The Google File System | Google | SOSP | 见核心必读 #1 |
| 2003 | Lustre: Building a File System for 1,000-node Clusters | Cluster File Systems | OLS（非同行评审） | Lustre 的公开架构说明，MDS/OSS/LDLM 三件套 |
| 2006 | Ceph: A Scalable, High-Performance Distributed File System | UCSC | OSDI | 见核心必读 #2 |
| 2006 | CRUSH: Controlled, Scalable, Decentralized Placement of Replicated Data | UCSC | SC | 可计算的伪随机放置算法，Ceph 数据分布核心 |
| 2007 | RADOS: A Scalable, Reliable Storage Service for Petabyte-scale Storage Clusters | UCSC | PDSW | Ceph 对象层的自治复制、故障检测与恢复 |
| 2008 | Scalable Performance of the Panasas Parallel File System | Panasas | FAST | 对象存储设备（OSD）路线 + 客户端 RAID，pNFS 的原型 |
| 2009 | GFS: Evolution on Fast-forward | Google | ACM Queue（访谈，非同行评审） | GFS 单 master 的局限与 Colossus 动机，罕见的一手反思 |
| 2010 | The Hadoop Distributed File System | Yahoo! | MSST | 见核心必读 #3 |
| 2011 | Windows Azure Storage | Microsoft | SOSP | 见核心必读 #5 |
| 2012 | Flat Datacenter Storage | Microsoft Research | OSDI | 全互联网络下的扁平 blob 存储，去掉数据局部性假设 |
| 2013 | The Quantcast File System | Quantcast | VLDB | HDFS 兼容、默认 Reed-Solomon 的开源实现 |
| 2014 | Tachyon: Reliable, Memory Speed Storage for Cluster Computing Frameworks | UC Berkeley | SoCC | 计算框架之上的内存级存储层（后为 Alluxio） |
| 2016 | Ambry: LinkedIn's Scalable Geo-Distributed Object Store | LinkedIn | SIGMOD | 跨地域 blob 存储，分区 + 异步复制 |
| 2017 | Azure Data Lake Store: A Hyperscale Distributed File Service for Big Data Analytics | Microsoft | SIGMOD | 微服务化的文件系统元数据层与分层存储 |
| 2018 | PolarFS: An Ultra-low Latency and Failure Resilient Distributed File System for Shared Storage Cloud Database | Alibaba | VLDB | 用户态 RDMA/SPDK 数据路径 + ParallelRaft，数据库专用分布式文件系统 |
| 2019 | CFS: A Distributed File System for Large Scale Container Platforms（ChubaoFS，现 CubeFS） | JD | SIGMOD | 元数据分区多 Raft + 数据分区，副本与小文件打包，CNCF CubeFS 的原始论文 |
| 2019 | File Systems Unfit as Distributed Storage Backends (BlueStore) | Red Hat / UCSC | SOSP | 见核心必读 #23 |
| 2020 | Millions of Tiny Databases (Physalia) | AWS | NSDI | 为 EBS 提供配置存储的细粒度共识单元，"爆炸半径"设计 |
| 2021 | Facebook's Tectonic Filesystem | Meta | FAST | 见核心必读 #7 |
| 2021 | Using Lightweight Formal Methods to Validate a Key-Value Storage Node in Amazon S3 | AWS | SOSP | 见核心必读 #25 |
| 2021 | A peek behind Colossus | Google | 官方博客（非同行评审） | Colossus 的唯一官方架构说明：元数据入 Bigtable、D 文件服务器 |
| 2021 | FoundationDB: A Distributed Unbundled Transactional Key Value Store | Apple / Snowflake | SIGMOD | 3FS 等系统外置元数据事务层的依赖，确定性模拟测试方法 |
| 2023 | More Than Capacity: Performance-oriented Evolution of Pangu in Alibaba | Alibaba | FAST | 见核心必读 #8 |
| 2023 | Fisc: A Large-scale Cloud-native-oriented File System | Alibaba | FAST | 薄客户端 + DPU 卸载，云原生场景的文件系统接入层 |
| 2023 | CFS: Scaling Metadata Service via Pruned Scope of Critical Sections | 中科大 / Baidu | EuroSys | 百度 CFS 的元数据服务：缩小事务临界区以提升并发 |
| 2023 | Tectonic-Shift: A Composite Storage Fabric for Large-Scale ML Training | Meta / Stanford | ATC | Tectonic 之上为训练负载加缓存层，工业界 AI 存储范式 |
| 2024 | What's the Story in EBS Glory: Evolutions and Lessons in Building Cloud Block Store | Alibaba | FAST | 云块存储十年演进，与 Pangu 配套阅读 |
| 2024 | Fire-Flyer AI-HPC: A Cost-Effective Software-Hardware Co-Design for Deep Learning | DeepSeek | SC | 3FS 所在的软硬协同集群，AI 训练存储的整机视角 |
| 2025 | 3FS（Fire-Flyer File System）设计说明与开源 | DeepSeek | 开源报告（非同行评审） | 无状态元数据 + FoundationDB + CRAQ 链复制 + 全闪存 RDMA，当前 AI 存储的公开参考实现 |
| 2026 | FalconFS: Distributed File System for Large-Scale Deep Learning Pipeline | Huawei / 上交 IPADS | NSDI | 深度学习流水线下的单 RPC 路径解析与元数据布局 |
| 2026 | Discard-Based GC for Distributed Log-Structured Storage | ByteDance | FAST | 日志结构分布式存储的空间回收，用 discard 取代 compaction |

## 3. 元数据服务与命名空间扩展

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2004 | Dynamic Metadata Management for Petabyte-scale File Systems | UCSC | SC | 见核心必读 #9 |
| 2011 | Scale and Concurrency of GIGA+ | CMU | FAST | 见核心必读 #10 |
| 2013 | TABLEFS: Enhancing Metadata Efficiency in the Local File System | CMU | ATC | 元数据放进 LSM 树（LevelDB），IndexFS 的单机基础 |
| 2014 | IndexFS | CMU | SC | 见核心必读 #11 |
| 2015 | CalvinFS: Consistent WAN Replication and Scalable Metadata Management for Distributed File Systems | Yale | FAST | 用确定性事务数据库（Calvin）承载文件系统元数据，跨 WAN 强一致 |
| 2015 | ShardFS vs. IndexFS: Replication Is above Scale-out Metadata | CMU | SoCC | 目录复制 vs 分片两条路线的直接对比 |
| 2015 | Mantle: A Programmable Metadata Load Balancer for the Ceph File System | UCSC | SC | Ceph MDS 负载均衡策略可编程化（注意与 2025 年同名论文区分） |
| 2015 | DeltaFS: Exascale File Systems Scale Better Without Dedicated Servers | CMU / LANL | PDSW | 无专用元数据服务器、作业私有命名空间的初始提案 |
| 2017 | HopsFS | KTH / Logical Clocks | FAST | 见核心必读 #12 |
| 2017 | LocoFS: A Loosely-Coupled Metadata Service for Distributed File Systems | 清华 | SC | 目录与文件元数据解耦、KV 化存储，国内元数据路线的起点 |
| 2021 | DeltaFS: A Scalable No-Ground-Truth Filesystem for Massively-Parallel Computing | CMU / LANL | SC | 元数据即数据、批量导入，HPC 创建风暴的解法 |
| 2022 | InfiniFS | 清华 | FAST | 见核心必读 #13 |
| 2023 | SingularFS: A Billion-Scale Distributed File System Using a Single Metadata Server | 清华 | ATC | 单元数据服务器 + PM/RDMA 达到十亿文件级 |
| 2023 | λFS: Scalable and Elastic Distributed File System Metadata Service using Serverless Functions | GMU 等 | ASPLOS | 元数据服务 serverless 化，弹性伸缩 |
| 2023 | FileScale: Fast and Elastic Metadata Management for Distributed File Systems | UMD | SoCC | HDFS 元数据的弹性分片与在线迁移 |
| 2025 | Mantle: Efficient Hierarchical Metadata Management for Cloud Object Storage | 中科大 / Baidu / 清华 | SOSP | 对象存储之上的层次命名空间与目录语义 |
| 2025 | HMFS: Decoupling Directory Semantics from Metadata Indexing | 清华 | SoCC | 目录语义与索引分离，路径解析与 rename 的新折中 |
| 2026 | MesaFS: An I/O-Efficient Metadata Service for Distributed File Systems | 清华 | EuroSys | 面向元数据 I/O 效率的服务端布局 |
| 2026 | SwitchFS: Asynchronous Metadata Updates with In-Network Coordination | 上交 IPADS | EuroSys | 可编程交换机参与元数据协调，异步更新保序 |
| 2026 | FalconFS | Huawei / 上交 IPADS | NSDI | 见第 2 节 |

## 4. 数据路径、小文件与对象存储

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2007 | Sinfonia: A New Paradigm for Building Scalable Distributed Systems | HP Labs | SOSP | mini-transaction 抽象，跨节点原子更新的经典设计 |
| 2009 | PLFS: A Checkpoint Filesystem for Parallel Applications | LANL / CMU | SC | 用日志结构中间层把 N-1 共享文件写转成 N-N，checkpoint 存储的起点 |
| 2010 | Finding a Needle in Haystack | Facebook | OSDI | 见核心必读 #4 |
| 2014 | f4: Facebook's Warm BLOB Storage System | Facebook | OSDI | 见核心必读 #6 |
| 2014 | Pelican: A Building Block for Exascale Cold Data Storage | Microsoft Research | OSDI | 受电力/冷却约束的冷存储机架，磁盘分组调度 |
| 2016 | Ambry | LinkedIn | SIGMOD | 见第 2 节 |
| 2018 | PolarFS | Alibaba | VLDB | 见第 2 节 |
| 2019 | ChubaoFS / CubeFS | JD | SIGMOD | 见第 2 节 |
| 2021 | Tectonic | Meta | FAST | 见核心必读 #7 |
| 2023 | Pangu | Alibaba | FAST | 见核心必读 #8 |
| 2026 | Discard-Based GC for Distributed Log-Structured Storage | ByteDance | FAST | 见第 2 节 |

## 5. 复制、共识与一致性

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2001 | Paxos Made Simple | Microsoft Research | ACM SIGACT News（非会议） | Paxos 的可读版本，共识入门 |
| 2004 | Chain Replication for Supporting High Throughput and Availability | Cornell | OSDI | 见核心必读 #14 |
| 2006 | The Chubby Lock Service for Loosely-Coupled Distributed Systems | Google | OSDI | 粗粒度锁 + 小文件的协调服务，GFS/Bigtable 的 master 选举依赖 |
| 2006 | Bigtable: A Distributed Storage System for Structured Data | Google | OSDI | 构建在 GFS 之上的表存储，也是 Colossus 元数据的宿主 |
| 2007 | Dynamo: Amazon's Highly Available Key-value Store | Amazon | SOSP | 一致性哈希 + 最终一致 + 反熵，与 GFS 路线相对的另一极 |
| 2007 | Paxos Made Live: An Engineering Perspective | Google | PODC | 把 Paxos 落地到 Chubby 的工程细节与坑 |
| 2009 | Object Storage on CRAQ | Princeton | ATC | 见核心必读 #15 |
| 2010 | ZooKeeper | Yahoo! | ATC | 见核心必读 #17 |
| 2012 | Spanner: Google's Globally-Distributed Database | Google | OSDI | TrueTime + 跨地域 Paxos，全局一致的标杆 |
| 2013 | Copysets: Reducing the Frequency of Data Loss in Cloud Storage | Stanford | ATC | 副本放置组合数与数据丢失概率的关系，放置策略必读 |
| 2014 | In Search of an Understandable Consensus Algorithm (Raft) | Stanford | ATC | 见核心必读 #16 |
| 2021 | FoundationDB | Apple / Snowflake | SIGMOD | 见第 2 节 |

## 6. 纠删码与冗余

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2010 | Network Coding for Distributed Storage Systems | USC / UC Berkeley | IEEE Trans. Information Theory | 见核心必读 #19 |
| 2012 | Erasure Coding in Windows Azure Storage | Microsoft | ATC | 见核心必读 #18 |
| 2013 | XORing Elephants: Novel Erasure Codes for Big Data | USC / Facebook | VLDB | HDFS 上的 LRC 实现（HDFS-Xorbas），修复流量实测 |
| 2014 | A "Hitchhiker's" Guide to Fast and Efficient Data Reconstruction in Erasure-coded Data Centers | UC Berkeley / Facebook | SIGCOMM | 在 RS 码上叠加 piggyback 降低修复 I/O，兼容现有部署 |
| 2017 | Giza: Erasure Coding Objects across Global Data Centers | Microsoft | ATC | 跨数据中心纠删码对象存储与元数据一致性 |
| 2018 | Clay Codes: Moulding MDS Codes to Yield an MSR Code | IISc 等 | FAST | 实用的最小存储再生码，已进入 Ceph |
| 2021 | Exploiting Combined Locality for Wide-Stripe Erasure Coding in Distributed Storage (ECWide) | 中科大 / CUHK | FAST | 宽条带纠删码降低冗余率的工程路径 |
| 2021 | RepairBoost: Boosting Full-Node Repair in Erasure-Coded Storage | CUHK 等 | ATC | 整节点修复的调度与并行 |
| 2022 | Tiger: Disk-Adaptive Redundancy Without Placement Restrictions | CMU | OSDI | 按磁盘可靠性自适应调整冗余 |
| 2023 | Practical Design Considerations for Wide Locally Recoverable Codes | Google 等 | FAST | 生产环境宽 LRC 的参数选择 |
| 2023 | ParaRC: Embracing Sub-Packetization for Repair Parallelization in MSR-Coded Storage | CUHK 等 | FAST | MSR 码修复的并行化 |

## 7. HPC 并行文件系统与 AI 训练存储

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2000 | PVFS | Clemson / ANL | Annual Linux Showcase | 见第 2 节 |
| 2002 | GPFS | IBM | FAST | 见第 2 节 |
| 2003 | Lustre | Cluster File Systems | OLS | 见第 2 节 |
| 2008 | Panasas | Panasas | FAST | 见第 2 节 |
| 2009 | PLFS | LANL / CMU | SC | 见第 4 节 |
| 2016 | An Ephemeral Burst-Buffer File System for Scientific Applications (BurstFS) | Florida State / ORNL / LLNL | SC | 节点本地 burst buffer 之上的临时共享文件系统，UnifyFS 前身 |
| 2018 | GekkoFS: A Temporary Distributed File System for HPC Applications | JGU Mainz / BSC | CLUSTER | 放弃 POSIX 完备性换取元数据吞吐，哈希扁平命名空间 |
| 2018 | A Year in the Life of a Parallel File System | NERSC / ANL 等 | SC | 生产并行文件系统一年的性能与故障实测 |
| 2020 | DAOS: A Scale-Out High Performance Storage Stack for Storage Class Memory | Intel | SCFA | 用户态、面向 PM/NVMe 的 HPC 存储栈 |
| 2020 | Quiver: An Informed Storage Cache for Deep Learning | MSR India | FAST | 训练感知的缓存替换，AI 存储缓存研究的起点 |
| 2021 | Analyzing and Mitigating Data Stalls in DNN Training (CoorDL) | UT Austin / MSR | VLDB | 量化训练中的数据加载停顿，存储对训练效率的影响 |
| 2021 | CheckFreq: Frequent, Fine-Grained DNN Checkpointing | UT Austin / MSR | FAST | 高频 checkpoint 的流水线化 |
| 2021 | DeltaFS | CMU / LANL | SC | 见第 3 节 |
| 2022 | Check-N-Run: A Checkpointing System for Training Deep Learning Recommendation Models | Meta / USC | NSDI | 推荐模型的增量、量化 checkpoint |
| 2023 | HadaFS: A File System Bridging the Local and Shared Burst Buffer for Exascale Supercomputers | 无锡超算 / 清华 | FAST | 神威超算 burst buffer 文件系统 |
| 2023 | UnifyFS: A User-level Shared File System for Unified Access to Distributed Local Storage | ORNL / LLNL | IPDPS | BurstFS 的生产化版本 |
| 2023 | SHADE: Enable Fundamental Cacheability for Distributed Deep Learning Training | Virginia Tech | FAST | 按样本重要性缓存 |
| 2023 | SiloD: A Co-design of Caching and Scheduling for Deep Learning Clusters | MSR 等 | EuroSys | 缓存与调度协同 |
| 2023 | Gemini: Fast Failure Recovery in Distributed Training with In-Memory Checkpoints | Rice / AWS | SOSP | 内存级 checkpoint 与快速恢复 |
| 2023 | Tectonic-Shift | Meta / Stanford | ATC | 见第 2 节 |
| 2024 | Fire-Flyer AI-HPC | DeepSeek | SC | 见第 2 节 |
| 2025 | ByteCheckpoint: A Unified Checkpointing System for Large Foundation Models | ByteDance / HKU | NSDI | 大模型训练 checkpoint 的统一存储层 |
| 2025 | 3FS | DeepSeek | 开源报告 | 见第 2 节 |
| 2026 | FalconFS | Huawei / 上交 IPADS | NSDI | 见第 2 节 |

## 8. 客户端、缓存与 FUSE

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2010 | Panache: A Parallel File System Cache for Global File Access | IBM | FAST | GPFS 之上的广域并行缓存，断连操作与一致性 |
| 2014 | Tachyon | UC Berkeley | SoCC | 见第 2 节 |
| 2017 | To FUSE or Not to FUSE | Stony Brook | FAST | 见核心必读 #24 |
| 2019 | ExtFUSE: Extension Framework for File Systems in User Space | Stony Brook / Google | ATC | 用 eBPF 把部分 FUSE 处理下沉到内核 |
| 2021 | XFUSE: An Infrastructure for Running Filesystem Services in User Space | Alibaba | ATC | 生产环境 FUSE 的并行化与热升级 |
| 2023 | Fisc | Alibaba | FAST | 见第 2 节，薄客户端路线 |
| 2024 | RFUSE: Modernizing Userspace Filesystem Framework for Scalable Kernel-Userspace Communication | 首尔大学 | FAST | 每核 ring channel 的 FUSE 通道重构 |
| 2025 | FUSE-over-io_uring | Linux 内核社区 | Linux 6.14（内核工程，非论文） | FUSE 通道正式并入 io_uring |
| 2025 | DFUSE: Strongly Consistent Write-Back Kernel Caching for Distributed File Systems | — | SoCC | 分布式文件系统写回缓存的强一致方案 |

## 9. 新硬件：持久内存、RDMA、DPU 与 CXL

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2017 | Octopus: An RDMA-enabled Distributed Persistent Memory File System | 清华 | ATC | PM + RDMA 一体化设计的分布式文件系统 |
| 2019 | Orion: A Distributed File System for Non-Volatile Main Memory and RDMA-Capable Networks | UCSD | FAST | 内核态 PM/RDMA 分布式文件系统，单边 RDMA 元数据访问 |
| 2020 | Assise: Performance and Availability via Client-local NVM in a Distributed File System | UT Austin 等 | OSDI | 客户端本地 NVM 作为一致性缓存与复制起点 |
| 2021 | LineFS: Efficient SmartNIC Offload of a Distributed File System with Pipeline Parallelism | KAIST 等 | SOSP（Best Paper） | 文件系统操作流水线卸载到 SmartNIC |
| 2021 | Octopus+ | 清华 | ACM TOS | Octopus 的期刊扩展 |
| 2023 | DPFS: DPU-Powered File System Virtualization | IBM Research / VU Amsterdam | SYSTOR | 用 DPU 对虚拟机透明提供文件系统 |
| 2024 | DPC: DPU-accelerated High-Performance File System Client | 重庆大学等 | ICPP | 文件系统客户端卸载到 DPU |
| 2025 | Famfs | Micron | FAST poster + 内核 RFC | CXL 共享内存上的 fs-dax 文件系统 |

## 10. 可靠性、故障与实证研究

| 年份 | 论文 | 机构 | 会议 | 为什么重要 |
|------|------|------|------|------------|
| 2007 | Failure Trends in a Large Disk Drive Population | Google | FAST | 首个十万级磁盘故障实证，SMART 预测能力有限 |
| 2007 | Disk Failures in the Real World: What Does an MTTF of 1,000,000 Hours Mean to You? | CMU | FAST | 磁盘年化故障率远高于厂商 MTTF |
| 2008 | An Analysis of Data Corruption in the Storage Stack | Wisconsin / NetApp | FAST | 静默数据损坏的规模与分布，端到端校验的依据 |
| 2008 | Avoiding the Disk Bottleneck in the Data Domain Deduplication File System | Data Domain | FAST | 去重存储的索引与局部性设计 |
| 2010 | Availability in Globally Distributed Storage Systems | Google | OSDI | 见核心必读 #20 |
| 2013 | The Tail at Scale | Google | CACM | 尾延迟来源与对冲请求等缓解手段 |
| 2014 | What Bugs Live in the Cloud? A Study of 3000+ Issues in Cloud Systems | Chicago 等 | SoCC | HDFS/Cassandra 等系统 bug 的分类研究 |
| 2015 | A Large-Scale Study of Flash Memory Failures in the Field | CMU / Facebook | SIGMETRICS | SSD 现场故障实证 |
| 2016 | Flash Reliability in Production: The Expected and the Unexpected | Toronto / Google | FAST | Google 数据中心 SSD 六年可靠性数据 |
| 2017 | Redundancy Does Not Imply Fault Tolerance | Wisconsin | FAST | 见核心必读 #21 |
| 2017 | Gray Failure: The Achilles' Heel of Cloud-Scale Systems | Microsoft Research | HotOS | 部分故障 / 灰色故障概念的提出 |
| 2018 | Fail-Slow at Scale | Chicago 等 | FAST | 见核心必读 #22 |
| 2020 | Understanding and Finding Crash-Consistency Bugs in Parallel File Systems | Texas A&M | HotStorage | 并行文件系统的 crash consistency 缺陷 |
| 2021 | Failure Recovery and Logging of High-Performance Parallel File Systems | — | ACM TOS | 并行文件系统故障恢复与日志机制综述 |
| 2023 | Perseus: A Fail-Slow Detection Framework for Cloud Storage Systems | Alibaba / 中科大 | FAST | 生产环境慢故障检测框架 |
| 2024 | Metis: File System Model Checking via Versatile Input and State Exploration | Stony Brook 等 | FAST | 文件系统模型检查 |

## 11. 与本仓库的对应关系

| 本仓库系统调研 | 直接相关论文 |
|----------------|--------------|
| [3FS](../project/3fs/README.md) | Fire-Flyer SC 2024、3FS 开源报告、CRAQ ATC 2009、FoundationDB SIGMOD 2021 |
| [BeeGFS](../project/beegfs/README.md) | 无同行评审论文；参照 PVFS、GPFS、Lustre 与 A Year in the Life SC 2018 |
| [CephFS](../project/cephfs/README.md) | Ceph OSDI 2006、CRUSH SC 2006、RADOS PDSW 2007、Dynamic Metadata SC 2004、Mantle SC 2015、BlueStore SOSP 2019 |
| [CubeFS](../project/cubefs/README.md) | ChubaoFS SIGMOD 2019 |
| [FastDFS](../project/fastdfs/README.md) | 无论文；机制上对应 Haystack OSDI 2010 |
| [GlusterFS](../project/glusterfs/README.md) | 无论文；对比 FDS OSDI 2012 的无中心元数据路线 |
| [JuiceFS](../project/juicefs/README.md) | 无论文；对比 Tachyon SoCC 2014、ADLS SIGMOD 2017 的"对象存储 + 外置元数据"路线 |
| [Lustre](../project/lustre/README.md) | Lustre OLS 2003、PLFS SC 2009、A Year in the Life SC 2018 |
| [SeaweedFS](../project/seaweedfs/README.md) | Haystack OSDI 2010、f4 OSDI 2014 |
| [2020 年后论文详解](../project/papers/README.md) | 本清单第 2–10 节中 2020 年及以后的全部条目 |

## 12. 按年份总索引

| 年份 | 论文（会议） |
|------|--------------|
| 2000 | PVFS (Annual Linux Showcase) |
| 2001 | Paxos Made Simple (SIGACT News) |
| 2002 | GPFS (FAST)；FARSITE (OSDI) |
| 2003 | GFS (SOSP)；Lustre (OLS) |
| 2004 | Chain Replication (OSDI)；Dynamic Metadata Management (SC) |
| 2006 | Ceph (OSDI)；CRUSH (SC)；Chubby (OSDI)；Bigtable (OSDI) |
| 2007 | RADOS (PDSW)；Dynamo (SOSP)；Sinfonia (SOSP)；Paxos Made Live (PODC)；Failure Trends (FAST)；Disk Failures in the Real World (FAST) |
| 2008 | Panasas (FAST)；Data Domain (FAST)；Data Corruption in the Storage Stack (FAST) |
| 2009 | CRAQ (ATC)；PLFS (SC)；GFS: Evolution on Fast-forward (ACM Queue) |
| 2010 | HDFS (MSST)；Haystack (OSDI)；ZooKeeper (ATC)；Availability in Globally Distributed Storage Systems (OSDI)；Panache (FAST)；Network Coding for Distributed Storage (IEEE TIT) |
| 2011 | GIGA+ (FAST)；Windows Azure Storage (SOSP) |
| 2012 | Erasure Coding in WAS (ATC)；Flat Datacenter Storage (OSDI)；Spanner (OSDI) |
| 2013 | XORing Elephants (VLDB)；Copysets (ATC)；The Tail at Scale (CACM)；TABLEFS (ATC)；QFS (VLDB) |
| 2014 | IndexFS (SC)；f4 (OSDI)；Pelican (OSDI)；Hitchhiker (SIGCOMM)；Raft (ATC)；Tachyon (SoCC)；What Bugs Live in the Cloud (SoCC) |
| 2015 | CalvinFS (FAST)；ShardFS (SoCC)；Mantle (SC)；DeltaFS (PDSW)；Flash Memory Failures in the Field (SIGMETRICS) |
| 2016 | Ambry (SIGMOD)；Flash Reliability in Production (FAST)；BurstFS (SC) |
| 2017 | HopsFS (FAST)；To FUSE or Not to FUSE (FAST)；Redundancy Does Not Imply Fault Tolerance (FAST)；Octopus (ATC)；Giza (ATC)；LocoFS (SC)；Gray Failure (HotOS)；ADLS (SIGMOD) |
| 2018 | Fail-Slow at Scale (FAST)；Clay Codes (FAST)；PolarFS (VLDB)；GekkoFS (CLUSTER)；A Year in the Life of a Parallel File System (SC) |
| 2019 | BlueStore (SOSP)；ChubaoFS (SIGMOD)；Orion (FAST)；ExtFUSE (ATC) |
| 2020 | Assise (OSDI)；DAOS (SCFA)；Quiver (FAST)；Physalia (NSDI)；Crash-Consistency Bugs in PFS (HotStorage) |
| 2021 | Tectonic (FAST)；ShardStore (SOSP)；LineFS (SOSP)；FoundationDB (SIGMOD)；ECWide (FAST)；RepairBoost (ATC)；XFUSE (ATC)；DeltaFS (SC)；CheckFreq (FAST)；CoorDL (VLDB)；Octopus+ (TOS)；Failure Recovery and Logging of HPC PFS (TOS)；Colossus 博客 |
| 2022 | InfiniFS (FAST)；Tiger (OSDI)；Check-N-Run (NSDI) |
| 2023 | Pangu (FAST)；Fisc (FAST)；Baidu CFS (EuroSys)；SingularFS (ATC)；λFS (ASPLOS)；FileScale (SoCC)；Tectonic-Shift (ATC)；Perseus (FAST)；HadaFS (FAST)；Wide LRC (FAST)；ParaRC (FAST)；Gemini (SOSP)；DPFS (SYSTOR)；UnifyFS (IPDPS)；SHADE (FAST)；SiloD (EuroSys) |
| 2024 | RFUSE (FAST)；EBS Glory (FAST)；Metis (FAST)；Fire-Flyer (SC)；DPC (ICPP) |
| 2025 | ByteCheckpoint (NSDI)；Mantle (SOSP)；HMFS (SoCC)；DFUSE (SoCC)；Famfs (FAST poster)；3FS 开源报告；FUSE-over-io_uring (Linux 6.14) |
| 2026（至 8 月） | FalconFS (NSDI)；MesaFS (EuroSys)；SwitchFS (EuroSys)；Discard-Based GC (FAST) |
