# ocserv 1.5.0 私有 backport 到 Debian 13 (trixie) — 设计文档

- 状态: 已确认 v2 (review 修正已并入, 待 writing-plans)
- 日期: 2026-06-18
- 范围: 把 sid 的 ocserv 1.5.0-1 源码 backport 到 Debian 13 trixie，以私有 apt 仓库形式受控分发、测试、pinning、升级、回滚，进入生产
- 关键约束:
  - 只拿 sid 源码，不拿 sid 二进制
  - 用 trixie 环境重新构建
  - deb 版本号 `1.5.0-1~bpo13+1`
  - 通过测试、pinning 和回滚机制进入生产

## 总体原则

```text
dry-run 不触碰真实发布状态;
testing 通道自动化验证候选 snapshot;
production 通道只接受人工 promote;
主机升级由 Ansible 显式执行;
回滚以 aptly snapshot 为事实源。
```

## 决策摘要

| 决策点 | 选择 |
|--------|------|
| 构建环境 | sbuild + schroot + trixie chroot |
| 源码获取 | dget + snapshot.debian.org 固定时间点 |
| 私有仓库 | aptly + 本地 publish + rclone sync 到 Cloudflare R2 |
| 回滚机制 | aptly snapshot 切换 |
| 测试机制 | 构建期校验 + staging 通道验证 (多阶段) |
| Pinning | 严格 pin: 只允许 ocserv 来自私有仓库, 其余一律拒绝 |
| 触发方式 | 混合: 前期全自动 + production 人工 workflow_dispatch |
| 仓库平台 | aptly 本地 publish → R2; Origin: THEHKUS-Backports |
| 配置管理 | Ansible role (add-repo / upgrade / rollback / verify) |
| CI 平台 | GitHub Actions + self-hosted runner |
| 整体编排 | 线性 CI pipeline + 显式人工闸门 |

---

## 第 1 节: 架构总览

### 1.1 事实源与分发层

```text
事实源:
  git 仓库 (debian/ 源码补丁, scripts/, Makefile, ansible/, .github/workflows/)
  aptly DB / snapshots (构建机持久化)
  构建产物归档 (.deb / .changes / .buildinfo)

分发层 (非事实源, 是发布结果):
  R2 /testing/
  R2 /prod/
```

R2 是发布结果而非事实源。回滚依据是 aptly snapshot, 不是 R2 当前对象状态。

### 1.2 角色与数据流

```
┌─────────────── CI pipeline (ci-testing.yml) ───────────────┐
│                                                             │
[push] │  1.build        sbuild in trixie schroot             │
       │     ↓                                                      │
       │  2.lint+smoke   lintian + smoke-basic (容器, 无 systemd) │
       │     ↓                                                      │
       │  3.pub-testing  aptly snapshot → publish switch          │
       │                  → rclone sync R2 /testing/ → cf purge   │
       │     ↓                                                      │
       │  4.staging      ansible 升级 staging + smoke-service 探活│
       │     ├─ 失败 → 自动 rollback-testing (snapshot 切换)       │
       │     └─ 通过 → 停, 等人工                                  │
       └────────────────────┬────────────────────────────────────┘
                              │
                   [workflow_dispatch 人工触发]
                              ↓
       ┌──────────── production 发布 (人工闸门) ───────────────┐
       │  5.promote-prod  aptly publish switch → R2 /prod/     │
       │                  (不自动升级生产机)                     │
       │  6.(独立人工) ansible -i production upgrade + verify   │
       └─────────────────────────────────────────────────────────┘

       ┌──────────── 回滚 (snapshot 切换) ─────────────────────┐
       │  staging:  探活失败 → 自动 publish switch 上一个 testing │
       │  prod:     人工 workflow_dispatch → switch + sync +     │
       │            ansible rollback (降级+重启+探活)             │
       └─────────────────────────────────────────────────────────┘
```

### 1.3 关键边界

- **构建机**: 专用 self-hosted runner / 长驻 VM。持久化 aptly DB (snapshots 是状态, 必须跨 job 保留)、GPG 签名 key、sbuild chroot
- **R2**: 两个独立路径 `/testing/` 和 `/prod/`, 各自有 Release/InRelease + 签名。物理路径隔离, 误发布 testing 不影响生产机
- **staging 机**: 只配 `/testing/` 源, 结构上与生产一致 (同 Debian 13, 同 ocserv 配置形态), 用于挡真实环境问题
- **生产机**: 只配 `/prod/` 源 + pinning, 只接受 ocserv 来自 `Origin: THEHKUS-Backports`
- **Ansible**: role 四个入口 (add-repo / upgrade / rollback / verify), staging 与 prod 共用同一 role, 靠 inventory 区分

### 1.4 并发锁

aptly DB 是有状态资源, repo-mutating 操作必须串行。CI 原生 concurrency + 脚本 flock 双保险。

```text
CI 层 concurrency group: repo-publish-lock
  作用于: publish-testing / staging-upgrade / promote-prod /
          rollback-testing / prod-rollback
  cancel-in-progress: false   (排队, 不抢占)

脚本层 flock:
  exec 9>/var/aptly/.locks/repo-publish.lock
  flock -n 9 || { echo "busy"; exit 1; }
  repo add / snapshot create / publish / switch / rclone sync 全程持锁
  (锁文件放 /var/aptly/.locks/, builder 用户可写; 不放 /var/lock/)
```

锁名 `repo-publish-lock` (而非泛化的 aptly-lock), 因为它保护的是: aptly DB mutation、testing/prod publish 指针、R2 当前通道内容、staging 验证期间的 testing 通道稳定性。

```text
允许并发 (无锁):     build, lint-and-smoke, fetch-source
必须串行 (持锁):     任何 aptly repo add / snapshot create /
                     publish snapshot / publish switch / rclone sync /
                     staging 验证期间
```

### 1.5 snapshot 命名

```text
snapshot 名: ocserv-1.5.0-1~bpo13+1-build-42
  - 含版本号 + build 号, 可追溯
  - 不含 testing/prod (snapshot 是构建产物, 与发布通道解耦)
```

---

## 第 2 节: 版本号约定与源码获取

### 2.1 版本号

```text
源包版本:      ocserv 1.5.0-1 (sid 原版)
backport 版本: 1.5.0-1~bpo13+1
完整文件名:    ocserv_1.5.0-1~bpo13+1_amd64.deb
snapshot 名:   ocserv-1.5.0-1~bpo13+1-build-42
```

**版本号规则:**

```text
1.5.0       upstream 版本, 来自 ocserv 上游源码
-1          Debian 修订号, 来自 sid 的 debian_revision
~bpo13+1    私有 backport 标记
              ~ 使该版本排序低于 sid 的正式 1.5.0-1 (防反向覆盖)
              bpo13 表示目标系统是 Debian 13 trixie
              +1 表示本次 backport 修订号
```

**版本号排序验证 (dpkg 行为):**

```text
1.5.0-1~bpo13+1  <  1.5.0-1        (backport 低于 sid, 防反向覆盖)
1.5.0-1~bpo13+1  >  trixie 旧版    (高于 trixie 现有旧版, 触发升级)
```

### 2.2 build 号约定

build 号只进入 snapshot 名和 CI artifact 名, **不进入 Debian 包版本号**。

```text
deb 版本:      1.5.0-1~bpo13+1
snapshot 名:   ocserv-1.5.0-1~bpo13+1-build-42
CI artifact:   ocserv-1.5.0-1~bpo13+1-build-42.tar
```

