# 面向新硬件的分布式文件系统论文调研（2020 年以后）

> 调研日期：2026-08-15
>
> 范围说明：本文调研 2020 年（含）之后发表的、以新硬件（persistent memory / PM、RDMA、NVMe & NVMe-oF、SmartNIC / DPU、CXL）为核心设计目标的**分布式文件系统**论文。所有论文均经过网络检索逐篇核实（会议、年份、作者机构、内容），未经核实的信息标注"待确认"。纯 KV 存储类工作（如 FUSEE、ROLEX、Sherman、Clover 等 disaggregated-memory KV）不属于文件系统，已明确排除。每篇论文附面向分布式文件系统设计者的设计启示。

---

## 1. 硬件趋势综述

### 1.1 Persistent Memory：从主角到"遗产硬件"

- 2019-2021 年 Intel Optane DC Persistent Memory（PMem，DIMM 形态，字节寻址，~300ns 延迟）是学术界分布式文件系统研究的绝对主角：Assise（OSDI'20）、Octopus+（TOS'21）、LineFS（SOSP'21）、SingularFS（ATC'23）全部以 Optane PMem 为目标硬件。
- **2022 年 7 月 Intel 宣布终止 Optane 业务**（Wind down），此后仅消化库存、履行既有合同。这意味着上述论文的目标硬件已无量产渠道，其原型系统在新集群上不可直接复现。
- 但 PM 论文的**软件设计遗产依然有效**：字节粒度日志、操作粒度（而非块粒度）一致性、用户态直写、crash-consistent 数据结构等技术，可迁移到低延迟 NVMe SSD（如 Optane SSD 后继者、三星 Z-NAND、CXL persistent memory 设备）或带电容保护的 DRAM 写缓冲上。
- 业界替代路径：CXL 附加内存（含未来的 CXL persistent memory）、NVDIMM-N、以及"高速 SSD + 电容保护 DRAM"组合。DAOS 的演进（见 §8）是最典型的案例——它 2020 年论文以 PMem 为一等公民，2023 年被迫推出 "Beyond PM" 的纯 NVMe 模式（Metadata-on-SSD）。

### 1.2 RDMA：从可选优化到默认假设

- 100/200/400 Gbps RDMA（InfiniBand / RoCEv2）已是 AI 训练存储集群的默认网络。单边 verbs（READ/WRITE）允许客户端绕过服务端 CPU 直接访问远端内存，把"网络往返"从毫秒级 RPC 变为个位数微秒。
- 对 DFS 设计的影响：
  - **CPU 成为新瓶颈**：网络与介质延迟都进入微秒级后，软件路径（RPC 编解码、内存拷贝、锁）占比反而上升，催生 kernel-bypass、零拷贝、run-to-completion 线程模型。
  - **数据/元数据路径分化**：大 IO 走单边 RDMA 直达存储介质（Octopus+、3FS），小 IO 与元数据走 RPC（双边 verbs），几乎成为标准范式。
  - **一致性协议下沉**：RDMA 允许把复制协议做成"客户端直写多副本 NVM"（Assise 的 chain replication）或由 NIC 代理（LineFS）。

### 1.3 SmartNIC / DPU：把文件系统搬进网卡

- NVIDIA BlueField（ARM 核 + NIC + PCIe switch）、AWS Nitro、阿里 CIPU 等 DPU 已在云厂商大规模部署。两类用法：
  1. **offload 后台任务**：把复制、压缩、CRC、日志 digest 等 CPU 密集工作移到 NIC ARM 核，释放主机 CPU 并降低性能干扰（LineFS）。
  2. **offload 整个客户端**：文件系统客户端整体运行在 DPU 上，主机侧只剩 virtio-fs / virtio-blk 等标准设备接口，实现零主机开销 + 裸金属/VM/容器统一接入 + 租户隔离（DPFS、Fisc、DPC）。
- 关键工程事实：DPU 上的 ARM 核（wimpy cores）单核性能约为主机 x86 的 30-50%，直接移植软件会**变慢**——LineFS 的核心贡献正是用流水线并行掩盖 wimpy core 劣势。

### 1.4 NVMe / NVMe-oF：介质快到文件系统必须让路

