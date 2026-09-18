# 3FS 数据布局与 I/O 路径

## 1. 数据单元与映射

普通文件按固定 chunk size 划分：

```text
chunk_index = floor(file_offset / chunk_size)
chunk_id    = encode(inode_id, chunk_index)
chain       = layout(chain_table_range, stripe_size, shuffle_seed, chunk_index)
```

inode 内保存的布局足以让客户端完成映射，不需要为每次 I/O 查询 Meta。连续 chunk 先在一个 stripe 内分布，再按 shuffle seed 打散 chain 选择，以避免所有文件都从相同 chain 开始形成热点。

每个目录可配置默认布局，使不同工作负载选择不同 chunk size、stripe 和 chain table。例如：

- 训练样本目录：较大 chunk、宽条带；
- Checkpoint：按写入并发和文件规模设置；
- 在线推理：使用与离线 batch 隔离的 chain table；
- 小文件目录：必须权衡 chunk 元数据和空间放大。

布局一旦写入 inode，就构成持久数据解释的一部分。升级时改变 shuffle 实现会让相同 inode 计算出不同 chain。项目构建文档要求在 GCC 10/11 历史 `std::shuffle` 差异间固定 `SHUFFLE_METHOD`，并在后续构建中保持不变。这不是普通性能参数，而是磁盘格式兼容条件。

## 2. Target、Chain 与 Chain Table

### 2.1 Target

Storage 服务管理一个或多个 target。同一 SSD 可划分多个 target，使一块盘参与多条 chain，也便于放置优化和故障粒度控制。target 并不是独立物理故障域：同盘 target 同时失效，放置算法必须避免同一 chain 的多个副本落在同盘/同节点。

### 2.2 Chain

chain 是有序 target 列表：

```text
head -> middle -> tail
```

公开部署示例默认 `replication_factor = 3`。每个成员持有 chunk 完整副本，而不是数据/校验分片。head 接受写，tail 决定提交完成；读可分散到满足版本条件的成员。

### 2.3 Chain Table

chain table 保存 chain 集合及 version。它有三项关键作用：

- 将数据布局与具体 target 关联；
- 让不同目录/业务使用不同硬件池；
- 通过单调递增 version 隔离旧拓扑请求。

只有 primary MgmtD 应修改 chain table。Storage 收到旧 version 的请求必须拒绝，客户端刷新后重试。基线最新提交本身修复“确保 ChainTable version 单调增长”，说明 version/epoch 是实际正确性热点，升级前应覆盖回退、重选主和并发更新测试。

## 3. 数据放置

项目部署脚本通过 balanced incomplete block design 和整数规划生成 chain，使副本组合尽量均匀。目标不是只让“每盘容量相等”，还包括：

- 每个 storage node/SSD 承担相近 target 数；
- 两个故障域共同出现在 chain 中的次数尽量均匀；
- 某 target 失效后，降级读流量不会集中到少数幸存目标；
- 恢复源/目标关系分散。

五节点部署示例中，每节点 16 NVMe、每盘多个 target，三副本 chain 用组合矩阵分布。脚本生成的表必须经过拓扑验证：

- chain 内不得出现相同物理盘；
- 最好不出现相同 storage node；
- 机架/交换机/PDU 维度要显式编码或事后验证；
- 扩容后新旧 chain table 的容量和流量倾斜要测量；
- target 离线时的读/恢复扇出不能压垮单节点。

仓库放置脚本中出现 EC 组合模式，只能说明它能求解类似纠删码宽度的目标组合，不能证明数据路径有编码、解码、校验块更新和 degraded reconstruct。

## 4. 写路径

一次覆盖写的核心过程：

1. Client 根据 layout 选择 chain 和 head，携带 chain version、chunk ID、offset/length、request identity 和 RDMA buffer 信息。
2. head 检查 chain version；旧请求被拒绝。
3. head 通过 RDMA Read 从客户端注册缓冲区拉取数据。
4. head 获取该 chunk 的锁。并发写同一 chunk 在 head 串行化。
5. Storage 读取当前 committed chunk，应用局部更新，构造 `pending = committed_version + 1`。
6. 更新向 successor 传播，直至 tail。
7. tail 持久化并将 pending 原子提升为 committed。
8. ACK 逆链返回；每个前驱提交相同版本并释放锁。
9. head 向客户端确认。

```text
Client buffer
    ^ RDMA Read
    |
  Head --pending--> Middle --pending--> Tail
   |                  |                  |
   +<------ ACK / commit v+1 ------------+
```

### 4.1 性能含义

