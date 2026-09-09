# FastDFS 资料来源、版本基线与研究方法

## 1. 研究范围

本调研从分布式存储工程视角回答以下问题：

- tracker、storage、client 和 Nginx 模块的职责及真实数据流是什么；
- group、store path、文件 ID、普通文件、appender 文件和 trunk 文件如何布局；
- 上传 ACK 的精确边界是什么，文件数据、复制 binlog 和副本分别何时持久；
- 新文件读取如何避开滞后副本，更新/删除/append 有怎样的一致性限制；
- tracker 集群是否有多数派共识，网络分区和 leader 切换会影响什么；
- 节点加入、单盘恢复、跨机房读写分离和扩容如何执行；
- trunk 是否真正解决小文件问题，又引入哪些协调、碎片和故障风险；
- 默认安全边界、监控、升级、性能证据和生产工具是否足够；
- FastDFS 的取舍对设计面向万亿小文件、EiB 容量、共识元数据、volume packing 和 EC 的新系统有什么启发。

不在本轮范围内：

- 没有搭建多机物理集群复现吞吐和 P99；
- 没有执行真实断电、双向网络分区、磁盘永久损坏和跨机房恢复；
- 不评估非官方 fork、未合并 PR 和第三方客户端的兼容性；
- 不把源码中存在但未纳入默认构建、含 placeholder 的工具视作生产能力；
- 不提供厂商 SLA、合规认证或安全审计结论。

## 2. 固定版本基线

