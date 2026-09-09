# SeaweedFS 复制、纠删码与数据完整性

## 1. 技术总结

SeaweedFS 使用两种不同生命周期的数据保护：

- **正常可写 volume**：拓扑感知完整副本，写成功要求全部当前副本成功；空间成本为 N×；
- **温冷封存 volume**：OSS 固定 Reed-Solomon `10 data + 4 parity`，空间约 1.4×，可容忍最多 4 个 shard 丢失。

EC 不是在每次小对象写上实时编码，而是把 quiet/sealed volume 异步转换。它降低冷数据容量成本，但不支持更新、删除只记 journal、正常读通常多一个 hop、丢 shard 后重建以整个 volume 为单位。`.ecsum` 修补了 parity bitrot 在重建时静默污染的风险，但只有调度 scrub 才能持续发现。

## 2. 完整副本

### 2.1 Placement

`xyz` 总副本为 `1+x+y+z`，按 DC/rack/server 分层选择。选择发生在创建/增长 volume 时，同一个 volume 的所有 needle 继承相同 placement。

优势：

-每次对象不需要存 placement metadata；
-恢复/搬迁顺序复制 volume；
-读任一副本；
-对小文件无单独复制 RPC 元数据。

限制：

-不能给同 volume 内某个重要对象更高副本；
-改变 replication 需要配置 volume 后运行修复；
-错误故障域标签影响整 volume；
-完整副本容量成本高。

### 2.2 同步写

入口 Volume Server 先本地写，再并发转发全部远端，任一失败返回错误。成功响应表示所有远端 write handler 都返回成功，不表示全部 fsync。

### 2.3 Degraded

Master 发现实际副本数不满足 placement 时将 volume 移出 writable；旧数据仍可从幸存副本读。不会立刻自动 repair，避免 transient disconnect 触发 storm。

业务容量规划要保留足够“新 writable volume”余量，否则大量副本失联时旧 volume 全只读，新写可能因 free slots/disk不足失败。

## 3. Replication repair

`volume.fix.replication`：

-扫描 under/over/misplaced volume；
-选健康源与符合 placement 的目标；
-复制完整 volume；
-校验/同步；
-4.41 改进为先放置新副本，再删除 misplaced 副本；
-可 `-doDelete=false` 只补不删；
-可限制 parallelism/per-server；
-对 over-replica 删除前可 check。

### 3.1 Repair 风险

-复制大 volume 占源盘顺序读、目标盘写、网络；
-多个盘同批故障时幸存盘压力上升；
-源副本本身可能静默损坏；
-修复期间新的 write/delete 需要 tail/sync；
-目标选择若物理 host 标签错误仍不安全；
-过早删除多余副本会降低安全裕度。

### 3.2 Repair SLO

建议定义：

```text
MTTD = heartbeat/alert detect time
queue wait = repair scheduler backlog
copy time ≈ volume physical bytes / min(source read, network, target write)
verification/tail time = delta + checksum/index
MTTR = MTTD + queue wait + copy + verify
```

保证 `MTTR < 可接受的第二故障暴露窗口`，并在全盘故障数倍并发时重新计算。

## 4. RS(10,4) EC

### 4.1 容量与容错

OSS 默认：

```text
k = 10 data shards
m = 4 parity shards
total = 14
storage overhead = (10+4)/10 = 1.4x
max missing shards = 4
```

“容忍 4 个 shard”不等于无条件容忍 4 个 server/rack：

-14 shard 必须分散；
-一个 server 可能持多个 shard；
-若一个故障域持 5 shard，单故障即不可恢复；
-同时存在 corrupt shard 时也消耗 parity budget。

### 4.2 Layout

约 30 GB volume：

-按连续 1 GB data block 组织；
-每 10 个 data block 生成 4 个 parity block；
-最终 14 shard，每 shard 约 3 GB；
-小 volume/边缘使用 1 MiB block。

这种布局让多数小 needle 落在一个 data block/shard，正常读无需读取 10 个 shard；跨 block needle 是边缘情况。

### 4.3 Encoding lifecycle

当前推荐 `erasure_coding` Admin plugin：

-默认启用；
-扫描间隔约 5 分钟；
-默认 fullness 0.8；
-quiet 300 秒；
-min size 30 MB；
-可 collection filter。

