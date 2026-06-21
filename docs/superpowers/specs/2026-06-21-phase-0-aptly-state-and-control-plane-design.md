# Phase 0：aptly 有状态发布模型与控制面边界 — 设计文档

- 状态: 已确认 v1.2 (评审 5 项阻塞收口 + 一致性修正已并入, 待 writing-plans)
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
| mTLS bootstrap | `POST /v1/session` 唯一无-client-mTLS 端点, OIDC 验证后签发 ≤10min client cert (§4.3.1) |
| candidate ingress 归属 | **仅 control-plane-testing**; production 实例不暴露 candidate create/manifest/finalize |
| OIDC 绑定 | policy matrix: workflow_ref + workflow_sha + repository_id + event_name 精确匹配, 非文件名 allowlist |
| R2 write-once | `If-None-Match: *` 条件写强制, 不依赖短期 URL + 随机 ULID |
| manifest 写入责任 | control-plane-testing 写 canonical manifest.json; build runner 只上传 artifact + provenance |
| 失败状态分类 | 永久终止态 vs 可恢复阻塞态 (持 externalization lock); r2/cdn 失败可重试非终止 |
| 外部可见性提交 | 受控分阶段算法 (pool→metadata→InRelease 最后), 禁止裸 rclone sync 作为发布事务 |
| Sigstore trust root | publish host 本地受控 trust bundle, 不来自 R2; 禁 --insecure-ignore-tlog |
| promotion evidence key | 独立于 APT GPG subkey; append-only revoke/supersede; freshness + generation 校验 |
| deployment result 反馈 | GET plan + POST result 端点; deploy runner 只读 immutable plan + 提交绑定结果, 不自行完成 operation (§4.7) |
| candidate retention ledger | 跨域中立 append-only 账本; GC fail-closed, 无未过期 production lease 才删 (§2.7) |
| externalization 状态顺序 | published→objects→verified→metadata→inrelease→r2_synced→cdn_purged→visibility_verified→completed (§3.2) |
| bootstrap role mapping | OIDC identity 必须唯一映射到已批准 role, 否则拒绝签发 cert; bootstrap audience 按 trust domain 拆分 (§4.3.1, §4.4) |
| idempotency 分类 | 按端点类型区分键维度, 非统一三元组; idempotency_key 不进 manifest (§4.8) |
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
| **control-plane-testing/production** | API 网关+鉴权+状态机编排 | 本域受限 issuing intermediate CA (root CA 离线)、staging R2 读 token | FastAPI/Go HTTP (mTLS, bootstrap 端点见 §4.3.1) | 执行任意 shell/aptly 参数 |
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
   │ 1. 使用 GitHub OIDC 请求 upload session; 提交 manifest content 给 control-plane-testing
   ▼
publisher control plane (仅 control-plane-testing; candidate ingress 在 production 实例上不存在)
   │
   │ 2. 校验 workflow identity (OIDC claims), 登记 candidate release, 生成 release_id
   │ 3. 验证并 canonicalize manifest content, 写入权威 manifest.json (build runner 不写 manifest)
   │    为该 release 的每个 artifact/provenance 签发短期精确 PUT URL
   ▼
R2 staging bucket / incoming prefix (apt-build-staging, 私有, 无公开端点)
   │
   │ 4. build runner 上传 .deb / .changes / .buildinfo / provenance.sigstore.json
   │    (manifest.json 由 control-plane-testing 自己写入, 非 build runner 上传 — §2.2)
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
1. **candidate ingress 只存在于 control-plane-testing。** ci-build 永远只调
   control-plane-testing 的 candidate create / manifest / finalize; control-plane-production
   **不暴露**这些端点, 不接受 ci-build identity, 不为 build runner 签发 staging upload session。
   production promotion 的唯一输入是: 同一个 sealed release_id + canonical manifest digest +
   artifact digest set + provenance bundle + testing_validation_record; production control plane
   从 R2 staging 读取同一 candidate artifact, 独立验证后导入自己的 aptly state (§4.5 promotion
   release_id 同一性)。build 域绝不直接触及 production control plane。
2. R2 staging 只承载候选构建产物, 不承载 aptly state。
3. staging bucket 与 testing/production repository 必须逻辑/凭据隔离。
4. build runner 只能写入自己的临时 release prefix (由 control plane 生成的 release_id)。
5. build runner 不能 list / read / delete / copy / overwrite 其他 release 的对象, 也不可读取
   自己已上传的对象 (除非 control plane 明确短期只读调试授权)。
6. build runner 不持长期 R2 / CF / aptly / GPG / publish-host SSH 凭据。
7. publish host 不信任 object key / 文件名 / manifest 内容 / build runner 声明本身, 必须重新验证。
8. publish host 不直接从 GitHub Artifact 取待发布 package; GitHub Artifact 可继续用于 CI job 间
   测试传递, 但不是 build→publish 的正式信任桥。

### 2.2 R2 staging 存储布局与生命周期

**独立私有 bucket:** `apt-build-staging` (与 testing/production repo bucket / backup / log bucket 物理或逻辑隔离)。

**对象布局:**

```text
incoming/v1/
  <release_id>/                          # ULID, control plane 生成
    manifest.json                        # canonical manifest (由 control-plane-testing 写入, 非 build runner)
    provenance.sigstore.json             # Sigstore verification bundle (build runner 上传)
    artifacts/
      0001.deb                           # object key basename = artifact_id + 扩展名, 与 Debian 原始文件名解耦
      0002.changes
      0003.buildinfo
```

**object key vs logical filename (消歧, 不再混为同一字段):**
- object key basename 形如 `<artifact_id>.<ext>` (例 `0001.deb`), 是 R2 寻址用的内部标识。
- Debian 原始文件名 (例 `ocserv_1.5.0-1~bpo13+1_amd64.deb`) 是 manifest 中的 `logical_filename`,
  是 aptly 导入时用的真实包名, 与 object key basename 解耦。
- manifest 的每个 artifact 必须同时声明 `artifact_id`、`object_key`、`logical_filename`、
  `kind`、`sha256`、`size` (见 §2.3 manifest schema)。
- control plane 用 `artifact_id` 生成 object key; publish host 用 object_key 从 R2 拉取,
  用 logical_filename + sha256 验证后导入 aptly。

**object key 规则:**
- `<release_id>` 必须由 control plane 生成 (§2.4), build runner 不可指定。
- artifacts 的 object_key 由 control plane 根据 manifest 声明的 artifact_id 生成; build runner
  不可自行指定 object key。
- 拒绝 `..` / 绝对路径 / 控制字符 / 非批准扩展名 (白名单: `.deb .changes .buildinfo`)。

**canonical manifest 的写入责任:**
- `manifest.json` 由 **control-plane-testing** 写入 staging (build runner 提交 manifest 内容,
  control plane 校验通过后由自己写入权威字节); build runner 不直接上传 `manifest.json`。
- build runner 只上传: 正式 artifact (.deb/.changes/.buildinfo) 与 `provenance.sigstore.json`。
- 这样 canonical manifest 的权威字节只来自 control plane, 不来自 build runner 的第二次上传,
  消除"build runner 篡改已固化 manifest"的可能。