- 写流量至少按副本数放大；三副本数据网络/介质写放大约 3 倍，另有 COW 与本地元数据写放大。
- 请求完成受整条 chain 尾部影响，慢 SSD、CPU stall、RNIC congestion 都进入 tail latency。
- 同 chunk 写在 head 串行，多个 writer 随机覆盖同一 chunk 不会随客户端数线性扩展。
- 不同 chunk/chain 可并行，chunk size 与应用并发决定能否打散。
- 中间成员失败时，前驱要等待新 chain 路由收敛并重试 successor。

### 4.2 幂等与去重

网络超时可能发生在“服务端已提交、客户端未收到 ACK”之后。3FS 请求携带 client/request identity，Storage 维护必要的去重/版本状态，防止简单重试重复应用写。生产测试必须覆盖：

- head 收到数据前断连；
- tail 已提交但 ACK 丢失；
- chain version 在重试期间变化；
- 客户端进程重启导致 UUID/sequence 变化；
- 同请求跨连接或跨 head 重放。

仅有 request ID 还不够，ID 生命周期、持久化窗口和 GC 必须与最大重试窗口匹配。

## 5. CRAQ 读路径

传统 Chain Replication 强一致读由 tail 提供。CRAQ 允许任意 replica 在“只持有 committed 版本”时返回数据；若某成员还保留 pending，标准 CRAQ 可询问 tail 哪个版本已提交。

3FS 进一步简化：

- target 只有 committed：直接读；
- 同时有 committed/pending：返回特殊状态；
- 默认 Client 等待并重试；
- relaxed read 可接受 pending 数据；
- 3FS target 不在每次 dirty read 上询问 tail。

优点：

- clean 状态读可分散到所有副本；
- 不增加 tail query 网络往返；
- 读带宽可接近所有副本聚合；
- 读路径无 Meta/FDB。

代价：

- 热写 chunk 的读可能反复遇到 pending；
- 默认读延迟取决于写提交和客户端 backoff；
- relaxed read 可能观察未完成全链提交的版本；
- 故障/重构期间可读成员减少，负载会重分布；
- “读任意副本”不等于任意时刻零协调返回。

## 6. RDMA 传输

3FS 数据写使用服务端 RDMA Read 拉取客户端数据。通常优势包括：

- 客户端不必在协议栈中多次复制；
- Storage 可以在拿到执行资源后再拉取，形成一定背压；
- 大块 I/O 更易接近链路带宽；
- 注册内存可复用。

工程风险：

- memory registration/pinning 需要上限和生命周期管理；
- 客户端 buffer 在完成前不可复用；
- RNIC QP/CQ 数、doorbell、completion polling 会消耗 CPU；
- NUMA 错位可能让 PCIe/内存带宽成为瓶颈；
- 网络分区和 stale rkey 必须快速失败而非永久挂起；
- RoCE 丢包与拥塞控制会显著放大 P99；
- RDMA 不是加密协议，网络隔离仍是安全前提。

3FS 同时有 TCP/RDMA 基础设施代码，但官方峰值和主要优化面向 RDMA。不能把 TCP fallback 的功能可用性理解为同等级性能。

## 7. FUSE 路径

FUSE daemon 实现的核心 callback 包括 lookup、get/setattr、readlink、mknod、mkdir、unlink、rmdir、symlink、rename、link、open、read、write、flush、release、fsync、opendir、readdirplus、statfs、create 和特定 ioctl/xattr。

已知边界：

- Linux 5.x FUSE 路径不能高效支持同一文件并发写，官方建议多文件并发；
- 4 KiB read IOPS 在设计测量中约到 400K 后共享队列/锁成为瓶颈；
- 小块非对齐随机读会触发额外数据处理；
- rename 的非零 flags 在检查实现中不支持；
- 普通 xattr 返回不支持，特殊 `hf3fs.lock` 用于目录控制；
- 未见 POSIX record lock/flock、通用 fallocate、copy_file_range 的完整 FUSE callback；
- statfs 的可用空间没有 quota 语义。

因此“能 mount”不应直接写成“完整 POSIX 兼容”。兼容性必须按目标应用的 syscall trace 验证。

## 8. USRBIO 路径

### 8.1 使用模型

典型步骤：

1. 挂载 3FS FUSE；
2. 通过路径 open 文件；
3. 将 fd 注册到 USRBIO；
4. 分配并注册 I/O buffer；
5. 创建 I/O ring；
6. prep 多个 read/write request；
7. submit 通知；
8. poll/reap completion；
9. 注销 fd、buffer 和 ring。

它保留 Meta/FUSE 的 namespace 和 fd 生命周期，同时绕过 FUSE read/write 的关键瓶颈。

