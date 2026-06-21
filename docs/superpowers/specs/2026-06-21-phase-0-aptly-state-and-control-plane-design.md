# Phase 0：aptly 有状态发布模型与控制面边界 — 设计文档

- 状态: 已确认 v1 (评审收口已并入, 待 writing-plans)
- 日期: 2026-06-21
- 范围: 为 Runner 安全加固重构（Phase 0-7）定死"有状态发布"与"控制面"的架构边界。
  Phase 0 **只产出本设计文档**, 不写代码、不创建基础设施、不改 workflow、不迁移真实流量。
  本文档是 Phase 1-7 各阶段 plan 的约束源。
- 父背景: `docs/superpowers/specs/2026-06-18-ocserv-backport-design.md`
- 上游动机: 将 self-hosted runner 从"builder 用户宿主机常驻"重构为
  "ephemeral non-root 容器 + `--ephemeral` + `--rm` + 无 docker socket + 无敏感挂载"。
  该重构要求 CI 内不再使用 sbuild/chroot, 转而在按 digest 固定的 Debian trixie builder
  镜像内以 `dpkg-buildpackage` 等非特权方式构建。sbuild 与"无特权 + 每 job 全新容器"
  存在根本冲突, 因此必须先把 aptly 的有状态发布核心从 build 域中剥离, 否则后续阶段
  无法收尾。

## 决策摘要

| 决策点 | 选择 |
|--------|------|
| 总体重构推进方式 | Phase 0-7 分阶段, 每阶段独立 spec/plan/PR, 纵向切片可独立验证与合并 |
| Phase 0 产出 | 仅架构决策文档, 零代码、零基础设施变更 |
| aptly state 归属 | 独立 publish host, systemd 常驻服务, 不在 runner/build 域 |
| publish host 拓扑 | **双 host 物理隔离**: publish-host-testing + publish-host-production, 不共享主机/磁盘/DB/key/控制面/凭据 |
| build→publish 数据桥 | R2 staging candidate release (control plane 签发短期精确 PUT URL) + publish host 拉取重新校验 + 本地 quarantine 导入 |
| candidate release ID | server-generated non-monotonic ULID (26 字符 Crockford Base32), 不可枚举 |
| provenance 格式 | SLSA Provenance v1 + in-toto DSSE + Sigstore keyless (GitHub OIDC) |
| GPG 体系 | 双独立 hierarchy; primary key 离线; 各 host 仅持本域 online signing subkey |
| rollback 协调 | 受控两阶段状态机: repo 先回滚, host 后显式降级; deploy runner 不触发 repo rollback |
| Job→control plane 认证 | GitHub OIDC (证明 workflow 身份) + mTLS (transport client identity), 短期动态签发, 不存长期密钥 |
| target environment 推导 | 由 endpoint + OIDC audience + mTLS identity + Environment approval + caller role allowlist 共同推导, 客户端不可字符串指定 |
| 迁移策略 | 双轨→切默认→删旧; 双轨期禁止新旧路径并行写同一公开 repo |

## 安全不变量 (贯穿 Phase 0-7, 任何阶段不得违反)

```text
1. 任何 GitHub Job 容器都不可拥有 docker socket / privileged / CAP_SYS_ADMIN / 宿主机 bind mount
   (例外: runner provisioner host 本身可拥有 docker daemon 用于创建 ephemeral Runner 容器;
            Job 容器内部仍禁止)。
2. build runner 永远不直接接触 aptly / GPG 私钥 / production R2 写 / production CDN / publish host shell。
3. deploy runner 永远不修改 aptly state / GPG / R2 repo write / CDN purge / repo rollback。
4. testing 身份永远不可调用 production control plane; production host 永远不信任 testing host 的
   本地文件 / SSH 返回值 / workflow 成功状态 / 未签名 JSON。
5. repo rollback 与 host downgrade 永远在 control plane 持久化状态机内推进, 不脱离状态机独立执行。
6. 新旧 publish 路径永远不可并行写同一个公开 repository (aptly state / R2 repo target / CDN metadata)。
7. GPG 私钥永远不出现在: GitHub Secret / runner 镜像 / artifact / R2 / CDN / git / deploy runner /
   build runner。primary key 离线保管。
8. build runner 永远不持有长期 R2 Access Key; 只接受 control plane 签发的短期、精确 object key、
   固定 HTTP method (PUT) 的 presigned URL。
9. target environment (testing/production) 永远由服务端多因素推导, 永远不接受客户端字符串指定。
10. 无任何流程允许 testing 与 production 共用 GPG primary key 或 online signing subkey。
```

---

## 第 1 节: 信任域拓扑与主机职责

### 1.1 四信任域 + 各域唯一职责

```text
┌─────────────────────────────────────────────────────────────────┐
│  信任域 A: Runner Host (run-job-provisioner)                      │
│  职责: 仅创建/销毁 ephemeral Docker Runner 容器                    │
│  持有: Docker daemon (仅供 provisioner 进程, 非 job 容器)          │
│  绝不持有: aptly state / GPG / production R2 / SSH / R2 staging   │
│  网络: job 容器不可见 docker.sock; job 容器出站受限                │
└─────────────────────────────────────────────────────────────────┘
        │ job 容器 (无 docker socket, 无敏感挂载, --ephemeral, --rm)
        ▼
┌─────────────────────────────────────────────────────────────────┐
│  信任域 B: Publish Host (双机物理隔离)                             │
│  publish-host-testing  与  publish-host-production                │
│  各自职责: 持有本域 aptly state/GPG, 执行受控 publish/rollback/sync│
│  各自服务: aptly.service(loopback) + control-plane(mTLS) +        │
│            publisher-worker(状态机执行)                            │
│  各自绝不: 跑 GitHub Runner / 跑 build / 暴露 docker.sock /        │
│            接任意 shell / 持有对域的 key/凭据                       │
└─────────────────────────────────────────────────────────────────┘
        ▲ R2 staging 拉取 + mTLS 控制请求
        │
┌─────────────────────────────────────────────────────────────────┐
│  信任域 C: Deploy Runner 容器 (staging / production 各自隔离)      │
│  职责: 仅执行 ansible upgrade/verify/rollback                     │
│  持有: 对应环境的 SSH 私钥(tmpfs, ssh-agent, 用完即焚)             │
│  绝不持有: aptly/GPG/R2/CF/publish-host shell/repo rollback 权限  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  信任域 D: R2 / CDN (逻辑独立 bucket)                              │
│  - apt-build-staging   : build→publish 数据中转 (私有, 无公开端点)  │
│  - apt-thehkus-testing : testing 静态仓库 (CDN origin)             │
│  - apt-thehkus         : production 静态仓库 (CDN origin)           │
│  绝不: 承载 aptly 管理接口 / GPG 私钥 / CI runner 工作目录          │
└─────────────────────────────────────────────────────────────────┘
```

> R2 bucket 拓扑: staging / testing / production 三者逻辑隔离。具体是否物理分三个 bucket
> 还是同一 bucket 的隔离 prefix + 独立凭据, 由 Phase 4 (testing) / Phase 6 (production)
> 各自 plan 决定, 但凭据必须隔离 (testing repo 写凭据 ≠ production repo 写凭据 ≠ staging 读凭据)。

### 1.2 双 publish host 物理隔离的硬约束

testing 与 production 必须各自拥有独立:

```text
1. 独立主机 (不得是同一 Docker host / 同一 VM 内两容器 / 同一 OS 两用户两 systemd service;
             不得共用宿主机磁盘/rootfs/Docker daemon/LVM/NFS/工作目录)
2. 独立 aptly state (DB/pool/local repo/snapshot/published state/publish lock/
                     import quarantine/audit log/backup/rollback metadata;
                     不得共享 aptly DB/pool/publish root/snapshot namespace/repo lock/~/.aptly)
3. 独立控制面 (publisher-control-plane-testing / publisher-control-plane-production;
               不同 endpoint / server cert / client CA / mTLS trust domain /
               workload identity policy / GitHub Environment mapping / 审计日志 /
               idempotency namespace / release state machine / R2 credential / CDN credential)
4. 独立 GPG 信任体系 (见 §3.1)
5. 独立备份与恢复 (见 §3.5)
```

