# SeaweedFS Master、Raft 与一致性边界

## 1. 技术总结

SeaweedFS 的 Master 是 volume directory/allocator，而不是文件元数据服务器。多个 Master 通过 Raft 选 leader，所有 assign、volume growth 和主要管理工作由 leader 负责，follower 转发或引导请求。固定 4.41 源码可见的 Raft command 核心是 `MaxVolumeId` 与 `TopologyId`；volume 的 server/rack/DC 位置、大小、只读、collection、EC shard 等由 Volume Server 心跳动态重建。

因此：

- Raft 保护“不要重复分配 volume id”和“不要让两套逻辑集群误接同一拓扑”等控制不变量；
- 它不复制每个 FID、needle、文件路径或每次 volume write；
- leader 故障后的数据可用性主要来自 Volume Server/Filer location cache 与副本；
- leader 切换后的 assign 可用性取决于 topology warm-up 和心跳补齐。

## 2. Raft 中的状态

### 2.1 MaxVolumeId

创建新 volume 前，leader：

1. 读取当前 `GetMaxVolumeId()`；
2. 计算 `next`；
3. 把 `NewMaxVolumeIdCommand(next, topologyId)` 提交 Raft；
4. command apply 后更新每个 peer 的 Topology；
5. 再返回新的 volume id。

Volume Server 心跳发现比当前更大的普通或 EC volume id 时也会向上调整 max id，防止 Master 从软状态重建后复用已存在的 id。4.41 还有针对“只剩 EC shard 的 volume 也必须推进 max id”的测试。

### 2.2 TopologyId

新集群生成 topology id 并通过 Raft snapshot 持久。若同一 Master 运行期收到不同 topology id，源码会以 split-brain 风险 fatal 退出。这是 4.x 的重要保护：

- 防止误把一批 Volume Server 同时接入两个独立 Master 集群；
- 防止恢复时错误复用旧 `mdir`/peer 集；
- 不能替代网络层 fencing，但能暴露明显错配。

### 2.3 不在 Raft 的状态

以下主要是内存/心跳软状态：

- volume id 到 data node location；
- data center、rack、server 层级；
- volume size、file/delete count、read-only/remote 状态；
- collection/replication/TTL/disk type layout；
- EC shard location；
- writable/crowded/full volume 列表；
- volume server capacity、disk tags。

Master 重启无需回放所有文件/volume 写日志，而由 Volume Server full heartbeat 汇报。

## 3. Heartbeat 与拓扑收敛

Volume Server 与 leader 建立长连接，周期性发送：

- 节点地址、dc/rack、disk type/tags；
- volume info；
- EC shard info；
- capacity/usage；
- 增量 add/delete/update。

Master 用 full heartbeat 对比旧状态，注册新增、注销缺失并修复 lookup index。4.41 源码专门处理“data node map 仍有 volume，但 vid2location 丢失”时 full heartbeat 重新注册的自愈。

### 3.1 Leader 切换

官方流程：

1. Raft 选出新 leader；
2. Volume Server 发现并切换 leader；
3. 向新 leader 报告完整 volume 列表；
4. 新 leader 逐步恢复 topology；
5. 未报告/副本不齐的 volume 暂不进入 writable。

`Topology` 记录 leader-change time 和当时是否已有 volume，以若干 heartbeat interval 为 warm-up。这个窗口避免新 leader 仅看到少数副本时误做增长、删除或写分配。

### 3.2 可用性影响

- **已有 FID 读**：若客户端/Filer 已缓存 volume location，可能不依赖即时 Master；cache miss 或 location 变更仍需 Master。
- **新写 assign**：需要 leader 且 layout 已收敛。
- **缺副本 volume**：被移出 writable，新写转向其他完整 volume。
- **后台任务**：应等拓扑稳定，避免在 warm-up/大规模 reconnect 时做修复或删除。

## 4. Volume allocation

可写 layout 的 key 大致由：

```text
collection + replica placement + TTL + disk type
```

Master 只有在以下条件满足时把 volume 放入 writable：

- 实际 location 数等于期望 copy count，或配置把 replication 视为 minimum 且实际更多；
- 所有副本均非 read-only；
- volume 未 oversized；
- volume 未被显式 drain/maintenance/vacuum。

