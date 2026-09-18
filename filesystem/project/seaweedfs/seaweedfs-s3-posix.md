# SeaweedFS S3 与 POSIX 接口语义

## 1. 技术总结

SeaweedFS 4.41 的 S3 API 覆盖已很广，包括基本对象/桶、Multipart、Versioning、Object Lock、Lifecycle、ACL、Tagging、Bucket Policy、IAM/STS、SSE-S3/SSE-C/SSE-KMS 和 S3 Tables。它仍不是 AWS S3 的完整行为副本：bucket notification/replication/website、Object Select/Restore 等缺失，部分 API 是静态或 stub 响应，namespace 仍受 Filer 目录模型影响。

`weed mount` 通过 Filer 提供 POSIX 风格文件系统，官方基线声称 pjdfstest 236 个测试文件、8,819 assertions 全通过且 allow-list 为空。这能证明大量 syscall corner case 已覆盖，但不能证明分布式 crash consistency、跨 mount page-cache coherency、shared mmap、锁在 Filer 崩溃期间连续有效或目标业务性能。

## 2. S3 架构

`weed s3` 是 Filer 上的无状态 gateway：

```text
S3 request
  -> SigV4/IAM/bucket-policy/condition
  -> bucket /buckets/<name>
  -> object entry / version entries / config entries
  -> chunk upload/download via Volume Server
```

一个 bucket 通常映射一个 collection，路径在 `/buckets/<bucket>`。优点：

- collection delete 可快速删除整个 bucket volume；
-可按 bucket 配 replication/disk/TTL；
-容量和 I/O 隔离较清楚。

代价：

-大量小 bucket 产生大量 collection/volume；
-同一个 S3 flat key namespace 需要适配 Filer directory；
-bucket configuration 与 object metadata 都依赖 Filer Store；
-S3 Gateway 的可扩展性受 Filer、Store 和 volume growth 共同约束。

## 3. API 覆盖

### 3.1 主要支持

| 类别 | 4.41 官方支持表 |
| --- | --- |
| Bucket | Create/Delete/Head/List、ACL、CORS、Encryption、Lifecycle、Location、Ownership、Policy、Tagging、Versioning、Object Lock、Public Access Block |
| Object | Get/Put/Head/Copy/Delete/MultiDelete、ACL、Attributes、Tagging、Legal Hold、Retention、ListObjects V1/V2、ListObjectVersions、POST form |
| Multipart | Create/UploadPart/UploadPartCopy/Complete/Abort/ListUploads/ListParts |
| Identity | SigV4 credentials、bucket policy、IAM user/group/policy/access key、STS AssumeRole/OIDC/LDAP/federation/caller identity |
| Encryption | SSE-S3、SSE-C、SSE-KMS、range/copy/multipart |
| Data lake | S3 Tables 与 Iceberg REST/catalog 相关能力 |

### 3.2 明确不支持或不完整

| API/能力 | 状态/差异 |
| --- | --- |
| S3 Express Directory Bucket | 不支持 |
| Bucket Notification | 不支持 |
| Bucket Replication | 不支持 |
| Static Website | 不支持 |
| SelectObjectContent | 不支持 |
| RestoreObject | 不支持 |
| GetObjectTorrent/Object Lambda | 不支持 |
| Lifecycle transition | Put lifecycle 可用，但 transition rule 不支持 |
| MFA Delete | 不支持 |
| Accelerate | Get 返回 Suspended，Put 不支持 |
| Analytics/Inventory/Intelligent Tiering/Metrics config | 部分 GET/List 为 stub/empty/NoSuchConfiguration，写配置不支持 |
| Request Payment | 只接受 BucketOwner |
| Logging | Get 返回空状态，Put 不支持 |

“SDK probe 不报错”不等于功能存在。依赖这些 API 的备份、数据治理、事件驱动、跨区域复制产品必须单独评估。

## 4. Namespace 差异

AWS S3 是 flat key space，`a` 和 `a/b` 可同时存在；Filer 是目录树。4.41 Filer 在自动创建父路径时可把已有 file promotion 成 directory，同时保留其 content/chunks，以改善兼容。但官方差异表仍指出：