不使用 `1.5.0-1~bpo13+1.42` 或 `1.5.0-1~bpo13+1-build42`。原因: Debian 版本号用于 apt 升级/降级/pinning/依赖解析; CI build 号用于追踪某次流水线构建; 二者职责不同, 不应混合。

### 2.3 已发布版本不可变规则

一旦某个 `.deb` 版本进入 testing 或 production 仓库, 该版本必须视为不可变。

```text
允许:   同一源码、同一补丁、同一 debian/ 目录重复构建,
        但只有在产物未发布前可以覆盖本地 artifact。
不允许: 已经发布 ocserv_1.5.0-1~bpo13+1_amd64.deb 后,
        再用同一个版本号发布内容不同的新 deb。
```

如果发生以下任一变化, 必须提升 backport 修订号 (`+1` → `+2`):

```text
debian/patches 变化
debian/rules 变化
debian/control 变化
构建依赖策略变化
systemd unit 变化
PAM 文件变化
默认配置文件变化
打包脚本影响最终 .deb 内容
修复构建错误后重新发布
```

例如第一次发布 `1.5.0-1~bpo13+1`, 修正打包内容后重新发布 `1.5.0-1~bpo13+2`。避免: APT 缓存混乱、R2 同名 deb 被覆盖、Packages 索引 hash mismatch、不同节点装到同版本不同内容的包、回滚时无法确认真实产物。

### 2.4 源码获取方式

```text
dget + snapshot.debian.org 固定时间点 URL
```

目标: 只获取 sid 源码包; 不配置 sid 二进制仓库; 不让 trixie 构建环境接触 sid 源; 未来可复现同一次源码输入。

**脚本:** `scripts/fetch-source.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

OCSERV_UPSTREAM_VERSION="1.5.0"
OCSERV_DEBIAN_REVISION="1"
OCSERV_SOURCE_VERSION="${OCSERV_UPSTREAM_VERSION}-${OCSERV_DEBIAN_REVISION}"

DEBIAN_SNAPSHOT_TIMESTAMP="YYYYMMDDTHHMMSSZ"
DEBIAN_SNAPSHOT_BASE="https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT_TIMESTAMP}"

# 注意路径是 /pool/main/o/ocserv/, 不是 /main/o/ocserv/
OCSERV_DSC_URL="${DEBIAN_SNAPSHOT_BASE}/pool/main/o/ocserv/ocserv_${OCSERV_SOURCE_VERSION}.dsc"

mkdir -p build/source
cd build/source

dget -x "${OCSERV_DSC_URL}"
```

产出:

```text
ocserv-1.5.0/
ocserv_1.5.0-1.dsc
ocserv_1.5.0.orig.tar.xz
ocserv_1.5.0.orig.tar.xz.asc
ocserv_1.5.0-1.debian.tar.xz
```

### 2.5 changelog 改写

源码解包后, 把 sid 版本 `1.5.0-1` 改写为 `1.5.0-1~bpo13+1`。

**脚本:** `scripts/rewrap-changelog.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKPORT_VERSION="1.5.0-1~bpo13+1"
MAINTAINER_NAME="Thehkus Admin"
MAINTAINER_EMAIL="master@thehkus.com"

cd build/source/ocserv-1.5.0

export DEBEMAIL="${MAINTAINER_EMAIL}"
export DEBFULLNAME="${MAINTAINER_NAME}"

dch \
  --distribution trixie \
  --force-distribution \
  -v "${BACKPORT_VERSION}" \
  "Private rebuild for Debian 13 trixie."
```

**changelog 字段约定:**

```text
Package:      ocserv
Version:      1.5.0-1~bpo13+1
Distribution: trixie          (不用 trixie-backports, 这是私有 backport)
Urgency:      medium
Maintainer:   Thehkus Admin <master@thehkus.com>
```

changelog distribution 保持 `trixie` 而非 `trixie-backports`, 因为这是私有 backport, 不是 Debian 官方 backports 发布流程。私有仓库实际 suite 由 aptly publish 阶段控制 (`trixie-testing` / `trixie-production`)。

### 2.6 重新生成 backport source package

修改 changelog 后, 不能直接把 sid 原始 `.dsc` 交给 sbuild。必须重新生成 backport source package。

**脚本:** `scripts/build-source-package.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

cd build/source/ocserv-1.5.0

dpkg-buildpackage -S -us -uc
```

执行后上级目录生成:

```text
ocserv_1.5.0-1~bpo13+1.dsc
ocserv_1.5.0-1~bpo13+1.debian.tar.xz
ocserv_1.5.0-1~bpo13+1_source.changes
```

后续 sbuild 必须使用 `ocserv_1.5.0-1~bpo13+1.dsc`, 不是 sid 原 `.dsc`。

### 2.7 sbuild 构建

**脚本:** `scripts/build-binary.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKPORT_VERSION="1.5.0-1~bpo13+1"
DSC="build/source/ocserv_${BACKPORT_VERSION}.dsc"

mkdir -p build/binary

sbuild \
  --chroot-mode=schroot \
  -d trixie \
  --arch=amd64 \
  --build-dir build/binary \
  --no-run-lintian \
  "${DSC}"
```

构建 chroot 命名: `trixie-amd64-sbuild`, `-d` 参数用 `trixie` (除非专门建了 `trixie-backports` chroot)。

**构建约束 (schroot APT sources):**

```text
允许:  trixie / trixie-updates / trixie-security / 必要时受控内部 build-dep 仓库
禁止:  sid / unstable / testing(forky) / 非受控第三方仓库
```

sid 只作为源码来源; trixie 是唯一构建和运行依赖来源; 不会误拉 sid 二进制依赖。

### 2.8 数据流: 源码到 deb

```
[snapshot.debian.org 固定时间点]
        │  dget -x (构建机本体执行, 不在 chroot 内)
        ↓
[ocserv_1.5.0-1.dsc + orig.tar.xz + debian.tar.xz]
        │  dpkg-source -x
        ↓
[ocserv-1.5.0/  sid 原始源码树]
        │  dch -v 1.5.0-1~bpo13+1
        ↓
[ocserv-1.5.0/  带 backport changelog]
        │  dpkg-buildpackage -S -us -uc
        ↓
[ocserv_1.5.0-1~bpo13+1.dsc]
        │  sbuild -d trixie  (干净 trixie schroot, 只看 trixie Build-Depends)
        ↓
[ocserv_1.5.0-1~bpo13+1_amd64.deb]
[ocserv-dbgsym_1.5.0-1~bpo13+1_amd64.deb]
[ocserv_1.5.0-1~bpo13+1_amd64.changes]
[ocserv_1.5.0-1~bpo13+1_amd64.buildinfo]
```

---

## 第 3 节: aptly 仓库模型与 R2 发布

### 3.1 aptly 仓库模型

单一本地 repo + 不可变 snapshot + 双 publish。

```text
aptly repo:     ocserv-backports        (单一收包池, 可变, 可含多个历史版本)
                        │
                        │ aptly repo add *.deb
                        ↓
aptly snapshot: ocserv-1.5.0-1~bpo13+1-build-42   (不可变, 构建产物固化)
aptly snapshot: ocserv-1.5.0-1~bpo13+2-build-57   (不可变)
                        │
          ┌─────────────┴──────────────┐
          │                            │
aptly publish:  testing                 production
  component:   main                    main
  distribution: trixie-testing         trixie-production
  origin:      THEHKUS-Backports       THEHKUS-Backports
  → filesystem: testing                → filesystem: prod
          │                            │
          ↓                            ↓
   rclone sync → R2 /testing/    rclone sync → R2 /prod/
```

