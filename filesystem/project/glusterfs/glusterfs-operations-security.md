# GlusterFS 生产运维与安全

## 1. 上线前的第一道门：维护来源

2026 年部署 GlusterFS 之前，先回答以下问题；任一没有明确负责人都应阻止新建核心集群：

1. 目标操作系统由谁提供 v11.2/后续 package？
2. upstream release-11 不更新时，谁回补 Critical/Important CVE？
3. OpenSSL、libfuse、XFS、Samba/NFS-Ganesha、QEMU/libgfapi 兼容由谁验证？
4. P0 data corruption 谁能读 AFR/DHT xattr 并提供修复？
5. 业务生命周期超过软件维护周期时，退出/迁移路径是什么？
6. 是否接受 Red Hat Gluster Storage 已 EOL，且社区 release schedule 未及时更新的现实？

技术 PoC 通过不能覆盖 supply-chain/support 风险。

## 2. 物理与故障域设计

### 2.1 Brick 基线

- 每个 brick 使用独立受支持文件系统/逻辑卷，通常为 XFS；
- brick 路径不得与 OS root 混用；
- 需要 trusted xattr、足够 inode、正确 mount options；
- 统一容量与性能，EC set 尤其受最小 brick 限制；
- RAID/controller write cache 必须有断电保护或禁用不安全 write-back；
- time sync、DNS、MTU、NIC bonding 和路由在全体 nodes/clients 一致；
- 禁止应用/运维用户直接访问 brick backend。

### 2.2 Replica/EC placement

每个 replica/disperse set 的 members 必须跨独立 failure domains：

- 不同 bricks 目录在同一磁盘，不是冗余；
- 同一节点多 disks 只能抵抗单盘，不能抵抗节点；
- 同一机架/ToR/电源域不能满足机架容灾；
- arbiter 的 failure domain 也必须独立；
- EC `N` fragments 放同一节点会同时损失多片，CLI 的 warning 不应使用 `force` 绕过。

### 2.3 跨站同步复制

同步 AFR/EC write latency 至少受最慢 required participant RTT 限制。跨高 RTT 站点还会放大 lock、lookup、metadata transaction 和 heal。通常应选择本地同步 replica/EC + geo-rep async DR，而不是把每个 write 放到 WAN quorum。

## 3. 容量规划

### 3.1 不是简单的 raw/replica

物理容量预算应包含：

```text
file payload × redundancy/EC overhead
+ filesystem allocation/slack
+ inode + directory + trusted xattrs
+ .glusterfs GFID hardlinks and indices
+ DHT linkfiles/layout
+ shard hidden files
+ snapshot COW and thin-pool metadata
+ heal/rebalance temporary copies
+ bitrot signatures
+ operational free-space reserve
```

### 3.2 Bytes 与 inodes 双水位

DHT v11.2 默认 `min-free-disk=10%`、`min-free-inodes=5%` 只用于 placement/warning，不能保证 heal/rebalance 有空间。建议设置更保守的业务水位：

- warning：bytes 或 inodes 70%；
- expansion trigger：75–80%；
- stop rebalance/snapshot growth：85%；
- write admission/emergency：按恢复所需空间定义，不等到 95%。

具体阈值需用最大文件、最大 heal batch 和 snapshot growth 计算，以上不是通用默认。

### 3.3 小文件容量

使用目标 XFS inode size、目录深度、xattr、replica count 做至少千万文件的实测：

- `df -h` 与 `df -i`；
- brick 实际 blocks；
- `.glusterfs` 占用；
- heal index 峰值；
- arbiter brick inode/maxpct；
- full heal 扫描速度。

不能用 `du` 的 logical payload 估算。

## 4. 最小生产 topology

### 4.1 推荐起点

对通用 RW 文件：

- 至少 3 个独立 storage nodes；
- distributed-replicated，replica 3；或 2 data + arbiter；
- 每个 replica set 的成员跨 nodes/racks；
- 额外 backup/geo-rep，不把 replica 当备份；
- 双独立网络或至少数据/管理 VLAN 与 QoS；
- 独立监控与配置备份。