4.41 还跟踪 `effective size = heartbeat reported size + pending assigned bytes`，在硬上限前提前停止 assign，并在后续 heartbeat 显示实际仍有空间时延迟恢复。这个逻辑减少高并发 assign 在 300 ms 心跳间隔内把同一 volume 冲爆。

## 5. Replication placement

三位字符串 `xyz` 表示在原始副本之外：

- `x`：不同 data center 的副本数；
- `y`：同 DC 不同 rack 的副本数；
- `z`：同 rack 不同 volume server 的副本数。

总副本：

```text
N = 1 + x + y + z
```

示例：

| placement | 总副本 | 容忍目标 |
| --- | ---: | --- |
| `000` | 1 | 无冗余 |
| `001` | 2 | 同 rack 不同 Volume Server |
| `010` | 2 | 同 DC 不同 rack |
| `100` | 2 | 不同 DC |
| `110` | 3 | 另一个 rack + 另一个 DC |

关键陷阱：

- 多个 Volume Server 进程在同一物理机上仍被视为不同 server；`001` 不保证跨主机；
- dc/rack 标签错误会让 placement 的形式满足但真实故障域不满足；
- 同 rack 多副本不能防 rack 断电；
- 跨 DC 同步完整副本把 WAN 延迟加入每次写。

## 6. 写一致性

官方 Wiki 用 quorum 公式描述：

```text
W + R > N
SeaweedFS: W=N, R=1
```

在无故障且所有副本写成功时，之后从任一成功副本读取应看到该版本。源码需要补充四个限定。

### 6.1 写顺序不是原子并行提交

入口副本本地成功后才向远端并发转发。不存在 prepare/commit 或 undo log。远端失败时：

- 客户端得到失败；
-入口和部分副本已存在数据；
-后台不会在这个函数中自动删除；
-客户端重试可能生成新 FID。

因此 `W=N` 是“成功响应要求 N 个应用成功”，不是“失败时 N 个都没写”。

### 6.2 Fail-fast 会留下结果不确定

`DistributedOperation` 收到第一个错误即 cancel 其他请求并返回。另一个正在执行的副本可能：

- 收到 cancel 前已提交；
- 服务端用不受客户端 cancel 影响的 context 继续；
-网络响应丢失但数据已写。

失败后的确切副本集合需要 scrub/repair，对客户端不可知。

### 6.3 ACK 与 stable storage

默认不 fsync。即便入口 `fsync=true`，远端 URL 只带 `type=replicate`、TTL、timestamp、chunk-manifest flag，没有 fsync。可推导：

| 层级 | 默认成功 ACK 是否保证 |
| --- | --- |
| 入口进程内写函数成功 | 是 |
| 远端进程内写函数成功 | 成功响应时是 |
| 入口 data backend `Sync()` | 仅 `fsync=true` |
| 所有远端 `Sync()` | 否 |
| index 和 data 同一原子持久点 | 否 |
| 主机断电后 N 副本均保留 | 不能推出 |

### 6.4 删除更弱

`deleteNeedle2` 固定 `fsync=false`，源码带 TODO。删除复制失败也会产生“部分副本 tombstone、部分仍可读”的状态。应用需要考虑 delete retry 和 eventual repair，而不能只套写入的 `W=N` 结论。

## 7. 读一致性

### 7.1 `R=1`

快速读随机/就近选一个 replica，不进行 quorum compare。正常前提是成功写已到全部副本。若存在：

- 失败写残留；
- 失败 delete；
-磁盘/索引损坏；
-运维误复制旧 volume；

不同副本可能返回不同结果。读取本身不会发现“另一个副本更新”。

### 7.2 Location cache

Filer、mount 和其他客户端订阅/缓存 volume location，降低 Master RTT。位置变更后 cache 依赖 generation/update/失效；4.41 Release 专门修复了 vid map cache generation。生产需监控：

- lookup miss；
- stale target retry；
- proxy/redirect 比例；
- volume location cache age；
- Master 切换后错误率。

### 7.3 线性化范围

可以合理声称：

- 单 Volume Server 内同一 volume 的 append/index update 在其锁下串行；
-成功完成的复制写在所有确认的副本上已被应用；
- Master 的 volume id 分配由 Raft 排序。

不能直接声称：