**Write-once 强制 (R2 层, 不依赖短期 URL + 随机 ULID):**
每个 artifact upload URL 必须:
- 精确绑定完整 object key (不可上传到其他路径);
- 仅允许 PUT (不可 GET/DELETE/COPY);
- 绑定 `If-None-Match: *` (R2/S3 条件写, 对象已存在则拒绝, 真正 write-once);
- 绑定 `Content-Type`;
- 绑定 `Content-MD5` 或等价上传完整性头;
- 有短有效期;
- 只能写一次;
- finalize 后立刻失效。
若发生重复 PUT、overwrite、checksum 不匹配、对象不存在或大小不匹配, release 必须失败。
`If-None-Match: *` 的强制签名必须在 Phase 4 集成测试中验证生效。

**生命周期策略 (spec 写死阈值, GC 身份明确):**
- candidate artifact 创建后 24h 内未 finalize → expired, 可 GC。
- finalize 后 72h 内未 publish → expired, 可 GC。
- publish 成功后的 artifact 保留期由 `promotion_eligible_until` 驱动 (见 §2.6), 不再用固定
  30 天; 必须至少覆盖 testing 验证、稳定观察、production approval、promotion eligibility、
  rollback / incident 取证窗口。
- GC 执行身份: publish host 上的专用 GC worker (systemd timer), **ci-build 永远没有 delete 权限**。
- GC 不可删除仍被 production promotion / rollback / incident investigation / restore drill 引用的 release
  (GC worker 查询 control plane 的引用计数)。

### 2.3 Manifest 与 Provenance

**Canonical JSON manifest (字段固定顺序, digest 可复算; 由 control-plane-testing 写入 staging):**

```jsonc
{
  "schema_version": 1,
  "release_id": "01J...",              // control plane 生成, ULID (§2.4)
  "repository": "GentleKingson/ocserv-backport",
  "source": {
    "commit": "<40-hex sha>",
    "ref": "refs/heads/main",
    "workflow_ref": "GentleKingson/ocserv-backport/.github/workflows/ci-testing.yml@refs/heads/main",
    "run_id": "...", "run_attempt": "...",
    "lock_tsv_digest": "<sha256>"       // source-lock/*.lock.tsv 的 digest, 身份闭环
  },
  "builder": { "image_digest": "sha256:..." },   // trixie builder image digest
  "packages": [
    {
      "name": "ocserv", "version": "1.5.0-1~bpo13+1",
      "arch": "amd64",
      "artifacts": [
        { "artifact_id": "0001", "kind": "deb",
          "object_key": "incoming/v1/<release_id>/artifacts/0001.deb",
          "logical_filename": "ocserv_1.5.0-1~bpo13+1_amd64.deb",
          "sha256": "...", "size": 12345 },
        { "artifact_id": "0002", "kind": "changes",
          "object_key": "incoming/v1/<release_id>/artifacts/0002.changes",
          "logical_filename": "ocserv_1.5.0-1~bpo13+1_amd64.changes",
          "sha256": "...", "size": 1234 },
        { "artifact_id": "0003", "kind": "buildinfo",
          "object_key": "incoming/v1/<release_id>/artifacts/0003.buildinfo",
          "logical_filename": "ocserv_1.5.0-1~bpo13+1_amd64.buildinfo",
          "sha256": "...", "size": 1234 }
      ]
    }
  ],
  "build_timestamp": "2026-06-21T12:00:00Z"
}
```

> `idempotency_key` 不在此 manifest 中 — 它是 API 请求控制字段, 在 control plane 状态库记录,
> 不属于 build artifact identity (否则重试会影响 manifest digest / SLSA subject / evidence 稳定性, §4.8)。
> `artifact_id` 是 control plane 分配的内部序号 (0001, 0002...), 驱动 object key basename;
> `logical_filename` 是 Debian 原始文件名, aptly 导入时用; `kind` 是 deb/changes/buildinfo,
> 约束 Sigstore subject 必须覆盖的种类。三者解耦, 不再混为单个 `filename` 字段。

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

**Sigstore / SLSA 信任根与验证不变量 (publish host 验证侧):**
- publish host 使用**本地受控、版本化的 Sigstore trust bundle** (Fulcio root + Rekor key +
  CT log roots), 由运维经离线受控通道更新; **trust bundle 不得来自 R2 staging artifact**,
  不允许运行时从 candidate bundle 读取或更新 trust root。
- **不允许** `--insecure-ignore-tlog` 或任何跳过 transparency log 校验的选项。
- 必须验证: Fulcio chain、Rekor inclusion proof、issuer (`https://token.actions.githubusercontent.com`)、
  **exact** certificate identity (含完整 workflow 路径 + ref)。
- 必须验证 **exact signer identity ↔ allowed `builder.id` pair** (predicate 中的 builder.id
  必须匹配 control plane 配置的允许值)。
- **DSSE subject 必须直接覆盖:** canonical `manifest.json` 的 SHA-256 + 每个 `.deb` + 每个
  `.changes` + 每个 `.buildinfo` 的 SHA-256。任一 subject 缺失 → provenance_invalid。
- provenance bundle **不覆盖自身**, 不形成循环 (bundle 的签名不把 bundle 自身列为 subject)。

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
- **write-once 在 R2 层强制**: 每个 PUT URL 绑定 `If-None-Match: *` (§2.2), 对象已存在则拒绝;
  不依赖短期 URL + 随机 ULID 的"难以猜测"作为唯一保护。
- 如需重新构建, 必须创建新的 release_id。
- 同一 release_id 不得绑定不同 manifest。
- 同一 manifest 不得复用于不同 release_id (除非有显式审计化的 deduplication policy)。
- publish host 必须对下载后的实际字节重新计算 SHA-256。
- 最终导入 aptly 的文件必须同时匹配: (1) control plane canonical manifest;
  (2) SLSA provenance subject; (3) publish host 下载后实际文件 hash。三者一致才导入。

### 2.6 Artifact retention (`promotion_eligible_until` 驱动, 非固定天数)

固定 30 天 retention 无法覆盖所有场景 (testing 验证长、production approval 等待、rollback/incident
取证)。改为 `promotion_eligible_until` 驱动:

```text
candidate artifact retention = max(
  finalize 后 72h (基本 publish 窗口),
  promotion_eligible_until (该 release 仍可被 production promote 的截止时间),
  rollback / incident 取证保留期 (默认 90 天, 可被 incident hold 延长)
)
```

GC worker 删除前必须确认: 该 release 未被任何 testing_validation_record、production promotion、
rollback target、active incident hold 引用。ci-build 永远没有 delete 权限 (§2.2)。

### 2.7 Candidate retention ledger (跨 testing/production 域的中立保留账本)

**问题:** §2.6 要求 GC 删除前确认 candidate release 未被 production promotion/rollback/incident
引用, 但 control-plane-testing 与 control-plane-production 物理隔离 (§1.2), production host 不可
访问 testing host, promotion-evidence 存储只允许 testing 写 / production 读。因此 testing-side GC
仅看 testing control plane 时, 可能删除 production 正在拉取或即将 promote 的 sealed candidate
artifact — 没有权威、跨域、不可伪造的地方能回答"该 candidate 是否正被 production 引用"。

**candidate-retention-ledger (与 promotion-evidence 分开的、最小化中立账本):**

```text
写入者 (受限, 各域独立签名身份):
  control-plane-testing:
    candidate-created、testing-validation、promotion-eligible lease
  control-plane-production:
    production-promotion-started、promotion-reference、rollback-reference、
    lease-renewal、lease-release

读取者:
  GC worker: 仅读取并验证所有 signed lease / reference

禁止直接读写:
  ci-build、publish Job、deploy Job、人工用户

所有 record:
  append-only、签名、write-once、带 expires_at
```

