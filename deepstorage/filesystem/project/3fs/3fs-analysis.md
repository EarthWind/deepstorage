# 3FS 技术评估、LightStore 映射与建议

## 1. 综合判断

3FS 是一套针对 AI/HPC 全闪存集群做深度软硬件协同的分布式文件系统。它的关键创新组合是：

- FDB 事务元数据 + 无状态 Meta；
- 客户端可计算 chunk 布局；
- RDMA 拉取式数据传输；
- CRAQ 风格的任意 clean replica 读；
- chain version fencing；
- FUSE 兼容入口 + USRBIO 高性能入口；
- 显式 target 状态机和在线 full-chunk recovery。

它不是一套面向所有存储层级的完整产品。公开基线最明显的空白是 EC、稳定 release、通用安全加密、native snapshot、quota、完整 ACL/locking、跨集群灾备和正式滚动兼容矩阵。

## 2. 优势

### 2.1 数据面短且可横向扩展

open 后不再经过 Meta，避免中心 metadata server 按数据字节扩容。读可从 chain 多个 clean replica 分散，适合大量训练节点并发读相同数据集。

### 2.2 元数据事务语义复用成熟系统

FDB 让 create/link/unlink/rename 有清晰的 ACID 基础，也让 Meta 真正无状态。相比自研跨分片事务，工程复杂度显著降低。

### 2.3 故障状态具体

serving/syncing/waiting/lastsrv/offline 不是抽象“健康/不健康”二值状态。syncing 接收线上 full-chunk replacement 并与后台扫描并行，使恢复能够追赶活跃写。

### 2.4 性能工程完整

3FS 没有停在“支持 RDMA”口号上，而是提供注册内存、异步 ring、批处理、Client 计算布局、local engine COW、placement solver 和指标。这些设计彼此配合，形成高聚合吞吐。

### 2.5 形式化验证意识

P 模型对 CRAQ/RDMA 不变量进行调度探索，有助于发现版本、消息重排和故障状态机错误。最新 chain table version 修复也说明团队持续围绕正确性迭代。

## 3. 主要风险

### 3.1 容量成本

三副本意味着约 3 倍原始数据，叠加 COW、GC 和恢复预留。对全闪存尤为昂贵。公开路径无可验证 EC，使 3FS 不适合直接承担成本敏感的 EiB 冷温数据。

### 3.2 写尾延迟

写必须穿越整条 chain，慢尾/慢盘/RDMA congestion 进入请求完成时间。同 chunk 写在 head 串行，随机覆盖热点无法靠增加 replica 扩展。

### 3.3 外部依赖集中

FDB 简化了元数据代码，却增加一个必须专业运营的全局系统。namespace、MgmtD lease、配置、session、GC queue 都依赖它。FDB 与 Storage 的跨系统灾备一致性仍待采用方解决。

### 3.4 网络假设强

官方规模来自专门设计的 IB 网络和软硬件协同。共享 RoCE 上的 PFC/ECN/DCQCN、incast 和 collective 流量可能让尾延迟与故障相关性远高于实验环境。

### 3.5 产品成熟度

截至调研基线：

- 无 Git tag；
- 无 GitHub Release；
- 主分支持续修复正确性/超时问题；
- 构建 shuffle 方法影响数据定位；
- 新旧 chunk engine 并存；
- 公开升级/回滚兼容矩阵不足。

这要求使用方把开源主分支当作需要自行产品化的源码，而非直接消费的稳定发行。

### 3.6 语义与安全

POSIX 只是“基础兼容”，不是完整。动态 length、多 chunk 非原子、read-only fd、xattr/lock/quota/snapshot 都可能影响应用。默认认证关闭且数据面未见公开传输加密，可信网络是隐含前提。

## 4. 适用性评分

评分：5 为非常适合，1 为明显不适合。

| 场景 | 分数 | 理由 |
| --- | ---: | --- |
| 大规模训练数据顺序/并行读 | 5 | RDMA、客户端直达、CRAQ 读扩展 |
| 模型权重并发加载 | 5 | clean replica 分摊热点 |
| Checkpoint 多文件写 | 4 | chain 写 + rename 发布；三副本成本 |
| KV Cache | 3–4 | 官方有实现/结果，但需按小块、P99 和 relaxed 语义验证 |
| HPC scratch | 4 | 高吞吐，语义和生命周期较匹配 |
| 大量小文件 | 2 | 每文件/每 chunk 元数据和分配放大 |
| 随机覆盖热点文件 | 2 | chunk 锁、COW、chain tail |
| 通用企业共享文件 | 2 | ACL/xattr/lock/quota/snapshot 产品面不足 |
| 多租户不可信网络 | 1–2 | 默认安全边界不足 |
| 跨地域灾备文件系统 | 1 | 无公开统一数据 DR |
| 低成本冷数据 | 1 | 无实际 EC、全闪存三副本 |
| 自建团队较弱 | 1–2 | FDB/RDMA/多组件和源码发布运维重 |