### 4.2 示例命令仅用于说明 topology

```bash
gluster peer probe node2
gluster peer probe node3

gluster volume create gv replica 3 \
  node1:/bricks/gv \
  node2:/bricks/gv \
  node3:/bricks/gv

gluster volume start gv
gluster volume info gv
gluster volume status gv detail
```

Arbiter：

```bash
gluster volume create gv replica 2 arbiter 1 \
  node1:/bricks/gv \
  node2:/bricks/gv \
  node3:/bricks/gv
```

实际命令应由目标 v11.2 package/CLI 验证；不要复制示例中的 host/path/failure-domain 假设。

## 5. 网络与端口

### 5.1 端口面

- 24007：glusterd management/volfile；
- 24008：历史/相关服务视发行包；
- brick ports：从 Gluster 10 起在 configured base/max 范围随机分配，常见基线从 49152 起；
- geo-rep SSH、NFS-Ganesha、SMB、monitoring 另有端口。

不要对互联网或通用办公网开放 trusted-pool/brick ports。用 storage subnet、host firewall 和双向 ACL 只允许明确 clients/peers。

### 5.2 网络 SLO

监控每 client↔brick 和 brick↔brick/geo-rep 的：

- RTT P50/P99、packet loss、retransmit；
- bandwidth/utilization/queue drops；
- MTU mismatch；
- DNS lookup latency/failure；
- connection churn/TLS handshake；
- per-node fd/conntrack limits。

AFR/EC tail latency由最慢 required child 主导，平均 RTT 没有代表性。

## 6. 安全模型与默认风险

### 6.1 默认值审计

| 项目 | v11.2/生成 graph 基线 | 风险 |
|------|----------------------|------|
| I/O TLS | off | data/credentials 明文，易被窃听/篡改 |
| `auth.allow` | `*` | 所有能连到 brick 的地址默认可尝试访问 |
| `auth.ssl-allow` | `*` | 受信 CA 下所有 CN 默认可访问 |
| root squash | off | native/protocol 组合下 remote root 权限风险，需逐协议验证 |
| group resolution | client sends gids，server manage-gids off | client 身份和 group list 可信边界较弱 |
| at-rest encryption | Gluster 核心不统一提供 | 依赖 LUKS/storage backend/KMS |
| bitrot | off | 默认无持续内容 checksum scrub |

### 6.2 TLS 硬化

Gluster native I/O path：

```bash
gluster volume set GV client.ssl on
gluster volume set GV server.ssl on
gluster volume set GV auth.ssl-allow client-cn-1,client-cn-2
```

各 node/client 需正确部署：

```text
/etc/ssl/glusterfs.pem
/etc/ssl/glusterfs.key
/etc/ssl/glusterfs.ca
```

Gluster 使用 mutual authentication；一侧开 TLS、另一侧不开不会自动降级，而是拒绝连接。上线必须滚动演练证书分发、rotation、expiry、CA rollover 和 revoked client。

Management path 不由 volume option 控制；官方方式是在每台需要 TLS 管理连接的机器创建：

```text
/var/lib/glusterd/secure-access
```

mount bootstrap client 若需要通过远端 glusterd TLS 获取 volfile，也必须配套。只设置 `client.ssl/server.ssl` 并没有加密 peer/volfile management traffic。

### 6.3 TLS 身份验证的局限

官方文档指出 client 并不充分消费 authenticated server identity 做 hostname-style validation。工程上应：

- 用私有 CA/最小证书集合；
- 每个角色/tenant 独立 CN；
- `auth.ssl-allow` 明确白名单，不保留 `*`；
- 保护 private key 权限；
- 把 network ACL 作为第二层；
- 在 staging 做伪造/错误 CN/错误 CA 测试。

### 6.4 IP ACL 与身份

```bash
gluster volume set GV auth.allow 10.20.0.0/16
```

`auth.reject` 只应用于明确要拒绝的地址段；reject 的匹配优先于 allow，因此不能用“全网 reject”再期望 allow 白名单覆盖。具体地址语法仍应在目标版本验证。IP ACL 不是用户认证，NAT/共享节点/容器环境尤其不能只靠 source IP 做 tenant isolation。