### 1.3 主机与服务清单

| 主机/服务 | 角色 | 持有的凭据 | 运行的东西 | 禁止 |
|---|---|---|---|---|
| **Runner Host** | job 容器 provisioner | 仅供 provisioner 的 docker | docker daemon + provisioner 脚本 | 持 aptly/GPG/prod 凭据 |
| **publish-host-testing** | testing 发布信任根 | testing GPG subkey、testing aptly DB、testing R2 repo 写、testing CF purge、staging R2 读 | aptly.service(loopback) + control-plane-testing + publisher-worker-testing | 跑 runner/build/production workload/暴露 docker.sock |
| **publish-host-production** | production 发布信任根 | production GPG subkey、production aptly DB、production R2 repo 写、production CF purge、staging R2 读 | aptly.service(loopback) + control-plane-production + publisher-worker-production | 跑 runner/build/testing workload/暴露 docker.sock |
| **aptly.service** (各 host 各一) | aptly CLI 后端 | aptly 系统用户 | aptly REST (仅 loopback/unix socket) | 公网/job 直接访问 |
| **control-plane-testing/production** | API 网关+鉴权+状态机编排 | mTLS CA、staging R2 读 token | FastAPI/Go HTTP (mTLS) | 执行任意 shell/aptly 参数 |
| **publisher-worker-testing/production** | 状态机执行 | 本地 quarantine + aptly socket + GPG agent | 受限状态机操作 | 接受外部 shell/路径 |
| **deploy-staging runner** | staging 部署 | staging SSH (tmpfs) | ansible | 持 aptly/GPG/R2/CF/repo rollback |
| **deploy-production runner** | production 部署 | production SSH (tmpfs) | ansible | 持 aptly/GPG/R2/CF/repo rollback |
| **ci-build runner** | 构建 | 仅 GitHub OIDC + 短期 PUT URL | dpkg-buildpackage | 持任何长期凭据/docker socket |

### 1.4 网络策略 (每域出/入方向)

```text
ci-build 容器:
  出: deb.debian.org/pool | snapshot.debian.org(预取节点) | control-plane(仅 candidate-release API) | R2 staging(仅签名 PUT URL)
  入: 无

publish-testing 容器:
  出: control-plane-testing(仅 publish-testing/rollback API, mTLS testing client)
  入: 无

publish-production 容器:
  出: control-plane-production(仅 promote-production/rollback API, mTLS prod client, 仅 Environment approval 后)
  入: 无

deploy-staging 容器:
  出: staging hosts(TCP 22) | control-plane-testing(仅查询 deploy plan, 无 publish 权)
  入: 无

deploy-production 容器:
  出: production hosts(TCP 22) | control-plane-production(仅查询 deploy/rollback plan)
  入: 无

publish-host-testing:
  入: control-plane-testing mTLS 端口(仅 testing 签约 client) | staging R2(出站拉取)
  aptly REST: 仅 loopback/unix socket, 不入公网/job 网
  不可达: production host / production R2 repo write / production CF zone

publish-host-production:
  入: control-plane-production mTLS 端口(仅 production 签约 client, 仅 Environment approval 后) | staging R2(出站拉取)
  aptly REST: 仅 loopback/unix socket
  不可达: testing host / testing R2 repo write / testing CF zone

promotion-evidence 存储 (见 §4.5):
  写: 仅 control-plane-testing 受控签名身份
  读: 仅 control-plane-production
  job runner / build / deploy / 人工: 不可直接读写
```

### 1.5 Phase 0 的物理实现约定 (明确边界, 不写代码)

- 本文档**描述** Publish Host 的服务拓扑, 但**不规定** systemd unit 文件名/路径细节
  (那是 Phase 4/6 的 plan 范围)。
- 本文档**列出** Runner label (ci-build / publish-testing / publish-production /
  deploy-staging / deploy-production) 与对应 Runner Group、GitHub Environment 的映射表,
  但**不规定** GitHub UI 配置步骤 (运维操作, Phase 1+ 各自 plan 涵盖)。
- 本文档**定义** R2 staging bucket 的逻辑职责和对象布局契约, 但**不规定** R2 backend 具体
  参数 (CORS/region 是 Phase 4 plan)。

---

## 第 2 节: candidate release 数据桥 (build 域 → publish 域)

### 2.1 总体数据流

```text
ci-build Runner
   │
   │ 1. 使用 GitHub OIDC 请求 upload session
   ▼
publisher control plane (testing 或 production 实例)
   │
   │ 2. 校验 workflow identity (OIDC claims), 登记 candidate release, 生成 release_id
   │ 3. 为该 release 的每个固定对象签发短期 PUT URL
   ▼
R2 staging bucket / incoming prefix (apt-build-staging, 私有, 无公开端点)
   │
   │ 4. build runner 上传 .deb / .changes / .buildinfo / manifest / provenance
   ▼
publisher control plane
   │
   │ 5. publish-testing 或 promote-production 请求
   │ 6. publisher-worker 从 R2 staging 拉取并重新校验
   ▼
publish host local quarantine directory
   │
   │ 7. hash / metadata / provenance / policy 全部验证通过
   ▼
aptly DB + pool + snapshot + publish state
   │
   │ 8. 由 publish host 执行受控 publish
   ▼
R2 production/testing repository + CDN purge
```

**关键原则:**
1. R2 staging 只承载候选构建产物, 不承载 aptly state。
2. staging bucket 与 testing/production repository 必须逻辑/凭据隔离。
3. build runner 只能写入自己的临时 release prefix (由 control plane 生成的 release_id)。
4. build runner 不能 list / read / delete / copy / overwrite 其他 release 的对象, 也不可读取
   自己已上传的对象 (除非 control plane 明确短期只读调试授权)。
5. build runner 不持长期 R2 / CF / aptly / GPG / publish-host SSH 凭据。
6. publish host 不信任 object key / 文件名 / manifest 内容 / build runner 声明本身, 必须重新验证。
7. publish host 不直接从 GitHub Artifact 取待发布 package; GitHub Artifact 可继续用于 CI job 间
   测试传递, 但不是 build→publish 的正式信任桥。

### 2.2 R2 staging 存储布局与生命周期

**独立私有 bucket:** `apt-build-staging` (与 testing/production repo bucket / backup / log bucket 物理或逻辑隔离)。

**对象布局:**

```text
incoming/v1/
  <release_id>/                          # ULID, control plane 生成
    manifest.json                        # canonical manifest (control plane 已固化 digest)
    provenance.sigstore.json             # Sigstore verification bundle (SLSA v1 + DSSE + keyless)
    artifacts/
      0001.deb
      0002.changes
      0003.buildinfo
```

**object key 规则:**
- `<release_id>` 必须由 control plane 生成 (§2.4), build runner 不可指定。
- artifacts 文件名必须严格匹配 manifest 声明的 filename, control plane 不接受未声明文件。
- 拒绝 `..` / 绝对路径 / 控制字符 / 非批准扩展名 (白名单: `.deb .changes .buildinfo`)。

**生命周期策略 (spec 写死阈值, GC 身份明确):**
- candidate artifact 创建后 24h 内未 finalize → expired, 可 GC。
- finalize 后 72h 内未 publish → expired, 可 GC。
- publish 成功后的 artifact 保留 30 天 (审计与 rollback 恢复需要)。
- GC 执行身份: publish host 上的专用 GC worker (systemd timer), **ci-build 永远没有 delete 权限**。
- GC 不可删除仍被 production promotion / rollback / incident investigation / restore drill 引用的 release
  (GC worker 查询 control plane 的引用计数)。

### 2.3 Manifest 与 Provenance

**Canonical JSON manifest (字段固定顺序, digest 可复算):**

