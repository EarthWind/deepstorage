# CephFS 快照、子卷、配额与镜像

## 1. 核心判断

CephFS 在同一 namespace 中提供任意目录子树快照，并用 subvolume/多文件系统组织租户；但四个词必须拆开理解：

- **snapshot**：不可变历史视图，创建与脏数据固化是异步协议；
- **subvolume**：受 mgr volumes 模块管理的目录树，不是独立文件系统；
- **quota**：客户端协作、近似执行，不是对恶意客户端的硬限制；
- **snapshot mirroring**：按快照异步推送到远端，不是同步复制或双活。

## 2. CephFS snapshot 语义

每个目录都呈现隐藏虚拟子目录 `.snap`。创建 `/a/b/.snap/s1` 就建立以 `/a/b` 为根的子树快照；删除用 `rmdir`，恢复可从快照视图拷回当前 namespace。

快照是不可变视图，但创建过程具有异步部分：

1. MDS 的 SnapServer 分配全文件系统唯一 `snapid`；
2. 在快照根创建/更新 SnapRealm metadata，并写 MDLog；
3. MDS 通知对子树内 inode 持有 caps 的客户端新的 SnapRealm；
4. 客户端生成 SnapContext/CapSnap；
5. 旧脏数据按包含该 snapshot ID 的 context flush 到 OSD；在完成前阻止会破坏快照版本的新写；
6. RADOS self-managed snapshots/COW 保存 file object 的旧版本；snapshot dentries/inodes 以内联版本存在 dirfrag objects。

`mkdir .snap/s1` 很快，是因为第 3–5 步不要求全部同步完成后才返回。最终写回协议维护快照内容，但这不是应用事务一致性的替代品。

### 2.1 SnapRealm

SnapRealm 是快照作用域和客户端写入版本上下文的核心：

- 在新的目录层级创建 snapshot 时产生 realm；
- `sr_t` 持久化 sequence、timestamps、snapshot IDs、`past_parent_snaps`；
- 每个 MDS rank 有 SnapClient，文件系统只有一个 SnapServer 管理 ID/删除集合；
- inode 被 rename 移出原 snapshot hierarchy 时，新 realm 保存过去父级 snapshots，确保旧快照仍能引用正确版本；
- hard-link inode 被放入覆盖全文件系统 snapshots 的 global SnapRealm，保存成本和 metadata 管理更高。

### 2.2 删除与空间回收

删除 snapshot 只移除 namespace/有效 snapshot 记录的第一步：删除 ID 进入 OSDMap，OSD 后台回收不再被其他 snapshots 引用的 object versions；snapshot metadata 随目录对象再次加载/写回而清理。因此空间释放异步，受 snapshot 数量、对象数、OSD 负载与其他快照引用影响。

### 2.3 应用一致快照流程

建议：

1. 暂停新写或取得应用 checkpoint/barrier；
2. 对所有相关 writer 执行 application flush 和 `fsync`；
3. 创建 snapshot；
4. 记录 snapshot name/ID 与应用 checkpoint ID；
5. 等待 mirroring status 确认远端完成后再宣告 DR checkpoint；
6. 最后解除 quiesce。

数据库/多文件应用若跳过 1–2，即使文件系统快照内部一致，也可能捕获业务上互不匹配的 WAL、manifest 和 data files。

## 3. subvolume 与 subvolume group

MGR `volumes` 模块提供：

| 抽象 | 实质 | 典型用途 |
|------|------|----------|
| FS volume | 一个 CephFS 及其 pools/MDS 服务的管理抽象 | 独立文件系统 |
| subvolume group | subvolumes 上层的目录/策略容器 | 统一 layout、quota、uid/gid、normalization |
| subvolume | 独立管理的目录树 | Ceph CSI PVC、Manila share、租户 share |

subvolume 可以有 size quota、data pool layout、uid/gid/mode、snapshot、clone、CephX path authorization 和 trash/purge lifecycle。它带来生命周期与策略隔离，但与同一 FS 的其他 subvolumes 共享：

- MDS ranks 和 cache；
- metadata pool；
- default data pool/backtrace；
- snapshot ID 空间；
- cluster maps、OSDs 和故障域。

因此一个 subvolume 的 metadata storm、cap leak 或 purge backlog 仍可影响同一 FS 的其他租户。需要更强 blast-radius 隔离时才考虑 multiple file systems。

## 4. multiple file systems

从 Pacific 起多 FS 支持稳定。每个 FS 有独立 metadata/data pools 和 MDS ranks，客户端只看到被 CephX 授权的 FS。优势：

- namespace、snapshot IDs、metadata pool 和 MDS 工作集隔离；
- 可按业务独立升级/维护/容量与 CRUSH policy；
- metadata throughput 可通过独立 MDS 集群隔离。

代价：

- 每个 FS 都要自己的 MDS ranks/standby 和 pools；
- 运维对象、PG、监控和升级矩阵增加；
- 不得共享 pool，否则 inode/snapshot ID 可能碰撞；
- 官方一般建议优先单 FS + subtree pinning 做负载隔离，除非确实需要更强边界。

## 5. quota 语义

目录 xattrs：

- `ceph.quota.max_bytes`
- `ceph.quota.max_files`

quota 对目录子树递归生效，根目录 quota 还能改变客户端 `df` 显示。设置 layout/quota 需要 CephX MDS cap 中的 `p` 权限。

### 5.1 关键限制

1. **协作式**：挂载客户端负责在达到 limit 后停止 writer；修改过或恶意客户端可绕过，不能防止不可信租户填满集群。
2. **不精确**：usage/recursive stats 异步传播，writer 常在越界后若干十秒内才被停止，可能超限。
3. **path caps 交互**：客户端必须能看到 quota 所在目录 inode；若只授权子路径而 quota 在不可见祖先，可能不执行。kernel client 还可能需要访问 quota 目录的父 inode。
4. **snapshot accounting**：文件变更/删除后仍由 snapshot 保存的数据不计入 quota。
5. **sparse accounting**：recursive bytes 计入 holes，未必等于物理占用。

