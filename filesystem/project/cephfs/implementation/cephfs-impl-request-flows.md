# CephFS 关键请求端到端流程

本文以时序图串联客户端、MDS、MON、OSD 在典型操作中的交互，并在每张图后标出对应的源码入口（用户态客户端 `src/client/Client.cc`、MDS `src/mds/*`）。时序图展示的是常见路径，省略了部分错误处理与优化分支。

## 1. 挂载（mount）

```mermaid
sequenceDiagram
    participant C as 客户端
    participant MON as MON
    participant M as MDS rank 0
    participant O as OSD
    C->>MON: 认证 (CephX: get_auth_session_key)
    MON-->>C: ticket + 订阅响应
    C->>MON: 订阅 MonMap / OSDMap / FSMap(MDSMap)
    MON-->>C: 当前各 map
    C->>C: 依据 fs 名选择 MDSMap, 找到 rank 0 地址
    C->>M: MClientSession(REQUEST_OPEN, client metadata)
    M->>M: 校验 caps (mds allow path), journal ESession
    M-->>C: MClientSession(OPEN)
    C->>M: MClientRequest(GETATTR "/" 或挂载子路径)
    M-->>C: reply + root inode + caps(pAsLsXsFs)
    Note over C,O: 挂载完成, OSD 连接按需建立
```

- 客户端：`Client::mount` → `authenticate` → `subscribe_mdsmap` → `_open_mds_session` → `path_walk(mount_root)`。
- MDS：`Server::handle_client_session` → `ESession` journal → 回复。会话打开时检查 `MDSAuthCaps`（`mds 'allow rw path=/x'`），之后每次请求按路径校验。

## 2. 路径查找与打开（lookup + open）

```mermaid
sequenceDiagram
    participant C as 客户端
    participant M0 as MDS rank 0 (auth: /)
    participant M1 as MDS rank 1 (auth: /proj)
    C->>C: 本地 dentry 缓存 + lease 命中 "/" 
    C->>M0: LOOKUP "/proj"
    M0-->>C: reply: dentry proj + inode + dir_auth=1
    C->>M1: OPEN "/proj/a/f" (O_RDWR)
    M1->>M1: path_traverse, rdlock 路径 dentry
    M1->>M1: Locker: 文件 filelock 状态评估<br/>只有本客户端 → loner → EXCL
    M1->>M1: journal EOpen (若首次以写打开)
    M1-->>C: reply + inode + caps pAsxLsXsxFsxcrwb + max_size
    Note over C: 后续 read/write 直接访问 OSD
```

- 客户端：`Client::_lookup` / `Client::_open` → `make_request(CEPH_MDS_OP_OPEN)`。
- MDS：`Server::handle_client_open` → `rdlock_path_pin_ref` → `Locker::issue_new_caps` → `Server::_do_open`（有写模式时 `mdlog->start_submit_entry(EOpen)`）。
- 若客户端缓存中没有 `/proj` 的 auth 信息，请求会先发往 rank 0，被 `request_forward` 转给 rank 1。

## 3. 创建文件（create）

```mermaid
sequenceDiagram
    participant C as 客户端
    participant M as auth MDS
    participant J as metadata pool (journal)
    C->>M: CREATE "/proj/a/new" mode=0644
    M->>M: rdlock_path_xlock_dentry: xlock 新 dentry,<br/>wrlock 父目录 filelock/nestlock
    M->>M: check_access(MAY_WRITE) + 配额检查
    M->>M: prepare_new_inode: 从 session prealloc_inos 取 ino,<br/>继承目录 layout, 设 uid/gid/mode
    M->>M: predirty_journal_parents: 父目录 mtime/nfiles,<br/>祖先 rstat 投影
    M->>M: EUpdate("openc"): metablob 含新 dentry+inode, 父 fnode
    M->>J: submit_entry
    M-->>C: early reply (unsafe) + caps Fxcwb
    J-->>M: safe
    M->>M: C_MDS_openc_finish: 应用投影, 链接 dentry
    M-->>C: reply (safe)
```

- MDS：`Server::handle_client_openc`（含 `O_EXCL` 检查）→ `prepare_new_inode` → `journal_and_reply`。新文件的数据对象**并不在此时创建**，第一次写入时由 OSD 隐式创建；backtrace 在首次写入/元数据回写时由 MDS 存储（`CInode::store_backtrace`）。
- 重试幂等：若客户端未收到回复而重发，`completed_requests` 中记录的 ino 让 MDS 返回同一 inode。

## 4. 写入与 fsync

