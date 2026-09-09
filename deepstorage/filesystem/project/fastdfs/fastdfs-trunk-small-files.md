# FastDFS 小文件与 Trunk 机制

## 1. 为什么需要 Trunk

普通模式下每个逻辑文件对应一个本地文件。海量小文件会造成：

- inode 和 dentry 数量巨大；
- create/unlink/random lookup IOPS 放大；
- 目录遍历、备份、fsck 和恢复时间增长；
- 文件系统 block/extent 内部碎片；
- 内核 slab/page cache 元数据占用；
- 同步线程每个对象都要做一次文件创建和 metadata 操作。

FastDFS trunk 把多个小逻辑文件装进较大的本地容器文件 slot，目标是减少物理文件数量和元数据 I/O。官方建议在平均文件小于约 200 KiB、单个存储目录预计超过一千万文件时评估开启，而不是所有工作负载默认开启。

## 2. 物理结构

### 2.1 Trunk file

trunk file 是预分配/创建的固定大小容器。V6.17：

- `use_trunk_file=false`，默认关闭；
- `trunk_file_size=64 MiB` 样例/代码常用值；
- 样例显式 `slot_max_size=1 MiB`；
- 部署文档称缺省 16 MiB并建议 1 MiB；
- 配置缺项时 tracker 代码按 trunk size 的 1/8 计算 slot max，并限制不超过 trunk 的一半。

这些值存在“文档默认、代码缺省、样例显式值”差异。生产应以启动日志/effective config 为准。

### 2.2 Slot 与 header

当逻辑文件大小加 header 小于等于 `slot_max_size` 时，storage 可分配 trunk slot。header 固定定义为：

```text
17 + max_extension_length + 1 = 24 bytes
```

它包含文件类型、分配空间、真实大小、CRC32、修改时间和格式化扩展名等信息。slot 可能比实际内容大，余量成为内部碎片；删除后 slot 回收到 free-space 索引，可按配置尝试相邻合并。

trunk 逻辑文件名在普通 27 字符字段后增加 16 字符 trunk info，编码 trunk file ID、offset、size 等定位信息。Nginx 模块/Storage 解析 file ID 后，从容器相应 offset 读取 header 和数据。

### 2.3 一个简化例子

```text
64 MiB trunk container
+----------+-------------------+---------+------------------+
| header A | object A + slack  | free    | header B + B ... |
+----------+-------------------+---------+------------------+
0          slot A end                    slot B
```

删除 A 不会立即缩小 trunk file，而是把 slot 放回 allocator。只有在满足条件且启用相关维护动作时，尾部/空容器才可能回收。

## 3. Trunk server

### 3.1 角色

每个 group 由一个 storage 充当 trunk server，维护空闲 slot 的内存树和 trunk binlog。其他 storage 在保存小文件时，需要向 trunk server 请求：

- 分配 slot；
- 确认分配成功/失败；
- 释放删除后的 slot；
- 同步 trunk free-space 状态。

tracker leader 参与 trunk server 的选择和状态分发。因为所有同组副本最终应使用一致的 trunk 物理位置，slot placement 不能让各 storage 独立随机决定。

### 3.2 性能影响

trunk server 把小文件写引入一个额外控制 RTT 和共享锁/内存结构。其主要瓶颈不是 64 MiB 数据传输，而是高频 slot allocation/confirmation/free：

- 单 group 小对象 create/delete IOPS 会集中；
- trunk server CPU/锁/网络抖动进入写 P99；
- leader/trunk server 切换期间分配暂停或重试；
- 使用 trunk 时 tracker 强制稳定的 `store_server` 策略，上传负载分散能力变化。

因此 trunk 解决 inode 元数据放大，但可能把瓶颈移到 allocator/control path。

## 4. 复制模型

一个 trunk 逻辑对象仍通过 FastDFS sync binlog 复制。各组员本地必须建立同样的 trunk file/slot 内容和 header。需要同步两类状态：

- 业务对象的 create/delete/update 操作；
- trunk allocator 的 slot 分配/释放和 free-space binlog。

V6.17 Release 专门修复“同组同机多 storage 实例时 trunk binlog 同步”问题，说明这条路径有额外状态耦合。恢复和版本升级必须覆盖普通文件与 trunk 文件两套格式。

## 5. 一致性和故障风险

### 5.1 分配确认交错

典型顺序：

```text
storage asks trunk server for slot
  -> storage writes header + content
  -> storage confirms allocation
  -> writes file sync binlog
  -> ACK client
```

如果写失败，storage 应释放/取消 slot。崩溃发生在任意两步之间，可能产生：

- 已分配未写入的 lost slot；
- 已写入但 allocator 认为 free 的冲突风险；
- 对象存在但 sync binlog 未持久；
- peer 容器与 allocator 日志进度不一致。

trunk init/repair 工具需要重放 allocator binlog或扫描 header，但在线写入时获取一致视图并不简单。

### 5.2 容器故障放大

普通文件一个 inode/extent 损坏通常影响一个对象；trunk file 的局部或整体损坏会影响同一容器内多个逻辑对象。若 64 MiB 容器有大量 KB 级对象，单一坏 extent、误截断或修复错误的爆炸半径明显扩大。

CRC32 在每个 slot header 中可帮助识别局部内容，但不是密码学校验，也不能替代容器级 scrub 和跨副本修复。

### 5.3 删除与碎片

高 churn 工作负载会产生大小不规则 free slots：

- 相邻 free slot 可配置合并；
- 不相邻空间形成内部碎片；
- allocator 内存/加载时间增长；
- group 物理 free space 与可用 slot 容量可能不一致；
- 删除未使用 trunk file 默认通常关闭，以降低误删风险。