```jsonc
{
  "schema_version": 1,
  "release_id": "01J...",              // control plane 生成, ULID (§2.4)
  "repository": "GentleKingson/ocserv-backport",
  "source": {
    "commit": "<40-hex sha>",
    "ref": "refs/heads/main",
    "workflow": ".github/workflows/ci-testing.yml",
    "run_id": "...", "run_attempt": "...",
    "lock_tsv_digest": "<sha256>"       // source-lock/*.lock.tsv 的 digest, 身份闭环
  },
  "builder": { "image_digest": "sha256:..." },   // trixie builder image digest
  "packages": [
    {
      "name": "ocserv", "version": "1.5.0-1~bpo13+1",
      "arch": "amd64",
      "deb":      { "filename": "..._amd64.deb",     "sha256": "...", "size": 12345 },
      "changes":  { "filename": "..._amd64.changes", "sha256": "...", "size": 1234 },
      "buildinfo":{ "filename": "..._amd64.buildinfo","sha256":"...", "size": 1234 }
    }
  ],
  "build_timestamp": "2026-06-21T12:00:00Z",
  "idempotency_key": "<uuid>"
}
```

**Provenance bundle (正式格式, 非自定义):**
- `provenance.sigstore.json` 是 Sigstore verification bundle, 内含:
  - DSSE envelope;
  - in-toto Statement (`_type: https://in-toto.io/Statement/v1`);
  - SLSA Provenance v1 predicate (`predicateType: https://slsa.dev/provenance/v1`);
  - keyless signature (GitHub Actions OIDC);
  - Fulcio short-lived certificate chain;
  - 签名时间戳;
  - Rekor transparency-log inclusion proof。
- build runner 使用 GitHub OIDC keyless sign (cosign), 不持长期私钥。
- provenance bundle 是 candidate release 必要对象, 缺失/格式错误/验证失败/与 manifest 不匹配 →
  release 不得进入 publish。
- publish host 不得重新签发/生成 provenance, 也不接受 build runner 上传后覆盖。

**Manifest/Artifact 限制 (写死阈值):**
- packages 数量上限: 1 (当前只发 ocserv, 留扩展位)。
- 单文件 size 上限: 50 MiB。
- `.deb` / `.changes` / `.buildinfo` 都必须由 provenance subject 或 manifest digest 间接、
  不可歧义地绑定。

### 2.4 release_id 格式与生成责任

**格式:** ULID (128-bit, 26 字符 Crockford Base32)。
- 前 48-bit: 毫秒级时间戳 (审计可排序)。
- 后 80-bit: CSPRNG 随机 (不可枚举)。
- 不含 `/ + =` 空格或 URL 编码敏感字符, 适合 R2 object key path segment。

**生成责任 (只能由 control plane 生成):**
- 禁止由 build runner / workflow YAML / run ID / shell env / API caller body /
  package filename / version / commit SHA / 人工输入 生成或指定。
- candidate release 创建 API: control plane 验证 OIDC → 生成新 ULID → 创建初始 release state →
  返回只读 release_id → 后续所有操作引用该已存在 release_id。
- 禁止客户端提交自定义 release_id。

**重要边界:** release_id 的不可预测性用于防止对象前缀被猜测, **不是授权机制本身**。
真正的授权边界是 OIDC 验证、control plane 状态、短期精确 PUT URL、publish host 独立校验、
R2 私有访问控制、publish host 不信任 release_id/object key/声明本身。

### 2.5 Release Sealing (上传完成后不可变)

```text
manifest_accepted → upload_authorized → uploaded_pending_validation → sealed → provenance_verified → artifact_verified
```

**Sealing 不变量 (硬性):**
- manifest digest 一旦接受, 不可修改。
- 已签发的 object key 不可被 build runner 改写为其他路径。
- finalize 后 release 进入 sealed 状态。
- sealed release 不允许补充/替换/删除/覆盖 artifact。
- 如需重新构建, 必须创建新的 release_id。
- 同一 release_id 不得绑定不同 manifest。
- 同一 manifest 不得复用于不同 release_id (除非有显式审计化的 deduplication policy)。
- publish host 必须对下载后的实际字节重新计算 SHA-256。
- 最终导入 aptly 的文件必须同时匹配: (1) control plane canonical manifest;
  (2) SLSA provenance subject; (3) publish host 下载后实际文件 hash。三者一致才导入。

---

## 第 3 节: GPG 体系、发布事务状态机与失败恢复

### 3.1 GPG Key Hierarchy (双 host 各自独立, primary 离线)

```text
┌─ testing trust domain ──────────────────────────────┐  ┌─ production trust domain ─────────────────────────┐
│                                                      │  │                                                    │
│  [testing primary key]   ← 离线保管(离线介质)        │  │  [production primary key] ← 离线保管(更高保护级别) │
│       │  仅用于: 签 subkey / 撤销 / 轮换             │  │       │  仅用于: 签 subkey / 撤销 / 轮换           │
│       ▼                                              │  │       ▼                                            │
│  [testing signing subkey] ← 常驻 publish-host-testing│  │  [production signing subkey] ← 常驻 publish-host-prod│
│       │  仅签 trixie-testing Release/InRelease       │  │       │  仅签 trixie-production Release/InRelease   │
│       │  gpg-agent 托管, passphrase 仅 host 内       │  │       │  gpg-agent 托管, passphrase 仅 host 内      │
│       ▼                                              │  │       ▼                                            │
│  [撤销证书] ← 离线备份(与 primary 分开存放)          │  │  [撤销证书] ← 离线备份                              │
└──────────────────────────────────────────────────────┘  └────────────────────────────────────────────────────┘

绝对禁止:
  - testing/production 共用 primary 或 subkey
  - subkey 出现在 secret/镜像/artifact/R2/git/deploy runner/build runner
  - production host 持 testing key 或反之
  - host 被入侵时"复制 key 到另一台顶替发布"
```

**Key 生命周期:**
- subkey 轮换: 定期 (建议 12 个月) + 事件触发 (host 被入侵)。
- host 被入侵响应: **只撤销该域 subkey**, 不轮换 primary (primary 离线未泄露);
  用 primary 签新 subkey 注入重建的 host。
- primary key 恢复: 离线介质 + 至少 2 人控制 (Shamir 分片或物理分割)。
- 撤销证书: 与 primary 分开离线存放。
- 客户端 apt keyring: testing/production 公钥独立分发, 客户端只信任对应域公钥。

### 3.2 Publish Host Worker 发布事务状态机

```text
approved_for_testing  (或 approved_for_production)
        │
        ▼  从本地 quarantine 目录(已重新校验 hash 的文件)导入
[imported_to_aptly]     aptly repo add <repo> <本地quarantine/*.deb>   ← 不接受 R2 路径/任意路径
        │               检查点: repo add 成功 → pool 含新 deb
        ▼
[snapshot_created]      aptly snapshot create <snapshot> from repo
        │               检查点: snapshot show 含 ocserv 正确版本
        ▼
[published]             aptly publish switch <dist> <snapshot>         ← GPG 签名在此步发生
        │               检查点: publish list 含 dist → Release/InRelease 已签
        │               ★ 此刻 aptly local state 已提交, 但 R2/CDN 还未更新 ★
        ▼
[r2_synced]             rclone sync /var/aptly/public/<channel>/ → r2:<bucket>/<channel>/
        │               检查点: R2 对象 checksum 与 local 一致
        │               ★ 失败恢复见 §3.4 ★
        ▼
[cdn_purged]            CF purge <channel>/dists/*
        │               检查点: purge API 返回 success
        ▼
[completed]             manifest_update(current/previous-good)         ← 最后才写 manifest
                        审计日志: release_id + snapshot + publish_revision +
                                  r2_sync_revision + cdn_purge_id + result
```

**事务不变量:**
- aptly local state 提交 (`published`) 与 R2/CDN 更新**不是原子事务**——这是 aptly + R2 架构的
  固有事实, spec 显式承认并提供恢复路径 (§3.4)。
- manifest (current/previous-good) **只在 `completed` 时写**, 中途任何失败都不更新 manifest——
  这保证 previous-good 始终指向"确定成功发布过"的状态, 是 rollback 的根基。