- SeaweedFS 同一路径 file/folder 语义与 AWS 不完全相同；
- `DeleteObject` 可删除 folder；
- delimiter 只支持 `/`；
-空目录是真实 metadata，删除最后对象后用异步 cleaner 清理；
-目录 marker、versioned directory marker 在 4.41 仍有多项修复。

任何使用零字节 directory marker、Hive-style partition、嵌套 key 和 version listing 的应用都应纳入回归。

## 5. Versioning

Versioning 通常通过隐藏 version entry、null version、delete marker 和 latest pointer 组合实现。4.41 Release 包含多项相关修复：

-全是 delete-marked object 的 listing prefix；
-exclusive list marker；
-versioned bucket self-copy；
-directory marker history；
-suspended versioning multipart/null marker；
-metadata-only copy chunk ownership；
-delete idempotency/object-lock tests。

这说明功能覆盖已深，但状态机复杂。生产验证至少包括：

1. Disabled -> Enabled -> Suspended -> Enabled；
2. null version 的覆盖和 delete；
3. delete marker 连续创建/删除；
4.带 `versionId` 的 GET/COPY/DELETE；
5.分页跨 delete-marked key；
6. directory marker；
7. Multipart completion 与 versioning 状态并发变化；
8. Gateway/Filer 重启和 owner ring change；
9. metadata Store mutation 中途失败后的重试。

`ObjectTransaction` 提供同 object serialization，但 mutations 不具备通用 rollback；版本状态设计必须依靠幂等 mutation 与 `RECOMPUTE_LATEST` 自修复。

## 6. Conditional operations

支持 `If-Match`、`If-None-Match`、modified/unmodified time 等条件。正确性依赖：

-请求按 object key route 到同一 owner Filer；
-owner lock 覆盖 condition read 和 mutation；
-所有写入口遵守同一 route；
-ring change cooling/warm-up fail-close；
-Filer Store 返回的 entry 不陈旧；
-后端异常不被当作 not found。

对于 shared Store 多 Filer 和强并发 CAS 场景，应验证 stale route、owner crash、DB read replica、超时后重试。

## 7. Object Lock/WORM

SeaweedFS 支持 bucket Object Lock config、retention、legal hold，并用对象 metadata/condition enforcement。它属于 S3 安全边界，官方 `SECURITY.md` 明确把绕过 retention 列为有效漏洞范围。

采用前检查：

- Governance 与 Compliance 模式；
-默认 retention 和 per-object override；
-有/无 `versionId` 删除；
-legal hold；
-管理员 bypass 权限；
-server clock/NTP；
-versioned bucket 的所有 mutation 路径；
-Filer raw API/Volume FID 是否能绕过 S3 enforcement；
-备份/复制后 retention metadata 与密钥；
-管理员、worker、shell 的权限隔离。

Object Lock 只在所有数据访问都经过受控 S3/Filer path 时成立。若攻击者能直接调用内部 Volume/Filer admin API，官方威胁模型已把它视为集群完全受控，而不是 WORM 边界。

## 8. Lifecycle

支持 expiration、noncurrent version/abort multipart 等规则；transition 不支持。Lifecycle 是后台引擎：

-规则存 Filer；
-扫描/重放对象；
-condition 防止扫描后对象已变化却被误删；
-删除形成 tombstone/garbage；
-物理容量最终还需 Vacuum/collection delete。

4.41 修复 daily replay 边界，避免 quiet cluster 卡住。监控应同时覆盖：

-rule scan lag；
-candidate/action/error；
-conditional failure/retry；
-version/delete marker处理；
-logical expired bytes；
-Vacuum 前 physical bytes；
-aborted multipart cleanup。

Lifecycle 与 volume TTL 不同：volume/needle TTL 是底层数据过期机制，不理解 S3 versioning/Object Lock；错误混用可能绕过预期保留或让 metadata 指向过期 chunk。

## 9. IAM、Bucket Policy 与 STS

### 9.1 认证

S3 使用 access key/secret、SigV4；可从静态 config 或 Filer/IAM API 管理 identity。`weed mini` 若不提供 key 可配置 anonymous Allow All，只适合开发。

