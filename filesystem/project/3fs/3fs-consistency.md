# 3FS 一致性、原子性与 POSIX 语义

## 1. 一致性分层

3FS 不能用一个“强一致”标签概括。至少要分四层：

| 层次 | 机制 | 保证边界 |
| --- | --- | --- |
| namespace | FoundationDB 事务 | 参与同一事务的 inode/dentry 操作 |
| 单 chunk 数据 | CRAQ/Chain Replication version | 同一 chunk 的有序写与默认强读 |
| 多 chunk 文件 | 客户端拆分请求 | 不具备跨 chunk 原子提交 |
| 元数据与数据 | session、length update、GC 协调 | 不存在一个同时覆盖 FDB 与所有 Storage 的原子事务 |

工程评审应逐项询问“哪一个对象、哪一个时间点、哪一种读模式”，而不是只问系统是否强一致。

## 2. Namespace 一致性

create、link、unlink、rename 等由 Meta 在 FDB 读写事务中执行。FDB 默认事务提供严格可串行化语义和冲突检测，因此：

- 相同 dentry 的并发 create 只能有一个成功；
- rename 的源/目标 dentry 可以在同一事务中变化；
- link count 与对应 dentry 更新可以一起提交；
- 父目录删除与子项创建可通过 conflict range 协调；
- 事务冲突由 FDB/Meta 重试。

限制：

- 仅限事务实际读取/写入和设置冲突范围的 key；
- 单次事务不能无限大或运行无限久；
- FDB 成功不代表文件数据已在另一个时间点完成；
- client timeout 后结果可能未知，需要幂等/查询处理；
- 目录递归操作必须拆为多个事务，因此整体非原子。

## 3. 单 Chunk 写顺序

同一 chunk 的写在 chain head 加锁并按 version 串行化。版本通常由 committed `v` 推进为 pending `v+1`，尾端提交后所有成员逐步把 `v+1` 设为 committed。

这提供的主要性质：

- 同一 chunk 不会有两个并发版本无序提交；
- 默认读不会把未完成提交的 pending 当作强一致结果；
- stale chain version 请求被 fencing；
- 重试可依靠 request identity 和 version 去重；
- 恢复以版本比较判断哪个副本需要同步。

边界：

- 锁粒度是 chunk，不是 byte range；
- 大 chunk 上无关 offset 的并发写也可能串行；
- chain ACK 反向传播时，各成员从 pending 到 committed 不是同一物理瞬间；
- 客户端超时不能简单等同于写失败；
- relaxed read 有意绕过默认读保证。

## 4. 多 Chunk 写

一个跨 chunk 的 write 会被拆分为多个 chunk 请求。可能出现：

- chunk A 已提交，chunk B 仍在重试；
- 客户端在中间崩溃；
- chain A 健康，chain B 正在切换；
- reader 看到文件不同 chunk 来自写入前后两个状态。

因此 3FS 不提供通用的“整次大 write 跨 chunk 原子可见”。应用如果需要原子发布，应使用上层协议：

1. 写入新临时文件；
2. fsync/close 并确认数据完成；
3. 用 namespace rename 原子发布路径；
4. 消费者只打开最终路径；
5. 必要时写 manifest/checksum 作为完成标志。

即使如此，也需要验证 fsync/close 的错误处理和掉电持久化，rename 只原子切换 namespace，不会把未持久数据变得可靠。

## 5. 默认读与 Relaxed Read

### 5.1 默认读

副本只存在 committed 版本时可直接返回。若同时存在 pending，Storage 返回状态让 Client 重试，避免读到尚未在整条 chain 完成的版本。

这接近单 chunk 的线性化读目标，但尾延迟受以下因素影响：

- 热 chunk 连续写造成 pending 窗口；
- tail 慢或 successor 重连；
- 客户端 backoff；
- chain table 切换；
- 读副本局部故障。

### 5.2 Relaxed Read

relaxed 模式允许读取 pending。它适合可容忍短暂版本不确定的缓存/推理场景，但必须明确：

- pending 可能尚未到达所有副本；
- 故障重构可能选择不同已提交状态；
- 相邻 chunk 的版本关系没有保证；
- 不能用于需要 read-after-write 强语义的控制文件；
- 不能因为读取更快就作为全局默认。

建议把 relaxed read 作为目录或应用显式策略，指标中区分使用量和重试率。

## 6. 文件长度语义

数据写直接去 Storage，inode length 在 FDB。3FS 用客户端上报与查询最后 chunk 让 length 收敛，这带来：

- writer 写成功后，其他客户端 stat 可能暂时见到旧长度；
- 多 writer 的最大 offset 需要聚合；
- sparse write/truncate/extend 与最后 chunk 状态交互复杂；
- close 通常是精确收敛点，但失败/超时必须处理；
- fsync 是否更新 length 受配置和调用路径影响；
- fdatasync 可只关注数据而不保证 inode length 立即更新。

基线提交历史仍包含 truncate/extend 同步修复，说明该路径应作为高风险回归项。建议应用把“完成标志”放入单独原子发布步骤，而不是轮询 size。

## 7. fsync、flush、close