### 8.2 并发模型

- I/O ring 用深度限制 in-flight 请求；
- 批量 prep/submit 摊薄通知开销；
- 单 ring 建议单生产者、单消费者；
- 多线程应使用多个 ring，避免共享 cache line/lock；
- 读 ring 与写 ring 分开更易保持语义；
- completion 可能乱序，应用用 user data 对应请求；
- 请求一旦准备，后台可能开始处理，不能假定 submit 才是唯一执行边界。

### 8.3 应用集成成本

USRBIO 不是透明加速：

- 训练框架或数据加载器需要 native binding；
- buffer 管理要满足 alignment、registration 与 pinning；
- error code、partial I/O、retry 和 cancellation 需显式处理；
- 容器要共享 mount、设备和内存锁权限；
- mount daemon 重启可能使注册对象失效；
- 测试需要覆盖 fork、exec、进程退出和异常释放。

## 9. Storage 本地引擎

### 9.1 经典引擎

默认/传统路径由固定数据文件、allocator、LevelDB/RocksDB chunk metadata 和内存缓存组成：

- 使用 XFS 上的 O_DIRECT 和 libaio；
- 物理 block size 按 64 KiB 至 64 MiB 的 2 次幂分级；
- 每个资源池可由多个大 physical file 组成；
- allocation bitmap 跟踪空闲块；
- 一般覆盖写使用 copy-on-write；
- append 可在满足条件时原地扩展；
- metadata DB batch 原子更新 chunk 位置、版本和 allocation；
- 延迟 recycle/hole punch 回收旧块。

COW 避免覆盖过程中破坏 committed 版本，但会增加临时空间和写放大。盘接近满时，无法分配新块即使旧块写后可释放，必须预留 recovery/COW/GC 空间。

### 9.2 新 Rust Chunk Engine

仓库存在可选新引擎，包含 allocator、RocksDB MetaStore、group 和 compaction 线程，设计粒度示例为 64 KiB、512 KiB、4 MiB 等。默认配置仍可见旧引擎开关关闭/新引擎未全局启用。

生产含义：

- 新旧引擎可能有不同磁盘格式和性能曲线；
- 升级/回退前必须确认 target 的格式识别；
- 混合引擎的恢复、checksum、GC 和工具兼容需验证；
- “源码存在”不等于默认稳定能力。

## 10. 校验和与持久化

chunk metadata 支持 CRC32C/CRC32 校验。不同读写操作的 checksum 开关可配置，默认值并非所有路径一致。应把以下问题拆开验证：

- 写入时是否计算并持久化；
- chain 每跳是否验证；
- 读取时客户端/服务端是否默认验证；
- partial overwrite 后 checksum 范围；
- recovery copy 是否验证源和目标；
- scrub 是否能主动发现 latent error；
- checksum mismatch 能否自动从健康副本修复。

CRC 能发现随机损坏，不提供认证，也不防恶意篡改。

本地 metadata DB 的同步写、O_DIRECT 和 chain ACK 共同构成持久化路径，但真实断电语义仍依赖：

- NVMe power-loss protection；
- drive cache/FUA/flush 行为；
- XFS 与 metadata DB WAL；
- kernel/driver；
- 每层 fsync 实现。

没有断电注入就不应宣称“ACK 后一定跨整机掉电不丢”。

## 11. 纠删码能力判断

在固定基线中，公开数据路径的证据指向 full replication：

- chain 成员保存完整 chunk；
- 写沿 chain 传播完整更新；
- 恢复比较 chunk version 并复制完整 chunk；
- 默认部署为 replication factor 3；
- 客户端读选择完整副本。

虽然 `deploy/data_placement` 脚本包含 EC 风格的组合参数/生成器，但未在客户端、Storage 和恢复主路径中找到 codec、data/parity stripe、partial update parity、degraded decode、rebuild 等成套实现。

严谨结论是：“固定公开基线未验证可用的 EC 数据保护能力”，而不是“项目未来不可能支持 EC”。

## 12. 数据路径容量与风险

三副本粗略容量模型：

```text
usable ~= raw / 3
         - XFS/metadata DB
         - COW temporary space
         - GC delayed reclaim
         - recovery reserve
         - operational headroom
```

实际可用比例必须按文件大小分布、chunk size、物理 block size 和删除率测量。小文件若每个文件至少占一个分配单元，会同时放大：

- Storage chunk metadata；
- physical block 内部碎片；
- FDB inode/dentry；
- create/open RPC；
- GC 对象数量；
- 三副本容量。

这也是 3FS 不宜未经验证直接承接万亿级小文件/低成本冷数据的根本原因。
