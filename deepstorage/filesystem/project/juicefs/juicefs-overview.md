# JuiceFS 调研（一）：总体架构

> 基线：juicefs v1.5.0-dev，commit `44a5657`（2026-08-06）

## 1. 定位

JuiceFS 是一个**基于对象存储 + 外置元数据引擎的 POSIX 文件系统**。它自身**不实现任何存储服务端**：
数据落在第三方对象存储（S3/OSS/COS/Ceph/HDFS/本地盘…），元数据落在第三方数据库
（Redis / MySQL / PostgreSQL / SQLite / TiKV / etcd / BadgerDB / FoundationDB）。

JuiceFS 交付的是**一个胖客户端**——所有文件系统语义、数据分块、缓存、后台 GC、compaction
全部在客户端进程内完成。这是理解它全部设计取舍的起点。

```
        ┌──────────────────────────────────────────────┐
        │  应用 (POSIX / HDFS API / S3 API / WebDAV)   │
        └────────────────┬─────────────────────────────┘
                         │
        ┌────────────────▼─────────────────────────────┐
        │        JuiceFS 客户端（单一进程）             │
        │  ┌────────────────────────────────────────┐  │
        │  │ 接入层: FUSE / Java SDK / S3 GW / WebDAV│ │
        │  ├────────────────────────────────────────┤  │
        │  │ VFS 层: 文件句柄、读写缓冲、预读、锁     │  │
        │  ├──────────────────┬─────────────────────┤  │
        │  │ Meta 引擎抽象     │ Chunk 存储抽象       │  │
        │  │ (Redis/SQL/TKV)  │ (本地缓存 + 对象存储) │  │
        │  └──────────────────┴─────────────────────┘  │
        └────────┬────────────────────────┬────────────┘
                 │                        │
       ┌─────────▼─────────┐    ┌─────────▼──────────┐
       │  元数据引擎        │    │   对象存储          │
       │  Redis/TiKV/MySQL │    │   S3/OSS/Ceph/...  │
       └───────────────────┘    └────────────────────┘
```

**没有 Master，没有 DataNode，没有元数据服务进程。** 集群"成员"就是一组各自挂载的客户端，
它们通过元数据引擎里的 session 表互相感知（见 [metadata 文档](juicefs-metadata.md) 第 6 节）。

## 2. 进程模型与代码结构

单一二进制 `juicefs`，子命令驱动（`cmd/main.go`）。核心包：

| 包 | 规模 | 职责 |
|----|------|------|
| `pkg/meta` | ~32k 行 | 元数据引擎抽象与三套实现（Redis / SQL / TKV），事务、GC、Quota、锁、Session |
| `pkg/chunk` | ~4.4k 行 | Block 级读写、本地磁盘缓存、内存页池、上传/下载并发与限速 |
| `pkg/vfs` | ~5.5k 行 | 文件句柄、写缓冲与 slice 提交、读预读、内部控制文件 |
| `pkg/object` | ~14k 行 | ~30 种对象存储适配器 + 压缩/加密/分片包装 |
| `pkg/fuse` | — | go-fuse 绑定 |
| `pkg/fs` | ~2k 行 | 面向 SDK 的路径式文件系统 API（Java/Python SDK 的底座） |
| `pkg/gateway` | — | S3 网关（MinIO gateway 接口） |
| `pkg/sync` | — | 跨存储数据同步（`juicefs sync`），含断点与多机分布式模式 |
| `sdk/java`, `sdk/python` | — | 语言 SDK；Java SDK 提供 HDFS 兼容接口 |

分层调用关系：

```
fuse.fileSystem  ──►  vfs.VFS  ──►  vfs.dataReader / dataWriter
                        │                    │
                        ▼                    ▼
                    meta.Meta          chunk.ChunkStore
                        │                    │
              redis/sql/tkv 实现        本地缓存 + object.ObjectStorage
```

关键接口边界：

- `meta.Meta`（`pkg/meta/interface.go:386`）：约 70 个方法，覆盖全部 POSIX 元数据操作
  加上 session/quota/GC/dump 等运维操作。三套后端各自实现内部 `engine` 接口，
  公共逻辑（权限、配额检查、缓存、compaction 触发）收敛在 `baseMeta`（`pkg/meta/base.go`）。