**GC fail-closed 语义:** GC worker 删除 candidate artifact 前, 必须读取 retention ledger;
ledger 不可读、任一 signature 无效、状态不完整、或有未过期的 production lease/reference 时,
**禁止删除** (fail closed, 宁可保留不可删)。

**域隔离不变量:** production control plane 不需要获得 testing publish 权限, 不接触 testing aptly
state; 它只需对自身正在使用的 candidate release 写入一个受限、签名的 retention lease。testing
control plane 不读 production 的 lease 内容细节, 只让 GC worker 验证签名有效性 + 未过期。

ledger 的具体存储实现 (独立 bucket / DB 表 / 文件系统) 见附录 A (Phase 6 plan 决定), 但其
访问控制契约本节写死。

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
        │               检查点: publish list 含 dist → Release/InRelease 已签 (aptly local)
        │               ★ 此刻 aptly local state 已提交, 但 R2/CDN 还未更新 ★
        ▼
[externalizing_objects] 受控分阶段外部提交算法 (§3.2.1) step 1-2: 上传 pool 对象 + 重新下载校验
        ▼
[r2_objects_verified]   step 2 完成: 每个 pool 对象 sha256 与 local expected 一致
        ▼
[metadata_staged]       step 3-4: 上传 Packages/Packages.gz/Release/Release.gpg + 验证 closure 完整
        ▼
[inrelease_committed]   step 5: 最后上传 InRelease 作为外部可见提交标记
        ▼
[r2_synced]             step 6: R2 端对象集合一致 (不含 CDN 可见性)
        │               ★ 可恢复阻塞态 r2_sync_pending / r2_sync_retrying (§3.4), 非终止态 ★
        ▼
[cdn_purged]            step 7: CF purge API 已接受请求 (仅表示 purge 请求成功, 非外部一致性确认)
        │               ★ 可恢复阻塞态 cdn_visibility_pending / cdn_visibility_retrying ★
        ▼
[external_visibility_verified]  step 8: 从独立 probe 验证 InRelease/Release/Packages/package bytes
        │               externalization lock 持续到此状态成功 (§3.2.2)
        ▼
[completed]             step 9-10: channel_state_record_update(current/previous-good) ← 最后才写
                        审计日志: release_id + snapshot + publish_revision +
                                  r2_sync_revision + cdn_purge_id + probe_result + result
```

**事务不变量:**
- `cdn_purged` 仅表示 purge API 接受请求, **不等于**外部一致性已确认; `completed` 依赖
  `external_visibility_verified`, 不只依赖 CDN API 返回成功。
- externalization lock (§3.2.2) 必须保持到 `external_visibility_verified` 成功为止。
- aptly local state 提交 (`published`) 与 R2/CDN 更新**不是原子事务**——这是 aptly + R2 架构的
  固有事实, spec 显式承认并提供恢复路径 (§3.4)。
- channel state record (current/previous-good, 原名 `manifest_update`, 改名以避免与 candidate
  `manifest.json` 混淆) **只在 `completed` 时写**, 中途任何失败都不更新——这保证 previous-good
  始终指向"确定成功发布过"的状态, 是 rollback 的根基。
- 审计日志每步追加, 不覆盖。

### 3.2.1 外部仓库可见性提交算法 (禁止裸 rclone sync 作为发布事务)

不带顺序、可能删除对象的通用 `rclone sync /var/aptly/public/<channel>/ → R2` **不是** repository
externalization 事务本身——它最多是受控分阶段同步中的实现工具。裸 sync 会让 APT 客户端看到
"新 InRelease + 旧 Packages"或"删除了仍被引用的旧 package"等不一致状态。

**受控分阶段外部提交算法 (worker 在 `externalizing_objects`..`external_visibility_verified` 状态执行;
步骤号与 §3.2 状态机一一对应):**

```text
1. 上传不可变 package / pool objects (按 sha256 命名或保持 aptly pool 路径);
   → 状态 externalizing_objects
2. HEAD 或重新下载校验每个对象与 local expected hash 一致 (上传后立即验证, 不信任上传成功返回值);
   → 状态 r2_objects_verified
3. 上传 Packages / Packages.gz / Release / Release.gpg 等 metadata (非 InRelease; 注意: Release
   必须包含, 它是 InRelease 的 detached 签名对应物, 部分 client 依赖它);
   → 状态 metadata_staged
4. 再次验证 metadata 引用的 package closure 已全部存在于 R2 (无悬空引用);
   → 仍在 metadata_staged, closure 校验通过才进下一步
5. 最后上传 / 覆盖 InRelease 作为外部可见提交标记 (InRelease 是 client 解析的入口, 必须最后落盘);
   → 状态 inrelease_committed → r2_synced