流程：

1. 选择 quiet normal volume；
2. 从一份正常副本 encode 14 shard；
3. 分发 shard/`.ecx/.ecsum`；
4.确认 shard 数量与位置；
5.成功后清理所有原 normal replicas；
6. collection 后续新写仍进 normal volume。

4.41 修复 encode 后按实际落点统计 shard、删除源前报告缺 shard 等问题；这正说明“删除 originals”必须有严格门槛和审计。

## 5. EC 读

### 5.1 健康

客户端选一个持 shard 的 server A。A 查 `.ecx` 确定 needle offset/size 和 shard，若数据在 B 则向 B 请求。相比正常 volume：

-多一次 A->B hop；
-A 负责 index/路由；
-网络和 CPU 成本更高；
-A/B load distribution 取决于选择。

### 5.2 缺 shard

A 从至少 10 个可用 shard 读取对应条带，用 RS reconstruct 请求范围。只重建请求数据可维持可用，但：

-tail latency 显著上升；
-每个 read 放大网络；
-多并发读可能形成 reconstruction storm；
-应尽快 whole-shard repair。

### 5.3 官方 benchmark

官方 Wiki 的单组测试：

| 场景 | 请求数/并发 | 约 req/s |
| --- | --- | ---: |
| normal volume | 102,040 / 16 | 31,435.64 |
| healthy EC | 同上 | 13,966.69 |
| EC with one of four servers down | 同上 | 9,152.52 |

这是同一测试中健康 EC 约为 normal 44%，故障 EC 约为 normal 29%。但文档缺少完整 CPU、盘、网络、对象分布、版本和运行环境，不可外推为通用比率。它只可靠地说明额外 hop/重建会显著降速。

## 6. EC 更新、删除与压缩

### 6.1 Update

EC volume 不支持 update。需要修改的 workload 不应过早 encode；若必须改变，先 decode 回 normal volume。

### 6.2 Delete

删除 needle id 持久追加到 `.ecj`，内存 set 加速 read masking。4.41 的实现顺序强调 journal durable 后才发布到内存，partial write 会 truncate。

逻辑删除不改 shard data，容量不收回。

### 6.3 Compaction

普通开源路径要求：

```text
EC shards -> decode normal volume -> normal vacuum/compact -> re-encode
```

这需要大量临时空间、网络与时间。频繁 delete 的 collection 可能不适合早期 EC。

## 7. EC balance

`ec.balance`：

1. 删除同 volume/server 的 duplicate shard；
2. 跨 rack 平衡；
3. rack 内跨 server/disk 平衡；
4.按 capacity 与已有 shard 数选目标；
5.考虑 Master replica placement。

生产不仅看全局 shard 数，还要按每个 EC volume检查：

-14 shard 是否齐；
-每 server/rack/DC 数；
-物理 disk id；
-同时失效故障域能丢几 shard；
-目标 capacity；
-最近 move/repair；
-`.ecsum` 是否存在且一致。

## 8. Bitrot

### 8.1 Needle CRC 的盲点

正常读取 needle 会验证 data CRC，但：

-冷数据没被读就不发现；
-parity shard 正常服务从不读；
-padding/未访问范围可能不覆盖；
-RS 把“存在的 shard”当正确输入，无法自行识别错误。

最危险情况：

1. parity shard 静默腐坏数月；
2. data shard 真丢失；
3. rebuild 使用坏 parity；
4.生成错误 data；
5.若不再有端到端 checksum，错误被发布。

### 8.2 `.ecsum`

4.41 默认 `-ec.bitrotChecksum=true`，每 shard 默认每 16 MiB 计算 CRC32C，sidecar 带自身 magic/version/length/payload CRC。

约 30 GB volume sidecar约 11 KB。特性：

-encode 时一次 pass 生成；
-随 shard 分发；
-absent 表示 feature off，兼容旧 volume；
-malformed sidecar rebuild fail-close；
-可 `-unsafeIgnoreSidecar` 强制绕过，必须视为 break-glass；
-旧 volume rebuild 可 trust-on-first-use 生成 sidecar。

### 8.3 `ec.scrub -mode checksum`

读取本地 shard 全部 block 比较 checksum；发现 mismatch 时用其他 clean shard reconstruct 仲裁，避免 stale sidecar误报。scrub 只读，不自动删除。

