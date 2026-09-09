# deepstorage

分布式存储系统技术调研资料库。以固定版本源码和官方文档为基线，对主流开源分布式文件系统 / 对象存储逐一做架构、元数据、数据路径、一致性、高可用、性能与运维层面的深度分析，并整理 2020 年以后的相关学术论文。

所有内容均为桌面研究：架构、默认配置和故障处理结论来自源码与官方资料，可信度较高；吞吐、延迟、规模上限等没有脱离环境给出单一数字，落地前需要在目标硬件上做 PoC 复核。

## 目录结构

```
deepstorage/
└── filesystem/
    ├── papers/      分布式文件存储重要论文清单（2000 – 2026.08）
    └── project/
        ├── 3fs/         DeepSeek 3FS（Fire-Flyer File System）
        ├── beegfs/      BeeGFS
        ├── cephfs/      CephFS
        ├── cubefs/      CubeFS
        ├── fastdfs/     FastDFS
        ├── glusterfs/   GlusterFS
        ├── juicefs/     JuiceFS
        ├── lustre/      Lustre
        ├── seaweedfs/   SeaweedFS
        └── papers/      分布式文件系统论文调研（2020 年之后）
```

## 调研对象

| 系统 | 定位 | 版本 / 源码基线 | 调研日期 | 入口 |
|------|------|-----------------|----------|------|
| 3FS | 面向 AI 训练 / 推理与 HPC 的全闪存分布式文件系统，元数据存于 FoundationDB，数据走 CRAQ 链式复制 | `deepseek-ai/3FS@22fca04`（2026-05-07，无 tag） | 2026-08-08 | [3fs/README.md](deepstorage/filesystem/project/3fs/README.md) |
| BeeGFS | HPC / AI 场景的并行 POSIX 文件系统，内核客户端直连存储目标，Buddy Mirroring 双副本 | `ThinkParQ/beegfs` tag `8.4.0` | 2026-08-07 | [beegfs/README.md](deepstorage/filesystem/project/beegfs/README.md) |
| CephFS | 构建在 RADOS 之上的 POSIX 共享文件系统，MDS 管理 namespace、锁与 caps | Ceph Tentacle `v20.2.3` | 2026-08-08 | [cephfs/README.md](deepstorage/filesystem/project/cephfs/README.md) |
| CubeFS | CNCF 毕业项目，Master / MetaNode / DataNode 三组件，副本与 EC（BlobStore）双栈，原生小文件打包 | `cubefs/cubefs@8193603`（2026-08-05，master） | 2026-08-05 | [cubefs/README.md](deepstorage/filesystem/project/cubefs/README.md) |
| FastDFS | 面向图片、音视频等文件对象的轻量分布式存储，tracker + storage，无目录树 | `happyfish100/fastdfs` tag `V6.17.0` | 2026-08-08 | [fastdfs/README.md](deepstorage/filesystem/project/fastdfs/README.md) |
| GlusterFS | 无独立元数据服务器，客户端 translator 图 + 后端原生文件系统，DHT / AFR / EC | GlusterFS `v11.2`（2025-07-02） | 2026-08-11 | [glusterfs/README.md](deepstorage/filesystem/project/glusterfs/README.md) |
| JuiceFS | 对象存储承载数据、外置元数据引擎（Redis / SQL / TiKV）的云原生文件系统 | `juicedata/juicefs@44a5657`（v1.5.0-dev，2026-08-06） | 2026-08-06 | [juicefs/README.md](deepstorage/filesystem/project/juicefs/README.md) |
| Lustre | 内核态 HPC 并行文件系统，MDT / OST 分离，LDLM 分布式锁提供强 POSIX 语义 | `lustre/lustre-release@eadb94b`（2026-07-13，master） | 2026-07-13 | [lustre/README.md](deepstorage/filesystem/project/lustre/README.md) |
| SeaweedFS | Haystack 思路的小对象存储，叠加 Filer 命名空间、S3 Gateway、FUSE 等多种接口 | `seaweedfs/seaweedfs` tag `4.41`（2026-08-06） | 2026-08-08 | [seaweedfs/README.md](deepstorage/filesystem/project/seaweedfs/README.md) |

## 论文清单与论文调研

