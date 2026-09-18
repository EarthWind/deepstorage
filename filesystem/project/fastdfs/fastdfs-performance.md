# FastDFS 性能模型与验证方案

## 1. 公开性能证据的边界

V6.17 仓库包含六类 benchmark：upload、download、mixed concurrent、small files、large files、metadata，并可生成 JSON/HTML 对比报告。源码确实调用 FastDFS client API，不是纯模拟器。但官方 README 没有提供足够的可审计实测组合：

- storage/tracker 节点数与拓扑；
- CPU、内存、磁盘、文件系统和 mount 参数；
- NIC、交换网络、RTT；
- FastDFS/libfastcommon/libserverframe exact build；
- trunk、replica、sync backlog 配置；
- 数据可压缩性和 page-cache 状态；
- 完整原始样本、误差条和失败明细。

README 中“Good: >100 MB/s”“small-file >1000 IOPS”“p95 <50ms”等文字只能视为示例阈值，不能作为 FastDFS 官方性能承诺。示例 JSON 也是格式样例，不是结果。

本报告因此不给出未经复现的 headline TPS，而是给出性能模型和可执行 PoC。

## 2. 为什么数据路径可能很快

### 2.1 Tracker 不传数据

每次请求只向 tracker 获取小路由消息，文件字节直接 client↔storage。只要 tracker QPS 和状态锁不饱和，扩大 storage 数量可以扩大不同 group/源节点的聚合带宽。

### 2.2 无逐文件远程元数据事务

上传生成自描述 file ID，下载从 ID 解码位置，不需要对外部数据库做一次 inode/dentry 事务。相比需要全局 namespace 的 POSIX 系统，控制路径更短。

### 2.3 本地文件系统与 page cache

normal file 直接存本地文件，Nginx 可本机读取，顺序大文件能利用 page cache、readahead、sendfile/zero-copy 等 Linux 能力。代价是冷缓存、inode lookup 和磁盘随机 I/O 会明显影响结果。

### 2.4 异步复制不进入前台 ACK

源 storage 不等待 peer，这降低上传 latency 并提高表观 throughput，但性能收益来自放宽持久性。测试不能只记录 client ACK；还要记录副本 catch-up 时间和源/目标资源。

## 3. 性能瓶颈模型

### 3.1 上传

单源上传上限近似：

```text
min(client NIC,
    source storage NIC,
    source disk write + metadata IOPS,
    DIO writer queue,
    CPU copy/CRC32/protocol,
    connection/work-thread capacity)
```

系统稳态还要满足：

```text
peer sync drain rate >= foreground mutation rate
```

否则 client ACK 看似正常，binlog backlog 和数据风险持续上升。N 副本时，每个 source 最终还需读出并向 N-1 个 peer 发送完整内容，网络和磁盘读放大约 N-1 倍。

### 3.2 下载

热点 normal file 可由同组多个 readable storage 分散，但副本数最多受每组 32 节点硬上限和完整副本成本限制。下载上限取决于：

- client→storage 或 Nginx→client 网络；
- 每组可读节点数；
- cold disk vs page cache；
- 文件大小和 syscall/connection overhead；
- HTTP Range、TLS、proxy/redirect；
- source-first 是否把流量集中到源；
- Nginx 本地缺失时的二跳带宽。

### 3.3 小文件普通模式

单请求固定成本主导：

- tracker RTT + storage RTT；
- TCP/connect/pool；
- open/create/close、inode/dentry/journal；
- CRC32 和 file name；
- binlog mutex/append；
- peer create/unlink；
- access log。

吞吐应以 ops/s 和 P99 衡量，MB/s 意义较小。目录数量只能分散 dentry，不能消除每文件 inode 操作。

### 3.4 Trunk 小文件

trunk 移除大部分 inode create，但增加：

- trunk server slot allocation RTT；
- allocator lock/tree；
- shared container random write；
- header encode/decode；
- delete/free/merge；
- trunk binlog；
- 读取时 offset/Range 处理。

是否更快取决于普通文件 metadata IOPS 与 allocator 串行化哪个更先到达瓶颈。不能只测试 bulk upload，需要高并发 create/delete 混合和 trunk server failover。