### 9.2 授权

支持 IAM-style action/resource/principal/condition 与 explicit deny。4.41 修复：

-写 bucket policy 必须具备对应 action；
-identity owner/account 解析；
-role session scope；
-IAM management action 按 IAM action 授权；
-audit assumed-role principal/caller。

复杂策略必须用 deny/allow matrix 回归，尤其：

-bucket vs object ARN；
-anonymous principal；
-IP、SecureTransport、prefix、tag、encryption condition；
-Multipart action inheritance；
-ACL、OwnershipControls、PublicAccessBlock 组合；
-cross-account/role session；
-admin 与 IAM API endpoint。

### 9.3 STS

官方表列 AssumeRole、WebIdentity、LDAPIdentity、GetFederationToken、GetCallerIdentity。它不是 AWS STS 的完整复制；token lifetime、policy intersection、OIDC claim mapping、key rotation 和 clock skew 需实测。

## 10. Server-Side Encryption

| 类型 | key 在哪里 | 关键要求 |
| --- | --- | --- |
| SSE-S3 | SeaweedFS KEK 包 DEK | 所有 Gateway 同 KEK；无 KEK 时 AES256 请求失败 |
| SSE-C | 客户端每请求提供 |备份进程没有 customer key，外部 replicate 可能跳过 |
| SSE-KMS | AWS/GCP/OpenBao/Vault；Azure experimental build tag | Gateway/backup 都要能访问相同 provider/key |

### 10.1 SSE-S3

推荐在 `security.toml [s3.sse]` 配 `kek` 或 `key`，或环境变量：

- `WEED_S3_SSE_KEK`：64 hex，便于旧 `/etc/s3/sse_kek` 迁移；
- `WEED_S3_SSE_KEY`：用 HKDF 派生。

所有 S3 Gateway 必须一致。变更 KEK 前必须设计 rewrap/migration；错误 key 会让已有 ciphertext 不可读。

### 10.2 Backup/Sync

官方文档指出：

- `filer.sync` 在 SeaweedFS 集群间复制 ciphertext 和 SSE metadata，不解密；两端 key/KMS 必须一致；
- `filer.backup/replicate` 到外部 sink 会解密成 plaintext，目标端需另配加密；
- SSE-C 因备份 context 没有 customer key，不能解密，会报错/跳过；
-不同 SSE key 的目标可能保存了字节却读出失败甚至 corrupt data。

备份验收必须逐 SSE 类型恢复读取，而不是只统计 object count。

## 11. POSIX 接口

`weed mount` 基于 FUSE（4.41 也加入 WinFsp）：

-路径/attr 经 Filer；
-数据按 chunk 到 Volume；
-本地 write buffer/chunk cache；
-open file handle 与 Filer log position；
-metadata subscription 做 invalidation；
-可选 distributed advisory lock。

### 11.1 pjdfstest 证据

官方 `POSIX-Compliance.md` 声称：

- 236 test files；
- 8,819 assertions；
- zero skipped；
- `known_failures.txt` 为空；
- CI workflow 固定 pjdfstest commit。

这是一项有价值的 conformance 证据，覆盖 chmod/chown/link/rename/unlink/mkdir/open/truncate/xattr 等许多 syscall edge case。

### 11.2 不能由 pjdfstest 推出的结论

-多客户端同时写同一文件的线性化；
-共享 writable mmap；
-Filer/Store/Volume crash 后的 fsync durability；
-cache invalidation 在丢 event/gap 后的上限；
-distributed lock 在 owner crash 时连续有效；
-目录 rename 百万 entry 的原子性；
-NFS/SMB lease/oplock 语义；
-大规模 metadata 性能；
-Windows 与 Linux 完全相同语义。

## 12. FUSE 一致性

### 12.1 Cache

mount 可缓存 attribute、entry、chunk 和 open handle。跨 mount 可见性依赖：

-Filer metadata event；
-LocalMetaLogBuffer flush/subscription；
-event gap recovery；
-cache TTL；
-open handle version；
-数据 chunk sealing/upload 完成。