```mermaid
sequenceDiagram
    participant A as 应用
    participant C as 客户端
    participant O1 as OSD (obj .00000000 primary)
    participant O2 as OSD (obj .00000001 primary)
    participant M as auth MDS
    A->>C: write(0, 6 MiB)
    C->>C: get_caps(Fw, Fb) 已持有
    C->>C: 写入缓存, size=6 MiB (≤ max_size), 标记 Fw dirty
    C-->>A: 返回
    A->>C: fsync(fd)
    par 数据回写
        C->>O1: MOSDOp write obj.0 [0, 4M) snapc
        C->>O2: MOSDOp write obj.1 [0, 2M) snapc
    end
    O1-->>C: commit (全副本持久)
    O2-->>C: commit
    C->>M: MClientCaps(FLUSH dirty=Fw, size=6M, mtime, flush_tid)
    M->>M: Locker::_do_cap_update → EUpdate("cap update")
    M-->>C: MClientCaps(FLUSH_ACK flush_tid)
    C-->>A: fsync 返回 0
```

- 若写入超出 `max_size`，客户端先发送 `MClientCaps(UPDATE)` 请求扩大，MDS 在 `Locker::check_inode_max_size` 中 journal 新 `max_size` 后授予——这保证写者崩溃时 MDS 只需探测 `[size, max_size)` 区间。
- 内核客户端路径：`ceph_write_iter` → `ceph_get_caps` → 页缓存写 → `ceph_writepages_start` → `ceph_osdc_start_request`；`ceph_fsync` → `filemap_write_and_wait_range` + `ceph_flush_caps`/`wait_caps_flush`。

## 5. 多客户端读写冲突

```mermaid
sequenceDiagram
    participant A as 客户端 A (写者, EXCL)
    participant M as MDS
    participant B as 客户端 B
    participant O as OSD
    B->>M: OPEN f (O_RDONLY) 或 GETATTR
    M->>M: filelock EXCL → SYNC (中间态 EXCL_SYNC)
    M->>A: MClientCaps(REVOKE: 去掉 Fxwb, 保留 Fscr)
    A->>O: 刷写全部脏数据
    O-->>A: commit
    A->>M: MClientCaps(UPDATE ack, dirty Fw: size/mtime)
    M->>M: journal cap update
    M->>M: filelock → SYNC
    M-->>A: FLUSH_ACK
    M-->>B: reply + caps Fscr + 最新 size
    B->>O: 读取数据 (看到 A 写入的全部内容)
    Note over A,B: 若 A 随后又要写 → B 的 Fc 被撤销,<br/>进入 MIX: 双方同步 I/O, 无缓存
```

这张图是 CephFS 强一致的完整体现：**B 的 open/stat 延迟包含了 A 刷脏的时间**。

## 6. 跨 rank rename

```mermaid
sequenceDiagram
    participant C as 客户端
    participant L as Leader MDS (目标目录 auth)
    participant W as Witness MDS (源目录 auth)
    participant JL as Leader journal
    participant JW as Witness journal
    C->>L: RENAME /p1/a → /p2/b (L 是 /p2 auth, W 是 /p1 auth)
    L->>L: 本地加锁: xlock dst dentry, wrlock /p2
    L->>W: MMDSPeerRequest(OP_XLOCK / AUTHPIN src dentry)
    W-->>L: ack
    L->>W: MMDSPeerRequest(OP_RENAMEPREP, 完整 rename 描述)
    W->>W: 投影: 移除 src dentry, (必要时)导出 inode
    W->>JW: EPeerUpdate(PREPARE) + rollback 信息
    JW-->>W: safe
    W-->>L: RENAMEPREPACK (witness 确认, 附导出的 inode)
    L->>L: EUpdate("rename"): 含所有 witness 列表
    L->>JL: submit
    JL-->>L: safe
    L-->>C: reply (safe, 跨 rank 不做 early reply)
    L->>W: OP_FINISH (commit)
    W->>JW: EPeerUpdate(COMMIT)
    W-->>L: COMMITTED
    L->>JL: ECommitted
```

- 实现：`Server::handle_client_rename` → `_rename_prepare_witness` → `handle_peer_rename_prep` / `_logged_peer_rename` → `_rename_prepare` → `_rename_apply` → `MDCache::committed_leader_peer`。
- 崩溃处理：若 leader 在 witness PREPARE 后崩溃，resolve 阶段 leader（新实例）根据自己 journal 中是否有 `EUpdate` 告知 witness 提交或回滚（witness 使用 PREPARE 中记录的 rollback blob）。
- 若被移动的 inode 本身的 auth 也随之改变（例如移动目录），还涉及 inode 导入/导出，复杂度进一步上升——跨 rank rename 是 CephFS 最慢、最容易出 bug 的路径之一，运维上应尽量让 rename 发生在同一 rank 子树内。