- PCIe 4.0/5.0 NVMe SSD 单盘 7-14 GB/s、百万级 IOPS；NVMe-oF 让远端 SSD 延迟只比本地高 ~10μs。
- 影响：用户态 IO 栈（SPDK）、每盘单线程 shared-nothing 引擎（DAOS）、"读缓存无用论"（3FS 认为 AI 随机读场景下缓存命中率低，干脆放弃缓存换取全盘随机读带宽）。
- 商业系统 VAST Data 基于 NVMe-oF 的 DASE（Disaggregated Shared-Everything）架构是该方向的工业代表，但**没有同行评审论文**，只有白皮书（本文按任务要求标注，不设独立章节）。

### 1.5 CXL：下一个周期的"共享存储介质"

- CXL 2.0/3.x 允许多主机通过 switch 共享一个内存池（load/store 直访）。这在物理上重新创造了"多机共享一块字节寻址介质"的场景——恰好是 PM DFS 论文假设的硬件形态，且比 RDMA 更低延迟（亚微秒）。
- 文件系统层面的探索刚起步：famfs（Micron，内核补丁 + FAST'25 poster）提供多主机共享挂载的 fs-dax 文件系统；学术界开始出现基于 CXL 共享内存的分布式 page cache / 元数据协调工作（多为 2025-2026 preprint，见 §10）。真实 CXL switch + 多主机共享内存硬件 2026 年仍未大规模上市，多数工作基于模拟或单机 CXL 扩展卡。

---

## 2. Assise: Performance and Availability via Client-local NVM in a Distributed File System

- **会议**：OSDI 2020（USENIX）
- **作者/机构**：Thomas E. Anderson（Univ. of Washington）、Marco Canini（KAUST）、Jongyul Kim（KAIST）、Dejan Kostić & Waleed Reda（KTH）、Youngjin Kwon（KAIST）、Simon Peter & Emmett Witchel（UT Austin）等
- **链接**：https://www.usenix.org/conference/osdi20/presentation/anderson ；代码 https://github.com/ut-osa/assise
- **目标硬件**：客户端本地 Intel Optane DC PMem + RDMA 网络

### 核心设计

- 颠覆"存储在远端服务器"的传统 DFS 模型：把 PM 放在**客户端本地**，计算与存储 colocate。
- **数据路径**：应用通过用户态库文件系统（基于 Strata 演化）直接写 process-local 的 PM 更新日志（无内核、无网络）；后台按链式复制（chain replication）经 RDMA 把日志复制到其他节点的 PM，再 digest 到共享区/冷层（SSD）。读优先命中 process-local → socket-local → client-local PM，最大化本地性。
- **缓存/一致性**：核心是 CC-NVM——一个**持久、可线性化、可崩溃恢复**的分布式 coherence 协议，把客户端本地 PM 当作 linearizable cache 管理；一致性粒度是 IO 操作（操作日志）而非固定大小的块，显著降低 false sharing 与协议流量；提供 prefix crash consistency。
- **可用性**：热备节点（failover replica）在其本地 PM 中持有最新日志副本，故障切换时无需从远端重建缓存，实现亚秒级 failover。

### 关键实验结果

- 对比 Ceph/BlueStore、NFS、Octopus：写延迟最多降低 22×，吞吐最多提高 56×，failover 最快 103×，扩展性好 6×；LevelDB、Postfix、Filebench 等应用显著受益。

### 局限

- 强依赖 Optane PMem（已停产）；客户端本地放持久数据改变了运维模型（客户端节点故障=数据副本故障）；用户态 libfs + 共享内核态 kernfs 的架构侵入性强，POSIX 兼容与多进程共享复杂。

### 设计启示

- "操作粒度一致性 + 客户端本地持久日志"思路可用于客户端 SDK 的写路径：客户端先写本地持久 WAL（NVMe/电容 DRAM），后台再推给存储节点，可把小写延迟从网络往返降为本地持久化延迟——但需承担客户端故障域的复杂性，与多数 DFS"客户端无状态"的假设冲突，适合作为可选的强化写缓冲模式。
- 分层本地性（process/socket/client-local）对读缓存层次设计有直接参考价值。

---

## 3. Octopus+: An RDMA-Enabled Distributed Persistent Memory File System

- **期刊**：ACM Transactions on Storage, Vol.17 No.3, 2021（ATC 2017 Octopus 的扩展期刊版；2020 年后版本收录于此）
- **作者/机构**：Youyou Lu、Jiwu Shu 等（清华大学存储研究组）
- **链接**：https://dl.acm.org/doi/10.1145/3448418 ；PDF https://storage.cs.tsinghua.edu.cn/papers/tos21octopus.pdf/
- **目标硬件**：Intel Optane DC PMem + RDMA（相比 ATC'17 版本，TOS'21 在真实 Optane 上重新评估并扩展了复制机制）

