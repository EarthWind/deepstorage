# SeaweedFS 删除回收、Vacuum、TTL 与分层存储

## 1. 技术总结

SeaweedFS 的 append-only volume 让写入简单，却把覆盖/删除空间变成 garbage。普通删除追加 tombstone，旧版本和被覆盖 chunk 仍在 `.dat`；默认垃圾比达到 0.3 后可 Vacuum。Vacuum 对一个 replication group 先 drain 可写状态，再在符合条件的副本上生成 compact 文件，全部 compact 成功后逐副本 commit，失败则 cleanup。

TTL、S3 Lifecycle、EC delete、Cloud Tier compaction 是四套不同层次的生命周期机制：

- TTL：needle/volume/path storage rule 的到期；
- S3 Lifecycle：理解版本、delete marker、multipart 和 condition 的对象级后台动作；
- EC delete：`.ecj` 中屏蔽 id；
- Vacuum/Tier compact：物理回收。

生产必须把“逻辑不可见”和“物理字节释放”分开监控。

## 2. Garbage 来源

正常 volume 中垃圾包括：

-同 FID 覆盖产生的旧 needle；
-Filer offset write 覆盖的旧 chunk；
-文件/对象删除 tombstone；
-S3 version/lifecycle 删除；
-Multipart/manifest 中被替代 chunk；
-复制失败和重新 assign 的未引用 needle；
-Filer metadata commit 失败而 cleanup 未完成的 chunk；
-TTL 已过期数据；
-不再引用的 metadata log chunk。

`.dat` 是 append-only，`rm`/unlink 不会 hole-punch 单 needle。逻辑 size、live size、physical size 会长期分离。

## 3. Garbage ratio

Volume Server 根据 file count、delete count、live size/garbage 计算 Vacuum check 响应。Master 默认：

- `garbageThreshold=0.3`；
- `maxParallelVacuumPerServer=1`。

Shell `volume.vacuum` 默认阈值也是 0.3。阈值越低：

-回收更及时；
-写放大更大；
-后台 I/O 更频繁。

阈值越高：

-物理空间浪费；
-满盘风险上升；
-Vacuum 一次搬运更多 live bytes 但频率低。

应按 overwrite/delete rate、free space 和维护带宽选择，不照搬 0.3。

## 4. Vacuum 协调流程

### 4.1 Check

Master 对所有副本并行调用 `VacuumVolumeCheck`：

-返回 garbage ratio；
-任何 RPC error 会让整组检查不通过；
-只对超过 threshold 的副本建立 vacuum list；
-超时与 volume size 相关。

### 4.2 Drain

`DrainAndRemoveFromWritable(vid)` 先阻止新 assign，避免 compact 期间继续接收大量新写。已持有 FID 的写和 tail delta 仍需实现正确处理，不能只靠 Master list。

### 4.3 Compact

对目标副本并行调用 streaming `VacuumVolumeCompact`，读取旧 index/data，把 live needle 复制到 `.cpd/.cpx`，受 compaction throttler 限制。

Master 按 server quota 控制同时 compact 数；全局 executor 也有限制。正常生产默认每 Volume Server 1 个，避免机械盘 seek/带宽饱和。

### 4.4 Commit

所有 compact 成功后，对 vacuum 副本逐一 commit：

-切换 data/index；
-报告 read-only 和新 volume size；
-更新 layout；
-记录 last vacuum time。

如果并非所有 location 都实际 Vacuum，还会查询其他副本状态；无法确定就把 volume 视为 read-only。

### 4.5 Cleanup

compact 阶段任何失败，调用 `VacuumVolumeCleanup` 删除临时文件。commit partial failure 的处理更复杂：有的副本可能已切换、有的未切换，后续需要状态检查/repair，不能假定全组原子。

## 5. Vacuum crash consistency

4.41 使用临时文件和 compaction commit marker，源码也包含针对 rename/旧 index 残留的防护。仍需覆盖：

-生成 `.cpd` 中进程 crash；
-data compact 完、index未完；
-commit marker 写前/后；
-data rename 成功、index rename 失败；
-一个副本 commit 成功、另一个失败；
-Master leader切换；
-磁盘在临时空间峰值时写满；
-遇到 unreadable needle。

