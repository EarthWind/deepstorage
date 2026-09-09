# Lustre 调研

调研基线：`github.com/lustre/lustre-release`，commit `eadb94b`（2026-07-13），master 分支。
所有文件行号引用均基于该 commit。

Lustre 与前两个调研对象**不属于同一技术脉络**。它是内核态 C 实现的并行文件系统，
诞生于 HPC 场景，2003 年起在超算 Top500 上占据统治地位。它代表的是
**"用分布式锁管理器换取真正 POSIX 语义"** 这条路线——与 JuiceFS/CubeFS
的"TTL 弱一致 + 客户端缓存"路线正面相对。

对 LightStore 的价值不在于照搬架构（内核态、强锁语义、无副本设计都不适用），
而在于两点：

1. **它解决了另外两个系统回避的问题**：跨客户端的强一致、精确的 `stat` 语义、
   写入空间预留、无中心协调的故障恢复。这些机制值得单独评估是否要引入。
2. **它踩过的坑更深**：20 年的生产演进，暴露了强一致路线在规模、运维、
   故障恢复上的全部代价。

| 文档 | 内容 |
|------|------|
| [lustre-overview.md](lustre-overview.md) | 定位、组件拓扑、FID 寻址、代码结构、与前两者的路线对比 |
| [lustre-ldlm.md](lustre-ldlm.md) | LDLM 分布式锁管理器：锁模式矩阵、三种 AST、LVB、inodebits、extent lock |
| [lustre-layout.md](lustre-layout.md) | 数据布局：条带化、PFL、FLR 镜像、DoM、EC 组件、DNE 条带目录 |
| [lustre-recovery.md](lustre-recovery.md) | 恢复机制：transno、VBR 版本化恢复、grant 空间预留、LFSCK |
| [lustre-analysis.md](lustre-analysis.md) | 设计评估与对 LightStore 的对照 |

## 三份调研的定位

| | JuiceFS | CubeFS | Lustre |
|---|---------|--------|--------|
| 路线 | 胖客户端 + 外置引擎 | 自研全栈（Go） | 内核态并行 FS（C） |
| 一致性 | close-to-open | TTL 弱一致 | **强 POSIX（锁驱动）** |
| 冗余 | 委托对象存储 | 副本 + EC | **依赖后端 RAID**（FLR 是后加的） |
| 小文件 | 无打包 | Tiny Extent | DoM（后加） |
| 与 LightStore 距离 | 远 | 近 | 正交（互补） |

前两份调研见 [../juicefs/](../juicefs/README.md) 与 [../cubefs/](../cubefs/README.md)。