- `chunk.ChunkStore`（`pkg/chunk/chunk.go:40`）：`NewReader(id, length)` / `NewWriter(id, tier)` /
  `Remove` / `FillCache` / `EvictCache`。上层只认 slice id，不关心对象 key 如何生成。
- `object.ObjectStorage`（`pkg/object/interface.go:80`）：Get(带 range)/Put/Copy/Delete/
  Head/List/ListAll/Multipart/Restore。

## 3. 接入方式

| 接入 | 实现 | 说明 |
|------|------|------|
| FUSE 挂载 | `pkg/fuse` + `cmd/mount.go` | 主用法，Linux/macOS；Windows 走 WinFsp（`pkg/winfsp`） |
| Java SDK / HDFS | `sdk/java` | Hadoop `FileSystem` 实现，大数据生态直连，不经 FUSE |
| Python SDK | `sdk/python` | 基于 cgo 导出 |
| S3 网关 | `pkg/gateway` + `cmd/gateway.go` | 把 JuiceFS 卷再暴露成 S3 |
| WebDAV | `cmd/webdav.go` | — |

同一个卷可以被以上任意方式并发访问，语义一致性由元数据引擎保证。

## 4. 卷（Volume）的概念

一个卷 = 元数据引擎中的一段命名空间（可加 key 前缀）+ 对象存储中的一个 bucket/prefix。
`juicefs format` 写入 `Format` 结构（`pkg/meta/config.go:77`），它是卷的不可变/半可变配置：

```go
type Format struct {
    Name, UUID, Storage, Bucket string
    BlockSize      int      // 默认 4MiB，format 后不可改
    Compression    string   // lz4 / zstd / none，不可改
    Shards         int      // 对象存储分桶数，不可改
    HashPrefix     bool     // 对象 key 是否加 hash 前缀，不可改
    Capacity, Inodes uint64 // 卷级配额，可改
    EncryptKey, EncryptAlgo string
    TrashDays      int      // 回收站保留天数，可改
    DirStats       bool     // 是否维护目录统计（目录配额的前提）
    UserGroupQuota bool
    EnableACL      bool
    ChangeLog      bool
    ...
}
```

`BlockSize`/`Compression`/`Shards`/`HashPrefix`/`MetaVersion` 属于**格式化后禁止修改**的字段，
`Format.update()`（`pkg/meta/config.go:115`）显式拒绝这些变更——因为它们决定了对象 key 与内容的编解码方式。

## 5. 功能矩阵

源码中可确认的能力：

- **POSIX 语义**：硬链接、符号链接、rename（含 `RENAME_EXCHANGE` / `RENAME_NOREPLACE` / whiteout）、
  fallocate（punch hole / keep size；collapse/insert range 返回 ENOTSUP，`pkg/meta/base.go:2223`）、
  flock + POSIX record lock、xattr、POSIX ACL、`copy_file_range`。
- **回收站**：`.trash/YYYY-MM-DD-HH/` 子目录组织，inode 从 `0x7FFFFFFF10000000` 起分配。
- **配额**：卷级容量/inode 数，目录级配额，user/group 配额。
- **克隆**：`juicefs clone`，元数据 CoW + slice 引用计数，不复制数据。
- **分级存储**：`Attr.Tier` + `object.Tiers`，写入时按文件 tier 选择对象存储层级。
- **数据加密**：静态加密（AES-GCM / ChaCha20-Poly1305 / SM4），密钥用 RSA 或 SM2 包装。
- **透明压缩**：LZ4 / Zstd（`pkg/compress`）。
- **运维工具**：`fsck`、`gc`、`dump`/`load`（元数据全量导出导入）、`status`、`profile`、
  `warmup`（预热缓存）、`compact`（手动触发合并）、`info`、`summary`、`changelog`。

## 6. 一句话总结

JuiceFS 用"**把文件系统做成一个客户端库**"换来了极低的运维成本和极广的后端兼容性；
代价是所有一致性、并发协调、后台维护工作都必须在无中心协调者的前提下解决，
而这正是它最多设计巧思、也最多约束的地方。后续文档逐层展开。

---

下一篇：[元数据引擎](juicefs-metadata.md)