这些调用应区分：

- FUSE flush：可能由 fd 副本/进程退出触发，不等同于全局持久化屏障；
- fsync：等待相关写并按配置更新精确长度；
- fdatasync：可不更新非必要元数据；
- close/release：结束 fd/session，并可能触发长度收敛和错误返回。

需要专项回答：

- 之前的异步 USRBIO 请求是否全部完成；
- chain 全体还是 tail 达到何种持久点；
- metadata DB 与 data file 的顺序；
- ACK 丢失时 fsync 如何查明结果；
- 一个 chunk 失败时整个 fsync 返回何错误；
- mount daemon 崩溃后应用是否获得明确失败。

公开设计足以说明流程，但不足以替代目标 SSD/驱动上的断电测试。

## 8. Unlink、Open FD 与 Session

可写 fd 有 session，可延迟 inode/chunk GC；read-only fd 不按同样方式追踪。结果是：

- writer 打开期间 unlink，数据回收通常受 session 保护；
- writer 崩溃后 session 超时，再进入 GC；
- read-only 打开后 unlink 的长期可读性不能直接等同 Linux 本地文件系统；
- FUSE daemon 或 Client 重启可能中断 fd 语义；
- hardlink 数、session 和 GC 必须一致，否则会提前删或长期泄漏。

应用若使用“打开旧文件、rename 新文件覆盖、旧 reader 继续读”的经典配置热更新模式，应把它列为验收测试。

## 9. Rename 与原子发布

单次 rename 的 dentry 修改可由 FDB 原子完成，适合作为发布边界。仍有四个条件：

1. 源和目标操作必须在实现支持的 rename 模式内；非零 rename flags 未完整支持。
2. 目标数据写和 fsync/close 必须先成功。
3. 消费者打开后读取的是 inode/chunk，不应重新依赖源路径。
4. FDB 恢复与 Storage 数据恢复必须保持引用一致。

目录递归 rename 只原子改变目录入口，不意味着目录下所有仍在写的文件数据形成同一快照。

## 10. Hardlink、Symlink 与“快照”

3FS 支持 hardlink 和 symlink，官方应用示例可用 hardlink 构建轻量数据集快照。它适用于：

- 数据文件写完后 immutable；
- 新版本目录用 hardlink 重用未变化文件；
- 修改通过新文件 + rename，而不是 in-place overwrite。

它不等价于文件系统原生 point-in-time snapshot：

- 对已有 inode 的原地覆盖会被所有 hardlink 观察到；
- 没有全局一致的快照时间；
- 不自动捕获 open writer；
- 不提供独立的快照生命周期、配额和复制；
- 不能替代 Storage 数据灾备。

## 11. POSIX 兼容矩阵

| 能力 | 基线判断 | 注意点 |
| --- | --- | --- |
| 基础 create/open/read/write | 支持 | USRBIO 与 FUSE 路径不同 |
| mkdir/rmdir/readdir | 支持 | 分页、超大目录和 GC |
| rename | 基础支持 | 特殊 flags 不完整 |
| hardlink/symlink | 支持 | hardlink snapshot 需 immutable |
| chmod/chown/mode | 支持基础 Unix 权限 | root token/uid 映射需治理 |
| 通用 xattr | 不支持 | 特殊 `hf3fs.lock` 不是通用 xattr |
| POSIX ACL/NFSv4 ACL | 未见完整实现 | 不能靠 xattr 承载 |
| flock/record lock | 未见完整实现 | 数据库等应用可能不兼容 |
| quota | 未见完整实现 | statfs 可用空间不代表租户额度 |
| fallocate | 未见完整通用接口 | 稀疏/预分配语义需测 |
| mmap coherent write | 不应默认假定 | FUSE/USRBIO 路径需应用验证 |
| atomic multi-chunk write | 不支持 | 用临时文件 + rename |
| native snapshot | 未见完整实现 | hardlink 模式不是通用快照 |
| cross-host cache coherence | 有客户端协议但非页缓存通用等价 | 需按应用行为测试 |

## 12. 应用兼容性验证

不要仅运行 `fio`。建议：

- 对目标应用抓取 syscall，统计 xattr、lock、mmap、rename flags、fallocate；
- 同文件多 writer、append writer、reader-writer 混合；
- open-unlink-read、rename-over-open、hardlink-overwrite；
- sparse write、truncate 收缩/扩展、洞读取；
- fsync/fdatasync/close 错误传播；
- 客户端、FUSE daemon、Meta、Storage 在调用中途崩溃；
- 目录权限、sticky bit、root/user token、跨 uid/gid；
- relaxed/default read 混用；
- 版本升级前后打开文件和路由缓存。

## 13. 一致性结论

3FS 的一致性设计对 AI 文件工作负载是合理的：namespace 借 FDB 得到清晰事务边界，单 chunk 借 chain version 和 committed/pending 状态得到有序更新，文件发布可用 rename。它不是通用事务文件系统：多 chunk、多文件、数据与元数据之间没有全局原子提交，动态 length 和 read-only fd 做了扩展性取舍。应用协议必须与这些边界对齐。