4.41 compaction 会记录并可能丢弃 unreadable index entry/bytes。Vacuum 不是从坏副本修复数据的工具；应先 scrub 并选健康副本 repair。

## 6. 临时空间

Vacuum 需要同时保留旧 volume 和 compact 后 live volume：

```text
temporary peak ≈ old_physical + live_after_compaction
                 + temp index + filesystem/rename headroom
```

最坏接近 2× volume size。若 disk 已接近满：

-没有空间 Vacuum；
-volume 因 full/readonly停止写；
-必须先移动/增加盘或显式指定 read-only volume Vacuum；
-删除逻辑数据不会立刻解困。

容量红线应为后台维护留出 20–40% 或按最大并发 Vacuum/EC 任务精确计算，而不是把磁盘用到 95% 后才回收。

## 7. TTL

TTL 可来自：

-volume 创建时 TTL；
-Filer path-specific rule；
-entry TTL；
-请求参数。

Volume TTL 会让同 volume 的数据具有相关过期策略。Filer directory 本身 TTL 被置 0；remote entry 由 remote storage 管生命周期。

TTL 风险：

-Filer metadata 可能仍存在但 chunk 已过期；
-不同 volume/replica clock；
-TTL 与 S3 Object Lock/versioning冲突；
-到期只是逻辑 read 不可用，物理回收仍需 Vacuum；
-错误 path rule 影响整个 prefix 的新写。

对 S3 保留策略优先使用 Lifecycle/Object Lock，不用底层 TTL 偷换语义。

## 8. S3 Lifecycle 与 physical reclaim

Lifecycle engine 根据对象 metadata 做：

-current expiration；
-noncurrent version expiration；
-delete marker 清理；
-abort incomplete multipart；
-tag/prefix/size 等 filter；
-conditional delete 防止对象在 scan 后变化。

逻辑 action 最终写 Filer metadata、删除 chunk/tombstone。物理回收链：

```text
Lifecycle match
  -> metadata delete / version marker
  -> chunk DELETE / tombstone
  -> garbage ratio grows
  -> Vacuum
  -> disk bytes released
```

运营仪表盘要同时显示 lifecycle eligible/logical delete 和 reclaim backlog；否则用户看到 bucket 已清空但磁盘不降会误判泄漏。

## 9. EC 生命周期

EC volume：

-不能更新；
-删除写 `.ecj`；
-shard 不原位缩小；
-普通 OSS compact 需 decode；
-之后 Vacuum；
-再 encode/distribute/check。

高删除率数据不应过早 EC。可用一个成本条件：

```text
expected_saved_capacity_by_EC
  > decode + network + vacuum + re-encode operational cost
```

否则完整副本 + periodic Vacuum 更简单。

## 10. Disk tier

Volume Server 可给每个 `-dir` 配 disk type，如 `hdd/ssd/nvme` 或自定义 tag。Filer path rule/collection placement overlay决定新 volume 放哪一类盘。

`volume.tier.move` 可：

-从一种 disk type 搬到另一种；
-按 fullness/quiet/collection 选择；
-可改变 target replication；
-整 volume 迁移。

`volume.move` 可指定 source/target/volume/disk。

注意：

-`volume.balance` 和 `volume.fix.replication` 默认不改变 disk type；
-index 可通过 `-dir.idx` 放 SSD，data 放 HDD；
-移动期间要避免同一物理 disk 被错误标签；
-分层策略按 collection/volume，不是 per-object实时 heat migration。

## 11. Cloud Tier

### 11.1 设计

Cloud Tier 把只读 volume 的 `.dat` 整体上传到 S3-compatible backend 或 full build 的 Rclone，保留本地 index/`.vif`：

```text
local:
  .idx/.vif -> fid offset/size
remote:
  one volume object -> HTTP Range(offset,length)
```

它不同于 Cloud Drive：

-Cloud Drive 让远端每个文件对应一个对象并缓存；
-Cloud Tier 让远端对象是 SeaweedFS volume，外部不可直接理解其中 needle；
-Cloud Tier 透明支持 Filer data encryption；
-Cloud Drive 文档明确不支持这种透明加密。