### 核心设计

- **紧耦合 NVM 与 RDMA**：文件系统镜像本身作为**共享持久内存池**直接暴露给 RDMA，消除"文件系统页缓存 ↔ 网络 mbuf"的重复拷贝。
- **数据路径**：client-active 模式——大 IO 由客户端用单边 RDMA READ/WRITE 直接读写服务端 PM 数据区，把负载从服务端 CPU 转移到客户端与网络（server 只做元数据裁决）。
- **元数据路径**：self-identified RPC（携带发送方标识的双边 verbs + 立即通知）；跨服务器操作（如 rename）用 collect-dispatch 分布式事务：本地日志 + RDMA 单边写远端完成分发，降低分布式事务的锁与日志开销。
- 目录集中于 directory metadata server，文件按 hash 分布到各服务器。

### 关键实验结果

- 在 Optane PMem 上大 IO 接近原始硬件带宽；元数据操作与数据 IO 比 GlusterFS、NFS、Ceph 等高出一到多个数量级（具体倍数随操作类型不同）。

### 局限

- hash 分布 + 单一目录服务器的元数据设计扩展性有限（非其研究重点）；无副本容错的完整故事（扩展版才补充复制）；Optane 停产同样影响复现。

### 设计启示

- "大 IO 单边 RDMA 直达、元数据小 RPC 双边"的路径分化可直接借鉴：存储节点的大块追加/读取走 RDMA 单边或 RDMA-based RPC 零拷贝，元数据操作保持小消息 RPC。
- client-active 负载转移思想与"客户端直连存储节点、控制面不在 IO 路径"的分离式架构原则一致，可进一步把 EC 编码、CRC 计算放在客户端。

---

## 4. LineFS: Efficient SmartNIC Offload of a Distributed File System with Pipeline Parallelism

- **会议**：SOSP 2021，**Best Paper Award**
- **作者/机构**：Jongyul Kim（KAIST）、Insu Jang（Univ. of Michigan）、Waleed Reda（KTH / UCLouvain）、Jaeseong Im（KAIST）、Marco Canini（KAUST）、Dejan Kostić（KTH）、Youngjin Kwon（KAIST）、Simon Peter（UT Austin）、Emmett Witchel（UT Austin / Katana Graph）
- **链接**：https://www.cs.utexas.edu/~witchel/pubs/kim21sosp-linefs.pdf ；代码开源（linefs）
- **目标硬件**：NVIDIA/Mellanox BlueField SmartNIC（ARM 多核）+ 客户端本地 PM（基于 Assise 改造）

### 核心设计

- 动机：Assise 类 client-local PM DFS 的复制、压缩、日志 digest 等后台任务消耗主机 CPU 并与应用争抢，造成性能干扰。
- **offload 划分**：把 DFS 分解为"host 侧极薄的 POSIX 接口 + 持久日志写入"与"NIC 侧全部 CPU 密集任务"（复制、压缩、数据 publication、索引构建、一致性管理）。主机故障时 NIC 上的 DFS 仍可继续提供部分服务（提升可用性）。
- **流水线并行**是核心技术：SmartNIC 的 wimpy ARM 核单核性能弱，直接搬运任务会变慢。LineFS 把 DFS 操作切成多个 stage（如取日志 → 压缩 → 复制 → 确认），组成跨核流水线并行执行，用吞吐掩盖单核延迟；host↔NIC 之间通过 DMA + 轮询通道通信。
- 主机与 NIC 分工遵循"数据路径延迟敏感部分留在主机 PM，吞吐型后台移到 NIC"。

### 关键实验结果

- 对比 Assise：LevelDB 延迟最多降 80%，Filebench 吞吐最多升 79%；在主机高负载（CPU 争抢）时优势更明显；主机故障期间 NIC 侧可维持 DFS 可用性。

### 局限

- 依赖 PM（停产）与特定代 BlueField（BlueField-1/2，ARM 核数与 DMA 带宽制约划分策略）；流水线划分是手工设计，通用性/可移植性有限；host-NIC 通信通道本身有开销。

### 设计启示