## 5. 与 LightStore 的架构对比

基于当前仓库文档，LightStore 的目标更偏向：

- 10^12—10^13 文件；
- EiB 级；
- Range Raft 元数据；
- append-only volume；
- 小文件 packing；
- replica + RS(12,4) EC；
- SDK-first、主动收缩 POSIX；
- Loc 间接寻址和 volume repair/GC。

| 维度 | 3FS | LightStore 方向 | 判断 |
| --- | --- | --- | --- |
| API | FUSE POSIX 风格 + USRBIO | SDK-first | LightStore 更易收缩语义 |
| 元数据 | FDB + stateless Meta | Range Raft 自管分片 | 前者开发快，后者控制力/自治强 |
| 数据单元 | 每文件固定 chunk | append-only packed record/volume | LightStore 更适合小文件 |
| 寻址 | inode + chunk index 直接算 chain | object/file -> Loc -> volume offset | Loc 更利于迁移/EC/GC |
| 复制 | chain full replication | 副本与 EC 分层 | LightStore 容量效率目标更强 |
| 写入 | random overwrite + COW | append-only | 3FS 语义更宽，LightStore 状态更简单 |
| 读 | clean replica 任意读 | 按 Loc/placement 直读 | 都避免 metadata 数据代理 |
| 恢复 | target chunk scan + full copy | volume repair/EC rebuild | volume 粒度更利于顺序恢复 |
| 元数据事务 | FDB 全局事务 | Raft range 内事务/跨 range 需设计 | 3FS rename/link 更直接 |
| 扩容 | 新 chain table/布局 | range/volume placement | 都需 version fencing |
| 小文件 | 无显式 packing 核心 | packing 是核心 | 不宜照搬 3FS chunk 分配 |
| 安全 | 可信 RDMA fabric 假设 | 可设计 SDK auth/encryption | LightStore 应尽早内建 |

## 6. LightStore 值得借鉴

### 6.1 单调 Route/Chain Version

所有 Client 和 Storage 数据请求携带布局 version，旧 version 明确失败并刷新。LightStore 的 placement epoch/volume generation 应满足：

- 只增不减；
- leader 切换不回退；
- 快照/恢复后不复用；
- 服务端强校验；
- Client bounded cache；
- 回包携带最小新 version 提示。

3FS 最新提交修复 version 单调性，说明应把此性质写成不变量并故障注入，而非普通字段。

### 6.2 显式 Target 状态机

LightStore 可借鉴：

```text
SERVING -> WAITING/OFFLINE -> SYNCING -> SERVING
                    \
                     LAST_KNOWN_GOOD
```

每个状态明确：

- 是否接收新写；
- 是否提供读；
- 是否作为恢复源；
- 是否可被 placement 选择；
- 进入/退出的 version barrier。

### 6.3 Recovery 与前台写合流

返回目标先接收线上 full replacement，再扫描旧数据，解决扫描期间持续变化问题。LightStore 在 volume repair 中可采用：

- repair snapshot/cursor；
- repair delta log 或新写直接双投；
- copy 与 live write 统一 generation；
- sync-done barrier；
- 限速和前台 SLO 联动。

对 EC，full replacement 要扩展为 stripe generation、data/parity 一致提交。

### 6.4 元数据键/ID 热点规避

3FS 的 little-endian inode key、4096 ID block、32 allocator shard、create 不更新父 inode 都值得借鉴：

- 顺序逻辑 ID 不等于顺序 KV key；
- ID 预分配减少共识写；
- 不把目录 mtime/child count 设为每 create 的强同步热点；
- 热目录按 key range/名称自然分散。

LightStore 需结合 Range Raft 的 split key 设计，避免所有新 ID 落在最后一个 range。

### 6.5 USRBIO Ring

LightStore SDK 可采用：

- registered/pinned buffer pool；
- 多 ring/queue；
- batch submit；
- completion 带 user data；
- explicit queue depth/backpressure；
- per-NUMA shard；
- read/write ring 隔离；
- 取消/超时/重试语义。

应比 3FS 更进一步，把 native SDK 作为一等接口，不依赖 FUSE fd 桥接。

### 6.6 P 形式化模型

优先建模：

- metadata Range Raft leader change；
- placement epoch；
- replica write/commit；
- EC stripe update/rebuild；
- volume seal/GC；
- Loc CAS；
- recovery 中二次故障。

模型不替代实现测试，但能明确不变量和消息调度。

### 6.7 Balanced Placement

3FS 用组合设计均衡 pairwise failure/recovery load。LightStore 的 replica/EC placement 不应只做容量 round-robin，应优化：