### 11.2 上传

`volume.tier.upload`：

-选 full/quiet volume；
-标 readonly；
-上传整个 `.dat`；
-记录 backend/key；
-本地删除/卸载 data；
-后续 range read。

要确保：

-remote object完整且 checksum/size已验证；
-`.vif` 和 backend config 被备份；
-所有副本对 remote state 一致；
-密钥/credential可轮换；
-Volume Server 重启能恢复 remote mapping。

### 11.3 读成本

虽然一次 needle 通常一个 Range GET，但：

-每个 GET 有请求费、最低计费和高延迟；
-大量 1 KB对象会产生昂贵 QPS；
-remote provider throttle 会抬尾延迟；
-Volume Server成为 range proxy；
-index丢失后远端大对象本身不易重建逐 needle map。

适合真正冷、低 QPS、较大平均对象；不是无成本的无限本地盘。

### 11.4 Tier compact

远端 volume delete 后对象不会缩小。`volume.tier.compact`：

1. 下载 remote `.dat` 到本地；
2. Vacuum/compact；
3.重新上传；
4.切换 remote object；
5.清理旧数据。

默认 garbage threshold 0.3。临时需要足以容纳下载 volume 与 compact output 的本地盘，且会产生云下载/上传费用。

## 12. Automated tiering

可在 Admin script 中加入：

- `volume.tier.upload -dest s3 -fullPercent=95 -quietFor=1h`；
- `volume.tier.compact -collection=.* -garbageThreshold=0.3`。

生产自动化需要额外 gate：

-最近 scrub clean；
-replication/EC healthy；
-remote credential和quota正常；
-前台 QPS低于阈值；
-目标 cloud class 支持即时 range read；
-不使用 archive class 导致 restore delay；
-任务幂等、单集群 lock；
-失败不删除本地唯一 copy。

## 13. Collection delete

S3 bucket 独立 collection 时可快速删除 collection/volume，优于逐对象 tombstone。但需验证：

-bucket确实没有共享 collection；
-version/object lock允许删除；
-Filer Store bucket table/entries清理；
-normal、EC、tiered volume 全覆盖；
-remote object实际删除；
-删除任务审计和不可恢复确认。

4.41 修复 remote directory delete 真正删除对象，提示历史版本/混合 tier 需要特别回归。

## 14. 容量监控

建议分别采集：

| 指标 | 意义 |
| --- | --- |
| logical live bytes | 用户可见数据 |
| volume physical bytes | 本地实际 `.dat` |
| garbage bytes/ratio | Vacuum候选 |
| tombstone/delete count | churn |
| free bytes by disk | 能否完成 Vacuum/EC |
| compact temp bytes | 进行中峰值 |
| EC logical/shard bytes | 1.4×及分布 |
| tier remote bytes | 云成本 |
| tier range GET/QPS/bytes | 云访问费/性能 |
| lifecycle eligible/action lag | 逻辑过期 backlog |
| reclaim lag | delete 到 physical free 的时间 |

## 15. PoC

1. 30%/70% garbage 的 Vacuum吞吐与前台 P99；
2.磁盘 80%/90% 使用率能否完成 Vacuum；
3. compact 每个阶段 kill/restart；
4.复制组 partial commit；
5.坏 needle 的处理；
6. TTL 与 Filer entry可见性；
7. S3 Lifecycle + versioning/Object Lock；
8. EC delete -> decode -> Vacuum -> re-encode；
9. Cloud Tier upload中断、远端对象 partial；
10.远端 429/5xx/高 RTT；
11. tier compact 本地空间与云费用；
12. bucket collection fast delete 与 remote/EC残留。

## 16. 小结

Append-only 的性能收益必须用显式 Vacuum 和容量余量偿还。TTL/Lifecycle/EC delete 只改变逻辑可见性，Cloud Tier 只转移介质，均不自动消除物理垃圾。生产运维应以“从逻辑删除到本地/远端字节释放”的完整流水线设 SLO，并把所有 compaction 当成需要额外副本、临时空间和可中断恢复的高风险后台任务。
