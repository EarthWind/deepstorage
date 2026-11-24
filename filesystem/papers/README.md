# 分布式文件存储论文

本目录收录分布式文件存储领域的论文资料，分两层：

- **清单**：[essential-papers-2000-2026.md](essential-papers-2000-2026.md)，跨度 2000 年至 2026 年 8 月，只给出论文、机构、会议和一句话定位。包括核心必读 25 篇 + 按主题分类的完整清单（生产系统、元数据、数据路径、复制与共识、纠删码、HPC/AI 存储、客户端、新硬件、可靠性实证）+ 按年份索引。
- **详解**：其余五份主题文档，只覆盖 2020 年（含）之后的论文，每篇有内容摘要、出处链接与设计启示。清单中 2020 年后的条目均可在详解文档中找到对应小节。

> 详解部分调研日期：2026-08-15
>
> 范围：2020 年（含）之后发表的分布式文件系统及紧密相关领域的论文，以 FAST / OSDI / SOSP / ATC / EuroSys / NSDI / ASPLOS / SC / SoCC 等系统方向会议为主，辅以少量经核实的期刊、workshop 与工业界技术报告（非同行评审材料在文中均明确标注）。
>
> 视角：面向分布式文件系统的设计者与研究者，为新系统的设计与既有系统的演进提供论文层面的参照。每篇论文均记录出处链接与"设计启示"（面向通用分布式文件系统设计的可借鉴经验）。

## 1. 建议阅读路径