6. r2_synced 标记: R2 端对象集合一致 (此时尚未含 CDN 可见性);
7. CF purge CDN (<channel>/dists/*);
   → 状态 cdn_purged (仅 purge API 接受请求)
8. 从独立 probe (非 publish host 自身网络) 验证: InRelease 签名有效、Release 有效、
   Packages 与 target closure 一致、package bytes 可下载且 sha256 匹配;
   → 状态 external_visibility_verified (externalization lock 持续到此成功)
9. 更新 channel_state_record (current / previous-good);
10. → 状态 completed
```

旧 package / pool object 不得由常规 sync 立即删除; 旧对象只能由 retention / GC (§2.6) 在确认
没有已发布 metadata、rollback target 或仍活跃 client 引用后删除。

**不变量:**
- package 文件、Packages index、Release、InRelease 必须形成一致集合; 不得出现混合缓存状态。
- InRelease 必须最后提交; 在它落盘前, client 即使拿到新 Packages 也无法通过 InRelease 校验,
  从而不会安装半成品。
- `cdn_purged` 仅表示 purge API 接受请求; 外部一致性由 step 8 独立 probe 确认
  (`external_visibility_verified`)。
- 旧对象删除由独立 GC (§2.6) 负责, 不在 publish 事务里; publish 事务只增不删 (除 InRelease 覆盖)。

### 3.2.2 Externalization 事务锁不变量 (防止并发 publish 导致状态脱节)

同一 channel 存在未完成的 externalization transaction 时 (状态处于 `published`..`external_visibility_verified`
之间, 含所有可恢复阻塞态 `r2_sync_*` / `cdn_visibility_*` / `manual_intervention_required`), 必须满足:

```text
- 不允许新的 publish (同 channel);
- 不允许新的 promote;
- 不允许新的 rollback 覆盖该状态;
- 不允许 worker 启动下一个 snapshot/publish switch;
- 只能恢复、重试、人工确认或明确 abort 当前 transaction。
```

否则会出现: release A 已在 aptly local publish → R2 sync 失败 → release B 被允许开始 →
R2 最终外部可见内容与 local aptly snapshot、channel state record、审计记录脱节。

### 3.3 并发锁 (跨 ephemeral 容器的串行化)

```text
锁机制: publish host 上的 publisher-worker.service 是单实例 (或受 systemd/DB advisory lock 保护)
       → control plane 收到 publish/rollback 请求后排队, worker 一次只处理一个发布事务
       → 天然串行, 不依赖跨容器 flock

幂等: 按端点类型区分 (§4.8), 不统一用单一三元组:
      session=(issuer,jti,audience,nonce); candidate-create=(caller_id,op,idempotency_key);
      manifest/finalize/publish/promote=(release_id,op,idempotency_key);
      rollback=(caller_id,target,op,idempotency_key); deployment result=(op_id,batch_id,run_id,run_attempt,idempotency_key)
      testing 与 production 各自独立 idempotency namespace (不同 host)

审计: 每个 state 转移写一条审计记录 (release_id, from_state, to_state, ts, caller_identity, result)
      → 审计日志只追加, 存 publish host 本地 + 加密备份 (不进 R2 staging)
```

### 3.4 失败状态分类: 永久终止态 vs 可恢复阻塞态

失败状态分两类, 避免"终止态可重试"的矛盾 (§4.1 状态机一致):

**永久失败 / 拒绝终止态 (不可恢复, 需新建 release 重来):**

```text
rejected_identity / rejected_manifest / provenance_invalid / policy_rejected /
hash_mismatch / metadata_mismatch / target_not_eligible / compatibility_gate_failed /
aptly_import_failed / snapshot_failed / publish_failed / expired
```

**可恢复阻塞态 (transaction 仍持有 externalization lock, §3.2.2, 可重试到 completed):**

```text
upload_incomplete          # finalize 前对象未齐
r2_sync_pending            # externalizing 中, 等待 R2
r2_sync_retrying           # R2 sync 失败, 自动重试中 (非终止)
cdn_visibility_pending     # 等待 CDN purge + probe
cdn_visibility_retrying    # purge/probe 失败, 自动重试中 (非终止)
manual_intervention_required  # 重试超阈值, 转人工 (transaction 仍持锁)
host_rollback_partial      # rollback 专用 (§8.8)
```

**失败恢复矩阵 (按失败点):**

| 失败点 | 状态类 | aptly local | R2 | CDN | channel state record | 恢复动作 |
|---|---|---|---|---|---|---|
| aptly import/snapshot/publish 失败 | 永久终止 (`*_failed`) | 未提交或回滚 | 未变 | 未变 | 未变 | 新建 release 重来; aptly local 若半提交, worker 用 snapshot/publishRevision 回滚到上一稳定 publish |
| **publish 成功, R2 sync 失败** | 可恢复 (`r2_sync_retrying`) | **已提交** | **旧** | 旧 | 未变 | worker 重试 externalization 算法 (§3.2.1, 幂等); 持锁期间禁止新 publish (§3.2.2); 超阈值转 `manual_intervention_required` |
| **R2 sync 成功, CDN purge/probe 失败** | 可恢复 (`cdn_visibility_retrying`) | 已提交 | 已新 | **旧缓存** | 未变 | worker 重试 CF purge + probe (幂等); CDN TTL 上限自愈; 持锁禁止新 publish; 超阈值转人工 |
| 全部成功后客户端报错 | `completed` | 新 | 新 | 新 | 新 | 走 rollback (§3.6) |

**核心原则:**
- aptly local publish 一旦成功, **绝不**因 R2/CDN 失败而回滚 aptly——aptly local state 是后续
  所有 publish/snapshot/rollback 的根基, 回滚它会破坏状态机。R2/CDN 是派生态, 靠重试 + TTL 自愈。
- R2/CDN 失败进入**可恢复阻塞态**(持锁), 不是终止态; 同一 release 仍可推进到 `completed`。
- externalization lock (§3.2.2) 在可恢复阻塞态期间持续持有, 阻止新 publish 造成状态脱节。
- channel state record 只在 `completed` 写; 可恢复阻塞态期间不写, 保证 previous-good 不被半成品污染。

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
                        ┌──────── GitHub OIDC 身份校验 (§4.4 policy matrix) ─────┐
                        │                                                          │
created ──► manifest_accepted ──► upload_authorized ──► uploaded_pending_validation
   │              │                                          │
   │              │                                     (finalize, sealed §2.5)
   │              │                                          │
rejected_   rejected_                                    downloaded ──► verified ──► quarantined
identity    manifest                                                       │              │
                                                                     hash_mismatch   metadata_mismatch
                                                                     provenance_invalid
                                                                                      │
                                                                                      ├─► approved_for_testing
                                                                                      │     ──► imported_to_aptly
                                                                                      │     ──► snapshot_created
                                                                                      │     ──► published (aptly local, §3.2)
                                                                                      │     ──► externalizing (§3.2.1)
                                                                                      │     ──► r2_synced / cdn_purged
                                                                                      │     ──► completed
                                                                                      └─► approved_for_production
                                                                                            (同链路, 需 testing_validation_record
                                                                                             + Environment approval, §4.5)
```

**状态分类 (与 §3.4 一致):**

```text
永久终止态 (不可恢复):
  completed | rejected_identity | rejected_manifest | provenance_invalid | policy_rejected |
  hash_mismatch | metadata_mismatch | missing_object | target_not_eligible |
  compatibility_gate_failed | aptly_import_failed | snapshot_failed | publish_failed | expired

可恢复阻塞态 (持 externalization lock §3.2.2, 可重试到 completed):
  upload_incomplete | r2_sync_pending | r2_sync_retrying |
  cdn_visibility_pending | cdn_visibility_retrying | manual_intervention_required |
  host_rollback_partial (rollback 专用, §8.8)
```

**状态机不变量:**
- 单调前进, 永不回退到上游状态; 失败进入终止态或可恢复阻塞态, 不回中间已通过态。
- 每个 release_id 全局唯一, 一旦 manifest_accepted 后 manifest digest 不可变 (§2.5 sealing)。
- target dist (testing/production) 由 caller mTLS identity + Environment + endpoint 推导,
  client 不可通过参数覆盖。
- **状态持久化语义:** control plane 应用进程可替换 (无状态编排层), 但 release / rollback state
  必须存在持久数据库中; Job 超时、runner 销毁、进程重启后状态可恢复, 不丢失。

### 4.2 API 端点契约 (每个 control plane 实例独立部署)

所有业务端点要求 mTLS (client certificate 经 §4.3 bootstrap 协议动态签发); 唯一例外是
bootstrap 端点本身 (仅 server TLS)。`{release_id}` 全局唯一 (§2.4)。

| Method + Path | 调用者身份 | 作用 | 关键字段 |
|---|---|---|---|
| `POST /v1/session` | Job (仅 server TLS, 无 client mTLS; OIDC 唯一凭证; 必须能唯一映射到一个已批准 role, 否则拒绝) | bootstrap: 验证 OIDC 后签发短期 mTLS client certificate (§4.3.1) | OIDC JWT, CSR/一次性公钥, nonce |
| `POST /v1/candidate-releases` | ci-build (mTLS, OIDC; **仅 control-plane-testing 暴露此端点**) | 创建 candidate release, 返回 release_id + 上传流程 | OIDC token, repo/ref/commit/run/attempt, idempotency_key |
| `POST /v1/candidate-releases/{release_id}/manifest` | ci-build (**仅 testing**) | 提交 canonical manifest content, control plane canonicalize 后写入权威 manifest.json + 签发 PUT URL (§2.2) | manifest JSON (§2.3, 不含 idempotency_key) |
| `POST /v1/candidate-releases/{release_id}/finalize` | ci-build (**仅 testing**) | 声明上传完成 → uploaded_pending_validation (sealed) | idempotency_key |
| `POST /v1/releases/{release_id}/publish-testing` | publish-testing (mTLS testing client) | 触发 testing publish 流程 | idempotency_key |
| `POST /v1/releases/{release_id}/promote-production` | publish-production (mTLS prod client, **仅 Environment approval**, 需 testing_validation_record) | 触发 production promotion (引用已通过 testing 的**同一个** release_id, 不重新构建/上传) | idempotency_key |
| `POST /v1/rollback` | publish-testing / publish-production (各自域) | 创建 rollback operation (§8) | target release_id/snapshot_id, idempotency_key |
| `GET /v1/deployment-operations/{operation_id}/plan` | deploy-staging / deploy-production (各自域, 仅读本域 op) | 返回已冻结不可修改的 deployment/rollback plan (release_id, plan_digest, package version/sha256, inventory revision, playbook revision, batch assignment, host allowlist) | — |
| `POST /v1/deployment-operations/{operation_id}/result` | deploy-staging / deploy-production (各自域) | deploy runner 提交与 plan 精确绑定的执行结果; **不得自行标记 operation completed**; control plane 验证后推进状态机 (§4.7) | operation_id, plan_digest, batch_id, run_id, run_attempt, inventory_revision, playbook_revision, before/after version, host-level result, health result, timestamp, idempotency_key |
| `GET /v1/releases/{release_id}` | 任意签约 client (按最小权限, §4.6) | 查询状态 | — |
| `GET /v1/rollback/{op_id}` | publish-* / deploy-* (按最小权限, 各域只读本域 op) | 查询 rollback operation 状态与 deploy plan | — |

(共 11 个端点: 1 bootstrap + 3 candidate-ingress + 2 publish/promote + 1 rollback + 2 deployment plan/result + 2 GET。)

**关键约束:**
- 端点**不接受** 任意 shell / 任意 aptly 参数 / 任意文件路径 / 任意 GPG 参数。
- `candidate-releases` / `manifest` / `finalize` 三个 candidate-ingress 端点**只在
  control-plane-testing 上存在**; control-plane-production 不暴露它们, 不接受 ci-build identity
  (§2.1 关键原则 1)。
- `publish-testing` 端点在 production control plane 上**不存在** (物理隔离)。
- `promote-production` 端点在 testing control plane 上**不存在**。
- deployment plan 是 immutable 的: deploy runner 不得从请求参数指定 package、version、host、
  inventory 或 action; 只能读自身被分配的 plan 并提交绑定该 plan 的执行结果。
- deploy runner 的 result report **不得自行**把 operation 标记为 completed; control plane 验证
  全部 batch 结果后才推进状态机。
- 所有写操作要求 idempotency; 幂等键按端点类型区分 (§4.8), 不统一用单一三元组。

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
  - client certificate 经 bootstrap 协议 (§4.3.1) 动态签发, 短期有效, 绑定 caller role /
    environment / audience;
  - testing 与 production 使用不同 CA / trust domain 或等价隔离的 client identity policy;
  - production endpoint 不接受 testing client identity。

Trust-domain CA 体系 (无长期 client private key 的根基):
  - trust-domain root CA 离线保管 (与 GPG primary key 同级别保护);
  - 各 publish host 仅持有本域受限 issuing intermediate CA, 或调用独立 issuer 服务;
  - testing issuer 永远不能签 production client identity;
  - production issuer 永远不能签 testing client identity;
  - CA 私钥轮换、撤销、CRL / short-lived certificate 策略必须存在 (各 publish host 维护本域 CRL
    或 short-lived cert 过期自失效, 不依赖长期吊销分发)。
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

### 4.3.1 Bootstrap 协议 (`POST /v1/session`) — 解决 mTLS 首次身份建立的循环

**问题:** 所有业务端点要求 mTLS, 但 Job 在获得 client certificate 之前无法调用任何端点来获取
该证书。`POST /v1/session` 是打破这一循环的唯一端点。

**传输:**
- 仅该 bootstrap endpoint 允许 TLS server-authenticated、无 client mTLS。
- 不允许匿名 HTTP, 不允许跳过 server certificate verification。

**请求:**
- GitHub OIDC JWT;
- CSR 或一次性 client public key (private key 仅保留在 Job 容器 tmpfs, 用完即焚);
- request nonce;
- 不接受 caller 指定 target environment、role 或权限范围 (role 由服务端从 OIDC claims 推导)。

**服务端验证 (完整 claim 校验, 见 §4.4 policy matrix):**
- JWT signature / JWKS;
- iss、aud、exp、nbf、iat、jti;
- repository_id、repository_owner_id;
- workflow_ref、workflow_sha;
- sha (commit)、ref、ref_type;
- event_name;
- environment;
- run_id、run_attempt;
- 单次 jti / nonce 防重放 (已用过的 jti 不得二次签发);
- **OIDC identity 必须能唯一映射到一个已批准 API role** (§4.4 列出的 role 之一); 若
  workflow_ref / workflow_sha / event_name / environment / repository_id / repository_owner_id /
  audience 不能唯一映射到已批准 role, `POST /v1/session` 必须拒绝, 不签发任何 client certificate
  (防止未受信 workflow 获取证书扩大签发面与 DoS 面)。

**响应:**
- 最长 10 分钟有效的 mTLS client certificate;
- certificate SAN 绑定 release role、workflow identity、run_id、run_attempt、audience;
- certificate 不可跨 target environment 使用, 不可跨 workflow role 使用。

**之后所有业务 API (candidate create/manifest/finalize、publish、promote、rollback、GET) 均要求
该短期 mTLS client certificate。** bootstrap 端点本身不计入业务调用, 只用于身份建立。

### 4.4 GitHub OIDC Claim Policy Matrix (端点 × role × 精确 claim)

`workflow` (文件名) 不可作为唯一 allowlist 键 — GitHub OIDC 同时提供 `workflow_ref`、
`workflow_sha`、`repository_id`、`repository_owner_id`、`event_name` 等 claim; `workflow_ref`
绑定完整 workflow 路径 + ref, 才是精确绑定。bootstrap 端点 (§4.3.1) 与各业务端点共用同一
policy matrix。

| API role | audience | 精确允许条件 |
|---|---|---|
| bootstrap-testing (获取 testing trust-domain mTLS cert) | `publisher-bootstrap-testing` | repository_id 固定、repository_owner_id 固定、iss 固定; OIDC identity 必须能唯一映射到下述 testing role 之一, 否则拒绝 |
| bootstrap-production (获取 production trust-domain mTLS cert) | `publisher-bootstrap-production` | repository_id 固定、repository_owner_id 固定、iss 固定; OIDC identity 必须能唯一映射到下述 production role 之一, 否则拒绝 |
| candidate-create | `publisher-candidate-testing` | repository_id 固定、workflow_ref 精确等于 `GentleKingson/ocserv-backport/.github/workflows/ci-testing.yml@refs/heads/main`、event_name ∈ {push, workflow_dispatch}、ref=refs/heads/main、禁止 PR/fork |
| publish-testing | `publisher-publish-testing` | workflow_ref 精确绑定 testing publish workflow、testing Environment、仅允许 testing trust-domain client cert |
| rollback-testing | `publisher-rollback-testing` | workflow_ref 精确绑定 testing rollback workflow、event_name=workflow_dispatch、testing Environment、仅 testing trust-domain cert |
| promote-production | `publisher-promote-production` | workflow_ref 精确等于 `.../promote-production.yml@<受保护 ref>`、environment=production、受保护 ref/tag、Environment approval 已生效 |
| rollback-production | `publisher-rollback-production` | workflow_ref 精确等于 `.../rollback-production.yml@<受保护 ref>`、event_name=workflow_dispatch、environment=production |
| deploy-staging-read | `publisher-deploy-staging-read` | 仅 staging deploy workflow、仅 staging environment、仅 GET plan |
| deploy-staging-report | `publisher-deploy-staging-report` | 仅 staging deploy workflow、仅 staging environment、仅 POST deployment result |
| deploy-production-read | `publisher-deploy-production-read` | 仅 production deploy workflow、仅 production environment、仅 GET plan |
| deploy-production-report | `publisher-deploy-production-report` | 仅 production deploy workflow、仅 production environment、仅 POST deployment result |

**通用固定 claim (所有 role):**

```text
iss:               "https://token.actions.githubusercontent.com"
repository_id:     <GentleKingson/ocserv-backport 的 repository_id, 固定>
repository_owner_id: <固定>
```

**统一拒绝:**

```text
- pull_request / pull_request_target 触发的事件
- fork 仓库
- 未保护 branch
- 缺失 environment claim 的 production request
- workflow_ref / workflow_sha 不匹配
- 同一个 jti 被二次使用 (重放, bootstrap + 业务端点均查)
- event_name 不在该 role 的允许集内
```

**Sigstore keyless 验证 (provenance, §2.3):** 必须匹配精确的 certificate identity (含完整
workflow 路径 + ref) 与 issuer (`https://token.actions.githubusercontent.com`), 不是仅判断
"来自同一个仓库"。与上方 policy matrix 的 workflow_ref 绑定一致。

### 4.5 testing_validation_record (testing → production promotion 正式接口)

testing validation 是 production promotion 的前置条件, 但 testing 通过的事实如何跨物理隔离
host 被 production control plane 验证, 必须定义为正式接口。

**生成者:** `control-plane-testing` 在 testing publish + testing deployment + testing smoke +
upgrade + rollback 验证全部满足后生成。

**记录字段:**

```jsonc
{
  "schema_version": 1,
  "evidence_id": "<uuid>",                       // 本记录的唯一 id
  "release_id": "...",
  "manifest_digest": "<sha256>",
  "provenance_digest": "<sha256>",
  "candidate_artifact_digest_set": ["<sha256>", ...],
  "testing_snapshot_id": "...",
  "testing_publish_revision": "...",
  "testing_validation_suite_version": "...",
  "testing_policy_version": "...",               // 生成时的 policy 版本, 供 production 比对
  "issued_at": "2026-...",
  "expires_at": "2026-...",                      // freshness 上限; 过期则 production 拒绝
  "generation": 2,                               // 单调递增; supersede 时 +1
  "testing_policy_result": "pass",
  "revocation_status": "active",                 // active | revoked | superseded
  "signature": "<promotion-evidence signing key>"
}
```

**约束:**
- 该记录不可被 ci-build / publish-testing job / deploy-staging job / 普通用户覆盖。
- **必须使用独立的 promotion-evidence signing key 签名; 不得复用 testing APT repository 的 GPG
  signing subkey** (GPG subkey 是给 APT 客户端验包用的, 职责不同; evidence key 是给 production
  control plane 验 testing 通过事实用的, 信任根独立)。
- production control plane 固定 trust anchor (promotion-evidence 公钥), 不从 evidence 记录本身
  读取 trust root。
- 存放于独立的 promotion-evidence 存储边界: 只允许 control-plane-testing 写, 只允许
  control-plane-production 读, job runner / build / deploy / 人工不可直接读写 (见 §1.4 网络)。

**promotion-evidence key 生命周期:**
- 独立于 APT GPG subkey; 独立轮换、独立撤销。
- revoke / supersede 必须是新的、签名的 **append-only** record (不就地修改旧 record 的状态字段;
  追加一条新 record 标记前一条 revoked/superseded, 保留完整审计链)。
- production promotion 前**必须读取并验证最新有效 evidence** (generation 最高的 active record)。
- production **不接受**: 过期 (超过 expires_at)、已撤销、generation 过旧 (低于当前最新 active)、
  或无法确认 freshness 的 evidence。

**production control plane 验证项:**
1. signature (来自 promotion-evidence signing key, 非 APT GPG subkey);
2. evidence 未过期 (expires_at) 且为最新有效 generation;
3. release_id;
4. manifest_digest;
5. provenance_digest;
6. artifact_digest_set;
7. testing_policy_version (与 production 期望版本兼容);
8. record 未被 revoked/superseded (查 append-only 链)。

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

### 4.7 Deployment plan / result 反馈通道 (状态机闭环的必要接口)

deploy runner 执行 Ansible 后, control plane 必须能获知实际结果才能推进状态机
(testing_validation_record 依赖 testing deploy/smoke/rollback 成功; rollback 状态机依赖
per-host before/after version + health result)。`GET /v1/deployment-operations/{op_id}/plan`
+ `POST /v1/deployment-operations/{op_id}/result` 是这个闭环的唯一接口。

**deploy runner 能力边界:**
- 可读取自身已分配的 immutable deploy / rollback plan;
- 可提交与该 plan 精确绑定的 execution result;
- **不可**创建、修改、重定向或完成 publish / promote / rollback operation;
- **不可**指定 release、snapshot、package version、inventory 或 host batch。

**GET plan:**
- 仅返回已冻结、不可修改的 deployment plan (release_id、plan_digest、package version/sha256、
  inventory revision、playbook revision、batch assignment、host allowlist);
- deploy runner 不得从请求参数指定 package、version、host、inventory 或 action。

**POST result — control plane 必须验证:**
1. report 来自对应 mTLS role (deploy-staging / deploy-production, 各自 trust domain);
2. report 来自对应 OIDC workflow (§4.4 policy matrix);
3. report 的 operation_id 属于该 caller 被分配的 operation;
4. report 的 batch_id 属于该 caller 被分配的 batch;
5. report 的 plan_digest 与 control plane 冻结的 plan 一致 (防 plan 篡改);
6. report 的 inventory_revision / playbook_revision 与 plan 一致;
7. idempotency: (operation_id, batch_id, run_id, run_attempt, idempotency_key) 唯一 (§4.8)。

**关键:** deploy runner 的 report **不得自行**把 operation 标记为 completed; control plane 验证
全部 batch 结果 (per-host before/after version + health/smoke/connectivity) 后, 才推进状态机
(testing → 生成 testing_validation_record; rollback → host_rollback_verified)。

### 4.8 Idempotency 键分类 (按端点类型, 不统一用单一三元组)

不同端点的幂等键维度不同 (session 与 candidate-create 无 release_id):

```text
session (POST /v1/session):
  (issuer, jti, audience, nonce) 防重放;
  jti 至少保留到 exp + clock-skew 后才可清理。

candidate-create (POST /v1/candidate-releases):
  (caller immutable identity, operation, idempotency_key);
  重放返回同一个 release_id。

manifest / finalize / publish / promote:
  (release_id, operation, idempotency_key)。

rollback (POST /v1/rollback):
  (caller identity, target release_id 或 snapshot_id, operation, idempotency_key)。

deployment result (POST /v1/deployment-operations/{op_id}/result):
  (operation_id, batch_id, run_id, run_attempt, idempotency_key)。
```

> 注意: `idempotency_key` 是 API 请求控制字段, **不属于 build artifact identity**, 因此已从
> canonical `manifest.json` (§2.3) 中移除 — 否则重试策略会影响 manifest digest、SLSA subject、
> promotion evidence 的稳定性。candidate-create 的 idempotency_key 在 control plane 状态库中
> 记录, 不进 manifest。

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
| R2 staging GC worker | 删除过期/审计保留期外的 candidate artifact; 删除前必须读 candidate-retention-ledger (§2.7) 验证无未过期 production lease | 不可删除被 promotion/rollback/incident/restore 引用的 release; ledger 不可读/signature 无效/lease 未过期时 fail closed 禁止删除; ci-build 永远没有 delete 权限 |

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
- 幂等: 按端点类型区分键维度 (§4.8); testing/production 独立 namespace。
- 审计: 每个 state 转移追加一条记录; 审计日志只追加, 存 publish host 本地 + 加密备份 (不进 R2 staging)。

---

## 第 10 节: 恢复路径汇总

| 故障 | 恢复路径 |
|---|---|
| publish host 被入侵 | §3.5: 撤销该域 subkey (不轮换 primary) + 隔离 + 从加密备份重建 host + 重新验证 R2/CDN/aptly 一致 |
| control plane 不可用 | control plane 应用进程可替换 (无状态编排层), 但 release/rollback state 在持久 DB; 重启实例恢复; rollback operation 状态持久化, Job 超时后可恢复 (§4.1) |
| R2 sync 失败 | §3.4: 可恢复阻塞态 (r2_sync_retrying, 持 externalization lock §3.2.2); 重试 externalization 算法 (§3.2.1); 不回滚 aptly; 超阈值转 manual_intervention_required |
| CDN purge/probe 失败 | §3.4: 可恢复阻塞态 (cdn_visibility_retrying); 重试 CF purge + probe; CDN TTL 上限自愈; 不回滚 aptly/R2; 超阈值转人工 |
| GPG key 不可用 | subkey 撤销 + 用离线 primary 签新 subkey + 注入; primary 不可用时走 primary recovery (Shamir/物理分割) |
| promotion evidence key 不可用 | 独立于 APT GPG subkey; 用 testing primary 签新 evidence subkey; production trust anchor 更新 |
| artifact 被篡改/manifest 不匹配 | publish host 重新计算 hash, 与 canonical manifest 不一致 → 永久终止态 (hash_mismatch/metadata_mismatch); 不导入 aptly, 需新建 release |
| OIDC 验证失败 | rejected_identity (永久终止); 不创建 candidate release |
| Sigstore/provenance 验证失败 | provenance_invalid (永久终止); trust root 来自本地不来自 R2 (§2.3) |
| repo 成功 host 失败 | §8.8: repo 保持 previous-good, 继续修复 host, 不重新暴露坏版本 |
| compatibility gate 不通过 | §8.9: repo 可回滚, host 不自动 downgrade, 转 manual intervention |
| GC 误判 / ledger 不可读 / lease 状态不完整 | §2.7: GC fail closed; ledger 不可读、signature 无效或有未过期 production lease 时禁止删除 candidate; 宁可保留不可删 |
| candidate retention ledger 写入失败 | production promotion/rollback 仍可进行 (ledger 是 GC 的前置, 非 publish 的前置); 但 GC 暂停删除直到 ledger 恢复并验证 |

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
□ 4. control plane API 契约 (11 端点含 bootstrap + deployment plan/result + 状态机)        → §4
□ 5. mTLS 认证 + GitHub OIDC 授权模型 (职责分离 + bootstrap 协议 §4.3.1) → §4.3
□ 6. testing/staging/production 外部 Job 权限矩阵                → §6
□ 7. 基础设施服务身份权限矩阵                                    → §7
□ 8. Runner Group/label/Environment/Secret 映射                  → §5
□ 9. publish/promote 状态机 + 外部可见性提交算法 (§3.2.1) + visibility_verified 闭环 → §3.2, §4.1
□ 10. 受控两阶段 rollback 状态机                                 → §8
□ 11. 并发锁/幂等(分类§4.8)/审计/失败恢复 (含 externalization lock §3.2.2) → §3.3, §3.4, §9, §10
□ 12. host 入侵/control plane 不可用/R2 sync 失败/CDN purge 失败/GPG 不可用/evidence key 不可用恢复路径 → §10
□ 13. candidate release 数据模型 (ULID + manifest + provenance + object key + sealing + write-once) → §2
□ 14. GPG key hierarchy (primary 离线 + subkey 托管 + 轮换 + 入侵响应) → §3.1
□ 15. 外部 Job identity、service principal、host identity 三类权限已分别列出, 不存在"谁实际执行该动作"未定义的权限空洞 → §6, §7
□ 16. testing_validation_record 的生成者、签名方式 (独立 evidence key, 非 APT GPG subkey)、存储位置、production 验证方式、revoke/supersede (append-only)、freshness/generation 语义已定义 → §4.5
□ 17. 所有安全关键字段均无开放式 TBD:
     - OIDC issuer/audience/claim policy matrix (workflow_ref+workflow_sha+repository_id) (§4.4);
     - mTLS bootstrap + client identity issuance/rotation/revocation (§4.3, §4.3.1);
     - release sealing + R2 write-once If-None-Match (§2.2, §2.5);
     - promotion evidence key 独立性 (§4.5);
     - publish/rollback lock owner (§3.3, §3.2.2, §8.2);
     - production fallback authorization (§11.2);
     - GPG key recovery owner (§3.1, §3.5);
     - Sigstore trust root 来源 (本地, 非 R2) (§2.3);
     - R2 staging GC owner (§2.2, §7)
□ 18. 从现有 workflow 迁移原则 (每阶段双轨→切换→删旧; 禁止新旧并行写同一公开 repo) → §11
□ 19. candidate ingress 仅 control-plane-testing (production 不暴露) → §2.1, §4.2
□ 20. 状态机失败分类 (永久终止态 vs 可恢复阻塞态) 一致, 无"终止态可重试"矛盾 → §3.4, §4.1
□ 21. deployment plan/result 反馈通道闭环 (testing_validation_record 与 rollback 状态机能获知 deploy 结果) → §4.2, §4.7
□ 22. candidate-retention-ledger 跨域中立账本 + GC fail-closed → §2.7, §7, §10
□ 23. externalization 状态顺序统一 (probe 在 purge 后, completed 依赖 visibility_verified) → §3.2, §3.2.1, §3.2.2
□ 24. bootstrap role mapping 收紧 (OIDC 必须唯一映射到已批准 role) + idempotency 按端点分类 → §4.3.1, §4.4, §4.8
□ 25. OIDC policy roles 完整 (含 rollback-testing / deploy-staging-read-report / deploy-production-read-report) → §4.4
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
□ 没有任何流程允许 build runner 触及 production control plane 的 candidate ingress (§2.1)
□ 没有任何流程允许长期 mTLS client private key 存放 GitHub Secret (§4.3, §4.3.1)
□ 没有任何流程允许 Sigstore trust root 来自 R2 staging 或允许 --insecure-ignore-tlog (§2.3)
□ 没有任何流程允许 promotion evidence 复用 APT GPG signing subkey (§4.5)
□ 没有任何流程允许裸 rclone sync 作为 repository externalization 事务本身 (§3.2.1)
□ 没有任何流程允许同一 channel 在 externalization 未完成时启动新 publish (§3.2.2)
□ 没有任何流程允许 R2 candidate object 被覆盖 (write-once If-None-Match, §2.2/§2.5)
□ 没有任何流程允许 deploy runner 自行完成 operation 或指定 release/version/inventory/host (§4.7)
□ 没有任何流程允许 GC 在有未过期 production lease 或 ledger 不可读时删除 candidate (§2.7 fail-closed)
□ 没有任何流程允许 bootstrap 对未映射到已批准 role 的 OIDC identity 签发 cert (§4.3.1)
□ 没有任何流程允许 idempotency_key 进入 canonical manifest (§2.3, §4.8)
□ 没有任何流程允许 completed 不经过 external_visibility_verified (§3.2)
```

---

## 附录 A: 占位符清单 (实现/执行时必须由 Phase 1-7 plan 决定)

| 占位符 | 出现位置 | 含义 | 决定阶段 |
|---|---|---|---|
| `apt-build-staging` bucket 具体参数 | §1.1, §2.2 | R2 staging backend (CORS/region/lifecycle 精确值) | Phase 4 plan |
| testing/production repo bucket 拓扑 | §1.1 | 是否物理分三个 bucket 还是同 bucket 隔离 prefix | Phase 4/6 plan |
| systemd unit 文件名/路径 | §1.3 | aptly.service / control-plane / publisher-worker 的具体 systemd 配置 | Phase 4/6 plan |
| R2 staging 读授权具体机制 | §7 | release-specific 短期 token vs 受控长期读凭据 | Phase 4 plan |
| mTLS bootstrap 签发实现 | §4.3, §4.3.1 | issuing intermediate CA 实现 (cfssl / step-ca / 自建); root CA 离线流程 | Phase 4 plan |
| repository_id / repository_owner_id 真实值 | §4.4 | GitHub OIDC policy matrix 绑定的固定值 | Phase 4 plan |
| Sigstore trust bundle 版本与更新通道 | §2.3 | Fulcio root + Rekor key 的离线受控更新方式 | Phase 4 plan |
| promotion-evidence signing key 实现 | §4.5 | 独立于 APT GPG subkey 的签名 key 体系 + trust anchor 分发 | Phase 6 plan |
| subkey 轮换周期 | §3.1 | 建议值 12 个月, 具体由运维决定 | Phase 6 plan |
| compatibility gate 检测实现 | §8.9 | ocserv 是否有不可逆迁移的检测脚本 | Phase 6 plan |
| externalization 算法具体实现 | §3.2.1 | 分阶段 R2 提交的工具 (受控 rclone 子命令 / 自写 uploader) | Phase 4 plan |
| candidate-retention-ledger 存储实现 | §2.7 | 独立 bucket / DB 表 / 文件系统的选择 + 双域写入者签名身份 | Phase 6 plan |
| deployment-operation plan store | §4.2, §4.7 | immutable plan 的存储与 batch 分配实现 | Phase 5/6 plan |

## 附录 B: 修订记录

### v1.2 (2026-06-21, 评审 5 项阻塞收口 + 一致性修正)

v1.1 解决了前 7 项, 但仍有 5 个会阻碍实现的规格缺口 (均先对照 spec 实际文本验证再改, 不改变
已确认架构):

```text
必须修改 (5 项):
1. deploy runner 缺结果回报接口 → 状态机无法闭环:
   新增 GET /v1/deployment-operations/{op_id}/plan + POST .../result (§4.2, §4.7);
   deploy runner 只读 immutable plan + 提交绑定结果, 不自行完成 operation;
   §4.4 补 rollback-testing / deploy-*-read / deploy-*-report role;
   §5/§6/§7 "deploy 仅 GET" 改为 "读 plan + 提交 result"
2. candidate artifact GC 无法安全判断 production 引用 (跨域隔离导致):
   新增 candidate-retention-ledger 跨域中立 append-only 账本 (§2.7);
   GC fail-closed, 无未过期 production lease / ledger 不可读 / signature 无效时禁止删除;
   §7 GC worker 行 + §10 恢复路径引用
3. externalization 状态顺序矛盾 (r2_synced 声称含 probe 但 probe 在 purge 后):
   统一为 published→externalizing_objects→r2_objects_verified→metadata_staged→
   inrelease_committed→r2_synced→cdn_purged→external_visibility_verified→completed (§3.2);
   算法补 Release 字段, cdn_purged 仅表 purge API 接受, completed 依赖 visibility_verified (§3.2.1);
   externalization lock 持续到 visibility_verified (§3.2.2)
4. bootstrap 写成"任意 Job"扩大签发面 + idempotency 统一三元组对无 release_id 端点不适用:
   bootstrap 改为 OIDC 必须唯一映射到已批准 role 否则拒绝 (§4.3.1);
   bootstrap audience 按 trust domain 拆分 testing/production (§4.4);
   idempotency 按端点分类 (session/candidate-create/manifest/rollback/deployment-result, §4.8)
5. 数据流图仍写 build runner 上传 manifest (与 §2.2 矛盾) + OIDC matrix 缺 testing rollback/staging deploy role:
   §2.1 数据流改为 control-plane-testing 写权威 manifest.json;
   §4.4 matrix 补齐 rollback-testing / deploy-staging-read / deploy-staging-report /
   deploy-production-report

文档一致性:
- manifest schema 去 idempotency_key (API 控制字段不进 artifact identity, §2.3/§4.8)
- §3.3/§9 幂等表述改为引用 §4.8 分类
- 端点数 9→11; 验收清单 20→25 项; 自审不变量 16→22 条; 附录 A 11→13 项
```

### v1.1 (2026-06-21, 评审 7 项阻塞收口 + 一致性修正)

按评审反馈并入 7 项必须修改 + 文档一致性修正, 不改变已确认的核心架构:

```text
必须修改 (7 项):
1. candidate ingress 仅 control-plane-testing; production 不暴露 candidate create/manifest/finalize
   → §2.1 关键原则 1, §4.2 端点表标注
2. mTLS 首次身份建立循环: 新增 POST /v1/session bootstrap 协议 (§4.3.1)
   + trust-domain root CA 离线 + 本域 issuing intermediate (§4.3, §1.3)
3. OIDC allowlist → endpoint×role×claim policy matrix
   (workflow_ref + workflow_sha + repository_id + event_name 精确匹配, 非文件名) → §4.4
4. R2 write-once: If-None-Match:* 条件写强制 (§2.2/§2.5);
   object_key basename vs logical_filename 解耦 (§2.2/§2.3);
   canonical manifest.json 由 control-plane-testing 写入, 非 build runner (§2.2);
   artifact retention 改 promotion_eligible_until 驱动 (§2.6)
5. 状态机失败分类: 永久终止态 vs 可恢复阻塞态分离 (§3.4, §4.1);
   externalization lock 不变量 (§3.2.2); manifest_update → channel_state_record_update (§3.2)
6. 禁止裸 rclone sync 作为发布事务; 受控分阶段外部可见性提交算法 (§3.2.1)
7. Sigstore/SLSA trust root 来自本地受控 bundle, 禁 --insecure-ignore-tlog (§2.3);
   promotion evidence key 独立于 APT GPG subkey + append-only revoke/supersede +
   freshness/generation 校验 (§4.5)

文档一致性修正:
- 端点数 7 → 9 (加 bootstrap + 标注 candidate ingress 域归属)
- §4.1 状态图统一 (含 upload_authorized/sealed, 终止/可恢复分类)
- §10 恢复路径表更新 (R2/CDN 可恢复阻塞态, 加 evidence key)
- §12.1 验收清单 18 → 20 项; §12.3 自审不变量 9 → 16 条
- 附录 A 占位符 8 → 11 项
```

### v1 (2026-06-21)

初始版本。基于 brainstorming 阶段逐节确认的架构决策 + 7 项评审收口要求, 形成 Phase 0
架构决策文档。核心决策: 双 publish host 物理隔离; R2 staging candidate release 数据桥;
SLSA v1 + Sigstore keyless provenance; 双 GPG hierarchy (primary 离线); 受控两阶段 rollback
状态机 (repo 先 host 后, deploy 不触发 repo rollback); mTLS + OIDC 职责分离; 双轨迁移禁止
新旧并行写同一公开 repo。