- 存储节点的后台任务（EC 编码、compaction、修复扫描、CRC、压缩）天然适合 DPU offload；即使不用 DPU，"把后台任务与前台 IO 隔离到不同核组 + 流水线化"也是可落地的软件结构。
- "NIC 侧保留最小服务能力以提升故障期可用性"对优雅降级设计（主机 hang 但盘可读）有参考价值。

---

## 5. DPFS: DPU-Powered File System Virtualization

- **会议**：SYSTOR 2023（ACM International Conference on Systems and Storage）
- **作者/机构**：Peter-Jan Gootzen（IBM Research Zurich / VU Amsterdam）、Jonas Pfefferle、Radu Stoica（IBM Research）、Animesh Trivedi（VU Amsterdam）
- **链接**：https://dl.acm.org/doi/10.1145/3579370.3594769 ；代码 https://github.com/IBM/DPFS
- **目标硬件**：NVIDIA BlueField-2 DPU，virtio-fs 硬件模拟能力

### 核心设计

- 主张云场景下**文件系统客户端与后端实现解耦**：主机（租户）只看到标准 virtio-fs 设备，完整的文件系统客户端运行在 DPU 的 ARM 核上，由云厂商管理与优化。
- **数据路径**：主机 VFS → 轻量 FUSE 层生成 FUSE 请求 → virtio queue 经 PCIe（SR-IOV 虚拟功能支持多租户）→ DPU 上的 DPFS 框架解析 FUSE 请求 → 后端（NFS 客户端、KV、镜像后端等可插拔）访问远端存储。
- 主机侧零配置、零软件修改（Linux 自带 virtio-fs 驱动即可），裸金属/VM 统一接入；后端可针对 workload/硬件做厂商侧优化。

### 关键实验结果

- 每 IO 的主机 CPU 效率提高 4.4×（CPU 周期从主机转移到 DPU）；吞吐/延迟与主机侧运行的对照组相当；揭示 BlueField-2 上 virtio-fs offload 的延迟构成（PCIe DMA、ARM 处理）。

### 局限

- DPU ARM 核性能有限，元数据密集 workload 受制于 DPU 侧处理能力；依赖 BlueField 的 virtio-fs emulation SDK（闭源组件）；FUSE 协议语义成为能力上限。

### 设计启示

- 对于"原生 SDK 之上封装 FUSE 接入层"的常见客户端路线，DPFS 展示了第二条路：**把客户端 SDK 整体跑在 DPU 上，主机以 virtio-fs 消费**，对不可改造的租户（VM、裸金属）尤其有价值，且客户端缓存/连接池由运营方统一管理。
- 若走此路线，SDK 需为 ARM + 低单核性能环境优化（无锁、批处理、少拷贝），并保持 FUSE 请求粒度与系统内部数据定位模型的高效映射。

---

## 6. Fisc: A Large-scale Cloud-native-oriented File System

- **会议**：FAST 2023
- **作者/机构**：Qiang Li 等，阿里巴巴集团（联合复旦大学、南京大学、厦门大学等）；盘古（Pangu）存储体系之上的云原生文件系统
- **链接**：https://www.usenix.org/conference/fast23/presentation/li-qiang-fisc ；PDF https://www.usenix.org/system/files/fast23-li-qiang.pdf
- **目标硬件**：自研 DPU（virtio-Fisc 设备）+ RDMA 数据中心网络 + NVMe SSD 存储集群

### 核心设计

- 面向容器化云原生场景：单机数百容器共享接入，传统重客户端（每客户端独占 CPU/内存/网络连接）无法复用资源。
- **轻量客户端**：把客户端瘦身为 POSIX 转发层，重逻辑（打开状态、缓存、协议）下沉，两层资源聚合（单机聚合 + 集群网关聚合）提高复用率。
- **存储感知分布式网关**（storage-aware distributed gateway）：位于存储集群侧，承接客户端请求并感知副本位置/负载做路由，提升 IO 服务的性能、可用性与可扩展性；网关无状态可水平扩展。
- **DPU offload**：virtio-Fisc 设备在 DPU 中 offload 网络栈与存储协议，提供从用户虚拟域（容器）到云厂商物理域文件系统的安全高效直通（passthrough），绕过虚拟化软件栈。

### 关键实验结果

- 生产部署三年，服务阿里巴巴 300 万+ CPU 核上的应用（数据库、大数据、AI 等）；论文报告轻客户端资源占用降至传统客户端的零头、网关路由降低长尾延迟（具体数字见论文）。