**关键约定:**
- snapshot 名只含版本+build 号, 不含 testing/prod。snapshot 是构建产物, 与发布通道解耦
- testing 与 prod 是两个独立 publish, 各自指向某个 snapshot
- 同一个 snapshot 可同时被 testing 和 prod 指向 (staging 验证通过后 prod 指向同一个已验证 snapshot)
- repo 是收包池, snapshot 是某时刻 repo 包集合的不可变视图。snapshot 内可能含历史多版本 (APT 默认选候选版本最高者); 回滚通过 switch 到 previous known-good snapshot 完成

### 3.2 仓库目录与 R2 路径映射

```text
构建机本地 (aptly filesystem publish):
  /var/aptly/public/testing/
    dists/trixie-testing/main/binary-amd64/Packages(.gz)
    dists/trixie-testing/Release(.gpg) + InRelease
    pool/main/o/ocserv/ocserv_1.5.0-1~bpo13+1_amd64.deb
  /var/aptly/public/prod/
    dists/trixie-production/...
    pool/main/o/ocserv/...

R2 bucket (静态托管, 公开读):
  r2://apt-thehkus/testing/   ←  rclone sync from /var/aptly/public/testing/
  r2://apt-thehkus/prod/      ←  rclone sync from /var/aptly/public/prod/

对外 URL:
  https://apt.example.com/testing/    → R2 /testing/
  https://apt.example.com/prod/       → R2 /prod/
```

**为什么本地 publish 再 sync, 而非 aptly 直接 publish 到 R2:**
- 本地 publish 是原子操作, sync 前可完整校验 Release/InRelease/Packages 一致性
- aptly 不需要持有 R2 凭据 (凭据只在 sync 步骤出现)
- sync 失败可重试, 不影响 aptly DB 状态
- 回滚时本地 switch 后重新 sync, R2 始终是本地状态的镜像

### 3.3 R2 sync 策略

用 `rclone sync` (镜像语义, 非 `copy`):

```bash
rclone sync /var/aptly/public/testing/ r2:apt-thehkus/testing/ \
  --checksum --transfers 4
rclone sync /var/aptly/public/prod/ r2:apt-thehkus/prod/ \
  --checksum --transfers 4
```

**语义 (精确表述):**

```text
rclone sync 的目标是让 R2 当前通道精确等于本地 aptly publish 目录。
R2 不承担历史保留职责。
历史保留、回滚锚点和审计依据全部由 aptly snapshot + build artifacts 承担。

当前 snapshot 指向新版本: 旧版本是否还在 R2 取决于当前 snapshot 是否仍包含旧版本包。
当前 snapshot 回滚到旧版本: 新版本若不属于旧 snapshot, 会从 R2 当前通道消失。
```

**为什么 sync 不 copy:** sync 会删除 R2 上本地已不存在的对象, 保证 R2 是本地精确镜像。copy 容易让 R2 累积不属于当前 publish 的陈旧对象。

### 3.4 R2 凭据注入

rclone 不会天然读取 `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` 这类自定义变量。凭据通过 `RCLONE_CONFIG_*` 环境变量在 runtime 注入, 由 `scripts/r2-sync.sh` 显式映射。

**GitHub secrets:**
```text
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
```

**`scripts/r2-sync.sh` 内部映射 (不把凭据写进 rclone.conf, 也不重复存 GitHub secrets):**
```bash
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

rclone sync /var/aptly/public/testing/ r2:apt-thehkus/testing/ --checksum --transfers 4
```

```text
凭据只存在一个地方 (GitHub secrets → CI runtime 环境变量 → rclone), 不重复存储。
rclone.conf 里只预置 remote 名称 "r2" 的骨架, 不含 access/secret。
```

### 3.5 缓存策略 (Cloudflare R2 custom domain)

```text
apt.example.com = Cloudflare custom domain 指向 R2 bucket。

/testing/dists/*  与  /prod/dists/*:
  no-cache 或极短 TTL
  每次 publish switch 后主动 purge

/testing/pool/*  与  /prod/pool/*:
  长 TTL
  .deb 文件名含版本号, 内容不可变
```

若后续选择完全禁用 Cloudflare cache, 仍保留 purge 步骤作为幂等安全动作。

### 3.6 GPG 签名

```text
签名 key:
  存于构建机, 仅 self-hosted runner 可访问
  aptly 配置文件指定 key ID + passphrase
  公钥导出供主机端安装

签名对象:
  Release.gpg (detached)
  InRelease  (clearsign)

公钥分发:
  导出 armored pubkey → ansible 分发到主机
  /etc/apt/keyrings/thehkus-backports.asc
  deb822 sources 用 Signed-By 引用
```

**key 约束:** 私钥绝不离开构建机; CI secret 只存 passphrase (解锁构建机本地 keyring, 不传输 key 本体)。

### 3.7 发布与切换操作清单

| 操作 | aptly 命令 | 后续 | 触发 |
|------|-----------|------|------|
| 首次发 testing | `snapshot create` → `publish snapshot ... trixie-testing` | rclone sync /testing/ + purge | CI 自动 |
| testing 升级新版本 | `repo add` → `snapshot create` → `publish switch trixie-testing <new>` | rclone sync /testing/ + purge | CI 自动 |
| staging 自动回滚 | `publish switch trixie-testing <previous-good>` | rclone sync /testing/ + purge + ansible rollback | 探活失败自动 |
| promote 到 prod | `publish switch trixie-production <validated>` | rclone sync /prod/ + purge | **人工 workflow_dispatch** |
| prod 人工回滚 | `publish switch trixie-production <previous-good>` | rclone sync /prod/ + purge + ansible rollback | **人工确认** |

**snapshot 保留策略:** 失败的 candidate snapshot **不删除**, 保留供排查; 只是不再作为当前 publish 指向。成功的 snapshot 长期保留作为回滚锚点。

**首次发布用 `publish snapshot`; 后续同一通道更新用 `publish switch`。** `publish switch` 在已发布仓库上原地切换到新 snapshot, distribution/component/architectures 等选项保留, 尽量减少不可用时间。

---

## 第 4 节: CI pipeline 编排

### 4.1 平台

```text
GitHub Actions + self-hosted runner (标签 [self-hosted, builder])
所有 job 跑 self-hosted runner (build/lint/smoke 无锁但仍跑 builder runner)
concurrency, workflow_dispatch, protected environment, repo/environment secrets
```

未来迁移 GitLab CI 时, DAG 和脚本不变, 只替换 CI 语法。

### 4.2 Job DAG