- 审计日志每步追加, 不覆盖。

### 3.3 并发锁 (跨 ephemeral 容器的串行化)

```text
锁机制: publish host 上的 publisher-worker.service 是单实例 (或受 systemd/DB advisory lock 保护)
       → control plane 收到 publish/rollback 请求后排队, worker 一次只处理一个发布事务
       → 天然串行, 不依赖跨容器 flock

幂等: 每个 (release_id, op, idempotency_key) 三元组在 control plane 状态库中唯一
      → 重放返回既有结果, 不重复 import/snapshot/publish
      → testing 与 production 各自独立 idempotency namespace (不同 host)

审计: 每个 state 转移写一条审计记录 (release_id, from_state, to_state, ts, caller_identity, result)
      → 审计日志只追加, 存 publish host 本地 + 加密备份 (不进 R2 staging)
```

### 3.4 失败恢复路径 (每类失败 → 具体动作)

| 失败点 | 状态 | aptly local | R2 | CDN | manifest | 恢复动作 |
|---|---|---|---|---|---|---|
| aptly import/snapshot/publish 失败 | `*_failed` | 未提交或回滚 | 未变 | 未变 | 未变 | 修复后重试同 release_id (幂等); aptly local 若半提交, worker 用 snapshot/publishRevision 回滚到上一稳定 publish |
| **publish 成功, R2 sync 失败** | `r2_sync_failed` | **已提交** | **旧** | 旧 | 未变 | worker 重试 r2 sync (rclone sync 幂等); 若持续失败, **不回滚 aptly** (aptly 已是新状态), 告警人工介入; R2 最终会一致 |
| **R2 sync 成功, CDN purge 失败** | `cdn_purge_failed` | 已提交 | 已新 | **旧缓存** | 未变 | worker 重试 CF purge (幂等); CDN 缓存有 TTL 上限, 最坏 TTL 过期自愈; 不回滚 aptly/R2 |
| 全部成功后客户端报错 | `completed` | 新 | 新 | 新 | 新 | 走 rollback (§3.6) |

**核心原则:** aptly local publish 一旦成功, **绝不**因 R2/CDN 失败而回滚 aptly——因为
aptly local state 是后续所有 publish/snapshot/rollback 的根基, 回滚它会破坏状态机。
R2/CDN 是派生态, 靠重试 + TTL 自愈。

### 3.5 Publish Host 被入侵的恢复 (不复制 key 顶替)

```text
检测: 审计日志异常 / key 泄露告警 / host 入侵指标
响应:
  1. 撤销该域 signing subkey (用离线 primary, 不轮换 primary)
  2. 隔离被入侵 host
  3. 从加密备份重建新 host:
     - 恢复 aptly DB/pool/snapshot/publish-state (备份是发布信任根的一部分)
     - 用 primary 签新 subkey, 注入新 host
     - 重建 control plane trust (新 server cert, 新 client CA 不变则 client 无感)
  4. 从已记录 release/snapshot state 重新验证并恢复发布
  5. 验证 R2/CDN 与 aptly local state 一致

绝对禁止: 复制 production key 到 testing host 顶替发布
```

### 3.6 Rollback 协调模型 (受控两阶段状态机)

详细状态机与协议见 **第 8 节**。本节仅给出核心原则:
- 顺序固定: repo 先回滚 → repo 可见性验证 → canary host downgrade → 分批 host downgrade →
  全量健康验证 → completed。
- repo rollback 属 `publish-production` / publish host 域。
- host downgrade 属 `deploy-production` 域。
- deploy runner 只能读取已确认的 rollback target, 不能触发或修改 repo rollback。
- repo 成功 host 失败时, repo 保持回滚状态, 继续修复 host, 不自动重新暴露错误版本。
- 对存在不可逆 data/config migration 的 release, 必须先经 compatibility gate, 不自动 downgrade。

---

## 第 4 节: 控制面 API 契约与身份模型

### 4.1 Candidate Release 创建/上传状态机

```text
                        ┌──────── GitHub OIDC 身份校验 (§4.4 allowlist) ────────┐
                        │                                                         │
created ──► manifest_accepted ──► uploaded_pending_validation ──► downloaded ──► verified
   │              │                        │                          │             │
   │              │                        │                          │             ▼
rejected_   rejected_                missing_object              hash_mismatch   quarantined
identity    manifest                                           metadata_mismatch     │
                                                                                  ├─► approved_for_testing ──► imported_to_aptly ──► ... (§3.2) ──► completed
                                                                                  │                              (testing dist)
                                                                                  └─► approved_for_production
                                                                                       (prod dist, 仅 Environment
                                                                                        approval 后, 需 testing_validation_record)

终止状态: completed | rejected_* | missing_object | hash_mismatch | metadata_mismatch |
          provenance_invalid | policy_rejected | aptly_import_failed | snapshot_failed |
          publish_failed | r2_sync_failed | cdn_purge_failed | expired
```

**状态机不变量:**
- 单调前进, 永不回退 (失败进入终止态, 不回中间态)。
- 每个 release_id 全局唯一, 一旦 manifest_accepted 后 manifest digest 不可变 (§2.5 sealing)。
- target dist (testing/production) 由 caller mTLS identity + Environment + endpoint 推导,
  client 不可通过参数覆盖。

### 4.2 API 端点契约 (每个 control plane 实例独立部署)

所有端点 mTLS; `{release_id}` 全局唯一 (§2.4)。

| Method + Path | 调用者身份 | 作用 | 关键字段 |
|---|---|---|---|
| `POST /v1/candidate-releases` | ci-build (mTLS, OIDC) | 创建 candidate release, 返回 release_id + 上传流程 | OIDC token, repo/ref/commit/run/attempt |
| `POST /v1/candidate-releases/{release_id}/manifest` | ci-build | 提交 canonical manifest, control plane 校验后签发 PUT URL | manifest JSON (§2.3) |
| `POST /v1/candidate-releases/{release_id}/finalize` | ci-build | 声明上传完成 → uploaded_pending_validation (sealed) | idempotency_key |
| `POST /v1/releases/{release_id}/publish-testing` | publish-testing (mTLS testing client) | 触发 testing publish 流程 | idempotency_key |
| `POST /v1/releases/{release_id}/promote-production` | publish-production (mTLS prod client, **仅 Environment approval**, 需 testing_validation_record) | 触发 production promotion (引用已通过 testing 的**同一个** release_id, 不重新构建/上传) | idempotency_key |
| `POST /v1/rollback` | publish-testing / publish-production (各自域) | 创建 rollback operation (§8) | target release_id/snapshot_id, idempotency_key |
| `GET /v1/releases/{release_id}` | 任意签约 client (按最小权限, §4.6) | 查询状态 | — |
| `GET /v1/rollback/{op_id}` | publish-* / deploy-* (按最小权限, 各域只读本域 op) | 查询 rollback operation 状态与 deploy plan | — |

**关键约束:**
- 端点**不接受** 任意 shell / 任意 aptly 参数 / 任意文件路径 / 任意 GPG 参数。
- `publish-testing` 端点在 production control plane 上**不存在** (物理隔离)。
- `promote-production` 端点在 testing control plane 上**不存在**。
- 所有写操作要求 `idempotency_key`; 相同 (release_id, op, idempotency_key) 重放返回既有结果。

### 4.3 身份模型 (mTLS + GitHub OIDC 职责分离)

```text
GitHub OIDC:
  - 用于证明 GitHub workflow / repository / ref / commit / job identity;
  - 用于 candidate release 创建、manifest 提交、upload session、testing publish request、
    production promotion request、rollback request、deploy plan read 等控制面调用;
  - 每类调用必须使用不同 audience;
  - 不同 audience 不可复用为其他 API 目的。

mTLS:
  - 用于 API transport client identity 与服务间身份;
  - 不允许把长期 mTLS client private key 作为 GitHub Secret 注入 Job;
  - 若 GitHub Job 必须使用 mTLS, client certificate 必须经 OIDC 验证后动态签发、
    短期有效、绑定 caller role / environment / audience;
  - testing 与 production 使用不同 CA / trust domain 或等价隔离的 client identity policy;
  - production endpoint 不接受 testing client identity。
```