### 局限

- 深度绑定阿里自研 DPU 与盘古基础设施，学术复现不可行；网关引入一跳转发（用聚合与调度收益换取），对极致延迟场景需 bypass 路径。

### 设计启示

- **"轻客户端 + 无状态网关"是支撑容器高密度接入的现成蓝图**——SDK 保持直连存储节点的高性能路径，同时提供经网关的轻量路径供海量小租户复用连接与缓存。
- virtio 设备抽象 + 物理域/虚拟域分离的安全模型，是支持多租户云环境时数据访问凭证越权防护的自然延伸。

---

## 7. SingularFS: A Billion-Scale Distributed File System Using a Single Metadata Server

- **会议**：USENIX ATC 2023
- **作者/机构**：Hao Guo、Youyou Lu、Wenhao Lv、Xiaojian Liao、Shaoxun Zeng、Jiwu Shu（清华大学）
- **链接**：https://www.usenix.org/conference/atc23/presentation/guo
- **目标硬件**：Intel Optane PMem（元数据持久化）+ RDMA

### 核心设计

- 命题：借助新硬件把**单元数据服务器**的性能推到极致（数百万 ops/s、十亿级文件），从而让绝大多数集群不再需要复杂的分布式元数据。
- 元数据全部存放于单服务器的 PM（NVMM）上；核心技术：
  - **无日志元数据操作**：利用 PM 字节寻址与 8 字节原子写，把常见元数据操作（create/unlink/stat）构造为无需 WAL 的 crash-consistent 更新。
  - **分层并发控制**：区分目录项与 inode 的并发粒度，目录时间戳等热点用原子指令更新，避免目录锁竞争。
  - RDMA 网络路径压低单次操作延迟。

### 关键实验结果

- 单元数据服务器达到十亿级文件规模与百万级 ops/s 量级的元数据吞吐（论文报告显著超越 CephFS/HopsFS 等分布式元数据系统的单组性能）。

### 局限

- 单服务器容量/吞吐终有上限（论文自身定位）；PM 停产后"十亿文件放单机字节寻址介质"的前提削弱；对目标规模远超十亿文件的系统，单 MDS 路线不适用，但其技术可用于加速单个分片。

### 设计启示

- 对采用分片 + 多 Raft 组元数据的系统，SingularFS 的价值在于**把每个分片/每台元数据服务器的单机性能做深**：无日志原子元数据更新、目录热点的原子指令化、层级化并发控制，都可以在 RocksDB/自研引擎之上或之下借鉴，减少分片（Raft 组）数量需求。
- 也提示一个架构问题：若单分片性能足够高，分片分裂阈值可以大幅提高，降低路由表规模与迁移频率。

---

## 8. DAOS：面向 SCM/NVMe 的用户态 scale-out 存储栈（及其"后 PM 时代"演进）

- **论文 1**：Z. Liang, J. Lombardi, M. Chaarawi, M. Hennecke, "DAOS: A Scale-Out High Performance Storage Stack for Storage Class Memory", SCFA 2020（Supercomputing Frontiers Asia），LNCS 12082, pp. 40-54
- **论文 2**：M. Hennecke 等, "DAOS Beyond Persistent Memory: Architecture and Initial Performance Results", ISC High Performance 2023 Workshops（Springer LNCS）
- **机构**：Intel（现由 HPE/社区主导，Linux Foundation 项目）
- **链接**：https://doi.org/10.1007/978-3-030-48842-0_3 ；https://link.springer.com/chapter/10.1007/978-3-031-40843-4_26 ；https://docs.daos.io
- **目标硬件**：Intel Optane PMem（元数据+小 IO）+ NVMe SSD（大 IO）+ RDMA/libfabric；2023 版转向纯 NVMe

### 核心设计

- 完全用户态、绕过内核的对象存储栈（严格说是对象存储 + 其上的 POSIX 文件系统层 libdfs/dfuse，在 HPC 语境下作为并行文件系统使用）。
- **介质分工**：小 IO 与元数据直接落 PMem（PMDK 事务，字节寻址，作为一等存储介质而非缓存）；大块 IO 经 SPDK 落 NVMe SSD——按 IO 尺寸选介质，任意对齐/大小都能拿到高带宽与高 IOPS。
- shared-nothing：每个 engine 独占核/盘/网口，Argobots 用户态调度；多副本或 EC，客户端直连所有 engine。
- **"Beyond PM"（2023）**：Optane 停产后推出 Metadata-on-SSD 架构——元数据结构改为 DRAM 常驻 + WAL 落 NVMe + checkpoint，模拟 PM 的低延迟持久化语义。这是"PM 设计如何退化回 SSD"的教科书案例。