### 3.5 Tracker

tracker 每请求数据很小，但仍有：

- route table lock/排序；
- group free-space选择；
- storage report；
- connection buffer pool；
- leader/trunk 管理；
- monitor/exporter 扫描。

应测 route-only QPS 与 latency，不让实际磁盘吞吐掩盖 tracker 上限。两个 tracker 并非一个共享负载均衡状态机；LB/SDK 策略会影响分布。

## 4. 容量效率与成本

### 4.1 Full replication

group 有 R 个 storage 完整副本时，理想 raw/usable 至少为 R。实际还包括：

- 文件系统预留和 journal；
- reserved storage space（样例 20%）；
- inode/block/slack；
- trunk 空 slot/尾部碎片；
- binlog、access log、临时文件；
- 恢复和增长余量；
- 外部 DR 副本。

两副本、预留 20% 的理论 usable/raw 上界约：

```text
usable/raw <= (1 - 0.20) / 2 = 40%
```

尚未扣除文件系统和 trunk 放大。三副本则约 26.7% 上界。实际容量规划必须按最小同组节点，而不是所有盘总和。

### 4.2 没有 EC

固定核心数据路径没有 Reed-Solomon 编码、解码和 parity rebuild。对 PB/EiB 冷数据，完整副本 TCO 可能成为决定性限制。上层压缩/去重只改变 payload，不改变同组复制倍数。

## 5. Benchmark 可信性检查

仓库 benchmark 的优点：

- 直接使用 C client；
- 支持线程、文件大小/数量、混合比；
- 记录 throughput、success、latency；
- 可比较版本；
- 小文件和 metadata 有单独程序。

采用前要修正/复核：

- 多线程共享 `rand()` 和全局统计是否线程安全；
- percentile 是保存全样本还是近似，是否包含 tracker 阶段；
- warmup 结果是否从统计中排除；
- download 是否命中 page cache；
- success latency 是否排除失败；
- client init 是否每线程重复，是否代表生产连接池；
- 结果中的 resource metrics 是否真实采集；
- cleanup 是否完整，是否影响后续轮次；
- upload ACK 并未包含 replica completion。

官方 suite 应与 fio、iperf、fs_mark、自研 async client 和 Prometheus/ebpf 交叉验证。

## 6. PoC 拓扑

至少三档：

### A. 单 Group 基线

- 2 tracker；
- group1 两个独立 storage；
- 每 storage 4 个独立 store paths；
- 4—8 client；
- 独立 Nginx gateway；
- 10/25/100 GbE 以目标生产为准。

用于测单组复制、normal/trunk、故障和恢复。

### B. 横向扩展

- 4 group × 2 storage；
- client 均匀/指定 group 两种；
- 比较 1/2/4 group 聚合带宽和 tracker QPS；
- 注入容量不均和一个慢 group。

用于验证 group expansion 是否线性，以及 max-free 路由是否形成新组热点。

### C. DR

- 主站 2 storage + 远端 `rw=none` storage，或独立 DR cluster；
- WAN RTT/带宽/丢包模拟；
- 大文件前台写 + backlog + recovery；
- 记录 remote verified RPO。

## 7. 工作负载矩阵

### 7.1 对象大小

固定 size 不能代表真实小文件。建议：

| 类别 | 大小 |
| --- | --- |
| tiny | 1 B、512 B、4 KiB |
| small | 16、64、128、256、512 KiB |
| medium | 1、4、16、64 MiB |
| large | 256 MiB、1、10 GiB |
| production trace | 真实 P10/P50/P90/P99 分布和扩展名 |

trunk 的边界要在 `slot_max_size-1`、等于和 `+1` 测试。

### 7.2 Operation mix

- immutable 100% upload；
- 95% download / 4% upload / 1% delete；
- 70/20/10；
- 50/45/5（仓库示例）；
- 80% create / 20% delete 小文件 churn；
- metadata get/set merge；
- appender 单写者和多写者；
- Range 4 KiB/1 MiB/顺序 streaming。

### 7.3 Cache state

每轮标注：