**禁止:**
- 静态 client certificate + 静态 private key 长期存放在 GitHub Secret。
- 任何 Job 共享同一个 control plane API token。
- 同一个 OIDC token 同时用于 Sigstore、candidate API、production promotion、deploy API。
- 调用方通过请求 body 自己指定 `testing` 或 `production` target。

**target environment 推导 (多因素, 服务端):**

```text
target = f(API endpoint, OIDC audience, mTLS identity, GitHub Environment approval, caller role allowlist)
```

客户端字符串不可单独决定 target。

### 4.4 GitHub OIDC Claim Allowlist

```text
audience:    "publisher-control-plane-testing" | "publisher-control-plane-production"
iss:         "https://token.actions.githubusercontent.com"
repository:  "GentleKingson/ocserv-backport"
ref:         allowlist (main + 受保护 release tag)
workflow:    allowlist (ci-testing.yml / promote-production.yml / rollback-production.yml)
environment: 仅 promote-production/rollback-production 要求 "production" claim
```

### 4.5 testing_validation_record (testing → production promotion 正式接口)

testing validation 是 production promotion 的前置条件, 但 testing 通过的事实如何跨物理隔离
host 被 production control plane 验证, 必须定义为正式接口。

**生成者:** `control-plane-testing` 在 testing publish + testing deployment + testing smoke +
upgrade + rollback 验证全部满足后生成。

**记录字段:**

```jsonc
{
  "release_id": "...",
  "manifest_digest": "<sha256>",
  "provenance_digest": "<sha256>",
  "candidate_artifact_digest_set": ["<sha256>", ...],
  "testing_snapshot_id": "...",
  "testing_publish_revision": "...",
  "testing_validation_suite_version": "...",
  "testing_completion_timestamp": "2026-...",
  "testing_policy_result": "pass",
  "revocation_status": "active",   // active | revoked | superseded
  "signature": "<control-plane-testing signing identity>"
}
```

**约束:**
- 该记录不可被 ci-build / publish-testing job / deploy-staging job / 普通用户覆盖。
- 必须由 testing control plane 的受控 signing identity 签名。
- 存放于独立的 promotion-evidence 存储边界: 只允许 control-plane-testing 写, 只允许
  control-plane-production 读, job runner / build / deploy / 人工不可直接读写 (见 §1.4 网络)。

**production control plane 验证项:**
1. signature (来自 testing control plane signing identity);
2. release_id;
3. manifest_digest;
4. provenance_digest;
5. artifact_digest_set;
6. testing_policy_version;
7. record 未被 revoked/superseded。

**重要:** testing validation record 只是 production promotion 的**必要条件**, 不是充分授权。
production control plane 仍必须独立验证 artifact、provenance、production Environment approval、
production policy、production repository state。

**production host 不可信任:**
testing host 的 SSH 返回值 / testing workflow 成功状态 / GitHub Job log / 人工文字确认 /
未签名 JSON / testing host 本地 filesystem / testing aptly pool 或 snapshot 复制结果。

**promotion 的 release_id 同一性 (消歧):** production promotion 引用的是**同一个** candidate
release_id (即 testing 已验证的那个 release)。production host 从同一个已封存 candidate release
(R2 staging) 拉取**相同字节**的 artifact, 独立重新验证 hash/manifest/provenance/policy, 然后导入
**自己的** aptly state, 创建**自己的** production snapshot, 用**自己的** production signing subkey 签名。
**不重新构建, 不重新上传, 不接受新 manifest。** 如需重新构建, 必须创建新的 release_id 从头走流程。
testing 的 release_id 与 production 的 release_id 是同一个标识符, 但两者在各自 host 上有独立的
aptly snapshot/publish_revision/audit record (各自 host 独立导入)。

### 4.6 GET 端点的最小权限 (不能所有角色读全部 release)

```text
ci-build:           只能查询自身 OIDC identity 创建的 release; 只能读取不含敏感凭据、
                    内部路径、worker error detail 的状态摘要。
publish-testing:    只能查询 testing release 与 testing rollback operation。
publish-production: 只能查询 production promotion 与 production rollback operation。
deploy-staging:     只能读取 staging deploy plan 和必要的 package target。
deploy-production:  只能读取 production deploy / rollback plan、target package version、
                    inventory revision 与 host batch plan。
```

---

## 第 5 节: Runner Group / label / Environment / Secret 映射

| 角色 | GitHub Environment | Runner Group / label | 可调用控制面 |
|---|---|---|---|
| build | 无 production secret 的 build 环境 | `ci-build` | candidate upload API |
| testing publish | `testing` | `publish-testing` | testing publish/rollback API |
| staging deploy | `staging` | `deploy-staging` | 不调用 publish API (仅 GET deploy plan) |
| production publish | `production` | `publish-production` | production promotion/rollback API |
| production deploy | `production` 或单独 `production-deploy` | `deploy-production` | 不调用 aptly/publish API (仅 GET deploy/rollback plan) |

**保证:**
- `ci-build` 无法调用 production API。
- `publish-testing` 无法调用 production API。
- `deploy-staging` 无法调用 production API。
- `publish-production` 无法 SSH 到 production application host。
- `deploy-production` 无法调用 aptly publish/rollback API。
- production API 只接受来自受保护 production Environment 的明确身份。
- testing 与 production 使用不同 mTLS client identity 或等价的独立 workload identity。
- production publish 与 production deploy 是两个独立 Job、独立 runner、独立 credential bundle。

---

## 第 6 节: 外部 Job 身份权限矩阵

| 能力 | ci-build | publish-testing | publish-production | deploy-staging | deploy-production |
|---|---|---|---|---|---|
| 创建 candidate release + 上传 staging | ✅ (仅 OIDC + 短期精确 PUT URL, 不持长期 R2 key) | ❌ | ❌ | ❌ | ❌ |
| list/read/delete/copy/overwrite 任意 staging object | ❌ | ❌ | ❌ | ❌ | ❌ |
| 触发 testing publish | ❌ | ✅ (提交请求, publish host worker 实际执行) | ❌ | ❌ | ❌ |
| 触发 production promotion | ❌ | ❌ | ✅ (提交请求, 需 approval + testing_validation_record) | ❌ | ❌ |
| 提交 rollback operation 请求 | ❌ | ✅ (testing) | ✅ (production) | ❌ | ❌ |
| 查询 release 状态 (GET, 按最小权限 §4.6) | ✅ (自身 release) | ✅ (testing) | ✅ (prod) | ✅ (staging plan) | ✅ (prod plan) |
| aptly CLI / DB | ❌ | ❌ | ❌ | ❌ | ❌ |
| GPG signing | ❌ | ❌ | ❌ | ❌ | ❌ |
| R2 staging 拉取 | ❌ | ❌ | ❌ | ❌ | ❌ |
| R2 repo 写 | ❌ | ❌ | ❌ | ❌ | ❌ |
| CDN purge | ❌ | ❌ | ❌ | ❌ | ❌ |
| SSH staging/prod hosts | ❌ | ❌ | ❌ | ✅ staging | ✅ prod |
| ansible deploy/rollback | ❌ | ❌ | ❌ | ✅ staging | ✅ prod |
| docker daemon / socket | ❌ (job 内) | ❌ | ❌ | ❌ | ❌ |
| 自行指定 target environment / release_id / object key | ❌ | ❌ | ❌ | ❌ | ❌ |

**关键措辞:**
- "触发 testing publish / production promotion / rollback" 表述为**提交请求**,
  实际 aptly rollback / GPG signing / R2 sync / CDN purge 只发生在对应 publish host 本地 worker。
- build 上传成功不代表 artifact 已被 control plane 或 publish host 接受。

---

## 第 7 节: 基础设施服务身份权限矩阵