```
push to main / 触发 ci-testing.yml
        │
        ↓
┌─── 1.build ───────────────────────────────────┐  (self-hosted, 无锁)
│ fetch-source → rewrap-changelog →             │
│ build-source-package → sbuild                 │
│ 产物: ocserv_1.5.0-1~bpo13+1_amd64.deb        │
│      + .changes/.buildinfo                     │
│ 上传为 CI artifact (含 build 号)               │
└────────────────────┬───────────────────────────┘
                     │ needs: build
                     ↓
┌─── 2.lint-and-smoke ──────────────────────────┐  (self-hosted, 无锁)
│ lintian .changes                               │
│ smoke-basic (trixie 容器, 无 systemd):         │
│   apt install deb → dpkg-query 版本 →          │
│   ocserv --version → unit 文件存在 →           │
│   二进制依赖完整                                │
│ 失败 → pipeline 终止, 不进入 publish           │
└────────────────────┬───────────────────────────┘
                     │ needs: lint-and-smoke
                     ↓
┌─── 3.publish-testing ─────────────────────────┐  concurrency: repo-publish-lock
│ flock + aptly repo add + snapshot create      │
│ snapshot name via scripts/snapshot-name.sh    │
│ aptly publish switch trixie-testing <snap>    │
│ rclone sync → R2 /testing/                    │
│ Cloudflare purge /testing/dists/*             │
│ 记录 snapshot 名到 job output (回滚锚点)       │
└────────────────────┬───────────────────────────┘
                     │ needs: publish-testing
                     ↓
┌─── 4.staging-upgrade ─────────────────────────┐  concurrency: repo-publish-lock
│ ansible-playbook -i staging                   │
│   -e ocserv_backport_action=upgrade           │
│   -e ocserv_target_version=1.5.0-1~bpo13+1    │
│ ansible-playbook -i staging                   │
│   -e ocserv_backport_action=verify            │
│   (smoke-service: systemd active + TCP/UDP)   │
│  ├─ 失败 → 触发 rollback-staging (自动)        │
│  └─ 通过 → pipeline 结束, 等人工               │
└─────────────────────────────────────────────────┘

══════════════ 人工闸门 ══════════════

┌─── promote-production.yml ── workflow_dispatch ┐  concurrency: repo-publish-lock
│ 输入: 待 promote 的 snapshot 名                 │
│ aptly publish switch trixie-production <snap>  │
│ rclone sync → R2 /prod/                        │
│ Cloudflare purge /prod/dists/*                 │
│ ❌ 不自动升级生产机, 由独立人工动作触发          │
└─────────────────────────────────────────────────┘

┌─── rollback-production.yml ── workflow_dispatch┐  concurrency: repo-publish-lock
│ 输入: 回滚目标 snapshot 名 + 回滚目标版本       │
│ aptly publish switch trixie-production <snap>  │
│ rclone sync → R2 /prod/                        │
│ Cloudflare purge /prod/dists/*                 │
│ ansible -i production rollback                 │
│   (降级 + 重启 + 探活, 失败则告警不静默)        │
└─────────────────────────────────────────────────┘
```

staging-rollback (testing 通道) 由 `staging-upgrade` job 失败时 `if: failure()` 内联触发, 不单独 workflow。

### 4.3 拆分为三个 workflow

```text
ci-testing.yml           push 触发
                         build → lint → smoke-basic → publish testing →
                         staging upgrade → staging verify
                         失败时 staging rollback

promote-production.yml   workflow_dispatch 触发
                         输入 snapshot
                         publish production → sync R2 → purge /prod/dists/*

rollback-production.yml  workflow_dispatch 触发
                         输入 target_snapshot / target_version
                         switch production → sync R2 → purge →
                         ansible rollback
```

拆分理由: GitHub UI 更清楚 (测试流水线/生产发布/生产回滚); production workflow 可配 protected environment 和审批。

### 4.4 触发条件

```yaml
# ci-testing.yml
on:
  push:
    branches: [main]
    paths:
      - 'debian/**'
      - 'scripts/**'
      - 'ansible/**'              # Ansible role 变更也触发 staging 验证
      - 'Makefile'
      - '.github/workflows/**'

# promote-production.yml
on:
  workflow_dispatch:
    inputs:
      snapshot:
        description: '待 promote 的 snapshot 名'
        required: true

# rollback-production.yml
on:
  workflow_dispatch:
    inputs:
      snapshot:
        description: '回滚目标 snapshot 名'
        required: true
      target_version:
        description: '回滚目标 deb 版本 (ansible rollback 用)'
        required: true
```

`target_version` 只在 rollback-production 出现, promote 不需要。Ansible role 变更会触发 staging 验证 (paths 含 `ansible/**`)。

### 4.5 Job 与 Makefile target 映射

CI job 内部只调用版本化脚本/Makefile target, 本地用相同 target 可复现整条链。

```makefile
# Makefile (版本化, 本地与 CI 共用)
.PHONY: fetch rewrap src-pkg binary lint smoke smoke-basic smoke-service \
        pub-testing sync-testing purge-testing \
        pub-prod sync-prod purge-prod \
        rollback-testing rollback-prod snapshot-name \
        require-SNAP require-TARGET_SNAP

OCSERV_VERSION := 1.5.0-1~bpo13+1
BUILD_NUMBER  ?= $(shell git rev-parse --short HEAD)

fetch:           ; scripts/fetch-source.sh
rewrap:          ; scripts/rewrap-changelog.sh
src-pkg:         ; scripts/build-source-package.sh
binary:          ; scripts/build-binary.sh
lint:            ; scripts/lint-package.sh
smoke-basic:     ; scripts/smoke-test.sh basic
smoke-service:   ; scripts/smoke-test.sh service
smoke:           ; scripts/smoke-test.sh basic

snapshot-name:   ; scripts/snapshot-name.sh

pub-testing:     ; scripts/aptly-publish.sh testing $$(scripts/snapshot-name.sh)
sync-testing:    ; scripts/r2-sync.sh testing
purge-testing:   ; scripts/cf-purge.sh testing

# 需要 SNAP / TARGET_SNAP 的 target 加 guard, 防止空参数传入脚本
require-SNAP:
	@test -n "$(SNAP)" || { echo "SNAP is required"; exit 1; }
require-TARGET_SNAP:
	@test -n "$(TARGET_SNAP)" || { echo "TARGET_SNAP is required"; exit 1; }

pub-prod: require-SNAP
	scripts/aptly-publish.sh production $(SNAP)
sync-prod:       ; scripts/r2-sync.sh production
purge-prod:      ; scripts/cf-purge.sh production

rollback-testing: require-TARGET_SNAP
	scripts/aptly-rollback.sh testing $(TARGET_SNAP)
rollback-prod: require-TARGET_SNAP
	scripts/aptly-rollback.sh production $(TARGET_SNAP)
```

每个 CI job 的 run 块就是一行 `make <target>`。snapshot 名由 `scripts/snapshot-name.sh` 单一产出, CI/Makefile/aptly 三处引用同一脚本, 避免命名漂移。需要参数的 target 加 guard, 防止忘记传参导致空字符串进脚本。

### 4.6 Secrets 与凭据边界

```text
CI secrets (repo/environment 级):
  R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET
  CF_API_TOKEN / CF_ZONE_ID          (cache purge)
  GPG_PASSPHRASE                    (解锁构建机本地 keyring)

留在构建机 (绝不入 CI secrets, 绝不离开构建机):
  aptly DB                          (/var/aptly)
  GPG 私钥本体                      (~/.gnupg)
  sbuild chroot                     (/var/lib/sbuild)
  staging/prod SSH 私钥             (self-hosted runner 本机 ssh-agent, 不入 GitHub Secrets)
  本地 publish 目录                 (/var/aptly/public)

理由: GPG 私钥和 aptly DB 是长生命周期状态, 放 CI secret 会丢失可复现性且难审计;
      CI 只注入一次性凭据和 passphrase。
```

SSH key 严格表述:
```text
CI 不注入生产 SSH 私钥。
生产 SSH 私钥不进入 GitHub Secrets。
self-hosted runner 使用本机受控 ssh-agent 或专用 deploy key。
staging/prod 权限分离 (不同 key / 不同 user)。
```

### 4.7 promote-prod 与 production upgrade 解耦