OSS 需要运营方调度。Enterprise 宣称有定时 scrub/auto-repair/backfill/versioned EC vacuum，但本文未审计私有实现。

## 9. 普通 volume scrub

needle CRC、`volume.fsck`、index checking 和 Volume Scrub 共同覆盖普通副本。正确流程应：

-全量轮巡冷 volume；
-从多个副本交叉比对；
-坏副本 quarantine/read-only；
-先复制健康副本，再删除坏副本；
-保留 bad needle/shard 清单；
-统计无法读取 bytes；
-将 scrub 周期纳入潜伏故障概率。

不能依赖用户恰好读取来发现 bitrot。

## 10. 故障矩阵

| 故障 | 完整副本 | EC |
| --- | --- | --- |
| 单 disk/node 丢失 | 其余副本读；volume readonly直到 repair | 只要丢 shard ≤4 可读/重建 |
| rack 丢失 | 取决于 `010` 等 placement | 取决于每 volume shard rack分布 |
| DC 丢失 | 取决于 `100/200` | 默认 EC balance 不自动等价跨 DC DR |
| 静默 needle bitrot | 读取 CRC 发现；可读其他副本 | data read 可发现，冷 parity需 `.ecsum/scrub` |
| 部分写 | 可副本分歧；`R=1` 不比较 | 活跃 volume 尚未 EC |
| 删除 | tombstone复制可部分失败 | `.ecj`；容量不回收 |
| 修复源损坏 | 可能复制坏数据，需 scrub | `.ecsum` 可排除 corrupt input |
| 5 shards 同失效 | N 副本模式看副本数 | RS(10,4) 不可恢复 |

## 11. 容量公式

### Hot

```text
raw ≈ logical_live / target_fill
      × copy_count
      × (1 + garbage_headroom + metadata/index overhead)
```

### EC

```text
raw ≈ logical_live / target_fill
      × 1.4
      × (1 + delete_journal/temporary/rebuild headroom)
```

### Mixed

```text
raw_total ≈ hot_logical × N
          + warm_logical × 1.4
          + vacuum temporary space
          + EC encode/decode/rebuild temporary space
          + Filer Store/log/backup
```

注意 transition 窗口可能同时存在 originals、14 shard 和 temp files，瞬时容量高于稳态。

## 12. 生产策略

建议：

-热数据至少 `010` 或真实跨 host 的 `001`，标签用物理故障域自动校验；
-跨 DC placement 只在 latency/SLA 允许时使用；
-repair 延迟加 grace，但 backlog 必须有 SLO；
-默认 repair 先 add 后 delete，故障期间 `-doDelete=false`；
-quiet、不可变、删除率低的 volume 才 EC；
-EC encode 后检查 14 shard、分散度、`.ecsum`，再删 originals；
-每天/每周按容量完成 `ec.scrub` 轮巡，不只抽样；
-scrub error先 quarantine，禁止用 `unsafeIgnoreSidecar` 自动继续；
-恢复演练同时覆盖丢 1/4 shard 与一个 corrupt parity；
-为 repair/EC/Vacuum 独立限流并预留磁盘。

## 13. PoC

1. placement 在实际 Kubernetes/裸机标签下是否跨物理 host；
2.断一台 Volume Server，volume 多久 readonly、多久 repair；
3.节点 5 分钟后回来是否出现 over-replica；
4. repair 中持续前台读；
5. primary/remote partial write 后 `R=1` 读差异；
6. EC encode 中 worker/master/volume kill；
7. encode shard 不齐时是否保留 originals；
8.丢 4 shard可读，丢 5 shard明确失败；
9.篡改 parity block，`ec.scrub` 和 rebuild fail-close；
10. malformed/absent `.ecsum`；
11. decode/vacuum/re-encode 的空间峰值；
12.全盘故障多 volume 并发 MTTR。

## 14. 小结

SeaweedFS 的完整副本适合热数据低延迟读，RS(10,4) 适合温冷 sealed volume。两者是生命周期分层，不是实时双重保护。可靠性取决于 placement 的物理真实性、显式 repair、EC balance、定期 scrub 和足够临时空间；单看“2 副本”或“可丢 4 shard”无法得到耐久性结论。