外部 Job 都没有 docker daemon、aptly CLI、GPG signing、R2 repo write 权限是正确的, 但本表
明确"谁负责启动 Runner 容器""谁负责执行 publish worker""谁负责推进 control plane 状态机"。

| 服务身份 / 主机 | 必须具备的能力 | 明确禁止的能力 |
|---|---|---|
| runner provisioner / runner host | 仅负责 `docker run --rm` 创建和销毁 ephemeral Runner 容器 | 不保存 aptly state / GPG key / production SSH / production R2/CDN credential; Job 不可访问 Docker socket |
| control-plane-testing | 验证 OIDC、签发 candidate upload session、维护 testing release state、接受 testing publish/rollback request、生成 testing_validation_record | 不可 SSH staging/prod application host; 不直接接受任意 shell/aptly 参数; 不接受 testing identity 之外的身份 |
| control-plane-production | 验证 production OIDC/approval、维护 production promotion 与 rollback state、验证 testing_validation_record | 不可作为 GitHub Runner; 不接受 testing identity 直接修改 production state |
| publisher-worker-testing | 本地验证 artifact、调用 testing aptly、使用 testing signing subkey、同步 testing repo、purge testing CDN | 不可访问 production host / production GPG / production R2/CDN |
| publisher-worker-production | 本地验证 artifact、调用 production aptly、使用 production signing subkey、同步 production repo、purge production CDN | 不可运行 testing workload; 不可接受 build runner shell; 不可 SSH production application host |
| deploy-staging runner | 读取已确认 deploy target, 执行 staging Ansible | 不可调用 aptly / GPG / R2 repo write / CDN purge / production API |
| deploy-production runner | 读取已确认 rollback/deploy target, 执行 production Ansible | 不可调用 aptly / GPG / R2 repo write / CDN purge / repo rollback API |
| R2 staging GC worker | 删除过期/审计保留期外的 candidate artifact | 不可删除被 promotion/rollback/incident/restore 引用的 release; ci-build 永远没有 delete 权限 |

**Docker daemon 权限例外说明:**
- runner provisioner host 可以拥有 Docker daemon, 用于创建 ephemeral Runner 容器。
- 任何 GitHub Job 容器都不可拥有 docker socket / docker CLI control path / privileged mode /
  CAP_SYS_ADMIN / 宿主机 bind mount。
- publish host、deploy host 和 Job Runner 均不以 Docker daemon 作为发布或部署控制机制。

**R2 staging 拉取权限收敛 (不泛化读):**
- publish-host-testing / publish-host-production 仅可拉取 control plane 为当前 operation 指定的
  完整 object key。
- 不可依赖 bucket listing 发现 artifact。
- 不可接受调用方传入任意 object key。
- 不可下载未绑定到已保存 manifest 的文件。
- production host 只能读取被 production control plane 标记为可进入 production verification 的
  candidate release。
- 优先采用 release-specific、短期或受控的读取授权, 而不是给 publish host 配置可任意列举、任意
  读取整个 staging bucket 的广泛 R2 credential。

---

## 第 8 节: 受控两阶段 Rollback 状态机

### 8.1 rollback 状态机

rollback 状态持久化在 control plane (production 实例), Job 超时/runner 销毁/网络中断/人工介入
后仍可恢复。

```text
requested → approval_pending → target_resolved → rollback_locked → repo_preflight
   → repo_rollback_in_progress → repo_rollback_published → repo_visibility_verified
   → host_preflight → host_rollback_in_progress → host_rollback_verified → completed
```

**失败/暂停状态:**

```text
approval_rejected
target_not_eligible
rollback_lock_conflict
repo_preflight_failed
repo_publish_failed
repo_visibility_unconfirmed
host_preflight_failed
host_rollback_partial          # repo 已回滚, 部分 host 降级失败
host_rollback_failed
health_verification_failed
compatibility_gate_failed
manual_intervention_required
```

### 8.2 Phase A: 冻结与锁定

production control plane 必须:
1. 验证调用者来自允许的 production rollback workflow。
2. 验证 production Environment approval。
3. 解析并锁定唯一的 `previous-good` target。
4. 获取 production repository rollback lock。
5. 获取 production deployment lock。
6. 暂停新的 production promotion。
7. 暂停新的 production deploy。
8. 拒绝新的并发 rollback operation。
9. 记录 rollback 开始前的 repo revision、current release、host deployment state。
10. 生成不可变 rollback plan。

**rollback lock 贯穿 repo rollback、repo visibility verification、host downgrade、最终 health verification。**
rollback 未完成期间, 不允许新的 production release 穿插。

**lock 持有者与执行层分离 (消歧):** 上述 lock 由 production control plane (编排层) 获取并持有
贯穿整个 rollback operation 的生命周期。publisher-worker (执行层) 在该 lock 保护下调 aptly 执行
repo rollback (§8.5); deploy-production runner (执行层) 在同一 lock 保护下执行 host downgrade
(§8.7)。编排层持锁推进状态机, 执行层在锁保护下做实际操作, 两者都不脱离状态机。

### 8.3 rollback target 必须是不可变的 previous-good release

rollback 不允许操作者临时输入任意版本/snapshot/package URL/shell 参数。每次 rollback 必须引用
一个已记录、已验证、不可变的 release record, 至少包含:

```text
rollback_operation_id
target_release_id
target_snapshot_id
target_publish_revision
target_distribution / target_component / target_architectures
target_package_set
target_package_versions
target_package_sha256
target_manifest_sha256
target_provenance_digest
target_repository_metadata_digest
target_ansible_playbook_revision
target_inventory_revision
```

**previous-good 严格定义:**
- 此前已完成 production publish;
- 此前已完成 production deployment;
- 所有 required health/smoke/connectivity checks 成功;
- 已经过稳定观察窗口;
- 未被标记 revoked/superseded/corrupt/incompatible;
- target snapshot、package closure、签名 metadata 均可恢复可验证;
- target release 有完整 audit record。

"最近一次成功 build""testing 通过的版本""当前 R2 目录看起来较旧的版本"都**不可**自动作为 rollback target。

### 8.4 Phase B: repo rollback preflight

production publish host 在真正修改 repository state 前必须验证:
- target snapshot 存在;
- target package closure 完整;
- target `.deb`/`.changes`/`.buildinfo`/manifest/provenance 全部可验证;
- target package metadata 与 rollback plan 一致;
- production signing capability 可用, production signing subkey 有效;
- aptly state 健康且可写;
- R2 production target 可写;
- CDN purge capability 可用;
- 当前 repository state 已被记录, 必要时可恢复;
- rollback 后 deploy runner 可从正式 production repo endpoint 下载目标 package;
- target distribution/component/architecture 与当前 production policy 一致;
- package downgrade 不违反已定义的 compatibility policy (见 §8.9)。

preflight 失败: 不修改 aptly、不同步 R2、不 purge CDN、不触发 host downgrade;
rollback 标记 `repo_preflight_failed`。

### 8.5 Phase C: repo rollback (publish host 执行)

repo rollback 由 production publish host 执行, 只能使用 control plane 已锁定的 target
snapshot/release。

**禁止:**
- 直接编辑 R2 上的 Release/Packages/InRelease 文件;
- 删除"新版本 package 文件"作为唯一回滚方法;
- 手工复制 testing host 的 pool 或 snapshot;
- 让 deploy runner 调用 aptly CLI;
- 让调用者传入任意 filesystem path / arbitrary aptly command;
- 从 build artifact 或临时 URL 直接给 production host 提供 package。

**发布顺序:**

```text
已验证 previous-good snapshot → 生成新 repository metadata → production signing subkey 签名
→ 更新 aptly publish state → 完整静态仓库同步至 production R2 → 新 Release/InRelease 成为外部可见提交标记
→ CDN purge/cache invalidation → 从独立网络位置验证 repository 可见性
```

**关键不变量:**
- package 文件、Packages index、Release、InRelease 必须形成一致集合;
- 不得出现"新 InRelease + 旧 Packages"或"旧 InRelease + 新 Packages"的混合缓存状态;
- repo rollback 结果生成新的可审计 production publish revision;
- repo rollback 完成不等于整个 rollback 完成。