[filesystem/papers/](deepstorage/filesystem/papers/README.md) 给出 2000 年至 2026 年 8 月的重要论文清单：核心必读 25 篇，以及按生产系统、元数据、数据路径、复制与共识、纠删码、HPC / AI 存储、客户端、新硬件、可靠性实证分类的完整列表和按年份索引。

[filesystem/project/papers/](deepstorage/filesystem/project/papers/README.md) 收录 2020 年（含）之后发表于 FAST / OSDI / SOSP / ATC / EuroSys / NSDI / ASPLOS / SC / SoCC 等会议的分布式文件系统论文，以及少量经核实的工业界技术报告，按五个方向组织：

1. [工业界大规模生产系统](deepstorage/filesystem/project/papers/industry-production-systems.md)：Tectonic、Pangu、Fisc、Baidu CFS、3FS、FalconFS、Colossus 等
2. [元数据扩展性](deepstorage/filesystem/project/papers/metadata-scalability.md)：InfiniFS、SingularFS、λFS、FileScale、Mantle、HMFS、MesaFS、SwitchFS 等
3. [新硬件方向](deepstorage/filesystem/project/papers/new-hardware.md)：持久内存、RDMA、SmartNIC / DPU 卸载、CXL
4. [HPC 与 AI 训练存储](deepstorage/filesystem/project/papers/hpc-ai-storage.md)：burst buffer、训练缓存、checkpoint 存储
5. [客户端与通用技术](deepstorage/filesystem/project/papers/client-and-general-techniques.md)：FUSE 优化、缓存一致性、纠删码、可靠性实证与 crash consistency

## 每个系统的文档组织

每个系统目录都是自包含的，通常包含以下文档（文件名以系统名为前缀）：

| 文档 | 内容 |
|------|------|
| `README.md` | 版本基线、技术摘要、核心结论、文档索引与阅读路径 |
| `*-overview.md` | 产品定位、组件拓扑、代码结构、部署形态、功能边界 |
| `*-metadata.md` | namespace 与元数据模型、分片方式、路径解析、rename / unlink 等操作、规模瓶颈 |
| `*-data-path.md` | 数据布局、读写路径、缓存、`fsync`、小文件处理、扩容与重平衡 |
| `*-consistency.md` | 一致性语义、缓存失效、锁、并发写入与跨节点事务边界 |
| `*-ha-recovery.md` | 副本 / EC、故障检测、切换、修复、fsck、备份与故障矩阵 |
| `*-operations.md` / `*-performance.md` | 部署、容量规划、监控、调优、基准、安全与运维清单 |
| `*-analysis.md` | 技术评估：优势、结构性代价、适用性评分、可借鉴与应规避的设计、选型建议与 PoC 计划 |
| `sources.md` | 调研方法、源码 / 文档基线、证据强度说明 |

部分系统按其自身特点调整了拆分方式，例如 CephFS 增加快照与多租户、CubeFS 增加 BlobStore（EC）、SeaweedFS 增加生命周期分层与 S3 / POSIX 接口、FastDFS 增加 trunk 小文件合并。

## 阅读建议

- **快速选型**：先读目标系统的 `README.md`，再读 `*-analysis.md` 中的适用性评分与选型建议。
- **架构评审**：按 overview → metadata → data-path → consistency → ha-recovery 的顺序阅读。
- **入门与补课**：从 [论文清单](deepstorage/filesystem/papers/essential-papers-2000-2026.md) 的核心必读 25 篇开始。
- **设计新系统**：横向阅读各系统 `*-analysis.md` 中"可借鉴 / 应规避的设计"章节，并对照 [论文调研](deepstorage/filesystem/project/papers/README.md) 的元数据扩展性与工业界生产系统两篇。
- **准备 PoC 或上线**：重点阅读 operations 文档，并把 ha-recovery 文档中的故障注入项纳入验收。
- **核验结论**：通过各目录 `sources.md` 回到固定版本源码与官方文档。

## 调研方法与证据边界

- 每个系统固定到具体 tag / commit，文中源码位置引用均以该基线为准。
- 区分三类材料：官方文档与宣称、固定版本源码事实、本文工程推断；推断不冒充官方 SLA。
- 论文调研中非同行评审材料（官方博客、开源报告、内核工程）均明确标注。