- 整个 Blob namespace 的线性化写；
-失败写没有副作用；
- Filer path 与 chunk 数据原子；
-所有 S3 operations 共享同一全局序列；
-跨 DC active-active 是强一致。

## 8. 网络分区

### 8.1 Master minority

失去多数派的 Master 不能成为有效 leader/提交新 id。Volume Server/Filer 应连接可用 leader。旧 location cache 可能维持一部分读，但新 assign 停止。

### 8.2 Volume 与 Master 分区

Master 会把失联节点/其副本移出 topology。副本数不足的 volume 变 read-only；不立即复制修复，避免节点很快回来时产生额外副本。

如果 Volume Server 的数据端口仍对客户端可达，知道 FID 的客户端可能仍能直读；这会形成“控制面认为离线、数据面仍服务”的可见性差异。

### 8.3 副本间分区

写入口能查到 remote location 但连接失败，整个写报错。已有本地 append 保留。若应用持续重试，可能制造大量垃圾和跨 volume 重复对象。

### 8.4 跨 DC

`100/200` 是同步写扇出，WAN RTT/抖动进入 P99。它提供的是 volume 副本跨 DC placement，不包括：

- Filer Store 跨 DC 的事务；
- S3 gateway owner lock 的跨 DC 一致 authority；
- 自动站点 failover/fencing；
- bucket replication 状态；
- 独立恢复点。

## 9. Repair 与 rebalance

### 9.1 为什么不立即自动 repair

官方理由是瞬时 heartbeat 丢失可能让系统误以为副本永久丢失；立刻复制会造成：

- 不必要的全 volume 网络/磁盘流量；
-节点回来后 over-replication；
- 大规模网络抖动触发 repair storm。

这是合理取舍，但要求：

- 明确 missing replica grace period；
- alert 与自动任务不会永久搁置；
-修复限流；
-在删除 over-replica 前做一致性检查；
-业务知道 degraded volume 新写停顿。

### 9.2 Admin/Worker

当前推荐启动 `weed admin` 与 `weed worker`。默认 admin script 每 17 分钟包含：

- `ec.balance -apply`；
- `fs.log.purge -daysAgo=7`；
- `volume.deleteEmpty -quietFor=24h -apply`；
- `volume.fix.replication -apply`；
- `s3.clean.uploads -timeAgo=24h`。

EC encoding 和 volume balance 已有专门 plugin。旧 `master.toml` maintenance 在连接 Admin 时跳过。升级时必须避免两套 scheduler 同时执行。

## 10. 故障时序表

| 故障点 | 客户端结果 | 可能持久状态 | 恢复动作 |
| --- | --- | --- | --- |
| Raft commit volume id 前 leader 崩 | assign 失败 | id 未提交/不应使用 | 新 leader 重试 |
| Raft commit 后响应前崩 | assign 不确定 | id 已消耗但无数据 | 空洞可接受，不应复用 |
| primary append 前崩 | 失败 | 无 needle | 重新 assign |
| primary append 后、replica 前崩 | 失败/断连 | primary 残留 | fsck/GC/Vacuum |
| 部分 replica success | 500 | 部分副本残留 | repair/scrub；应用幂等 |
| success ACK 后 primary 掉电 | 成功 | 取决于 page cache/fsync；remote 同样不保证 fsync | 断电测试、读其他副本 |
| delete 部分成功 | 500 | 部分已 tombstone | 重试 delete/repair |
| leader 切换 | 短暂 assign 失败 | data 不变，topology 重建 | 等 heartbeat warm-up |

## 11. 监控建议

至少告警：

- Raft leader/peer count、leader changes、apply/snapshot error；
- topology warm-up 时间、volume server heartbeat age；
- writable volume count、crowded/full/readonly；
- actual vs desired replica count；
- write replication failure by timeout/refused/server error；
- assign retry/reassign、partial write cleanup；
- volume location lookup/cache miss；
- repair queue age/bytes、balance queue、over-replica pending delete；
- topology id mismatch/fatal。

## 12. 小结

Master Raft 让 volume id 和集群身份有单一序列，但 SeaweedFS 的数据一致性不由 Raft 统管。理解系统时应画三张状态机：Master allocation、Volume replication、Filer metadata。热复制的成功响应需要全副本应用，但失败非原子、fsync 不传播、读只取一副本；这正是生产 SLA 和 PoC 故障注入必须覆盖的核心。