### 8.6 Phase D: repo visibility verification

host downgrade 只能在 repo endpoint 已被验证为一致后开始。从 deploy runner 所在网络或等价独立
网络探针位置验证:

1. `InRelease` 或 `Release.gpg` 签名有效;
2. repository metadata 对应 target release;
3. APT policy 可解析出目标 package version;
4. target package SHA-256 与 rollback plan 一致;
5. target package 可成功下载;
6. CDN/R2 已不再返回错误版本 metadata;
7. Packages index、Release、InRelease 之间无版本/hash 不一致;
8. 多次探测稳定 (避免单次缓存命中误判)。

**验证失败:**
- 不启动 host downgrade;
- 保持 rollback lock;
- 可安全重试 R2 sync / CDN purge / visibility probe;
- 超出重试阈值进入 `repo_visibility_unconfirmed`;
- 不允许 host 从 publish host 本地路径/临时对象 URL/任意缓存目录安装旧包绕过正式 repo 验证。

### 8.7 Phase E: host downgrade (deploy runner 执行, 显式精确分批)

deploy-production Job 只能从 control plane 读取已确认 rollback plan:

```text
rollback_operation_id
target_release_id
target_package_versions
target_package_sha256
target_repository_revision
target_inventory_revision
target_ansible_playbook_revision
host_batch_plan
```

**分批策略:** canary batch → small production batch → remaining batches → fleet-wide verification。

**每台 host 执行:**
1. 读取并记录当前 package version;
2. 确认 target version 在已验证 production repo 中存在;
3. 只允许 rollback plan 白名单列出的 package 和 version;
4. 精确版本 downgrade: `apt-get install package=<target-version> --allow-downgrades`;
5. **禁止:** `apt full-upgrade` / `apt-get dist-upgrade` / 未绑定版本 install /
   wildcard package downgrade / 任意第三方 repo source 修改 / 任意用户输入 package version;
6. 安装后重新验证: 已安装 package version / metadata / service version / systemd active state /
   service port / health endpoint / connectivity / smoke test / error log / 监控指标。

**canary 失败:** 停止扩展到后续 batch, 进入 `host_rollback_partial` 或 `host_rollback_failed`,
不继续扩大影响面。

### 8.8 repo 成功、host rollback 失败的收尾语义 (最关键异常场景)

```text
当 repo rollback 已完成, 但部分 host downgrade 失败:
  repo 保持 previous-good
  host rollback 继续受控重试或人工修复
  rollback operation 不得标记 completed
  新的 production promotion / deploy 保持冻结

对应状态: host_rollback_partial (或 repo_rolled_back_hosts_pending)
```

此时:
- 成功降级的 host 保持旧版本;
- 失败 host 被明确标记为 drifted;
- 不为"让 repo 与失败 host 看起来一致"自动重新发布坏版本;
- 不自动把成功降级的 host 再升级回错误版本;
- 失败 host 触发告警;
- 可对失败 host 有限次数自动重试;
- 超过阈值转入人工事件处理;
- 控制面展示每台 host 当前版本/目标版本/失败原因/上次尝试时间/下一步动作。

**repo 保持 previous-good 的意义:** 阻止错误版本继续扩散。部分 host 暂时仍运行新版本, 是可观测
可修复的不一致; 把坏版本重新发布出去会扩大事故。

### 8.9 不可逆迁移的 compatibility gate

package downgrade 并不总是安全。host downgrade 前必须检查错误 release 是否已执行:
- 不可逆数据库 schema migration;
- 数据格式升级;
- 配置格式升级;
- persistent state migration;
- key format rotation;
- protocol version upgrade;
- incompatible filesystem migration;
- external API contract change;
- 依赖组件版本变更导致旧 binary 无法工作。

**compatibility gate 不通过:**
- repo rollback 仍可执行 (阻断错误版本扩散);
- host downgrade 不得自动执行;
- rollback operation 进入 `compatibility_gate_failed` 或 `manual_intervention_required`;
- 依据独立 incident recovery runbook 决定数据回滚/配置转换/forward fix/维护窗口/停止服务后恢复 snapshot。

不能因 repo 已回滚就盲目认为任何 host 都可安全 package downgrade。

### 8.10 最终完成条件

rollback 只有在以下全部满足时才标记 `completed`:

```text
1. production repository 已回到锁定的 previous-good release;
2. repo endpoint 已完成签名、metadata、package availability、CDN/R2 一致性验证;
3. 所有受管 production hosts 已显式安装 rollback plan 中的目标 package versions;
4. 每台 host 的 service、health、smoke、connectivity、监控验证通过;
5. 没有 drifted host、pending retry host 或未处理 compatibility exception;
6. rollback locks 已按规则释放;
7. audit record、snapshot relation、publish revision、host result、恢复材料已完整写入控制面。
```

### 8.11 每次状态转换的审计记录字段

```text
rollback operation ID
caller identity
GitHub Environment approval reference
target release / snapshot / publish revision
control plane version
publish worker version
deploy workflow run ID
inventory revision
per-host before/after version
R2 sync revision
CDN purge request ID
失败原因
retry count
transition timestamp
```

---

## 第 9 节: 审计、幂等与并发

见 §3.3 与 §8.11。核心:
- 并发锁: publish host worker 单实例串行; rollback lock 贯穿全流程 (§8.2)。
- 幂等: (release_id, op, idempotency_key) 三元组唯一; testing/production 独立 namespace。
- 审计: 每个 state 转移追加一条记录; 审计日志只追加, 存 publish host 本地 + 加密备份 (不进 R2 staging)。

---

## 第 10 节: 恢复路径汇总

| 故障 | 恢复路径 |
|---|---|
| publish host 被入侵 | §3.5: 撤销该域 subkey (不轮换 primary) + 隔离 + 从加密备份重建 host + 重新验证 R2/CDN/aptly 一致 |
| control plane 不可用 | control plane 是无状态编排层 (状态在持久 DB), 重启实例恢复; rollback operation 状态持久化, Job 超时后可恢复 |
| R2 sync 失败 | §3.4: 重试 r2 sync (幂等); 不回滚 aptly; 持续失败告警人工 |
| CDN purge 失败 | §3.4: 重试 CF purge (幂等); CDN TTL 上限自愈; 不回滚 aptly/R2 |
| GPG key 不可用 | subkey 撤销 + 用离线 primary 签新 subkey + 注入; primary 不可用时走 primary recovery (Shamir/物理分割) |
| artifact 被篡改/manifest 不匹配 | publish host 重新计算 hash, 与 canonical manifest 不一致 → 拒绝 (hash_mismatch/metadata_mismatch); 不导入 aptly |
| OIDC 验证失败 | rejected_identity; 不创建 candidate release |
| repo 成功 host 失败 | §8.8: repo 保持 previous-good, 继续修复 host, 不重新暴露坏版本 |
| compatibility gate 不通过 | §8.9: repo 可回滚, host 不自动 downgrade, 转 manual intervention |

---

## 第 11 节: 迁移策略与切换原则

### 11.1 双轨迁移原则

```text
1. 先加新路径 + 验证, 不动旧路径 (双轨)
2. 切换默认到新路径, 旧路径保留为受控 fallback
3. 验证期过后, 删除旧路径 + 旧凭据 + 旧长期 SSH material
4. 每次切换必须保留明确回退开关 (旧 workflow 或已验证 release artifact)
```

### 11.2 不可双重发布的安全约束

双轨不等于允许旧路径和新路径同时修改同一个公开 repository。