### 6.5 UID/GID 与 root

Native protocol 在 RPC header 中携带 UID/GID/辅助组，brick 以这些 credential 执行 POSIX 检查。风险包括：

- 能控制 native client 主机 root 的人可能伪造本地 UID；
- RPC group 数约有 93 上限；
- `server.manage-gids=on` 可在 brick 端按 UID 解析 groups，但要求 LDAP/SSSD/NSS 一致可用；
- NFS/SMB gateway 有另一层 identity mapping；
- root/all squash 的实际覆盖范围随协议/graph，必须实测而不是假设。

GlusterFS 不是零信任 multi-tenant storage。安全边界应至少是独立 client trust zone，强隔离 tenant 更适合独立 volume/cluster/gateway 和网络域。

### 6.6 At-rest encryption

Gluster v11 upgrade guide已把历史 crypt translator列为 deprecated/removed。需要静态加密时使用：

- 每 brick LUKS/dm-crypt；
- 硬件/云盘 encryption；
- 独立 KMS 与启动解锁流程；
- snapshot/backup/geo-rep secondary 同样加密。

加密层必须位于 backend 下方并与 XFS/LVM snapshot/故障恢复兼容。

## 7. 日常监控

### 7.1 必须持续采集

| 层 | 指标/状态 |
|----|-----------|
| trusted pool | peer connected、config version/checksum、management transaction failures |
| volume | topology、options diff、op-version、client versions |
| brick | online/PID/port、bytes/inodes、latency、FOP error、fd、CPU/RSS |
| client | mount process、connected children、outstanding frames、reconnect、cache/RSS |
| AFR/EC | heal pending/oldest age/rate、split-brain、degraded sets |
| DHT | layout anomalies、lookup-everywhere/linkfiles、rebalance skipped/failed/progress |
| snapshot | thin pool data/metadata、snapshot age/count、snapd |
| geo-rep | worker state、crawl type、last synced、checkpoint、backlog |
| integrity | last scrub、bad objects、unsigned queue、application checksum |

### 7.2 常用命令

```bash
gluster peer status
gluster pool list
gluster volume info all
gluster volume status all detail
gluster volume status GV clients
gluster volume get GV all
gluster volume heal GV info summary
gluster volume heal GV info split-brain
gluster volume rebalance GV status
gluster volume geo-replication status detail
```

`volume profile` 提供 per-brick FOP latency/hit；`volume top` 找热点；statedump 可检查 callpool、inode/fd table、mempool、iobuf 和 xlator private state。

### 7.3 Statedump 使用

Statedump 是进程内状态快照，适合：

- mount/brick hung：看 pending call frames/locks；
- RSS 增长：比较两次 mempool/alloc type；
- fd/inode leak：看 table refcount；
- translator queue：看 private dump。

它不是轻量 metrics；生成和解析需要版本化工具，并避免在大量 processes 同时 dump 填满 `/var/run`/配置目录。

## 8. 日志与审计

常见位置：

- `/var/log/glusterfs/glusterd.log`；
- `/var/log/glusterfs/cli.log`；
- `/var/log/glusterfs/cmd_history.log`；
- `/var/log/glusterfs/bricks/*.log`；
- client mount log；
- `/var/log/glusterfs/glustershd.log`；
- `glfsheal-<vol>.log`；
- geo-rep primary/secondary logs。

要求：

- 集中收集并保留 node/volume/brick/GFID 字段；
- CLI history 进入不可变审计；
- 对 ENOTCONN/EIO/ESTALE/ENOSPC/lock timeout 分类告警；
- 日志 rotation 不得删掉长时间 heal/rebalance 的起点；
- 所有节点时钟同步以便跨 client/brick correlation。

## 9. 扩容与 Rebalance Runbook

### 9.1 前置门槛

- heal backlog=0、split-brain=0；
- 所有 bricks/peers online；
- 有足够 source/destination free bytes/inodes；
- 无 snapshot pool 高水位、无 geo-rep backlog 紧急状态；
- 备份/快照已验证；
- 应用低峰或有 admission control；
- 新 bricks 的 failure domain/容量/XFS options 合规。

