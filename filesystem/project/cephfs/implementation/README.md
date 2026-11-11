# CephFS 实现文档

> 源码基线：[`ceph/ceph@v20.2.3`](https://github.com/ceph/ceph/tree/v20.2.3)（Tentacle，commit `06c2f9c3`）；内核客户端参考 Linux 主线 `fs/ceph`、`net/ceph`
>
> 视角：存储研发工程师。回答“这些设计在代码里是如何落地的：模块怎么切、请求怎么流动、数据怎么编码”。

设计层面的“为什么”见 [设计文档](../design/README.md)。本目录中的类名、函数名与消息名以 v20.2.3 为准；不同版本存在重命名（例如 `ESlaveUpdate` → `EPeerUpdate`、`MMDSSlaveRequest` → `MMDSPeerRequest`），阅读旧资料时需要对照。

## 文档列表

| # | 文档 | 内容 | 关键图 |
|---|------|------|--------|
| 1 | [源码地图与进程模型](cephfs-impl-source-map.md) | 源码目录、模块依赖、MDS 线程与锁模型、消息体系 | 模块依赖图、类关系图、线程模型图 |
| 2 | [MDS 实现剖析](cephfs-impl-mds.md) | MDSDaemon/MDSRank、请求生命周期、Server、Locker、MDLog/Journaler、MDCache、Migrator、StrayManager/PurgeQueue | 请求处理管线、journal 写入/过期、迁移状态机 |
| 3 | [客户端实现剖析](cephfs-impl-client.md) | libcephfs `Client`、内核 `fs/ceph`、caps 处理、ObjectCacher、Objecter、Striper、异步目录操作 | 客户端栈结构、caps 处理流程、Objecter 重发流程 |
| 4 | [关键请求端到端流程](cephfs-impl-request-flows.md) | mount、lookup/open、create、write+fsync、read、rename（跨 rank）、unlink+purge、mksnap、MDS failover | 9 张端到端时序图 |
| 5 | [持久化格式](cephfs-impl-on-disk-format.md) | metadata/data pool 对象命名、dirfrag omap 编码、journal 格式、backtrace、各类表 | 对象布局图、journal 格式图 |
| 6 | [文件系统初始化流程](cephfs-impl-bootstrap.md) | 建池、MON `fs new`、rank 分配、`MDSRank::boot_create` 写出初始对象、多 rank 初始化 | 初始化时序图、boot_create 流程图 |
| 7 | [文件、目录与数据块的存储和索引](cephfs-impl-storage-indexing.md) | inode 内联 dentry、dirfrag 与 fragtree、数据对象计算寻址、BlueStore 物理索引、backtrace 反查、快照版本 | 路径示例图、dirfrag 定位图、BlueStore 索引图、open_ino 流程 |

## 推荐的源码阅读顺序

1. `src/mds/MDSRank.cc`：`MDSRank::handle_message` / `_dispatch`，建立“消息 → 子系统”的整体印象。
2. `src/mds/Server.cc`：`handle_client_request` → `dispatch_client_request` → 任选一个 `handle_client_*`（推荐 `handle_client_openc`）。
3. `src/mds/Locker.cc`：`acquire_locks`、`issue_caps`、`handle_client_caps`。
4. `src/mds/MDLog.cc` + `src/osdc/Journaler.cc`：`submit_entry`、`_submit_thread`、`trim`。
5. `src/mds/MDCache.cc`：`path_traverse`、`rejoin_*`、subtree 管理。
6. `src/client/Client.cc`：`make_request`、`_write`、`get_caps`、`handle_caps`。
7. `src/osdc/Objecter.cc`：`op_submit`、`_calc_target`。

## 调试与观测入口

| 工具 | 用途 |
|------|------|
| `ceph tell mds.<id> dump_ops_in_flight` / `dump_historic_ops` | 查看请求卡在哪个阶段（`flag_point`：`acquired locks`、`failed to xlock`、`submit entry: journal_and_reply` 等） |
| `ceph tell mds.<id> session ls` / `client ls` | 会话、caps 数量、客户端元数据 |
| `ceph tell mds.<id> dump cache <file>` | 导出缓存对象（大缓存慎用） |
| `ceph tell mds.<id> get subtrees` | 子树分区与 auth 分布 |
| `ceph tell mds.<id> perf dump` | `mds`、`mds_log`、`mds_cache`、`purge_queue` 等计数器 |
| `cephfs-journal-tool --rank=<fs>:0 journal inspect / event get summary` | 离线检查 journal |
| 内核 `/sys/kernel/debug/ceph/*/{mdsc,osdc,caps}` | 内核客户端在途 MDS/OSD 请求与 caps |
| `debug_mds=20 debug_ms=1` | 最详细日志（性能影响大，短时开启） |