```text
promote-prod = 仓库侧变更 (aptly switch + R2 sync + purge)
               不自动升级生产机
production upgrade = 主机侧变更 (人工窗口, ansible rolling upgrade)
                     restart ocserv + verify
```

二者解耦: 可以选择升级窗口、滚动升级, 不会因 promote 立即影响线上节点。

### 4.8 staging 自动回滚判定

```text
staging-upgrade job 内:
  ansible upgrade → ansible verify (smoke-service)
  if verify 失败:
    自动执行 rollback-testing
      (aptly switch + rclone sync + ansible rollback)
    pipeline 标记失败, 通知人工
    保留失败 candidate snapshot 供排查 (不删除)
```

自动回滚只发生在 staging/testing 通道, 绝不触碰 prod。

---

## 第 5 节: Ansible role — add-repo / upgrade / rollback / verify

### 5.1 设计原则与边界

```text
做:    apt key + deb822 source + apt pinning + apt update +
       安装指定 ocserv 版本 + 降级指定 ocserv 版本 +
       systemd restart + verify
不做:  ocserv.conf 业务参数 / 证书签发 / 证书吊销 / 用户库 /
       RADIUS / daloRADIUS / Vault 配置 / 防火墙和 NAT 策略重构
```

可检查配置文件和证书是否存在、可读, 但不负责生成或修改。所有动作幂等, 重复执行安全。staging 与 prod 共用同一 role, 靠 inventory 变量区分。

### 5.2 Role 结构

```
ansible/roles/ocserv_backport/
├── defaults/main.yml
├── tasks/
│   ├── main.yml               # 入口分发
│   ├── add-repo.yml           # 加源 + 公钥 + pinning
│   ├── upgrade.yml            # apt 升级 + 重启 + 探活
│   ├── rollback.yml           # apt 降级 + 重启 + 探活
│   └── verify.yml             # 纯探活 (CI 与人工共用)
├── templates/
│   ├── thehkus-backports.sources.j2
│   └── ocserv-pin.j2
└── files/
    └── thehkus-backports.asc  # GPG 公钥 (构建机导出, 入仓)
```

### 5.3 通道区分 (inventory 变量)

```yaml
# inventories/staging/group_vars/all.yml
ocserv_channel: testing
ocserv_repo_suite: trixie-testing
ocserv_repo_baseurl: https://apt.example.com/testing
ocserv_tcp_port: 4433
ocserv_udp_port: 4433

# inventories/production/group_vars/all.yml
ocserv_channel: production
ocserv_repo_suite: trixie-production
ocserv_repo_baseurl: https://apt.example.com/prod
ocserv_tcp_port: 443
ocserv_udp_port: 443
```

deb822 模板据此渲染。prod 机器物理上无法访问 testing 源 (源文件只配 prod baseurl), 反之亦然。

### 5.4 deb822 源文件模板

`templates/thehkus-backports.sources.j2`:

```
# /etc/apt/sources.list.d/thehkus-backports.sources
Types: deb
URIs: {{ ocserv_repo_baseurl }}
Suites: {{ ocserv_repo_suite }}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/thehkus-backports.asc
Enabled: yes
```

### 5.5 pinning 模板 (严格 pin, 先默认拒绝再白名单)

`templates/ocserv-pin.j2`:

```
# /etc/apt/preferences.d/ocserv-thehkus-backports
# 先默认拒绝 THEHKUS-Backports 仓库的所有包
Package: *
Pin: release o=THEHKUS-Backports
Pin-Priority: -1

# 再白名单放行 ocserv, 钉到当前通道 suite
Package: ocserv
Pin: release o=THEHKUS-Backports,n={{ ocserv_repo_suite }}
Pin-Priority: 1001
```

**语义:**
- 默认拒绝: THEHKUS-Backports 仓库任何包优先级 -1 (拒绝安装)
- 白名单: `ocserv` 从当前通道取, 优先级 1001 (>1000 允许降级, 确保回滚能装到旧版)
- `n={{ ocserv_repo_suite }}` 把 pin 钉到当前通道: prod 机器只从 `trixie-production` 接受, 即使误配 testing 源也不生效

**验收 (必须通过 `apt-cache policy ocserv` 验证):**
```text
ocserv from THEHKUS-Backports,trixie-production: 1001
other packages from THEHKUS-Backports: -1
Debian trixie official packages: 500
```

### 5.6 add-repo 任务

```yaml
- name: 确保 keyrings 目录存在
  file: { path: /etc/apt/keyrings, state: directory, mode: "0755" }

- name: 安装 GPG 公钥
  copy:
    src: thehkus-backports.asc
    dest: /etc/apt/keyrings/thehkus-backports.asc
    mode: "0644"

- name: 渲染 deb822 源文件
  template: { src: thehkus-backports.sources.j2, dest: /etc/apt/sources.list.d/thehkus-backports.sources }
  notify: apt update

- name: 渲染 pinning 文件
  template: { src: ocserv-pin.j2, dest: /etc/apt/preferences.d/ocserv-thehkus-backports }
  notify: apt update
```

add-repo 可幂等执行; upgrade/rollback 必须显式触发。

### 5.7 upgrade 任务 (显式版本, 不用 latest)

```yaml
- name: 断言必须传入 ocserv_target_version
  assert:
    that:
      - ocserv_target_version is defined
    fail_msg: "upgrade 必须显式传入 ocserv_target_version"

- name: apt update
  apt: { update_cache: yes }

- name: 校验 candidate 来源/版本/priority (调用版本化脚本, 解析 apt-cache policy)
  script: assert-apt-policy.sh --package ocserv
          --expected-version {{ ocserv_target_version }}
          --expected-origin THEHKUS-Backports
          --expected-suite {{ ocserv_repo_suite }}
          --expected-priority 1001

- name: 确保 ocserv-backport 状态目录存在
  file:
    path: /var/lib/ocserv-backport
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: 升级前记录当前版本到本机状态文件 (审计)
  command: dpkg-query -W -f='${Version}' ocserv
  register: ocserv_version_before
  changed_when: false

- name: 写入版本记录到本机 (审计, 非回滚依据)
  copy:
    dest: /var/lib/ocserv-backport/previous-version
    content: "{{ ocserv_version_before.stdout }}\n"

- name: 安装指定版本 ocserv (不用 latest)
  apt:
    name: "ocserv={{ ocserv_target_version }}"
    state: present
    allow_downgrade: yes

- name: 重启 ocserv
  systemd: { name: ocserv, state: restarted }

- name: 探活
  import_tasks: verify.yml
```

关键修正:
- upgrade 不用 `state: latest`, 必须安装 `ocserv={{ ocserv_target_version }}`
- 回滚依据是显式传参或 aptly snapshot, 不依赖跨 play register 变量
- candidate 校验由独立脚本 `scripts/assert-apt-policy.sh` 解析 `apt-cache policy ocserv`, 不留给实现者自由发挥 (见 5.11)
- 写入 `/var/lib/ocserv-backport/previous-version` 前先 mkdir

### 5.8 rollback 任务 (必须显式传参)

```yaml
- name: 断言必须传入 ocserv_target_version
  assert:
    that:
      - ocserv_target_version is defined
    fail_msg: "rollback 必须显式传入 ocserv_target_version (人工确认目标版本)"

- name: apt update (拿旧版索引)
  apt: { update_cache: yes }

- name: 降级 ocserv
  apt:
    name: "ocserv={{ ocserv_target_version }}"
    state: present
    allow_downgrade: yes          # 用 allow_downgrade, 不用宽泛 force

- name: 重启 ocserv
  systemd: { name: ocserv, state: restarted }

- name: 探活
  import_tasks: verify.yml
```