因此 quota 适合友好租户的软容量治理，不适合计费真相源或安全隔离。硬防满应使用独立 pools/FS、OSD pool quotas/容量保留、可信 gateway 和外部 admission control 等组合。

## 6. CephX path/FS authorization

CephX entity 同时需要 MON、MDS 和 OSD caps。典型限制包括：

- 指定 filesystem name；
- 指定 path 与 `r`/`rw`；
- `root_squash` 限制 uid 0；
- `s` 允许 snapshot，`p` 允许 layout/quota，`x` 允许执行/遍历；
- OSD caps 限定带 CephFS application tag 的 metadata/data pools；
- 可按 network 限制来源。

path restriction 依赖 MDS 执行 namespace 授权，同时 OSD caps 必须与 FS/pool tag 正确匹配。直接给客户端宽泛 `osd allow rw pool=*` 会破坏租户边界。CephX 保护的是已认证实体；获得 keyring 的主机仍应被视为有相应能力的受信客户端。

## 7. snapshot schedule

MGR `snap_schedule` 可按路径定时创建和按 retention policy 删除 snapshots，适合本地恢复点自动化。生产注意：

- schedule 成功不等于应用已 quiesce；
- snapshot 数量增加会放大 metadata/object version 与删除回收成本；
- volume 删除后模块可能仍引用旧 pools，官方文档提示需要重启/清理模块状态；
- schedule 与 mirror 应统一命名、retention 和“远端已同步才删源端”的策略。

## 8. snapshot mirroring

`cephfs-mirror` 将配置目录的 snapshots 异步 push 到远端 CephFS：先同步文件/目录内容，再在远端创建同名 snapshot。它是 checkpoint replication，不复制每个实时 write。

### 8.1 组件与流程

1. 本地 mgr `mirroring` 模块保存 peer、目录与 daemon assignment；
2. `cephfs-mirror` 用只读源权限扫描源 snapshots，用 `rwps` 远端权限写文件并创建 snapshot；
3. 按目录分配同步任务，复制常规文件/目录/符号链接；
4. 完成后持久化 last synced snapshot、failure/recovery 和进度指标；
5. 远端出现同名/冲突或不可达时进入 failed，后续成功同步可恢复。

### 8.2 明确边界

- 异步，RPO 至少是“最后一个成功同步 snapshot”，不是最后一次本地 write。
- v20.2.3 文档只支持单 peer；不应按任意多站点 fan-out 设计。
- regular file、directory、symlink 支持；其他特殊文件会忽略。
- hard links 不保留 hard-link identity，会按独立文件同步。
- 官方建议部署单 mirror daemon；虽然可多 daemon 分摊 M/N 目录并提供 HA，但文档标注多 daemon 未充分测试。
- 远端应当视为只读，但 CephFS 不自动强制；应靠 MDS caps 阻止业务修改/创建 snapshots。
- 源/远端被同时写、远端 snap-schedule 或人工改动会产生冲突和错误。

### 8.3 DR 不等于 HA

mirror 解决站点级副本/历史恢复，不解决本地 MDS/OSD 故障的秒级接管；本地 HA 依靠 MON、standby MDS 和 RADOS redundancy。反过来，本地三副本也不能替代异地 DR，因为同一 cluster 的误删、认证泄露、软件 bug、机房故障可能影响全部副本。

### 8.4 RPO/RTO 计算

```text
RPO ≈ snapshot interval
    + snapshot 等待/队列时间
    + crawl 与 data sync 时间
    + 监控发现/重试窗口

RTO ≈ 确认最后完整 snapshot
    + promote/重新授权远端
    + 客户端 remount/DNS/服务切换
    + 应用校验与重放
```

应告警：last synced snapshot age、queue wait、crawl/data-sync duration、sync bytes/files、failure count、daemon assignment 和 metrics freshness。

## 9. 备份策略

CephFS snapshot 与 mirror 都不是离线、不可篡改备份。推荐至少区分：

| 层次 | 目标 | 机制 |
|------|------|------|
| 本地快速恢复 | 用户误删/短期回滚 | CephFS snapshots + retention |
| 异地文件系统恢复 | 站点故障 | snapshot mirroring，远端独立 Ceph cluster |
| 防逻辑破坏/凭据泄露 | 不可变长期保留 | 断开权限的对象/磁带/备份系统，独立凭据与 retention lock |
| 元数据灾难取证 | journal/cluster 配置恢复 | 配置、keyrings、crush/osd/fs maps、journal export 与运行手册 |

恢复演练必须包括：从指定 snapshot 恢复应用、远端重新授权/promote、客户端 remount、权限/xattr/ACL/hard link/special file 校验，以及实际 RTO。

## 10. 对 LightStore 的启示

1. 快照必须定义“创建返回”“所有 writer 看到 snapshot epoch”“数据版本可回收”的三个时点。
2. snapshot context/generation 应贯穿 Meta Range、SDK 与 DataServer record，GC 只回收不再被任何 snapshot 引用的 generation。
3. quota 不能只依赖 SDK 协作；若要做不可信多租户，服务端 admission 和 physical reservation 必须强制。
4. tenant namespace、data placement、encryption key、quota、snapshot 和 DR policy 应是同一管理对象。
5. 异步 mirror 要把 last-complete-checkpoint 作为一等状态，禁止用“daemon healthy”代替 RPO。
6. 海量小记录快照应基于 volume/segment COW 或 manifest，而不是每 record 版本对象。