```text
1. 新路径验证初期只允许 shadow mode:
   可构建 / 可生成 manifest / 可上传 candidate / 可在隔离 testing repository 或非公开 snapshot 中验证;
   不可与旧路径同时对同一个公开 testing/production repo 执行 publish。

2. 切换默认路径时:
   必须设置单一 active publisher;
   旧路径进入受控 fallback;
   新旧路径不能并发修改同一个 aptly state、R2 repo target、CDN metadata。

3. fallback 只能在明确触发条件下启用:
   新路径发生已定义故障;
   获得对应 environment approval;
   记录 fallback reason;
   记录旧路径执行的 release/snapshot/package closure;
   fallback 完成后必须回填审计记录。

4. production migration:
   不允许"为了验证新路径"让旧生产 publish 与新生产 publish 并行写 production repository;
   必须先在 testing 完成 publish、rollback、restore、key recovery、failure handling 演练;
   production 切换前必须完成 access review、credential inventory、rollback drill、restore drill。

5. 删除旧路径的完成条件:
   旧 Runner 已注销;
   旧长期 SSH material 已撤销;
   旧 R2/CDN/GPG credential 已删除;
   旧 sbuild/host build state 已删除;
   旧 workflow 不再具有 production publish 或 deploy 权限;
   回退方案已指向新的、已验证 release artifact / controlled recovery procedure, 而不是保留永久旧系统。
```

### 11.3 实施顺序 (Phase 0 spec 描述, Phase 1-7 plan 执行)

```text
1. 完成 Phase 0 (本 spec) 双 publish host trust boundary
2. 先部署 publish-host-testing
3. 将 candidate artifact → testing publish 流程完整迁移并验证
4. 建立 testing key hierarchy、testing control plane、testing R2/CDN credential
5. 完成 testing publish、rollback、审计、恢复演练
6. 再部署 publish-host-production
7. 建立独立 production key hierarchy、production control plane、production R2/CDN credential
8. 迁移 production promotion
9. 迁移 production rollback (受控两阶段状态机)
10. 在生产切换前完成 production restore drill、key recovery drill、rollback drill、access review
11. 最后删除旧的共享 publish 路径、共享 key、共享 token、旧 Runner 访问权限
```

### 11.4 当前 workflow 的迁移映射 (Phase 0 描述目标, 不在本阶段改)

```text
ci-testing.yml 的 build job         → ci-build label (Phase 1-3)
ci-testing.yml 的 publish-testing   → publish-testing label + control plane (Phase 4)
ci-testing.yml 的 staging-upgrade   → 拆 deploy-staging (Phase 5)
promote-production.yml              → publish-production + deploy-production 拆分 (Phase 6)
rollback-production.yml             → 受控两阶段 rollback 状态机 (Phase 6)
```

---

## 第 12 节: Phase 0 范围与非目标

### 12.1 Phase 0 验收标准 (文档级, 非代码验收)

```text
□ 1. publish host 责任边界 (双 host 物理隔离)                    → §1
□ 2. 信任域网络拓扑 (4 域 + 网络策略)                            → §1.4
□ 3. aptly state/pool/DB/snapshot/publish-state/GPG 存储与备份   → §3
□ 4. control plane API 契约 (7 端点 + 状态机)                    → §4
□ 5. mTLS 认证 + GitHub OIDC 授权模型 (职责分离)                 → §4.3
□ 6. testing/staging/production 外部 Job 权限矩阵                → §6
□ 7. 基础设施服务身份权限矩阵                                    → §7
□ 8. Runner Group/label/Environment/Secret 映射                  → §5
□ 9. publish/promote 状态机                                      → §3.2, §4.1
□ 10. 受控两阶段 rollback 状态机                                 → §8
□ 11. 并发锁/幂等/审计/失败恢复                                  → §3.3, §3.4, §9, §10
□ 12. host 入侵/control plane 不可用/R2 sync 失败/CDN purge 失败/GPG 不可用恢复路径 → §10
□ 13. candidate release 数据模型 (ULID + manifest + provenance + object key + sealing) → §2
□ 14. GPG key hierarchy (primary 离线 + subkey 托管 + 轮换 + 入侵响应) → §3.1
□ 15. 外部 Job identity、service principal、host identity 三类权限已分别列出, 不存在"谁实际执行该动作"未定义的权限空洞 → §6, §7
□ 16. testing_validation_record 的生成者、签名方式、存储位置、production 验证方式、revoke/supersede 语义已定义 → §4.5
□ 17. 所有安全关键字段均无开放式 TBD:
     - OIDC issuer/audience/claim allowlist (§4.4);
     - mTLS client identity issuance/rotation/revocation (§4.3);
     - release sealing (§2.5);
     - promotion evidence (§4.5);
     - publish/rollback lock owner (§3.3, §8.2);
     - production fallback authorization (§11.2);
     - GPG key recovery owner (§3.1, §3.5);
     - R2 staging GC owner (§2.2, §7)
□ 18. 从现有 workflow 迁移原则 (每阶段双轨→切换→删旧; 禁止新旧并行写同一公开 repo) → §11
```

### 12.2 Phase 0 的明确非目标 (防止范围蔓延)

```text
Phase 0 不做 (留给后续阶段 plan):
  - 不写任何 systemd unit / Dockerfile / 控制面代码 / aptly 配置
  - 不配置 R2 bucket / CF zone / mTLS CA / OIDC application
  - 不改任何 .github/workflows/*.yml
  - 不删除现有 sbuild / bootstrap-build-host.sh / aptly-*.sh
  - 不注册新 runner / 不创建 GitHub Environment
  - 不迁移任何真实发布流量

Phase 0 唯一产出: 一份架构决策文档 (本 spec), 它是 Phase 1-7 各自 plan 的约束源
```

### 12.3 spec 自审不变量 (确认无流程违反安全原则)

```text
□ 没有任何流程要求 build runner 持有长期 R2、GPG、SSH、Cloudflare 或 Docker credential
□ 没有任何流程允许 deploy runner 修改 aptly state
□ 没有任何流程允许 testing identity 调用 production control plane
□ 没有任何流程允许 production host 信任 testing host 的本地文件或 SSH 结果
□ 没有任何流程允许 repo rollback 与 host downgrade 脱离 control plane 状态机独立推进
□ 没有任何流程允许新旧 publish 路径并行写同一公开 repository
□ 没有任何流程允许 testing 与 production 共用 GPG primary key 或 online signing subkey
□ 没有任何流程允许客户端字符串单独决定 target environment
□ 没有任何流程允许 build runner 自行指定 release_id / object key / target environment
```

---

## 附录 A: 占位符清单 (实现/执行时必须由 Phase 1-7 plan 决定)

| 占位符 | 出现位置 | 含义 | 决定阶段 |
|---|---|---|---|
| `apt-build-staging` bucket 具体参数 | §1.1, §2.2 | R2 staging backend (CORS/region/lifecycle 精确值) | Phase 4 plan |
| testing/production repo bucket 拓扑 | §1.1 | 是否物理分三个 bucket 还是同 bucket 隔离 prefix | Phase 4/6 plan |
| systemd unit 文件名/路径 | §1.3 | aptly.service / control-plane / publisher-worker 的具体 systemd 配置 | Phase 4/6 plan |
| R2 staging 读授权具体机制 | §7 | release-specific 短期 token vs 受控长期读凭据 | Phase 4 plan |
| mTLS client cert 动态签发实现 | §4.3 | 短期动态签发的具体实现 (cfssl / step-ca / 自建) | Phase 4 plan |
| subkey 轮换周期 | §3.1 | 建议值 12 个月, 具体由运维决定 | Phase 6 plan |
| promotion-evidence 存储具体实现 | §4.5 | 独立 bucket / DB 表 / 文件系统的选择 | Phase 6 plan |
| compatibility gate 检测实现 | §8.9 | ocserv 是否有不可逆迁移的检测脚本 | Phase 6 plan |

## 附录 B: 修订记录

### v1 (2026-06-21)

初始版本。基于 brainstorming 阶段逐节确认的架构决策 + 7 项评审收口要求, 形成 Phase 0
架构决策文档。核心决策: 双 publish host 物理隔离; R2 staging candidate release 数据桥;
SLSA v1 + Sigstore keyless provenance; 双 GPG hierarchy (primary 离线); 受控两阶段 rollback
状态机 (repo 先 host 后, deploy 不触发 repo rollback); mTLS + OIDC 职责分离; 双轨迁移禁止
新旧并行写同一公开 repo。