- hot page cache；
- working set > aggregate memory 的 cold-ish steady state；
- 首次读；
- Nginx/CDN cache hit/miss；
- local hit vs cross-storage proxy。

不能通过生产节点 drop_caches；PoC 使用独立环境或超内存数据集。

## 8. 指标

### Client

- success/error/timeout/unknown outcome；
- ops/s、MiB/s；
- P50/P95/P99/P99.9/max；
- tracker route latency 与 storage data latency分开；
- reconnect/retry count；
- public HTTP TTFB/total latency。

### Storage

- CPU user/system/softirq、context switches；
- DIO queue depth/wait；
- per-path IOPS/bandwidth/await/util；
- network throughput/retransmit；
- connection current/max；
- upload/download success；
- binlog append/fsync latency；
- sync bytes/files/lag；
- inode usage/dentry slab；
- page cache hit/miss；
- trunk alloc latency/fragmentation。

### Tracker

- route QPS/latency/error；
- active connections；
- report/heartbeat latency；
- lock contention/CPU；
- tracker view mismatch；
- leader/trunk changes。

### Correctness

- acknowledged file missing on source/peer；
- size/hash mismatch；
- duplicate upload/orphan；
- delete convergence；
- per-file verified replica count；
- DR verified RPO；
- recovery completeness。

## 9. 性能与安全/持久性联动

以下开关不能只看吞吐：

| 变更 | 可能性能收益 | 同时验证 |
| --- | --- | --- |
| ACK 不等副本 | 低写延迟 | 源故障 RPO |
| 降低 binlog sync interval | 更快复制意图落盘 | fsync CPU/IO 抖动，仍不等于数据持久 |
| 增加 sync threads | backlog 更快 | 前台 P99、源读/目标写争用 |
| 开启 trunk | 小文件 inode 减少 | allocator P99、碎片、故障放大 |
| 增加 work threads | 更多网络并行 | context switch/锁 |
| io_uring/send-zc | 网络 CPU 降低 | 内核/NIC兼容、回退路径 |
| source-first read | 新写可见性更好 | 热源集中、读扩展变差 |
| access log | 可审计 | 日志 I/O、敏感数据 |
| TLS gateway | 机密性 | CPU、TTFB、连接复用 |
| application encryption | 静态安全 | CPU、range read、去重失效 |

## 10. 故障下性能

稳态峰值不是生产容量。必须在以下状态维持 SLO：

- 一个 storage offline，剩余节点承担全部读；
- 新 storage 初始同步；
- 单盘 recovery；
- 网络抖动导致 backlog；
- tracker failover；
- trunk server/leader 切换；
- 80%/90%/95% 磁盘使用率；
- base_path/binlog 高水位；
- Nginx local miss 全部 proxy；
- checksum scrub 与备份并行。

生产配置应以最坏降级状态的可接受吞吐为准，而不是健康状态最大值。

## 11. 建议验收门槛

门槛需由业务填值，结构可以是：

```text
normal upload:
  success >= 99.99%
  P99 <= X ms
  acknowledged-but-unavailable after source power-off = 0 within stated RPO contract

download:
  P99 TTFB <= Y ms
  checksum mismatch = 0
  one-storage-down throughput >= Z% baseline

replication:
  P99 verified second-replica lag <= R seconds
  backlog drains within D minutes after 30-minute partition

recovery:
  foreground P99 degradation <= Q%
  post-recovery full manifest/checksum pass = 100%

trunk:
  live/allocated ratio >= F%
  alloc P99 <= T ms
  restart allocator load <= S minutes
```

注意 `0` 丢失只能在定义好的故障模型、时间窗和测试覆盖中成立，不能泛化为绝对无丢失。

## 12. 结论

FastDFS 有实现高吞吐的结构条件：短控制路径、客户端直达、本地文件、异步副本和粗粒度 group 扩展。但表观上传性能与持久性是直接交换，且 group 静态布局、完整复制和小文件元数据会限制规模。可信性能结论必须同时报告 client ACK、远端副本完成、资源放大和故障状态；否则测试只是测到了“把风险推到后台”的速度。