rollback 必须显式传入 `ocserv_target_version`; 没有目标版本就 fail。回滚目标版本必须仍在当前 aptly snapshot 内 (R2 /prod/ 当前 publish 包含它); 若版本已被移出当前 snapshot, 需先在构建机 `publish switch` 到含该旧版的 snapshot, 再跑 ansible rollback。

### 5.9 verify 任务 (纯只读, TCP+UDP 精确匹配, 配置测试可选)

```yaml
- name: 检查 ocserv 服务 active
  systemd: { name: ocserv }
  register: svc
  failed_when: svc.status.ActiveState != 'active'

- name: 检查 TCP 监听 (精确匹配端口, 避免 443 误匹配 4433)
  shell: "ss -H -ltn sport = :{{ ocserv_tcp_port }}"
  register: ss_tcp
  changed_when: false
  failed_when: ss_tcp.stdout | length == 0

- name: 检查 UDP 监听 (精确匹配端口)
  shell: "ss -H -lun sport = :{{ ocserv_udp_port }}"
  register: ss_udp
  changed_when: false
  failed_when: ss_udp.stdout | length == 0

- name: 检查版本号匹配预期
  command: dpkg-query -W -f='${Version}' ocserv
  register: ver
  changed_when: false
  failed_when: "expected_version is defined and ver.stdout != expected_version"

- name: 检查 journalctl 最近日志无明显 fatal (大小写不敏感)
  command: journalctl -u ocserv --since "5 min ago" --no-pager
  register: journal
  changed_when: false
  failed_when: >
    'fatal' in (journal.stdout | lower) or
    'config error' in (journal.stdout | lower) or
    'permission denied' in (journal.stdout | lower)

- name: (可选) ocserv 配置语法校验
  command: ocserv --test-config --config=/etc/ocserv/ocserv.conf
  changed_when: false
  when: ocserv_run_config_test | default(false) | bool

- name: occtl 可执行 (以 root; rc != 0 即失败, 不掩盖 permission/socket 错误)
  command: occtl show users
  register: occtl_out
  changed_when: false
  become: yes
  failed_when: occtl_out.rc != 0
```

verify 是纯只读、可独立调用。修正点:
- 端口检查用 `ss -H ... sport = :<port>` 精确匹配 (避免 `443` 子串匹配 `4433`)
- journalctl 检查对输出 `lower` 后匹配 (避免 `Fatal`/`FATAL` 漏检)
- occtl 检查 `rc != 0` 即失败 (不掩盖 permission denied / socket 连接失败 / 非零退出; 空用户在线时 `show users` 正常返回空, rc=0)
- `ocserv --test-config` 设为可选 (参数是否存在取决于版本和打包方式)
- occtl 明确以 root 执行 (需访问管理 socket)

### 5.10 入口分发 (不默认 upgrade)

`tasks/main.yml`:

```yaml
- name: 断言必须显式指定 ocserv_backport_action
  assert:
    that:
      - ocserv_backport_action is defined
      - ocserv_backport_action in ['add-repo', 'upgrade', 'rollback', 'verify']
    fail_msg: "必须显式 -e ocserv_backport_action=add-repo|upgrade|rollback|verify"

- import_tasks: add-repo.yml
  when: ocserv_backport_action in ['add-repo', 'upgrade', 'rollback']

- import_tasks: upgrade.yml
  when: ocserv_backport_action == 'upgrade'

- import_tasks: rollback.yml
  when: ocserv_backport_action == 'rollback'

- import_tasks: verify.yml
  when: ocserv_backport_action == 'verify'
```

变量名 `ocserv_backport_action` (避免和 Ansible 内部概念或其他 role 变量冲突)。生产 role 不默认 upgrade, 必须显式指定。

**调用示例:**
```bash
# staging 升级 (CI 自动)
ansible-playbook -i inventories/staging site.yml \
  -e ocserv_backport_action=upgrade \
  -e ocserv_target_version=1.5.0-1~bpo13+1

# prod 升级 (人工, 在 promote-prod 之后独立执行)
ansible-playbook -i inventories/production site.yml \
  -e ocserv_backport_action=upgrade \
  -e ocserv_target_version=1.5.0-1~bpo13+1

# prod 回滚 (人工)
ansible-playbook -i inventories/production site.yml \
  -e ocserv_backport_action=rollback \
  -e ocserv_target_version=1.5.0-1~bpo13+1

# 仅探活
ansible-playbook -i inventories/production site.yml \
  -e ocserv_backport_action=verify
```

### 5.11 apt-cache policy 校验脚本

`scripts/assert-apt-policy.sh` 是版本化脚本, 解析 `apt-cache policy ocserv` 输出, 验收 candidate 来源/版本/priority。

**输入参数:**
```text
--package <name>              如 ocserv
--expected-version <ver>      如 1.5.0-1~bpo13+1
--expected-origin <origin>    如 THEHKUS-Backports
--expected-suite <suite>      如 trixie-production (注意: 见 5.12 release 字段验证)
--expected-priority <n>       如 1001
```

**行为:**
```text
1. apt-cache policy <package>
2. 解析 Candidate 行, 断言 Candidate == expected_version
3. 解析版本表, 找到 expected_version 对应来源
4. 断言该来源含 expected_origin 且 (suite 匹配 expected_suite)
5. 断言该来源 priority == expected_priority
成功: 退出 0
失败: 退出非 0, 打印完整 apt-cache policy 输出便于排查
```

**示例验收输出 (成功):**
```text
OK: Candidate = 1.5.0-1~bpo13+1
OK: 来源 = THEHKUS-Backports trixie-production, priority 1001
```

Ansible upgrade/verify 通过 `script:` 模块调用, 保证本地与 CI 行为一致。

### 5.12 pinning release 字段实现后验证

pinning 模板用 `n={{ ocserv_repo_suite }}` 匹配。`n=` 对应 APT release 的 codename; aptly 发布时 `distribution` 在 `apt-cache policy` 中显示为 `a=`、`n=` 还是两者都有, 需在 staging 上确认。

```text
实现后必须以 apt-cache policy ocserv 的 release 字段为准。
若 trixie-production 显示在 a= 而非 n=:
  pinning 应调整为 a=trixie-production, 或同时使用 a/n 匹配。
验收标准不变:
  ocserv 私有仓库版本 priority = 1001
  私有仓库其他包 priority = -1
```

5.11 的 `assert-apt-policy.sh` 在 staging 实测后, 据此确定 `--expected-suite` 的匹配方式 (字段名)。

---

## 第 6 节: 构建机环境初始化与 dry-run 流程

### 6.1 构建机初始化清单 (一次性)

目标: 专用构建机 / self-hosted runner 主机, Debian trixie amd64, 专用 `builder` 用户。