### 9.2 分阶段

1. peer probe/new brick verification；
2. add complete replica/disperse sets；
3. 先观察 topology 与 clients refresh；
4. 必要时 `fix-layout`；
5. 小范围/正常 throttle data rebalance；
6. 监控前台 P99、failed/skipped、disk/network；
7. 完成后重复 heal/split-brain/checksum/容量分布验证。

不要同时做 major upgrade、brick replacement、bitrot full scrub 和 rebalance。

## 10. Upgrade

### 10.1 v11 前检查

官方 v11 upgrade guide 要求清理 removed/deprecated features，例如旧 lock-heal/grace options、crypt/stripe/tiering/glupy 等 translator。任何自定义 volfile/老 feature 都可能让 online upgrade 失败。

### 10.2 Online vs offline

官方 generic guide 明确：

- online rolling upgrade 只建议 replicated/distributed-replicated；
- dispersed/distributed-dispersed 或 pure distributed 应使用 offline procedure；
- upgrade 期间禁止配置变更；
- secondary geo-rep cluster 先升级；
- server 先于 clients，最终版本应收敛；
- 每升级一个 replica node，等待 heal backlog 清零再继续。

### 10.3 Op-version

`cluster.op-version` 限制可生成/使用的 feature/protocol，只有所有 servers/clients 支持时才 bump：

```bash
gluster volume get all cluster.op-version
gluster volume get all cluster.max-op-version
gluster volume status GV clients
```

升级 binary 不自动意味着可以安全启用新 op-version。bump 前要枚举所有长连接 FUSE/libgfapi/gateway clients，并准备回滚边界。

### 10.4 维护状态带来的额外要求

因为 v11.2 后 release-11 未见更新，upgrade runbook 还要增加：

- package source hash/signature 和 SBOM；
- downstream patches 清单；
- 编译器/OpenSSL warning 及 sanitizer/regression 结果；
- 恢复旧 package 的可用仓库；
- 从 Gluster 迁出的数据迁移 PoC。

## 11. Quota

Gluster directory quota 可限制 bytes/inodes，但 client cache 会造成短时 overshoot：多个 clients 同时写一个接近 hard limit 的目录时，各自 cache 的 usage 尚未刷新，可能共同越界，直到 timeout 后停止后续写。

工程结论：

- quota 是容量治理，不是恶意 tenant 的硬安全边界；
- timeout=0 强制每次更新向 server 查询，会严重增加 metadata latency；
- 需要监控 logical quota、brick physical usage 和 snapshot/COW 三套水位；
- rename/hardlink/multi-level quota 的边界要专项测试；
- billing 应以可审计 usage pipeline 为准，不只读取 client cache。

## 12. 备份配置

除了数据 backup，还要保存：

- `/var/lib/glusterd` 的只读一致备份（按官方流程，不能在运行中随意回灌）；
- `gluster volume info/get all` 输出；
- peer UUID/hostname/IP 与 failure-domain inventory；
- volume/brick UUID、LVM/XFS mapping；
- TLS cert/CA/rotation metadata（private keys 用安全 KMS/backup）；
- geo-rep sessions/checkpoints；
- snapshot list/backend LV；
- package/version/op-version/client inventory；
- custom systemd/firewall/sysctl/mount options。

配置恢复演练应在隔离网络重建，不把备份的 glusterd state 直接注入生产 peers。

## 13. 生产变更守则

1. 一次只做一种 topology/upgrade/integrity 变更。
2. 任何变更前 heal=0、split-brain=0。
3. 用 GFID、brick set 和 failure domain 定位目标，不只用 path/hostname。
4. destructive command 前保存 CLI 输出、xattr 和 backend snapshot。
5. `force` 不是修复选项；只有理解被绕过的安全检查后才可能使用。
6. 变更完成的定义包含业务 checksum、heal、client versions 和监控恢复，不是 CLI 返回 success。
7. 保持明确的 migration exit plan。