### 关键实验结果

- IO500 榜单多年霸榜（ISC/SC 各期，10 节点与全系统组）；SCFA'20 论文展示任意 IO 尺寸下接近介质极限的带宽/IOPS；Aurora 超算（Exascale）的存储底座。

### 局限

- 架构为 Optane 设计，Metadata-on-SSD 属"移植适配"，WAL+checkpoint 引入了 PM 时代不存在的写放大与恢复复杂度；POSIX 层是对象模型上的适配层，语义/兼容性弱于原生内核文件系统；部署复杂。

### 设计启示

- **按 IO 尺寸/类型分介质**是通用原则：元数据服务的复制日志与热点元数据可走"电容 DRAM/低延迟 SSD WAL + checkpoint"（正是 DAOS Beyond-PM 的结构）；存储节点大块追加写走普通 NVMe 的顺序带宽。
- 用户态 IO 栈（SPDK）+ 每盘单线程 shared-nothing 引擎是存储节点达成 TB/s 级聚合带宽的成熟路线；DAOS 证明了该路线在万级盘规模的可运维性。

---

## 9. Famfs：面向 CXL 分列共享内存的 fs-dax 文件系统

- **发表形态**：Linux 内核 RFC 补丁系列（2024 年 2 月起，LWN 多次报道）+ **FAST 2025 poster/演讲** + LSFMM 2024/2025、SNIA SDC、MSST 2025 等报告；**无长篇同行评审论文**（此点为其现状，非缺陷标注）
- **作者/机构**：John Groves 等（Micron）
- **链接**：https://lwn.net/Articles/963406/ ；https://github.com/cxl-micron-reskit/famfs ；FAST'25 页面 https://www.usenix.org/conference/fast25
- **目标硬件**：CXL 2.0+ 共享 fabric-attached memory（多主机经 CXL switch 共享同一内存池）；设计上不绑定 CXL，任何可多主机映射的共享内存均可

### 核心设计

- 场景：多台主机对同一个 TB 级共享内存池做零拷贝数据共享（如特征表、KV cache、列式数据集），应用无需修改，用 mmap/read 直访。
- **数据路径**：fs-dax 接口——文件即共享内存中的 extent 列表，open/mmap 后 load/store 直访，**完全没有网络与 IO 栈**；这是所有 DFS 中数据路径最短的形态。
- **元数据路径**：刻意极简——由单一 Master 节点创建/分配文件（append-only 的元数据日志写在共享内存里），其他主机以只读方式挂载并重放元数据日志；不支持一般性的多写者 POSIX 语义（回避了 CXL 上尚无成熟跨主机缓存一致性协议的难题）。
- 2025 年起转向 FUSE 实现（fuse/famfs 融合，配合内核 dax iomap 支持）以求合入主线。

### 关键实验结果

- 公开材料以功能演示与微基准为主（多主机共享挂载、对比 NFS 的数量级带宽优势属预期结论）；缺少同行评审的系统性评测（待确认：正式论文是否在撰写中）。

### 局限

- 多主机共享 CXL 内存硬件（CXL switch + MHSLD）2026 年仍处早期，多数验证在模拟/单机环境；单 Master、只读从节点的模型远弱于通用 DFS；跨主机缓存一致性依赖软件约定（写者 flush、读者失效）。

### 设计启示

- 短期非竞品，长期是信号：**当 CXL 共享内存池成熟，"热数据层"可能不再经过网络**。冷热分层设计可预留"CXL 共享内存"介质类型的抽象位。
- famfs 的"append-only 元数据日志 + 从节点重放"与追加写存储的理念同构，是极小信任面下做共享的一个可借鉴模式。

---

## 10. 3FS（Fire-Flyer File System）：AI 时代的 RDMA + NVMe 分布式文件系统