- failure-domain diversity；
- pairwise/cohort 共现次数；
- degraded read fan-in；
- rebuild source/target 网络；
- rack uplink；
- head/leader 角色。

## 7. LightStore 不宜照搬

### 7.1 全量三副本作为唯一保护

EiB 目标下全量三副本成本难接受。建议保持：

- 热数据/写缓冲用副本；
- sealed volume 后转 RS(12,4) 等 EC；
- repair/GC 明确处理 replica→EC 状态迁移；
- 元数据记录 encoding generation。

### 7.2 每小文件一个独立 Chunk

万亿文件若每文件形成独立 Storage chunk metadata 和最小 block，会造成数量与容量双放大。LightStore 应坚持 packing：

- 多小对象写入 append-only volume；
- Loc 记录 offset/length/checksum；
- seal 后顺序 EC；
- GC 按 live ratio 搬迁。

### 7.3 完整 POSIX

hardlink、rename、open-unlink、锁、xattr、mmap、并发 length 会显著扩大状态机。SDK-first 可明确只支持：

- Put/Get/Delete；
- immutable or append；
- conditional metadata update；
- manifest/atomic pointer swap；
- list with snapshot token。

需要 POSIX 时另做网关并明确弱化边界。

### 7.4 把全局元数据交给单一外部 FDB

FDB 方案适合快速获得全局事务，但 LightStore 若核心目标是 Range Raft、EiB 元数据自治，就不应同时引入另一个权威全局数据库。可以借鉴事务思想，不必复制依赖：

- range 内线性事务；
- 跨 range 用受限协议/避免语义；
- config/placement 独立 consensus；
- session/GC queue 分片。

### 7.5 依赖可信 RDMA 网络

LightStore 若服务更广泛环境，应把：

- TLS/mTLS；
- key rotation；
- tenant authorization；
- checksum/authenticated encryption；
- TCP/QUIC fallback；
- rate limit/QoS

作为协议一等属性。RDMA 可做优化而非安全模型基础。

## 8. 设计风险登记

| 风险 | 概率 | 影响 | 触发信号 | 缓解 |
| --- | --- | --- | --- | --- |
| 无稳定 release 导致回归 | 高 | 高 | 主分支频繁正确性修复 | 固定 fork/SHA、回归、canary |
| chain version 回退 | 中 | 极高 | stale route、提交冲突 | 单调不变量、P 模型、持久 epoch |
| RoCE 拥塞放大 P99 | 高 | 高 | PFC/ECN/CQ timeout | 隔离 fabric、调参、压力注入 |
| 三副本成本超预算 | 高 | 高 | usable/raw 低、盘扩容快 | 明确 TCO；不适合则选 EC 系统 |
| 小文件 metadata/空间放大 | 高 | 高 | create P99、chunk count、碎片 | 上层打包或改变系统 |
| FDB 故障影响全局 namespace | 中 | 极高 | transaction retry/recovery | 独立 HA/backup/DR/演练 |
| 数据与元数据灾备不一致 | 中 | 极高 | restore 后 orphan/missing | manifest、双层备份、对账 |
| recovery 拖垮前台 | 高 | 高 | P99、源盘 100%、ETA 上升 | 限速、优先级、分批 |
| 安全默认值误用 | 中 | 极高 | auth=false、共享网络 | 安全基线、自动阻断上线 |
| POSIX 语义不兼容 | 中 | 中高 | syscall ENOTSUP、应用异常 | trace + compatibility suite |
| 新旧引擎/格式不兼容 | 中 | 高 | upgrade/rollback fail | 格式矩阵、离线迁移、备份 |
| checksum 未端到端开启 | 中 | 高 | latent corruption | 强制配置、scrub、repair |

## 9. 采用决策

### 9.1 可以进入 PoC

同时满足：

- AI/HPC 大块读是主负载；
- 已有 IB 或可控 RoCE；
- 全闪存、三副本预算可接受；
- 有 FDB/RDMA/存储工程团队；
- 应用可采用 USRBIO；
- 单数据中心 HA 是主要目标；
- 可自行维护固定源码发行。

### 9.2 需要附加条件

- 小文件：先用容器文件/packing 改造；
- Checkpoint：采用临时文件 + fsync/close + rename + manifest；
- 多租户：补齐 auth、网络隔离、加密和审计；
- 灾备：增加跨系统数据复制和恢复验证；
- RoCE 共网：先通过 incast/collective/recovery 混合压测；
- 生产升级：至少完成 N/N+1 矩阵和回滚。

### 9.3 建议停止评估

若核心要求是：

- 原生 EC 和低容量成本；
- 跨地域强灾备；
- 完整 POSIX/ACL/lock/quota/snapshot；
- 默认端到端加密与成熟多租户；
- vendor-grade release/SLA；
- 无 RDMA/FDB 运维能力。

