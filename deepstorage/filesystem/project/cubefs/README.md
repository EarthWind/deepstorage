# CubeFS 调研

调研基线：`github.com/cubefs/cubefs`，commit `8193603`（2026-08-05），master 分支。
所有文件行号引用均基于该 commit，格式为 `<component>/xxx.go:NNN`。

CubeFS 是 CNCF 毕业项目（原 ChubaoFS，京东开源），是本调研中与 LightStore **架构最接近**的系统：
自研 Master / MetaNode / DataNode 三组件、卷 + 分区模型、副本与 EC 双栈、原生小文件打包。
因此它的取舍比 JuiceFS 更具直接参考价值——包括它踩到的坑。

| 文档 | 内容 |
|------|------|
| [cubefs-overview.md](cubefs-overview.md) | 定位、组件拓扑、代码结构、卷与分区模型、部署形态 |
| [cubefs-metadata.md](cubefs-metadata.md) | MetaNode：内存 BTree、inode ID 区间分片、Raft、快照、事务、extent 索引 |
| [cubefs-data-path.md](cubefs-data-path.md) | DataNode：Data Partition、Extent Store（tiny/normal）、复制协议、客户端读写与 seal-and-new |
| [cubefs-blobstore.md](cubefs-blobstore.md) | BlobStore：纠删码子系统，ClusterMgr / BlobNode / Access / Scheduler，Location 寻址与 CodeMode |
| [cubefs-analysis.md](cubefs-analysis.md) | 关键设计评估，与 LightStore 的逐点对照 |

## 与 JuiceFS 调研的关系

两份调研互补，覆盖了分布式文件系统的两条主流路线：

| | JuiceFS | CubeFS |
|---|---------|--------|
| 路线 | 胖客户端 + 外置引擎 | 自研全栈服务端 |
| 元数据 | 复用 Redis/SQL/TiKV | 自研 MetaNode + Multi-Raft |
| 数据 | 第三方对象存储 | 自研 DataNode + BlobStore |
| 与 LightStore 的距离 | 远（可借鉴局部机制） | 近（可对照整体架构） |

JuiceFS 调研见 [../juicefs/README.md](../juicefs/README.md)。