## 7. 删除与后台回收（unlink + purge）

```mermaid
sequenceDiagram
    participant C as 客户端
    participant M as auth MDS
    participant OC as 其他持有 caps 的客户端
    participant PQ as PurgeQueue
    participant O as OSD (data pool)
    C->>M: UNLINK /proj/a/f
    M->>M: xlock dentry, xlock linklock, wrlock 父目录
    M->>OC: 撤销 dentry lease
    M->>M: EUpdate("unlink_local"): dentry → null,<br/>inode 移入 stray, nlink=0
    M-->>C: reply (unsafe → safe)
    M->>M: StrayManager::eval_stray
    alt 仍有打开者或 caps
        M->>M: 留在 stray, 等待 cap 释放
    else 无引用
        M->>PQ: push PurgeItem(ino, layout, size, snapc)
        PQ->>PQ: journal 追加 (500.* 对象)
        PQ->>O: 删除 ino.00000000 ... ino.N (限速)
        O-->>PQ: 完成
        PQ->>M: 回调: 移除 stray dentry, journal EPurged 回收 ino
    end
```

- 实现：`Server::handle_client_unlink` → `_unlink_local` → `_unlink_local_finish` → `MDCache::notify_stray` → `StrayManager::eval_stray` → `StrayManager::_purge` / `PurgeQueue::push`。
- 删除目录（rmdir）要求目录为空，且需检查所有 dirfrag（可能在多个 rank 上），跨 rank 时也需要 peer 协议。

## 8. 快照创建（mksnap）

```mermaid
sequenceDiagram
    participant C as 客户端
    participant M as auth MDS (目录)
    participant S as SnapServer (rank 0)
    participant OC as 子树内其他客户端
    C->>M: MKSNAP /proj/.snap/s1
    M->>M: xlock snaplock, 校验快照数量上限 (mds_max_snaps_per_dir)
    M->>S: MMDSTableRequest(PREPARE create snap)
    S->>S: journal ETableServer(prepare), 分配 snapid
    S-->>M: AGREE(snapid, table version)
    M->>M: EUpdate("mksnap") + 更新/创建 SnapRealm
    M->>M: journal safe
    M->>S: COMMIT
    S->>S: journal ETableServer(commit)
    M->>OC: MClientSnap(CREATE/UPDATE, realm, 新 seq)
    M-->>C: reply
    OC->>OC: queue_cap_snap: 冻结已有脏状态为 capsnap,<br/>以旧 snapc 刷写后 FLUSHSNAP
```

- 实现：`Server::handle_client_mksnap` → `SnapClient::prepare_create` → `_mksnap_finish` → `MDCache::send_snap_update` / `do_realm_invalidate_and_update_notify`。
- 一致性组快照（多个子卷同时快照）在 Squid 之后可通过 quiesce 协议先暂停相关 I/O 再创建，由 mgr volumes 模块编排。

## 9. MDS failover 中的客户端视角

```mermaid
sequenceDiagram
    participant C as 客户端
    participant OLD as 旧 MDS (rank 0)
    participant MON as MON
    participant NEW as 新 MDS (rank 0)
    participant O as OSD
    C->>OLD: 请求 X (已 unsafe 回复)
    OLD--xC: 进程崩溃
    C->>O: 已持有 caps 的数据 I/O 仍可继续
    MON->>MON: beacon 超时, blocklist 旧 MDS
    MON-->>C: FSMap: rank 0 = NEW (replay)
    Note over NEW: replay journal
    MON-->>C: FSMap: rank 0 reconnect
    C->>NEW: MClientSession(OPEN) + MClientReconnect<br/>(caps, 打开 inode 路径, snaprealm, flock)
    Note over NEW: rejoin: 对照 journal 恢复 caps 与锁
    MON-->>C: FSMap: rank 0 clientreplay
    C->>NEW: 重发 unsafe 请求 X (replay 标志)
    NEW-->>C: reply X (safe)
    MON-->>C: FSMap: rank 0 active
    C->>NEW: 重发在途 (未回复) 请求
```

- 客户端：`Client::handle_mds_map` 检测 rank 状态变化 → `send_reconnect` → `resend_unsafe_requests` → `kick_requests`。
- MDS：`Server::handle_client_reconnect` 收集 caps；`MDCache::rejoin_open_ino_finish` / `process_imported_caps` 关联 inode；`Server::reconnect_tick` 在 `mds_reconnect_timeout` 后驱逐未重连的客户端（并 blocklist）。
- 未在 reconnect 窗口内重连的客户端会失去全部 caps，其未刷写数据丢失——这也是客户端版本过旧、网络抖动时 failover 后出现大批驱逐的原因。