继续 PoC 的机会成本可能高于选择其他系统。

## 10. 建议 PoC 阶段

### 阶段 0：证据冻结

- fork 固定 SHA；
- 生成 SBOM；
- 冻结 shuffle method；
- 记录所有 default diff；
- 建立 issue/commit watch。

### 阶段 1：功能与语义

- 部署最小 HA FDB/MgmtD/Meta/Storage；
- 跑 namespace/POSIX compatibility；
- 验证 USRBIO 生命周期；
- 验证 auth；
- 用 manifest 做数据校验。

### 阶段 2：性能

- 目标应用 trace；
- FUSE/USRBIO；
- 单节点→多节点 scaling；
- metadata hot directory；
- write/fsync/close；
- 资源/TCO 模型。

### 阶段 3：故障

- chain head/middle/tail；
- 节点/盘/RNIC；
- MgmtD/FDB；
- 分区、时钟、磁盘满；
- recovery 中再次故障；
- checksum corruption。

### 阶段 4：运维

- 72h soak；
- GC/trash；
- 扩容/缩容；
- backup/restore/DR；
- upgrade/rollback；
- on-call runbook。

### 阶段 5：决策

以业务指标评审：

- GPU idle/step time；
- Checkpoint deadline；
- P99/P999；
- recovery SLO；
- 每有效 TiB TCO；
- 人力与升级风险；
- 安全/合规差距。

## 11. 推荐下一步

### 对 3FS 选型

1. 建一个 5—8 Storage 节点、独立 FDB/MgmtD/Meta 的非混部 PoC。
2. 固定 `22fca045` 或重新审核的新 SHA，不跟随 main 自动升级。
3. 先跑应用 trace 和故障测试，再做峰值 benchmark。
4. 把 EC、snapshot、quota、TLS、ACL、rolling upgrade 视为缺口，不以 roadmap 抵消。
5. 计算三副本全闪存的三年 TCO，并与 Ceph/对象存储/并行文件系统对比。

### 对 LightStore

1. 将 placement epoch 单调性和 target 状态机写成正式规范。
2. 为 replica/EC recovery 建 P/TLA+ 类模型。
3. SDK 采用多 ring、批量、注册 buffer 和明确 completion 语义。
4. 保持小文件 packing、append-only volume 和 sealed 后 EC。
5. 设计 manifest/atomic pointer swap 替代全 POSIX rename/link 复杂度。
6. 从第一版加入 mTLS、tenant token、审计、checksum 和灾备 manifest。
7. 建立 recovery/GC 对前台 SLO 的资源控制。

## 12. 尚待回答的问题

在投入生产前，应向维护者或通过源码/PoC回答：

1. 哪个 commit 被实际生产使用，是否有内部稳定分支和安全修复策略？
2. N/N+1 各组件协议、FDB schema、磁盘格式的兼容矩阵是什么？
3. 默认强读的完整线性化点和 pending retry 上限是什么？
4. ACK 后在不同 SSD PLP/flush 配置下的断电持久保证是什么？
5. 新 Rust chunk engine 的生产状态、迁移/回退方案是什么？
6. 是否有端到端 scrub 与自动从健康副本 repair 的正式 runbook？
7. 如何获得 FDB 与 Storage 一致的灾备恢复点？
8. read-only fd 在 unlink、mount 重启和 GC 下的精确语义是什么？
9. checksum 在每条读、写、恢复路径的默认开关和覆盖范围是什么？
10. 认证 token 的随机强度、轮换、撤销和 transport protection 路线是什么？
11. RoCE 推荐的 PFC/ECN/DCQCN 参数和共网隔离要求是什么？
12. 生产 6.6 TiB/s 测试的 block size、配置、P99 和 write/degraded 结果是什么？
13. EC 是否有明确的已实现分支或仅为放置脚本预留？
14. quota、native snapshot、ACL/locking 是否明确不在目标范围？
15. chain table 增长、旧 table 生命周期和扩缩容迁移的正式流程是什么？

## 13. 最终结论

3FS 值得作为“AI 全闪存 RDMA 数据面”的高性能候选，而不应作为“通用、低成本、成熟分布式文件系统”的默认候选。对与其假设一致的训练集群，它的架构上限和工程设计很有吸引力；对 EiB 小文件、EC 成本、安全多租户和跨域灾备，LightStore 当前方向更匹配。

技术上应学习 3FS 对数据路径、状态机、version fencing 和形式化模型的重视，同时保留 LightStore 的 append-only packing、Loc 间接层、Range Raft 和副本转 EC。这种选择比复制一个完整 3FS 架构更符合 LightStore 的规模与成本目标。