1. 先按 [核心必读 25 篇](essential-papers-2000-2026.md#1-核心必读-25-篇) 的顺序建立整体框架。
2. 根据关注点进入清单对应主题节：设计元数据服务看第 3 节，设计数据路径与冗余看第 4、6 节，做可靠性工程看第 10 节。
3. 需要结合具体系统时，用清单第 11 节的对照表跳到本仓库对应的系统调研。
4. 需要 2020 年后论文的细节与设计启示时，进入下方的详解文档（按关注点的阅读建议见第 5 节）。

## 2. 详解文档导航

按主题分为五个方向，每个方向一份文档：

1. [工业界大规模生产系统](industry-production-systems.md)：Meta Tectonic / Tectonic-Shift、Alibaba Pangu / Fisc、Baidu CFS、DeepSeek Fire-Flyer 与 3FS、Huawei FalconFS、Google Colossus（博客）与 CacheSack 等。看"真实生产规模下什么设计能活下来"。
2. [元数据扩展性](metadata-scalability.md)：InfiniFS、CFS、SingularFS、λFS、FileScale、Mantle、HMFS、FalconFS、MesaFS、SwitchFS 等。聚焦 namespace 分区、路径解析、rename 原子性、热点与弹性扩容，是元数据服务设计最直接的参照。
3. [新硬件方向](new-hardware.md)：Assise、Octopus+、LineFS、DPFS、DAOS、Famfs、3FS 等。覆盖 persistent memory（含 Optane 停产后的格局）、RDMA、SmartNIC/DPU 卸载与 CXL。
4. [HPC 与 AI 训练存储](hpc-ai-storage.md)：HadaFS、DeltaFS、UnifyFS、GekkoFS、CHFS 等 burst buffer / 超算文件系统，Quiver、SHADE、SiloD 等训练缓存，以及 CheckFreq、Gemini、ByteCheckpoint 等 checkpoint 存储工作。
5. [客户端与通用技术](client-and-general-techniques.md)：FUSE 优化（XFUSE、RFUSE、FUSE-over-io_uring）、缓存一致性（DFUSE、Concordia）、纠删码（ECWide、wide LRC、Tiger、RepairBoost、ParaRC）、可靠性实证与 crash consistency（Perseus、EBS 演进、Metis 等）。

单篇精读（基于论文原文逐节解读，含架构图、流程图与整体总结）：

- [Tectonic（FAST 2021）](tectonic-fast2021/README.md)：Facebook EB 级多租户文件系统（含 10 张 sketchnote 图解）。覆盖三层哈希分片元数据、单写者与跨分片 move、TrafficGroup 多租户、数仓 hedged quorum 写与 Blob quorum append 转码、生产数据与经验教训。
- [Tectonic-Shift（ATC 2023）](tectonic-shift-atc2023.md)：Meta 在 HDD Tectonic 前加透明 flash 读缓存 Shift 服务 ML 训练。覆盖功耗驱动的软硬件设计空间、DLRM 训练负载刻画、一致性哈希 + CacheLib 架构、基于作业规格的准入/重插入策略与 PID 写入限速、策略评估与生产 29% 功耗收益。
- [InfiniFS（FAST 2022）](infinifs-fast2022.md)：清华等提出的数据中心级元数据服务。覆盖阿里云盘古负载刻画、访问-内容解耦分区、基于出生三元组哈希的推测式路径解析（含 rename-list/back-pointer）、乐观访问元数据缓存与惰性失效、孤儿环与事务、因素分析与千亿文件评估。
- [SingularFS（ATC 2023）](singularfs-atc2023.md)：清华用单台元数据服务器（Optane PM + RDMA）支撑十亿级文件。覆盖单机路线的规模论证、基于 btime/dtime 时间戳不变式的无日志元数据操作、写者/更新者/读者三级并发控制（cmpxchg16b 无锁时间戳）、NUMA 间与 NUMA 内的混合 inode 分区、惰性崩溃恢复，以及与 InfiniFS、CFS 的对照。
- [Colossus（2021 官方博客 + 2025 两篇续篇）](colossus-blog2021.md)：Google 集群级文件系统，GFS 的继任者（非论文）。覆盖从 GFS 单 master 到 Curator + BigTable 元数据的演进、Borg/Spanner/Colossus 三块基石与两层元数据的区分、客户端库/Curator/BigTable/D 服务器/Custodian 五个组件、元数据递归存储的自举问题、共享存储池与资源解耦、服务层级、flash 按 IO 与 HDD 按容量的配比、2025 年 L4 SSD 读缓存与写回放置、handle + quorum 追加的有状态协议与 Rapid Storage 的版本号隔离，以及 Tectonic 论文误称元数据存于 Spanner 等资料矛盾。
- [CacheSack（ATC 2022）](cachesack-atc2022.md)：Google Colossus Flash Cache 的准入算法（Colossus L4 缓存的方法基础）。覆盖磁盘 IO 成本与 flash 写放大/寿命约束、索引与数据分离的缓存架构、FIFO + 28% 二次机会淘汰、LARC 的三个问题与"命中率不等于省磁盘读"（下层 buffer cache）、按表/locality group 分类与四种准入策略、TTL 近似 LRU 的逐块可加估算（附手算示例）、分数背包 + 下凸包贪心与 127 个候选保留时间、5000 桶/ghost cache/382 个模拟器等工程参数、可内省可维护的落地经验、生产 A/B（磁盘读 −6%、写入 −26%、TCO −6.5%）与仿真中的 U 形总成本曲线，以及会议版与期刊版数字差异等问题。
- [盘古 2.0（FAST 2023）](pangu-fast2023.md)：阿里巴巴统一存储底座 Pangu 从"卖容量"到"卖性能"的演进。覆盖盘古 1.0 到 2.0 两阶段、重客户端 + Raft master（命名空间与 stream 分离）+ chunkserver 架构、统一只追加 FlatLogFile 与自包含 chunk 布局、元数据优化（并行解析、批量、预取、捎带省 RTT）、USSOS 用户态运行时与 USSFS、chasing/non-stop write/backup read/概率黑名单、泰山服务器、有损 RDMA、EC + LZ4 把流量放大从 6.375× 降到 2.94×、RDCA 让数据驻留 LLC、混合 RPC 与 mwait、FPGA 压缩与网卡 CRC、单节点有效吞吐 6.1× 的六阶段瓶颈转移、两次双十一事故与四条教训，以及 P999 前后不一致、mwait 单位存疑等问题。
- [EBS Glory（FAST 2024）](ebs-fast2024.md)：阿里云弹性块存储十年三代演进与经验。覆盖 EBS1 原地更新 Ext4 chunk 的局限、EBS2 建在盘古上的日志结构（LSBD、TxnFile、LSM 索引）与 128 GiB/32 GiB/数据扇区三级分段、后台 GC 转 EC(8,3)+LZ4、EBS3 的 Fusion Write Engine 跨盘合并与 FPGA 压缩及 JournalFile/SegmentCache/DataFile 两级日志、空间放大 3→1.29→0.77 与流量放大 3→4.69→1.59、EBSX 与"尾延迟看软件"、BlockClient 与三级并行的吞吐弹性和 Base+Burst、三级爆炸半径与 Federated BlockManager、令牌桶逻辑故障域、FPGA→ASIC/ARM 的卸载取舍、三个 What If，以及 FPGA 延迟、"提升 X%"口径等不一致之处。
- [DisCoGC（FAST 2026）](discogc-fast2026.md)：字节跳动 ByteDrive + ByteStore 的 discard 与 compaction 结合 GC。覆盖 compaction-only 的写放大/空间放大两难、ByteDrive 两层（Volume/Segment，LSM 索引、块级压缩）与 ByteStore（LogFile、chunk、自包含扇区的用户态文件系统 UFS）结构、三类生产 trace（表 1 重排核对）与连续写/覆盖分析、discard 五步流程、EC 损失与 cluster 损失（可超过 50%）及边界扩展与 cluster 对齐 EC 条带、批处理/并行度/流控、修正垃圾率与双模式 compaction、两阶段 trim 与 trim 过滤/合并、Mock discard 灰度与 WAL 崩溃一致性、位图压缩、生产与测试床评估（TCO −20%）、调参与监控处置规则，以及章节间口径不一致之处。
- [Fisc（FAST 2023）](fisc-fast2023.md)：阿里巴巴面向云原生容器的文件系统接入层（后端为盘古）。覆盖重客户端与集中网络网关的问题刻画、两层功能聚合的轻量客户端（DPU agent + 存储侧 proxy）、文件粒度路由与存储感知故障处理、就近读、virtio-Fisc 设备与 FPGA 快路径、DPU 资源优化、vRPC 与端到端 QoS，以及评估数字中的不一致之处。
- [Assise（OSDI 2020）](assise-osdi2020.md)：UW、KTH、KAIST、UT Austin 等把持久内存放在客户端本地的分布式文件系统（LineFS 的基础）。覆盖 NVM 各层延迟与价格、远端存储与客户端本地两种架构对比、LibFS/SharedFS/集群管理器结构、pessimistic 与 optimistic 两种崩溃一致模式、更新日志写路径与 RDMA 链式复制、分层读路径与温副本、CC-NVM 的前缀崩溃一致与层级租约委托、进程/OS/节点故障与 epoch 位图恢复、微基准与 LevelDB/Filebench/MinuteSort/Postfix 评估，以及摘要倍数（56×、6×、40×）的出处问题。
- [Octopus+（ACM TOS 2021）](octopus-plus-tos2021.md)：清华把 RDMA 原语揉进文件系统内部机制的分布式持久内存文件系统（ATC 2017 Octopus 的期刊扩展）。覆盖 GlusterFS 在 NVM + RDMA 上约 99% 的软件开销与四个低效根源、DMS + 哈希分布数据服务器架构与 NVM 五区布局、共享持久内存池把远程 IO 拷贝从 7 次降到 4 次、client-active IO 与 CPU 加锁 + RDMA 解锁、`write_with_imm` 自识别 RPC、collect-dispatch 事务与 2PC 对比、目录集中化与持久跳表索引、操作日志元数据复制与客户端驱动数据复制、DDIO 下的写后 flush RPC 与 COW 故障原子性、相对 ATC'17 会议版的变化表、Optane 上的评估（Mkdir 软件延迟 6.3 µs、单服务器读 11.9 GB/s、自识别 RPC 4.1 Mops/s），并列出十余处图文不一致和六个未回答的设计问题。
- [LineFS（SOSP 2021）](linefs-sosp2021.md)：KAIST、UT Austin、KTH 等把客户端本地 PM 分布式文件系统（基于 Assise）的后台任务卸载到第一代 BlueField SmartNIC。覆盖 Assise 与 Ceph 的客户端 CPU 账单、PCIe 与弱核两大卸载难点（直接卸载慢 30 倍以上）、LibFS / NICFS / 内核工作线程的分工、先持久后发布、共享前两级的发布与复制流水线、主动链式复制与低延迟/高吞吐连接分离、租约卸载与访问控制、主机崩溃时的独立 NICFS 模式、多租户干扰与 DMA 中断 vs 轮询的实验、压缩省带宽，以及引言与评估数字不一致、"好 X%"口径等问题。
- [DPFS（SYSTOR 2023）](dpfs-systor2023.md)：IBM Research 与 VU Amsterdam 用现成 DPU（BlueField-2）+ 内核自带 virtio-fs 把云文件系统客户端整体卸载出租户主机。覆盖块层 vs 文件层卸载的 I/O 放大论证、DPFS-HAL / DPFS-FUSE / 可插拔后端三层框架、NFS（libnfs + XLIO）与 RAMCloud KV 后端、约 40 µs 框架开销与延迟分解、主机 CPU 4.4× 的微架构推导、单队列与队列深度等局限及后续内核多队列补丁，以及与 Fisc、LineFS 的对照。
- [DAOS（SCFA 2020）](daos-scfa2020.md)：Intel 面向 Optane 持久内存 + NVMe 的全用户态开源分布式对象存储。覆盖传统并行文件系统的三层开销、PMDK/SPDK/libfabric 三块基石与介质分工、Argobots 每请求一个 ULT 的轮询式服务端（九步 I/O 流程）、128 位对象 ID 的算法放置、所有副本直接 RDMA 拉客户端数据的副本/EC 写与失败不等待的变种 2PC、去中心化重建、多版本消除读-改-写（含 EC 部分条带写）、端到端校验、libdfs/dfuse/拦截库的 POSIX 分层、IO500 SC19 图表读数（含论文未提的 easy 带宽落后），以及持久内存容量等数字矛盾。
- [Fire-Flyer AI-HPC（SC 2024）](fireflyer-aihpc-sc2024.md)：DeepSeek 万卡 PCIe A100 集群整篇论文精读（3FS 细节见下一条）。覆盖算力需求与集群形态、PCIe + 单网卡节点与双区两层 Fat-Tree（含 122 台交换机推导）、成本与功耗账、HFReduce 的两个算法与 24 倍访存/chained write/共享 Root Port 瓶颈链、HaiScale 的 PP 错峰与 FSDP 及全部扩展性数据复算、存算一体网络防拥塞与关闭 DCQCN、HAI 分时调度与 5 分钟 checkpoint、验证器、一年 Xid/内存/IB 闪断原始数据复算、下一代 1:1 网卡多平面网络，以及 LLaMA 91% 效率、表 VII/VIII 闪断次数等不一致之处。
- [3FS / Fire-Flyer（SC 2024 + 2025 开源设计说明）](3fs-fireflyer-sc2024.md)：DeepSeek 万卡 PCIe A100 集群与其文件系统。覆盖 PCIe + 单网卡 + 两层 Fat-Tree 双区的成本账、HFReduce/HaiScale、存算一体网络的防拥塞（SL/VL、静态路由、关闭 DCQCN、request-to-send）、无状态 meta + FoundationDB 键设计与文件长度维护、链表与 BIBD 恢复均衡布局、改造的 CRAQ、目标状态机与在线恢复、chunk 引擎、USRBIO、checkpoint 与 KVCache、一年硬件故障数据，以及性能数字口径核对。
- [FalconFS（NSDI 2026）](falconfs-nsdi2026.md)：上交 IPADS 与华为面向深度学习流水线的分布式文件系统。覆盖自动驾驶 DL 负载刻画与"查找税"/瞬时倾斜两大挑战、无状态客户端架构、文件名哈希 + 选择性重定向的混合元数据索引（含 O(n log n) 例外表证明）、按需拉取 + 广播失效的惰性命名空间复制、锁与 WAL 的并发请求合并、基于 `LOOKUP_PARENT` 的 VFS shortcut，以及评估数字口径与表格笔误的说明。
- [CFS（EuroSys 2023）](cfs-eurosys2023.md)：中科大与百度的全 POSIX 分布式文件系统元数据服务。覆盖锁开销实测、文件属性与命名空间层级的分层组织（TafDB 范围分区 + FileStore 哈希）、无 2PC 的跨层写入顺序与 GC、单分片原子原语与 delta apply / last-writer-wins 冲突合并、rename 快慢路径、去代理层，以及与 InfiniFS 的逐项对照。
- [λFS（ASPLOS '23）](lambdafs-asplos2023.md)：GMU、爱荷华州立与弗吉尼亚大学把 HopsFS 的 NameNode 改写成 serverless 函数，构建弹性元数据缓存层。覆盖 HopsFS 无状态 NameNode 与静态规模的两个问题、HTTP-TCP 混合 RPC 与连接共享、按父目录哈希的固定 deployment 分区与 trie 缓存、随机 HTTP 替换的敏捷扩缩容模型与防抖动/落后者缓解、INV/ACK 一致性协议与子树前缀失效和卸载、Spotify 突发负载与成本评估（含 Pareto 基准的期望值推导）、λIndexFS 移植，以及多处百分比分母错误与摘要数字无出处等问题。
- [FileScale（SoCC 2023）](filescale-socc2023.md)：UMD（Abadi 组）在 HDFS 内实现的三层元数据架构。覆盖单机内存/联邦/DDBMS 三条路线的缺口、ZooKeeper 挂载表的 proxy 与 watch 两种路由和过期路由转发、前缀独占的写回缓存与远程 WAL、以完整路径为主键的 14 表关系模式（含表 1 的 pid 错误）、跨分区请求的刷脏—逐出—DDBMS 事务流程、单节点与 32 NameNode 扩展评估、1% 跨分区事务的吞吐断崖、VoltDB 与 Ignite 对比，以及与 λFS 读缓存路线的对照。
- [Mantle（SOSP 2025）](mantle-sosp2025.md)：中科大与百度为云对象存储（百度 BOS）设计的层级元数据服务。覆盖对象存储无状态代理的约束、表式元数据的逐级 RPC 解析与共享目录 2PC 竞争（生产命名空间平均深度约 11 层）、TafDB + 每命名空间 IndexNode 的包含式两层架构（约 80 B/目录）、TopDirPathCache 与无锁 Invalidator、follower/learner 读、delta 记录、IndexNode 上的单 RPC 加锁防环、各项优化消融与生产命名空间数据，以及与 CFS、FalconFS 的对照和多处数字不一致。
- [HMFS（SoCC 2025）](hmfs-socc2025.md)：清华存储组在 RDMA + PM 上的分布式元数据服务，InfiniFS、SingularFS 的后续。覆盖点/范围操作的生产比例（点操作 95.3%）、有序 KV 在 PM 上的瓶颈实测、PM 哈希表 + 目录内链表的索引解耦组织与 64 字节统一布局、基于"ctime ≥ mtime"与 16 字节原子写的无日志更新和按需恢复、流水线/两段并行/缓存/LZ4 的目录遍历、定长每 CPU 分配器、间接对象实现的 rename 与硬链接、单机与 120 亿文件扩展评估，以及 4 台服务器 create/stat 数字写反等不一致。
- [MesaFS（EuroSys 2026）](mesafs-eurosys2026.md)：清华存储组面向 NVMe SSD 的元数据服务，HMFS 的 SSD 版姊妹篇。覆盖元数据存储成为新瓶颈的实测（InfiniFS 仿真只达裸 SSD 的 8.4%–37.2%）、拆分更新与布局有序两类额外写、父子依赖与 ID 唯一两条不变式、先写子项后缓冲父目录的有序更新与同 ID + 临时 backpointer 的 rename、MesaKV 两层布局与 O(1) 分裂的 WO-HTree、各操作的 SSD 写次数、全盘扫描式崩溃恢复、分项分析（create 约 15k → 335k ops/s），以及引言数字归属不清等问题。
- [SwitchFS（EuroSys 2026）](switchfs-eurosys2026.md)：上交 IPADS 用可编程交换机协调的异步元数据更新（FalconFS 同一作者）。覆盖 P/C 聚合与分离的两难、盘古负载中目录更新与目录读的比例（约 86% 的更新不会被立刻读）、父目录修改记入本地 change-log 的 create/statdir/rmdir 流程、可交换性驱动的 change-log 合并与主动聚合、UDP 下的去重与崩溃恢复、Tofino 上组相联的网内脏集合、附录的可串行化论证、交换机 vs 专门服务器 vs 所属服务器的对比，以及"提升"与"加速"口径混用等问题。

## 3. 跨文档重叠说明

部分论文同时涉及多个主题，会在多份文档中出现；下表标注主文档（详解所在），其余文档为交叉视角或简述：

| 论文 | 主文档 | 其他出现位置（视角） |
|------|--------|----------------------|
| Tectonic (FAST 2021) | 工业界生产系统 | 元数据扩展性（namespace 分层 KV 化视角） |
| Tectonic-Shift (ATC 2023) | 工业界生产系统 | HPC/AI 存储（训练 IO 视角，简述） |
| InfiniFS (FAST 2022) | 元数据扩展性 | 工业界生产系统、客户端与通用技术（客户端元数据缓存视角） |
| CFS (EuroSys 2023) | 元数据扩展性 | 工业界生产系统、客户端与通用技术（事务临界区视角） |
| λFS (ASPLOS '23) | 元数据扩展性 | 精读文档 lambdafs-asplos2023.md；与 CFS 精读对照（同以 HopsFS 为基线） |
| FileScale (SoCC 2023) | 元数据扩展性 | 精读文档 filescale-socc2023.md；与 λFS 精读对照（读缓存 vs 写回缓存） |
| Mantle (SOSP 2025) | 元数据扩展性 | 精读文档 mantle-sosp2025.md；与 CFS（同团队、同底座 TafDB）、FalconFS（服务端解析）精读对照 |
| HMFS (SoCC 2025) | 元数据扩展性 | 精读文档 hmfs-socc2025.md；与 InfiniFS、SingularFS（同组前作、主要基线）精读对照 |
| MesaFS (EuroSys 2026) | 元数据扩展性 | 精读文档 mesafs-eurosys2026.md；与 HMFS（同组 PM 版）、SingularFS、InfiniFS 精读对照 |
| SwitchFS (EuroSys 2026) | 元数据扩展性 | 精读文档 switchfs-eurosys2026.md；新硬件（可编程交换机视角）；与 FalconFS、CFS、Mantle、MesaFS 精读对照 |
| Colossus (2021 博客 + 2025 续篇) | 工业界生产系统 | 精读文档 colossus-blog2021.md |
| CacheSack (ATC 2022) | 工业界生产系统 | 精读文档 cachesack-atc2022.md；Colossus 精读（L4 缓存） |
| EBS Glory (FAST 2024) | 客户端与通用技术 | 精读文档 ebs-fast2024.md；工业界生产系统（简述） |
| DisCoGC (FAST 2026) | 工业界生产系统 | 精读文档 discogc-fast2026.md；与 EBS Glory 精读对照 |
| Pangu 2.0 (FAST 2023) | 工业界生产系统 | 精读文档 pangu-fast2023.md；客户端与通用技术（EC/压缩视角） |
| Fisc (FAST 2023) | 工业界生产系统 | 新硬件（DPU 卸载视角）、客户端与通用技术（轻量客户端视角） |
| SingularFS (ATC 2023) | 元数据扩展性 | 新硬件（PM + RDMA 视角） |
| FalconFS (NSDI 2026) | 元数据扩展性 | 工业界生产系统、HPC/AI 存储（深度学习负载视角） |
| 3FS / Fire-Flyer (SC 2024 + 2025 开源报告) | 工业界生产系统 | 新硬件（RDMA+NVMe 视角）、HPC/AI 存储（AI 负载视角） |
| Fire-Flyer AI-HPC (SC 2024，整篇精读) | 工业界生产系统 | 精读文档 fireflyer-aihpc-sc2024.md（计算、网络、平台、故障视角） |
| DPFS (SYSTOR 2023) | 客户端与通用技术 | 新硬件（DPU 视角） |
| DAOS (SCFA 2020) | HPC/AI 存储 | 新硬件（SCM/后 PM 演进视角） |
| Assise (OSDI 2020) | 新硬件 | 精读文档 assise-osdi2020.md；与 LineFS 精读对照（LineFS 基于 Assise） |
| Octopus+ (ACM TOS 2021) | 新硬件 | 精读文档 octopus-plus-tos2021.md；元数据扩展性（DMS 集中目录、collect-dispatch 事务视角），与 Assise 精读对照（服务器池化 vs 客户端本地） |

## 4. 论文总索引

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
| Assise: Performance and Availability via Client-local NVM | UW / KTH / KAIST / UT Austin 等 | OSDI 2020 |
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

## 5. 阅读建议

- **设计元数据服务 / namespace**：先读[元数据扩展性](metadata-scalability.md)全篇，再对照[工业界生产系统](industry-production-systems.md)中 Tectonic 与 FalconFS 的取舍。
- **设计数据路径 / 存储节点**：读[工业界生产系统](industry-production-systems.md)中 Pangu、Fisc，[新硬件](new-hardware.md)的 RDMA/用户态栈部分，以及[客户端与通用技术](client-and-general-techniques.md)的纠删码章节。
- **面向 AI 训练负载选型/优化**：读[HPC 与 AI 训练存储](hpc-ai-storage.md)的负载特征综述与 3FS/FalconFS/Tectonic-Shift 相关小节。
- **设计客户端（FUSE vs SDK）**：读[客户端与通用技术](client-and-general-techniques.md)第 1-2 章，对照 Fisc 的轻量客户端路线。
- **评估可靠性工程**：读[客户端与通用技术](client-and-general-techniques.md)第 4 章（Perseus、故障注入研究、Metis）。

## 6. 总体观察

2020 年之后的分布式文件系统研究呈现几条清晰主线：

1. **元数据服务成为主战场**。FAST/SOSP/EuroSys 上 DFS 论文的多数创新集中在 namespace 分区、路径解析与 rename 原子性上；共识是"目录树语义与元数据索引解耦"（InfiniFS、HMFS、FalconFS、Mantle 均属此路线的不同切法）。
2. **工业界论文从"容量导向"转向"性能与成本导向"**。Pangu 的演进论文直接以 100Gbps+ 网络与 SSD 为前提重写数据路径；Fisc 把客户端做薄并卸载到 DPU。
3. **AI 训练负载重塑设计目标**。2023 年后新系统（3FS、FalconFS、Tectonic-Shift）普遍以"海量小文件随机读 + 大文件 checkpoint 写 + 读多写少"为第一负载假设，FFR（fast failure recovery）与吞吐密度优先于 POSIX 完备性。
4. **Optane 停产使 PM 路线转向**。Assise/Octopus+/SingularFS 的 PM 假设需重新评估，社区转向 CXL（Famfs）与 NVMe 用户态栈（DAOS 演进、3FS）。
5. **FUSE 不再被默认接受**。XFUSE/RFUSE/io_uring 改造内核通道，Fisc/DPFS 干脆绕开，自研 SDK + 薄客户端成为生产系统主流。

各文档内的具体数字、链接与"待确认"标注以各文档正文为准。

## 7. 说明

- 非同行评审材料（技术报告、官方博客、访谈、内核工程）在清单与详解中均已标注。
- 2026 年 7 月的 OSDI / ATC 2026 论文尚未纳入，待补充。