```text
[1] 基础构建工具链
    apt install -y \
      sbuild schroot debootstrap \
      build-essential devscripts debhelper debhelper-compat \
      dpkg-dev fakeroot lintian quilt \
      rclone aptly gnupg git curl ca-certificates
    (schroot 是 sbuild 的 chroot backend, 已包含; 不单独装 sbuild-schroot)

[2] trixie sbuild schroot
    sbuild-createchroot \
      --arch=amd64 \
      --components=main \
      trixie /var/lib/sbuild/trixie-amd64-sbuild \
      http://deb.debian.org/debian
    schroot APT sources 严格限定:
      允许  trixie / trixie-updates / trixie-security / 必要时受控内部 build-dep 仓库
      禁止  sid / unstable / testing(forky) / 非受控第三方仓库

[3] GPG 签名 key (本地生成, 不出构建机)
    gpg --generate-key  (专用 backport signing key)
    gpg --armor --export <KEYID> > ansible/roles/.../files/thehkus-backports.asc
    记录 KEYID + passphrase → passphrase 入 GitHub secret

[4] aptly 初始化
    aptly config edit: 指定 gpgKey, rootDir=/var/aptly
    aptly repo create ocserv-backports
    origin 固定: THEHKUS-Backports
    owner 设置 (builder 用户运行 aptly/rclone):
      chown -R builder:builder /var/aptly

[5] 本地 publish 目录
    mkdir -p /var/aptly/public/{testing,prod}
    chown -R builder:builder /var/aptly/public
    mkdir -p /var/aptly/.locks        # flock 锁文件目录
    chown -R builder:builder /var/aptly/.locks
    chmod 0755 /var/aptly/.locks

[6] R2 / Cloudflare 配置
    rclone config: 命名 remote "r2", 不保存 access/secret
    (CI runtime 通过环境变量注入 R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY)
    Cloudflare: custom domain apt.example.com → R2 bucket
    缓存规则: /dists/* no-cache, /pool/* 长 TTL

[7] GitHub self-hosted runner
    按官方文档注册 runner, 标签 [self-hosted, builder]
    验证 runner 能访问 R2/CF 凭据 (环境变量) 与本地 GPG keyring

[8] GitHub secrets (repo 或 environment 级)
    R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET
    CF_API_TOKEN / CF_ZONE_ID
    GPG_PASSPHRASE
    (SSH 私钥 / GPG 私钥 / aptly DB 均不入 secrets)

[9] 权限隔离
    创建专用 builder 用户运行 runner / sbuild / aptly / rclone / ansible
    不让 runner 直接以 root 长驻
    需要 root 的操作通过 sudo 白名单执行 (sbuild / schroot / system maintenance)

[10] 备份 (构建机有持久状态, 必须备份)
    /var/aptly                  (仓库状态 + snapshot 历史)
    ~/.gnupg                    (仓库签名能力)
    /etc/schroot/chroot.d/      (sbuild chroot 定义)
    rclone config
    GitHub runner 配置
    没有备份则 R2 静态仓库可继续被 apt 读取, 但无法可靠 publish switch 或回滚
```

### 6.2 dry-run 目标

用一条可复现命令链验证整条 pipeline 的脚本正确性, **不触碰 R2 / staging / prod / 正式 aptly DB**。任何一步失败即定位到具体脚本。是 writing-plans 阶段每步实现后的验收基线。

### 6.3 dry-run 流程 (全本地)

```
┌─ 1. 源码获取 (构建机本体) ──────────────────────┐
│  make fetch                                     │
│  断言: build/source/ocserv-1.5.0/ 存在          │
│      + ocserv_1.5.0-1.dsc 存在                  │
└────────────────────┬────────────────────────────┘
                     ↓
┌─ 2. changelog 改写 ────────────────────────────┐
│  make rewrap                                    │
│  断言: debian/changelog 顶部版本 = 1.5.0-1~bpo13+1 │
│      distribution = trixie                      │
└────────────────────┬────────────────────────────┘
                     ↓
┌─ 3. 重出 source package ───────────────────────┐
│  make src-pkg                                   │
│  断言: ocserv_1.5.0-1~bpo13+1.dsc 生成          │
└────────────────────┬────────────────────────────┘
                     ↓
┌─ 4. sbuild 二进制构建 ─────────────────────────┐
│  make binary                                    │
│  断言: ocserv_1.5.0-1~bpo13+1_amd64.deb 生成    │
│      + .changes / .buildinfo                    │
└────────────────────┬────────────────────────────┘
                     ↓
┌─ 5. lintian ───────────────────────────────────┐
│  make lint                                      │
│  断言: 无 Error (Warning 可接受, 记录)          │
└────────────────────┬────────────────────────────┘
                     ↓
┌─ 6. smoke-basic (trixie 容器, 无 systemd) ──────┐
│  make smoke-basic                               │
│  干净 trixie rootfs/container 中 apt install deb│
│  断言: dpkg-query 版本正确                      │
│      ocserv --version 可执行                    │
│      systemd unit 文件存在                      │
│      配置文件路径存在                           │
│      二进制依赖完整 (仅对 /usr/sbin/ocserv 和    │
│        /usr/bin/occtl 执行 ldd, 确认无 not found│
│        不递归扫整个包, 避免误扫脚本/插件/非 ELF)│
└────────────────────┬────────────────────────────┘
                     ↓
┌─ 7. aptly 本地验证 (临时 DB, 不污染正式) ───────┐
│  APTLY_ROOT_DIR=$(mktemp -d) 使用临时 aptly DB  │
│  aptly repo create ocserv-backports-dryrun      │
│  aptly repo add ocserv-backports-dryrun *.deb   │
│  aptly snapshot create <snap> from repo         │
│  aptly snapshot show <snap>                     │
│  断言: snapshot 内 ocserv 版本正确              │
│  ❌ 不 publish / 不 sync R2                      │
│  清理临时 rootDir                               │
└────────────────────┬────────────────────────────┘
                     ↓
┌─ 8. snapshot 名一致性 ─────────────────────────┐
│  scripts/snapshot-name.sh                       │
│  断言: 输出 = ocserv-1.5.0-1~bpo13+1-build-42   │
│  CI/Makefile/aptly 三处引用同一脚本             │
└─────────────────────────────────────────────────┘
```

### 6.4 smoke-test 分级

```text
smoke-basic (CI lint-and-smoke 阶段强制):
  干净 trixie rootfs/container 中 apt install deb
  dpkg-query 检查版本
  ocserv --version
  systemd unit 文件存在
  配置文件路径存在
  二进制依赖完整 (仅对 /usr/sbin/ocserv 和 /usr/bin/occtl 执行 ldd, 确认无 not found)
  (不假设 systemd / TUN / UDP 可用, 不递归 ldd 整个包)

smoke-service (staging verify 阶段强制):
  在 systemd VM / privileged LXC / staging VM 中启动 ocserv
  检查 systemd active
  检查 TCP/UDP 监听
  检查 journalctl 无 fatal
```

普通容器通常没有完整 systemd, 也没有 `/dev/net/tun`、`CAP_NET_ADMIN`、真实 UDP/TUN 路径。CI 阶段只跑 smoke-basic; 真正 `systemctl start ocserv + TCP/UDP` 放 staging verify。

### 6.5 dry-run 边界

```text
✅ 执行:
  fetch / rewrap / src-pkg / binary / lint / smoke-basic /
  aptly 本地 add+snapshot (临时 APTLY_ROOT_DIR)

❌ 不执行:
  publish snapshot/switch / rclone sync / cf purge /
  ansible staging/prod / 触碰正式 /var/aptly DB
```

dry-run 验证"脚本能不能跑出正确的 deb + snapshot", 不是"能不能上生产"。R2 / staging / prod 留给首次正式运行。

### 6.6 首次正式运行 (dry-run 通过后)

```text
[人工] git push → 触发 ci-testing.yml
       build → lint → smoke-basic → publish-testing → staging-upgrade → staging-verify
[自动] staging-verify 失败 → 自动 rollback-testing
[人工] staging 通过 → workflow_dispatch promote-production.yml
       aptly switch prod → rclone sync /prod/ → cf purge
[人工] 选择升级窗口 → ansible -i production upgrade
[人工] ansible -i production verify
```