容量监控必须同时看文件系统 free space、trunk free slots、fragmentation、allocator 节点数和新 trunk 创建速率，而不能只看 `df`。

## 6. 不可逆运维约束

官方部署文档明确提示：可以在运行中开启 trunk，但一旦产生 trunk 文件，不要再关闭，否则删除旧文件会有问题。原因是 file ID 和真实文件位置依赖 trunk 解析；把全局开关关闭会让后续逻辑按普通文件路径处理旧对象。

因此开启 trunk 是数据格式迁移，不是普通性能 toggle。正确流程应包括：

1. 固定 FastDFS 和 Nginx module 兼容版本；
2. 备份 tracker/storage/trunk 系统文件和配置；
3. 小规模新 group 先开启，不直接改全量存量组；
4. 验证 upload/download/range/delete/metadata/slave/recovery；
5. 验证 trunk server crash、tracker leader 切换和 binlog 重放；
6. 记录不可回退点；
7. 若要退出，采用逐对象读出并上传到新 group，而不是改回 `false`。

## 7. 容量模型

### 7.1 普通模式

粗略物理成本：

```text
raw = payload rounded to filesystem allocation
    + inode/dentry/xattr/journal
    + N full replicas
```

4 KiB block 文件系统中，几百字节文件也可能消耗一个 block 加 inode；数十亿文件的 inode table 和备份遍历成本很高。

### 7.2 Trunk 模式

粗略物理成本：

```text
raw = sum(payload + 24-byte header + slot slack)
    + trunk container tail/free fragmentation
    + allocator/binlogs
    + N full replicas
```

它显著降低每对象 inode/dentry，但 slot rounding 和 churn 碎片仍可能可观。真实放大取决于对象大小分布，而非平均值。容量 PoC 至少要用 P10/P50/P90/P99 大小和真实删除/覆盖比例生成数据。

### 7.3 Slot max 选择

- 太小：大量中小对象仍成为普通文件，inode 减少有限；
- 太大：大 slot 删除造成更大碎片，容器故障影响更多数据，写放大和恢复竞争增强；
- 1 MiB 只是官方样例建议，不是对所有分布的最优值；
- 64 MiB trunk size 也要结合文件系统 extent、repair 粒度和内存索引测量。

## 8. Nginx 读取

Nginx module 解析逻辑名字和 trunk info，读取指定 offset/length。需要验证：

- Range 请求只返回逻辑对象范围，不能越过 slot；
- header size/CRC/mtime 异常正确失败；
- 本地缺失时 proxy 到另一个 storage，不把整个 trunk 暴露；
- sendfile/directio 配置不会绕过模块边界；
- 缓存 key 包含完整 file ID，删除/重建不会混淆；
- V1.26 与 FastDFS V6.17 协议/格式兼容。

## 9. 监控指标

建议每 group 至少监控：

| 指标 | 目的 |
| --- | --- |
| trunk server ID/active | 协调角色是否稳定 |
| alloc/free/confirm error rate | allocator 健康 |
| trunk binlog lag/size | peer allocator 状态是否追平 |
| container count/create rate | 容量增长和碎片趋势 |
| allocated bytes vs live bytes | 真实空间放大 |
| free slot count/size histogram | 是否出现大量不可利用碎片 |
| delete and merge latency | churn 影响 |
| header/CRC/read errors | 局部损坏 |
| recovery throughput/error | 容器重建能力 |
| create P50/P95/P99 | trunk server 是否成为瓶颈 |

官方 exporter 并未必直接暴露全部 allocator 指标，需要解析日志、扩展 exporter 或离线工具。没有指标就开启 trunk，会把容量异常推迟到上传失败才发现。

## 10. Trunk 故障测试矩阵

1. slot 分配前/后 kill 请求 storage；
2. 内容写完但 confirm 前 kill；
3. confirm 后、sync binlog fsync 前断电；
4. trunk server 与 tracker leader 同时故障；
5. tracker 网络分区时两侧尝试分配；
6. 删除与分配同尺寸 slot 高并发；
7. container 局部字节篡改和 truncate；
8. 单盘恢复只包含部分 trunk/binlog；
9. Nginx range/zero-length/boundary 请求；
10. 多版本 FastDFS 与 Nginx module 滚动升级；
11. 数亿 slot 重启时 allocator 加载时间和内存；
12. 30%/70%/95% 空间利用率下的碎片与 P99。

## 11. 与专用小文件存储的差异

FastDFS trunk 是“本地大文件 + 中央 slot allocator + 完整副本”。现代 append-only volume/object packing 通常还会引入：

- sealed immutable volume；
- 独立 location indirection；
- generation/checksum；
- live-ratio GC 搬迁；
- placement 与物理 offset 解耦；
- seal 后 EC；
- manifest/segment index；
- 容器级 scrub 和 repair。

FastDFS file ID 直接编码 group/path/trunk offset，后续搬迁难以保持 ID 不变；这限制了在线 compaction、跨组 rebalance 和副本→EC 转换。它能缓解经典文件系统 inode 问题，但不等价于为万亿小对象设计的完整 volume layer。

## 12. 结论

trunk 是 FastDFS 最有价值也最需要纪律的扩展。对于稳定、不可变、大小分布集中在 KB—数百 KB 的对象，它能显著降低 inode 和目录元数据成本；对于高删除、高覆盖、要求自动 compaction/EC/跨组迁移的工作负载，它会暴露 allocator、碎片和位置固化问题。

采用决策应以真实对象分布和故障测试为依据，并把“开启不可轻易回退”写入变更审批。若 LightStore 的目标是 10^12—10^13 文件，值得借鉴的是 packing 方向和简洁 header，而不是把 trunk server 与物理 offset 直接固化进长期对象 ID。