4.41 修复 open handle 按 Filer log position version、metadata gap 和 chunk upload lifetime，说明这些边界在快速演进。需要实测：

-A rename/unlink 后 B open/stat/readdir；
-A 覆盖写后 B 已打开 fd；
-event stream 断开/重连；
-Filer rolling restart；
-metadata Store failover；
-client offline 超过 log retention。

### 12.2 fsync/close

mount 的 `fsync` 需要穿过：

```text
local buffer -> chunk upload -> Volume replica path -> Filer metadata entry
```

底层 `fsync=true` 不传播到所有 replica 的事实仍然适用。必须以 mount syscall + power fault 验证，不用名称推断 POSIX durability。

### 12.3 Rename

文件 rename 在支持 transaction 的 Store 可较强；目录 rename O(N)，Store 和 crash model 决定中间状态。对热目录/大目录树不应假定本地 XFS/ext4 的常数级 rename。

## 13. Distributed POSIX advisory locks

默认 `weed mount` 的锁只在本 mount 有效。`-dlm` 开启后：

-每个 mount 创建 session；
-lock key 通过 LockRing 选 owner Filer；
-owner 内存 `posixlock.Manager` 维护 flock/range locks；
-keepalive 每 5 秒左右发送 held lock；
-session TTL 15 秒，sweeper 约 5 秒；
-ring change/重启后 reassert；
-prior-owner cooling probe 与约 10 秒 warm-up fail-close。

局限：

-仅 advisory，不是 mandatory；
-不持久到 metadata log；
-owner Filer crash 后，官方承认 key 在 cooling window + reassert round trip 内不受保护；
-Linux 才把 FUSE lock forwarding 完整接入；
-macFUSE 在 kernel 内按 mount 处理 flock，即使 `-dlm` 不同 mount 也不能协调；
-client session 失联到 TTL 之间，旧 lock 仍占用。

需要锁正确性的数据库/队列不应未经故障验证直接运行在 mount 上。

## 14. S3 与 POSIX 混合访问

同一 namespace 同时暴露 S3 与 mount 会出现语义冲突：

-S3 object key 与目录/file promotion；
-S3 versioning 隐藏 entry 不应被普通 FUSE 修改；
-Object Lock 可能被 raw Filer/mount path 绕过；
-Unix uid/gid/mode 与 IAM/bucket policy 不同；
-S3 SSE metadata 与 Filer普通写；
-Lifecycle 删除与 mount open file；
-ETag/MD5 与分块/加密。

建议：

-不同 collection/prefix 分离协议；
-Object Lock bucket 禁止非 S3 入口；
-明确哪个权限系统是 authority；
-对跨协议 rename/copy/delete 做禁用或审计；
-不要把内部 `/buckets` 直接挂给普通用户。

## 15. 兼容性 PoC

### S3

- AWS CLI/SDK 版本矩阵；
- SigV4 presign、streaming/chunked；
- Multipart retry/abort/list；
-Versioning 状态机与 pagination；
-Object Lock 全矩阵；
-SSE 三种模式的 PUT/GET/RANGE/COPY/Multipart；
-bucket policy/IAM/STS explicit deny；
-Lifecycle/TTL；
-大量 bucket/collection growth；
-unsupported API 的应用降级。

### POSIX

- pjdfstest 本地复跑；
- fio/fsx 与应用真实 syscall trace；
-多 mount cache coherency；
-flock/fcntl lock + owner Filer kill；
-fsync + power fault；
-百万 entry readdir/rename/unlink；
-hardlink/xattr/sparse file/mmap；
-rolling upgrade、event gap、log retention；
-Linux/Windows/macOS 分开验收。

## 16. 小结

SeaweedFS 的 S3 表面已经丰富，但“API 支持”必须拆成 endpoint 存在、语法接受、状态持久、并发正确、故障恢复和 AWS 边缘一致六层。POSIX conformance 结果值得肯定，却不是分布式语义证明。首期生产最稳妥的边界是 S3/对象主入口、限制高级状态机、协议隔离；FUSE 和 active-active 并发作为独立 PoC。