- **发表形态**：DeepSeek 2025 年 2 月开源（github.com/deepseek-ai/3FS）+ 设计文档/技术报告；其集群背景见 arXiv:2408.14158 "Fire-Flyer AI-HPC"。**非同行评审论文**，此处收录因其为 2020 后 RDMA+NVMe DFS 最有影响力的工业实现之一
- **机构**：DeepSeek（深度求索）
- **链接**：https://github.com/deepseek-ai/3FS
- **目标硬件**：大规模 NVMe SSD 池（180 存储节点、数千 SSD）+ 200/400G InfiniBand RDMA

### 核心设计

- 面向 AI 训练/推理 IO 特征（海量并发随机读、checkpoint 大写、KVCache）：
  - **分离式架构**：cluster manager + 元数据服务（无状态，元数据存 FoundationDB 事务型 KV）+ 存储服务（chunk 引擎）+ 客户端（FUSE 及原生 API）。
  - **数据路径**：RDMA 优先、零拷贝、kernel bypass；链式复制 CRAQ（Chain Replication with Apportioned Queries）提供强一致读写分流——写走链头到链尾，读可打到任意副本。
  - **放弃读缓存**：认为 AI 随机读命中率低，直接压榨全盘随机读 IOPS/带宽，简化一致性。
- FUSE 之外提供绕过 FUSE 瓶颈的原生客户端 API（USRBIO）。

### 关键实验结果（官方报告）

- 180 节点集群聚合读吞吐 6.6 TiB/s；GraySort 110.5 TiB / 30 分钟（3.66 TiB/min）；KVCache 读峰值 40+ GiB/s。

### 局限

- 非同行评审，数字为厂商自报；元数据依赖 FoundationDB 的事务吞吐上限；CRAQ 在写热点下链尾延迟放大；POSIX 语义裁剪（面向 AI 场景取舍）。

### 设计启示

- 3FS 是分离式架构最直接的开源对标物。一个值得研究的分岔：用"通用事务 KV（FoundationDB）承载元数据"换开发速度，还是用"自研分片 multi-raft 元数据"换极限规模与可控性——3FS 的实践检验了前者在数千客户端下的可行性边界。
- CRAQ 的"任意副本可读"与追加写、密封后只读的数据布局互补：密封后的数据天然任意副本可读，仍在写入中的数据可借鉴 CRAQ 读分流。
- "为 AI 场景砍读缓存"提醒设计者：缓存策略应按 workload 画像可配置，而非固定设计。

---

## 11. 其他相关工作（简述）

- **DPC: DPU-accelerated High-Performance File System Client**（ICPP 2024，Best Paper 提名；Kan Zhong 等，重庆大学/相关团队与厂商合作）：把分布式文件系统客户端卸载到 DPU，主机经共享内存环与 DPU 协作，兼顾吞吐与主机 CPU 释放。DPFS 路线的延续，验证了国产化场景下 DPU 客户端 offload 的可行性。链接：https://dl.acm.org/doi/10.1145/3673038.3673123
- **SwitchFS: Asynchronous Metadata Updates for Distributed Filesystems with In-Network Coordination**（EuroSys 2026；Jingwei Xu、Mingkai Dong、Haibo Chen 等，上海交大 IPADS）：用可编程交换机（属广义"新硬件"）在网内跟踪目录状态，实现异步元数据更新——操作提前返回、目录更新推迟到读取时结算，同时隐藏延迟并摊薄开销。对元数据服务的目录热点（大目录并发 create）是一条激进但有启发的思路。链接：https://dl.acm.org/doi/10.1145/3767295.3769349 ；arXiv:2410.08618（前身名 AsyncFS）
- **HiDPU**（FAST 2025）：面向分列式（disaggregated）存储的 DPU 侧混合索引方案，非完整文件系统，但代表 DPU 内存受限环境下索引结构的设计功力（细节待确认）。
- **DPC: A Distributed Page Cache over CXL**（arXiv 2026，preprint，待确认录用情况）：基于 CXL 共享内存构建跨主机分布式 page cache，对比 VirtioFS/NFS/JuiceFS——CXL 与文件访问栈结合的早期学术信号。
- **TeRM: Extending RDMA-Attached Memory with SSD**（FAST 2024，清华）：非文件系统，但其"RDMA 可注册内存扩展到 SSD"的机制对 RDMA DFS 的内存管理有支撑意义。
- **VAST Data**：NVMe-oF + SCM 写缓冲的 DASE 商业架构，**无同行评审论文**（仅白皮书），按任务要求在此标注。
- **排除说明**：FUSEE（FAST'23）、ROLEX（FAST'23）、Sherman（SIGMOD'22）等为 disaggregated-memory **KV 存储**而非文件系统，不在本调研范围。