| 项目 | 固定基线 |
| --- | --- |
| 核心官方仓库 | [happyfish100/fastdfs](https://github.com/happyfish100/fastdfs) |
| 正式版本 | [V6.17.0 Release](https://github.com/happyfish100/fastdfs/releases/tag/V6.17.0) |
| Git 提交 | `ba3ed217397036fe0b674b3962eef41cd013e920` |
| 提交时间 | 2026-08-04 14:57:34 +08:00 |
| GitHub 发布时间 | 2026-08-05 |
| 调研时 master HEAD | `29a2687ec390b103fb0557361c9de8ee999e2adf`，晚于正式 tag，未用作能力基线 |
| 核心 License | GPL-3.0 |
| 官方依赖 | libfastcommon `V1.0.87`、libserverframe `V1.2.14`（按 `INSTALL`） |
| Nginx 模块 | [fastdfs-nginx-module](https://github.com/happyfish100/fastdfs-nginx-module) `V1.26` |
| Nginx 模块提交 | `3c2a4c789f7a9f578e4f60534cd3f5e3eea1d49c`，2025-11-12 |

V6.17.0 的正式发布说明包括：storage 向 tracker 注册时的 IP 身份校验；storage 间同步使用由源 storage 生成、经 tracker 分发的 16 字节密钥；删除 storage/group 和设置 trunk server 时校验客户端 IP；以及多同步线程 join 与多实例 trunk binlog 同步修复。本文把这些视为 V6.17 的增量安全和稳定性能力，不外推到旧版本。

使用固定 tag 而非 master 是必要的。调研时间与 V6.17 发布接近，master 已有更新；任何将来修复都可能改变本文关于默认值、写路径或工具成熟度的判断。所有生产复核都应携带版本、SHA、依赖版本和实际配置。

## 3. 证据等级

| 等级 | 定义 | 使用规则 |
| --- | --- | --- |
| A | 固定 tag 下的源码、配置、Makefile、协议和测试 | 判断真实调用路径、默认样例值、状态机、硬上限和缺失能力 |
| B | 官方 README、部署文档、HISTORY、Release 和 Wiki | 判断设计意图、推荐拓扑、发布变更和操作建议 |
| C | 同一作者的官方配套仓库，例如 Nginx 模块 | 判断 HTTP 下载路径和跨 storage 代理行为 |
| D | 基于 A/B/C 的工程推断 | 必须写成“推断”“风险”或“需验证”，不能冒充官方承诺 |

当资料冲突时采用以下优先级：固定版本实际调用路径 > 固定版本样例配置 > 固定版本官方文档 > Wiki/首页描述。例子：部署文档说 `reserved_storage_space` 的缺省值为 1 GiB并推荐 10%，但 V6.17 样例配置实际写的是 20%；报告会分别称为“代码/文档缺省”和“样例值”，不混为一谈。另一个例子是部署文档称 `slot_max_size` 默认 16 MiB、建议 1 MiB，而样例已经显式为 1 MiB，代码在项目缺项时按 trunk 大小的 1/8 计算。

## 4. 官方资料

### 4.1 项目与发布

- [FastDFS 官方仓库](https://github.com/happyfish100/fastdfs)：项目定位、代码、License 和发行入口。
- [V6.17.0 Release](https://github.com/happyfish100/fastdfs/releases/tag/V6.17.0)：正式发布说明和 V6.17 安全/同步修复。
- [Tags](https://github.com/happyfish100/fastdfs/tags)：版本序列。
- [固定版本 HISTORY](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/HISTORY)：历史功能和兼容性变更。
- [中文 README](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/README_zh.md)：产品定位、组件、group、文件 ID 和功能概览。
- [安装说明](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/INSTALL)：依赖和构建。
- [官方部署建议](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/docs/recommended-deployment-plan_CN.md)：storage ID、trunk、节点数量、线程和目录建议。
- [官方 Wiki](https://github.com/happyfish100/fastdfs/wiki)：安装和配置补充。Wiki 在调研时仍出现 6.16.1 内容，因此仅作次级资料。

### 4.2 固定源码证据锚点

以下链接全部固定到 V6.17.0 SHA，后续主分支变化不会改变证据内容。

| 主题 | 证据 |
| --- | --- |
| group/tracker/storage 硬上限和状态枚举 | [tracker_types.h](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/tracker/tracker_types.h) |
| tracker 路由和下载副本筛选 | [tracker_mem.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/tracker/tracker_mem.c) |
| tracker 请求处理、storage join、状态上报 | [tracker_service.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/tracker/tracker_service.c) |
| tracker leader 排序和通知 | [tracker_relationship.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/tracker/tracker_relationship.c) |
| tracker 配置解析和 trunk 强制选择策略 | [tracker_func.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/tracker/tracker_func.c) |
| 上传完成、文件名生成、更新/删除 | [storage_service.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/storage_service.c) |
| 本地文件读写线程与 close 路径 | [storage_dio.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/storage_dio.c) |
| 同步 binlog、buffer fsync、目标游标、同步线程 | [storage_sync.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/storage_sync.c) |
| storage 参数解析 | [storage_func.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/storage_func.c) |
| storage 注册、同步密钥生成与 tracker 交互 | [tracker_client_thread.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/tracker_client_thread.c) |
| 单盘恢复 | [storage_disk_recovery.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/storage_disk_recovery.c) |
| trunk slot 内存索引与分配 | [trunk_mem.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/trunk_mgr/trunk_mem.c) |
| trunk header、路径和解码 | [trunk_shared.h](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/trunk_mgr/trunk_shared.h)、[trunk_shared.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/storage/trunk_mgr/trunk_shared.c) |
| 客户端 tracker 路由调用 | [tracker_client.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/client/tracker_client.c) |
| 客户端 storage 协议和 metadata API | [storage_client.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/client/storage_client.c) |
| tracker 样例配置 | [tracker.conf](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/conf/tracker.conf) |
| storage 样例配置 | [storage.conf](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/conf/storage.conf) |
| HTTP token 样例配置 | [http.conf](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/conf/http.conf) |
| storage ID 和读写模式 | [storage_ids.conf](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/conf/storage_ids.conf) |
| Prometheus exporter | [exporter README](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/monitoring/prometheus_exporter/README.md)、[实现](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/monitoring/prometheus_exporter/fdfs_exporter.c) |
| benchmark 套件 | [benchmarks README](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/benchmarks/README.md)、[源目录](https://github.com/happyfish100/fastdfs/tree/ba3ed217397036fe0b674b3962eef41cd013e920/benchmarks) |
| 默认构建的扩展工具 | [tools/Makefile](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/tools/Makefile) |
| snapshot/rebalance 成熟度反证 | [fdfs_snapshot.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/tools/fdfs_snapshot.c)、[fdfs_rebalance.c](https://github.com/happyfish100/fastdfs/blob/ba3ed217397036fe0b674b3962eef41cd013e920/tools/fdfs_rebalance.c) |

### 4.3 HTTP 下载模块

- [fastdfs-nginx-module 官方仓库](https://github.com/happyfish100/fastdfs-nginx-module)。
- [V1.26 固定配置](https://github.com/happyfish100/fastdfs-nginx-module/blob/3c2a4c789f7a9f578e4f60534cd3f5e3eea1d49c/src/mod_fastdfs.conf)：tracker、group、store path、proxy/redirect 等配置。
- [V1.26 common.c](https://github.com/happyfish100/fastdfs-nginx-module/blob/3c2a4c789f7a9f578e4f60534cd3f5e3eea1d49c/src/common.c)：token 校验、本地文件判断、远端 storage 路由和下载。
- [V1.26 Nginx module](https://github.com/happyfish100/fastdfs-nginx-module/blob/3c2a4c789f7a9f578e4f60534cd3f5e3eea1d49c/src/ngx_http_fastdfs_module.c)：HTTP range、proxy 和 Nginx upstream 路径。

## 5. 研究方法

1. 用官方 tags、release 和 Git 远端引用确定正式版本及固定 SHA，不使用“最新版”作为不可复现基线。
2. 从样例配置、枚举、协议结构、进程入口和 Makefile 建立组件与能力清单。
3. 沿 client→tracker→storage 追踪上传、下载、更新和删除调用，精确定位响应发送前发生的写入、close、binlog 和 fsync。
4. 沿每个目标 storage 的同步 reader/mark/binlog 追踪组内复制，检查新节点状态转换和恢复源依赖。
5. 检查 tracker leader 选择、通知成功条件、失联处理和多 leader 处理协议，区分“高可用”与“共识”。
6. 对 trunk 追踪 slot 分配、文件头、trunk server、free-space 合并、binlog 和恢复，避免只依据功能说明。
7. 将 V6.17 安全改动与普通客户端协议分开，确认其保护的是节点注册、同步和部分管理命令，而不是通用用户鉴权。
8. 检查 benchmark 是否真实调用客户端 API、是否包含硬件和原始结果；只把它作为实验工具，不把示例 JSON 当成实测。
9. 检查监控指标和工具默认构建目标；对含 placeholder 或危险 shell 调用的辅助代码降低证据等级。
10. 将结论提炼为通用的设计启示（可借鉴的机制与应规避的设计），并给出 PoC 故障矩阵和退出标准。

## 6. 关键定义

| 术语 | 本文定义 |
| --- | --- |
| tracker | 维护 group/storage 状态和路由选择的轻量控制服务，不存放逐文件 namespace，也不转发正常文件字节 |
| storage | 存放文件、提供客户端协议、维护同步 binlog 并与同组节点复制的服务 |
| group | 容量和复制边界；同组 storage 目标是完整副本，组间数据互不复制 |
| store path | 一个 storage 实例配置的本地数据目录/挂载点，逻辑文件名中以 `Mxx` 标识 |
| file ID | `group_name/logic_filename`；应用访问文件的持久标识，不是 POSIX path |
| source storage | 最初接收上传或产生变更 binlog 的 storage；其 ID/IP 编码在普通文件名中 |
| normal file | 普通不可变上传文件；FastDFS 可更新/删除它，但其下载路由可以在多个副本间分散 |
| appender file | 允许 append/modify/truncate 的文件类型；路由和同步语义更依赖源节点与操作顺序 |
| trunk file | 承载多个小逻辑文件 slot 的固定大小本地容器文件，不是用户暴露的单一业务对象 |
| sync binlog | 源 storage 记录 create/append/delete/update/modify/truncate/rename/link 操作的顺序日志 |
| mark/cursor | 每个同步目标维护的 binlog 读取位置和进度文件 |
| ACK 边界 | storage 向 client 发成功响应前已完成的动作集合；不自动等同于副本或介质持久性 |
| eventual consistency | 副本通过异步日志最终趋同；不代表并发冲突有全局序列化或丢失窗口为零 |

## 7. 限制与稳健性

- **没有硬件复现。** 性能与恢复时间只给出模型、变量和测试计划，不能视为吞吐承诺。
- **源码审计不是完整形式验证。** 跟踪了关键路径和全仓引用，但没有证明所有异常交错下的正确性。
- **依赖版本影响行为。** libfastcommon、libserverframe、内核、文件系统、Nginx 和客户端语言绑定都可能改变时序与故障表现。
- **未覆盖所有配置组合。** 本文重点使用 V6.17 样例值；实际部署必须生成 effective config 并重新推导。
- **未验证文件系统断电语义。** `write`/`close`、rename、目录项和存储设备缓存的持久顺序取决于 XFS/ext4、mount 参数、控制器 PLP 等。
- **“未发现”不是永久否定。** 没有在固定基线找到通用 TLS、RBAC、EC、强一致快照或自动跨组再均衡，不能推导私有版本或未来版本永远没有。
- **工具成熟度判断只针对 tag。** 某些扩展工具可能正在快速开发；含 placeholder、未默认构建意味着不能作为当前生产承诺，而非永远不可用。
- **安全不是渗透测试。** 这里只审视协议和默认配置，不替代代码审计、模糊测试、CVE 管理与合规评估。

## 8. 如何引用本文

建议同时携带四类上下文：版本 SHA、具体配置、证据等级和是否实机验证。例如：

> 在 `FastDFS V6.17.0@ba3ed217` 的固定源码和样例配置中，上传成功路径未等待组内副本，数据写路径只观察到 `write`/`close`；该结论尚需在目标文件系统和电源故障模型下实测。

不要把它缩写成“FastDFS 一定丢数据”，也不要反向写成“两个 storage 就保证强持久”。正确做法是把故障窗口、RPO、应用幂等和外部备份纳入同一个验收模型。