### 6.7 首次验证清单 (staging 全链路)

```text
□ staging apt-cache policy ocserv
    Candidate = 1.5.0-1~bpo13+1
    来源 = apt.example.com/testing (THEHKUS-Backports)
    Priority = 1001
□ 其他包 (如 nginx) apt-cache policy
    THEHKUS-Backports 来源 = -1 (确认其余包被拒)
□ dpkg -l ocserv 版本正确
□ systemctl status ocserv = active
□ ss -ltn 含 ocserv TCP 端口
□ ss -lun 含 ocserv UDP 端口
□ journalctl -u ocserv 无 fatal/config error/permission denied
□ occtl show users 可执行 (以 root 或有 socket 权限用户)
□ staging 回滚演练: 故意触发一次 verify 失败, 确认 auto-rollback-testing 生效
```

**回滚演练规则:**
```text
首次上线前必做;
后续常规版本发布可选;
每次重大流程改动后 (CI / aptly / R2 sync / Ansible rollback / pinning) 必做。
```

### 6.8 production 额外验收

```text
□ production apt-cache policy ocserv
    Candidate = 1.5.0-1~bpo13+1
    来源 = apt.example.com/prod (THEHKUS-Backports, trixie-production)
    Priority = 1001
□ production 没有任何 /testing/ source
    /etc/apt/sources.list.d/ 内无 testing baseurl
□ production apt-cache policy ocserv 不显示 trixie-testing
□ production 只显示 trixie-production
□ dpkg -l ocserv 版本正确
□ systemctl status ocserv = active
□ TCP/UDP 监听正常
□ journalctl 无 fatal
```

### 6.9 项目文件结构

```
ocserv-backport/
├── docs/superpowers/specs/
│   └── 2026-06-18-ocserv-backport-design.md   ← 本 spec
├── debian/                        # 补丁 / 本地 debian 化 (如有)
├── scripts/
│   ├── fetch-source.sh
│   ├── rewrap-changelog.sh
│   ├── build-source-package.sh
│   ├── build-binary.sh
│   ├── lint-package.sh
│   ├── smoke-test.sh              # 参数: basic | service
│   ├── snapshot-name.sh           # 单一名源 (CI/Makefile/aptly)
│   ├── assert-apt-policy.sh       # 解析 apt-cache policy, 校验 candidate
│   ├── aptly-publish.sh           # testing 或 prod, by channel
│   ├── aptly-rollback.sh
│   ├── r2-sync.sh                 # 内部映射 RCLONE_CONFIG_R2_* 环境变量
│   └── cf-purge.sh
├── ansible/
│   ├── site.yml
│   ├── inventories/
│   │   ├── staging/group_vars/all.yml
│   │   └── production/group_vars/all.yml
│   └── roles/ocserv_backport/
│       ├── defaults/main.yml
│       ├── tasks/{main,add-repo,upgrade,rollback,verify}.yml
│       ├── templates/{thehkus-backports.sources,ocserv-pin}.j2
│       └── files/thehkus-backports.asc
├── .github/workflows/
│   ├── ci-testing.yml             # push: build→lint→smoke→pub-testing→staging
│   ├── promote-production.yml     # workflow_dispatch: pub-prod→sync→purge
│   └── rollback-production.yml    # workflow_dispatch: switch→sync→purge→ans
└── Makefile                       # 版本化, 本地与 CI 共用
```

---

## 附录: 关键约定速查

| 项 | 值 |
|----|-----|
| upstream 版本 | 1.5.0 |
| Debian 修订 | 1 |
| backport 版本 | 1.5.0-1~bpo13+1 |
| 目标发行版 | Debian 13 trixie |
| changelog distribution | trixie |
| changelog maintainer | Thehkus Admin <master@thehkus.com> |
| aptly origin | THEHKUS-Backports |
| testing suite | trixie-testing |
| production suite | trixie-production |
| GPG 公钥路径 (主机) | /etc/apt/keyrings/thehkus-backports.asc |
| R2 bucket | apt-thehkus |
| 对外域名 | apt.example.com |
| snapshot 名模式 | ocserv-<version>-build-<n> |
| pinning (ocserv) | 1001 |
| pinning (其余) | -1 |
| CI 并发锁 group | repo-publish-lock |
| Ansible 入口变量 | ocserv_backport_action |
| runner 标签 | [self-hosted, builder] |
| 构建机用户 | builder |

## 附录: 实现时待填入的真实值

以下占位符在 spec 中以示例形式出现, 实现时必须替换为真实值, 不得保留字面量:

| 占位符 | 出现位置 | 含义 |
|--------|---------|------|
| `YYYYMMDDTHHMMSSZ` | `scripts/fetch-source.sh` 的 `DEBIAN_SNAPSHOT_TIMESTAMP` | snapshot.debian.org 固定时间点, 锁定 ocserv 1.5.0-1 源码。填入后在 git 中固定, 保证可复现 |
| `apt.example.com` | R2 对外域名 / deb822 baseurl / inventory | Cloudflare custom domain 指向 R2 bucket |
| `apt-thehkus` | rclone remote 的 R2 bucket 名 | R2 bucket 实际名 |
| `<ACCOUNT_ID>` | `scripts/r2-sync.sh` 的 R2 endpoint | Cloudflare account ID, 拼接 R2 S3 endpoint。实现时填入 (可作 CI secret 或构建机固定值) |
| `<KEYID>` | 构建机 GPG key | `aptly config` 与 `gpg --export` 引用的 key ID |
| `build-42` 中的 `42` | snapshot 名 / CI artifact | `scripts/snapshot-name.sh` 运行时从 `git rev-parse --short HEAD` 或 CI run id 动态生成, 非硬编码 |
| staging 端口 `4433` | inventory 示例 | staging 实际端口, 按 staging 真实配置填 |

## 附录: 修订记录

### v2 (review 修正, 2026-06-18)

按代码评审反馈并入以下修正, 提升实现可执行性:

```text
必须修改 (8 项):
1. 初始化清单移除不确定的 sbuild-schroot 包名, schroot 已是 backend
2. R2 凭据明确经 scripts/r2-sync.sh 映射为 RCLONE_CONFIG_R2_* (rclone 不读自定义变量)
3. workflow_dispatch 输入拆分, target_version 只属 rollback-production
4. ci-testing.yml 触发路径加入 ansible/** (role 变更须触发 staging 验证)
5. verify 的 occtl 检查改为 rc != 0 即失败, 不掩盖 permission/socket 错误
6. verify 端口检查改用 ss -H ... sport = :<port> 精确匹配 (避免 443 误匹配 4433)
7. upgrade 写 previous-version 前先 mkdir /var/lib/ocserv-backport
8. apt-cache policy 校验独立成 scripts/assert-apt-policy.sh, 明确解析规则

建议修改 (6 项):
9. pinning n= 字段实现后在真机验证, 可能需改 a= (见 5.12)
10. journalctl 检查对输出 lower 后匹配
11. Makefile 需参 target 加 require-SNAP / require-TARGET_SNAP guard
12. flock 锁文件改放 /var/aptly/.locks/ (builder 可写)
13. 初始化明确 /var/aptly owner = builder:builder
14. smoke-basic ldd 仅扫 /usr/sbin/ocserv 与 /usr/bin/occtl, 不递归整个包
```