---

## 12. 汇总表

| 论文 | 会议/年份 | 目标硬件 | 核心思路 | 现实可用性 |
|---|---|---|---|---|
| Assise | OSDI 2020 | 客户端本地 PM + RDMA | 客户端 PM 作线性一致可恢复缓存，操作粒度一致性，链式复制，亚秒 failover | Optane 停产，思想可迁移至低延迟 SSD/电容 DRAM；代码开源 |
| Octopus+ | ACM TOS 2021 | PM + RDMA | FS 镜像即共享持久内存池，零拷贝；大 IO 单边 RDMA client-active，自识别 RPC + collect-dispatch 事务 | Optane 停产；RDMA 路径设计仍是范式级参考 |
| LineFS | SOSP 2021（Best Paper） | BlueField SmartNIC + PM | DFS 分解为 stage，流水线并行 offload 后台任务到 wimpy ARM 核，消除主机干扰 | BlueField 可得，PM 依赖是障碍；流水线 offload 方法论通用 |
| DPFS | SYSTOR 2023 | BlueField-2 DPU | virtio-fs 把 FS 客户端整体虚拟化到 DPU，主机零修改，后端可插拔 | 硬件在售、代码开源（IBM/DPFS），工程可复现性最好之一 |
| Fisc | FAST 2023 | 自研 DPU + RDMA | 轻客户端 + 存储感知无状态网关 + virtio-Fisc DPU 直通，云原生高密度接入 | 深度绑定阿里基础设施，不可复现；架构模式可借鉴 |
| SingularFS | ATC 2023 | PM + RDMA | 单元数据服务器极限优化：无日志原子元数据操作、分层并发控制 | Optane 停产削弱前提；单机元数据优化技术可移植 |
| DAOS | SCFA 2020 / ISC 2023 Workshop | PM + NVMe（后转纯 NVMe）+ RDMA | 用户态 shared-nothing 栈，按 IO 尺寸分介质；后 PM 时代 Metadata-on-SSD | 开源、生产级（Aurora/IO500），社区活跃，可用性最高 |
| Famfs | 内核补丁 + FAST 2025 poster | CXL 共享内存 | 多主机共享挂载的 fs-dax FS，单 Master + append-only 元数据日志 | 硬件（CXL switch 共享内存）未普及；代码开源，属前瞻布局 |
| 3FS | 开源技术报告 2025（非评审） | NVMe 池 + RDMA | FoundationDB 元数据 + CRAQ 链复制 + 无读缓存，AI workload 特化 | 开源可部署，工业验证充分；数字为自报 |
| DPC（客户端） | ICPP 2024 | DPU | DFS 客户端卸载至 DPU | 论文级原型 |
| SwitchFS | EuroSys 2026 | 可编程交换机 | 网内协调的异步元数据更新 | 依赖 P4 交换机，原型阶段 |
| VAST Data | 无论文（白皮书） | NVMe-oF + SCM | DASE 分列共享架构 | 商业闭源，标注：无同行评审论文 |

---

## 13. 总体结论

1. **PM 一代论文（Assise/Octopus+/LineFS/SingularFS）的硬件已死、软件遗产仍活**：操作粒度一致性、无日志原子元数据更新、客户端持久写缓冲，应以"低延迟 NVMe + 电容 DRAM"为替身吸收进元数据服务与 SDK 设计，不应直接押注 PM。
2. **RDMA 是当下确定性最高的投入**：大 IO 单边直达存储节点、小消息 RPC 元数据路径、客户端承担编码计算（client-active），三者与"客户端直连存储节点、控制面不在 IO 路径"的分离式架构零冲突，收益已被 Octopus+/DAOS/3FS 反复验证。
3. **DPU 有两条渐进路线**：先做 LineFS 式后台任务隔离（纯软件即可开工），再评估 DPFS/Fisc 式 virtio-fs 客户端 offload（面向多租户云形态）。
4. **CXL 关注但不押注**：为存储介质层预留"共享内存介质"抽象；跟踪 famfs 与 CXL 3.x 硬件进展即可。
5. **3FS 是最值得逐行对读的开源系统**：其 FoundationDB 元数据与 CRAQ 复制的取舍，恰好是"自研 multi-raft 元数据 + 追加写数据布局"路线的对照实验。
