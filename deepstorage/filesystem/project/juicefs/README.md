# JuiceFS 调研

本目录收录对分布式存储系统的源码级调研，面向需要理解或设计分布式文件存储系统的读者。

## JuiceFS

调研基线：`github.com/juicedata/juicefs`，版本 v1.5.0-dev，commit `44a5657`（2026-08-06）。
所有文件行号引用均基于该 commit，格式为 `pkg/xxx/yyy.go:NNN`。

| 文档 | 内容 |
|------|------|
| [juicefs-overview.md](juicefs-overview.md) | 定位、整体架构、进程模型、代码结构、功能矩阵 |
| [juicefs-metadata.md](juicefs-metadata.md) | 元数据引擎：数据模型、三种后端的 Key/Schema 布局、事务与重试、Session/锁/Quota |
| [juicefs-data-path.md](juicefs-data-path.md) | 数据路径：Chunk/Slice/Block 三级模型、写路径、读路径与预读、缓存体系、对象存储抽象 |
| [juicefs-gc-consistency.md](juicefs-gc-consistency.md) | 空间回收：Compaction、引用计数、Trash、延迟删除、后台任务协调；一致性模型 |
| [juicefs-analysis.md](juicefs-analysis.md) | 设计评估与启示：关键设计权衡、可借鉴的机制、应规避的设计、定位决定的取舍 |

## 阅读建议

先读 overview 建立整体印象，再按关注点进入 metadata 或 data-path。
若关注设计取舍与可借鉴的机制，可直接跳到 analysis，其中每条结论都回指前面文档的对应章节。
