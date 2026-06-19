# trixie 构建主机 bootstrap 自动化 — 设计文档

- 状态: 已确认 (待 writing-plans)
- 日期: 2026-06-19
- 范围: 把现有 `docs/BUILD_HOST_BOOTSTRAP.md`(纯手动 10 段命令)转化为一个幂等、可重跑、阶段化的自动化脚本 `scripts/bootstrap-build-host.sh`,用于在 dedicated trixie amd64 builder 上完成本机初始化
- 父 spec: `docs/superpowers/specs/2026-06-18-ocserv-backport-design.md` §6.1
- 关键边界: bootstrap 只管**构建机本机状态**;GitHub runner 注册与 secrets 留人工后置

## 决策摘要

| 决策点 | 选择 |
|--------|------|
| 脚本运行位置 | A: 目标机(trixie builder)本地跑,不管 OS 安装 |
| 幂等边界 | C: 分阶段幂等(safe-repeat / skip-if-exists / fail-if-exists / 只读) |
| 外部信息传入 | B: 环境变量 > `.bootstrap.env`(chmod 600) > `read -s` 交互回退 |
| GitHub runner/secrets | A: bootstrap 不注册 runner、不写 secrets,只打印手动清单 |
| GPG key 策略 | 三模式显式互斥: `--generate-gpg-key` / `--import-gpg-key <path>` / `--reuse-gpg-key <KEYID>` |
| 实现形态 | 方案 1: 单脚本 + 共享 helpers,阶段函数组织,支持 `--from-stage`/`--only-stage` |
| 运行用户 | `BOOTSTRAP_BUILDER_USER`(默认 builder)+ passwordless sudo,**禁止 root 直接运行** |

## 安全边界(总原则)

```text
本机长期状态由 bootstrap 管;
GitHub 外部权限和 secrets 由人工显式配置;
production 相关外部状态不被 bootstrap 隐式修改;
敏感值不出现在命令行参数、终端日志、set -x 输出中;
GPG signing key 是长期身份,不自动替换;
构建机迁移必须导入旧 key,而不是生成新 key。
```

---

## 第 1 节: 脚本骨架与配置加载

### 1.1 入口与参数解析

```text
scripts/bootstrap-build-host.sh
  ├── _common.sh (复用 + 扩展)
  ├── .bootstrap.env (gitignored, 操作者填真实值)
  └── 阶段函数 + main()
```

**参数(互斥/可选):**

```text
--from-stage <stage>     从指定阶段开始执行(跳过之前的)
--only-stage <stage>     只执行一个阶段
--generate-gpg-key       GPG 模式: 生成新 signing key (fail-if-exists)
--import-gpg-key <path>  GPG 模式: 导入已有私钥
--reuse-gpg-key <KEYID>  GPG 模式: 复用本机已有 key
--dry-run                只打印将执行的动作,不修改状态
-h, --help
```

**约束:**

```text
- 三个 GPG 模式参数互斥,同时给 ≥2 个则 die
- --from-stage 与 --only-stage 互斥
- 非法/未知 stage 名 → die,并列出合法 stage 列表
- GPG 模式延迟到 setup_gpg_key 阶段才校验:
    不指定任何 GPG 模式 → 只在执行到 setup_gpg_key 时 die
    --only-stage install_packages → 不触发 GPG 校验
    --only-stage/--from-stage 包含 setup_gpg_key → 必须校验三模式
  (允许只跑 packages 等阶段不碰 GPG)
```

### 1.2 阶段定义(固定顺序)

```text
preflight              只读: OS=trixie、架构=amd64、非 root + 有 sudo、磁盘两级阈值
load_config            幂等: 加载 .bootstrap.env (权限校验) + 默认值;不主动 read -s
install_packages       safe-repeat: apt install -y 一组包
prepare_directories    safe-repeat: mkdir + chown /var/aptly/{public,.locks,state}
setup_sbuild_chroot    skip-if-exists: chroot 存在则校验 sources、跳过;否则创建
setup_gpg_key          三模式互斥: generate/import/reuse (此阶段才校验模式)
setup_aptly            skip-if-exists: repo 存在跳过;config 校验
setup_rclone_skeleton  skip-if-exists: rclone.conf 只放 remote 名骨架,不存凭据
check_runner           只读: 检测本地 .runner 是否已注册 (已注册=info,非 fail)
check_backups          只读: 检查备份源路径存在性,缺失只 warn 不 die
print_manual_github_steps  纯输出: 打印 GitHub 手动清单 (按 --only-stage 条件执行)
```

**main() 流程:**

```bash
main() {
  parse_args "$@"
  run_stages_in_order    # 按 --from/--only/默认全跑 过滤
}
```

### 1.3 配置加载(优先级 + 修改 1/2/3)

```text
优先级 (高 → 低):
  1. 当前进程环境变量
  2. .bootstrap.env (gitignored, 必须 chmod 600 + owner=当前用户)
  3. read -s 交互回退 (仅 bootstrap 实际消费的敏感必填项,且在对应阶段懒加载)
  4. 可推导默认值 (BOOTSTRAP_BUILDER_USER=builder 等)
  5. 非敏感必填项缺失 → die (仅在对应阶段校验)
```

**load_config 阶段只做:**

```text
- 若 .bootstrap.env 存在: check_secret_file_mode (mode==600, owner==当前用户)
- load_bootstrap_env_defaults(): 只为"当前未设置"的变量填值,不覆盖已有环境变量 (修改 3)
- 填可推导默认值 (仅当未设置):
    BOOTSTRAP_BUILDER_USER=builder
    BOOTSTRAP_APTLY_ROOT=/var/aptly
    BOOTSTRAP_REPO_NAME=ocserv-backports
- 不主动 read -s,不强制 R2/CF/GitHub secrets 存在
```

**配置项分类(修改 1):**

```text
bootstrap 实际消费:
  BOOTSTRAP_BUILDER_USER (默认 builder)
  BOOTSTRAP_APTLY_ROOT (默认 /var/aptly)
  BOOTSTRAP_REPO_NAME (默认 ocserv-backports)
  BOOTSTRAP_APT_BASE_URL (默认 https://apt.example.com)
  BOOTSTRAP_GPG_KEYID (reuse/import 必填)
  BOOTSTRAP_GPG_PASSPHRASE (setup_gpg_key 阶段 read -s)

bootstrap 不实际消费(仅 rclone skeleton 或手动清单提示):
  BOOTSTRAP_R2_ACCOUNT_ID (setup_rclone_skeleton 用;缺失只跳过不 die)
  BOOTSTRAP_R2_BUCKET (默认 apt-thehkus,手动清单用)
  BOOTSTRAP_GITHUB_RUNNER_URL (手动清单用)

当前 bootstrap 不读(留给未来 github-connect.sh):
  BOOTSTRAP_R2_ACCESS_KEY_ID / BOOTSTRAP_R2_SECRET_ACCESS_KEY
  BOOTSTRAP_CF_API_TOKEN / BOOTSTRAP_CF_ZONE_ID
  BOOTSTRAP_GITHUB_RUNNER_TOKEN  (短期 token,不鼓励落盘,见 .env.example 注释)
```

---

## 第 2 节: 各阶段行为与守卫逻辑

### 2.1 preflight(只读校验)

```text
检查:
  /etc/os-release: ID=debian, VERSION_CODENAME=trixie
  架构: uname -m == x86_64
  运行用户: 当前不是 root (die "run as ${BUILDER_USER} with passwordless sudo, not root")
  权限: 有 passwordless sudo (sudo -n true 成功)
  磁盘 (检查 BOOTSTRAP_APTLY_ROOT 与 chroot 目录所在文件系统):
    < 15GB available → die
    15GB–30GB      → warn
    >= 30GB        → pass
行为: 任一 hard 项不满足 → die,明确说明缺什么
理由: 假设目标机是干净 trixie amd64 builder;提前失败比中途失败友好
```

### 2.2 load_config(见 §1.3)

### 2.3 install_packages(safe-repeat)

```text
行为:
  sudo apt-get update
  sudo apt-get install -y <固定包列表>
包列表 (spec §6.1 [1],已移除 sbuild-schroot):
  sbuild schroot debootstrap
  build-essential devscripts debhelper debhelper-compat
  dpkg-dev fakeroot lintian quilt
  rclone aptly gnupg jq docker.io git curl ca-certificates
幂等: apt-get install -y 天然幂等,已装跳过;不 pin 版本
```

### 2.4 prepare_directories(safe-repeat)

```text
行为:
  sudo mkdir -p /var/aptly/public/{testing,prod}
  sudo mkdir -p /var/aptly/.locks
  sudo mkdir -p /var/aptly/state
  sudo chown -R ${BUILDER_USER}:${BUILDER_USER} /var/aptly
  sudo chmod 0755 /var/aptly/.locks
幂等: mkdir -p + chown -R 天然幂等
安全守卫:
  若 /var/aptly 已存在且非空且 owner 既非 root 也非 ${BUILDER_USER}:
    die "unexpected /var/aptly owner; refusing to chown (manual review)"
  (owner 是 root 或 ${BUILDER_USER} 则正常 chown)
注: 不创建 /var/lib/ocserv-backport —— 那是 staging/prod 主机的 audit 目录,非 builder 职责
```

### 2.5 setup_sbuild_chroot(skip-if-exists)

```text
守卫:
  CHROOT_DIR=/var/lib/sbuild/trixie-amd64-sbuild
  [[ -d ${CHROOT_DIR} ]] → log "chroot exists; verifying" → verify_chroot_sources → return
行为(不存在时):
  sudo sbuild-createchroot --arch=amd64 --components=main \
    trixie ${CHROOT_DIR} http://deb.debian.org/debian
  verify_chroot_sources
verify_chroot_sources():
  读取 ${CHROOT_DIR}/etc/apt/sources.list (及 sources.list.d/*.sources)
  断言只含 trixie / trixie-updates / trixie-security
  含 sid / testing / forky → die "chroot sources contaminated; manual fix"
理由: chroot 重建耗时且可能破坏正在用的 chroot;存在则只校验不重建
```

### 2.6 setup_gpg_key(三模式互斥 + 延迟校验)

```text
进入此阶段才校验三模式:
  统计 --generate-gpg-key / --import-gpg-key / --reuse-gpg-key 出现次数
  >1 → die "GPG modes are mutually exclusive"
  ==0 → die "specify one of --generate-gpg-key/--import-gpg-key <path>/--reuse-gpg-key <KEYID>"

懒加载 passphrase (此阶段):
  read_secret_if_missing BOOTSTRAP_GPG_PASSPHRASE "GPG passphrase"

固定 uid 约定 (generate 模式生成时):
  Name-Real: THEHKUS-Backports
  Name-Email: master@thehkus.com

模式逻辑:

  --generate-gpg-key:
    守卫 (KEYID 精确优先 + uid/email 兜底):
      BOOTSTRAP_GPG_KEYID 已设置且本机有该 secret key
        → die "key ${KEYID} exists; use --reuse-gpg-key ${KEYID} (do NOT regenerate)"
      本机有 uid/email 匹配 THEHKUS-Backports 或 master@thehkus.com 的 secret key
        → die "signing key already exists; use --reuse-gpg-key <KEYID>"
    否则:
      gpg --batch --generate-key <临时 keyfile (Name/Email/Passphrase)>
      从 gpg 输出解析新 KEYID
      设置 BOOTSTRAP_GPG_KEYID=<新 KEYID>
    导出公钥 → ansible/roles/ocserv_backport/files/thehkus-backports.asc

  --import-gpg-key <path>:
    require BOOTSTRAP_GPG_KEYID (非敏感必填,缺失 die)
    gpg --list-secret-keys ${KEYID} 已存在:
      log "key already in keyring; treating import as reuse"
      导出公钥 → return    (重跑幂等,不 die)
    校验:
      <path> 不存在或不可读 → die
      gpg --import <path>
      gpg --list-secret-keys ${KEYID} 无 private key → die "imported key has no private part"
      KEYID 与导入文件不匹配 → die
    导出公钥 → .../thehkus-backports.asc

  --reuse-gpg-key <KEYID>:
    require BOOTSTRAP_GPG_KEYID (== 参数值或 env)
    gpg --list-secret-keys ${KEYID} 无 private key → die "no private key for ${KEYID}"
    导出公钥 → .../thehkus-backports.asc (覆盖 placeholder)

安全:
  passphrase 不写日志,不 set -x
  私钥绝不导出 (只导出公钥)
  dry-run 下只打印 "DRY-RUN: would generate GPG signing key for THEHKUS-Backports",
    不打印 keyfile 内容
```

### 2.7 setup_aptly(skip-if-exists + config 校验)

```text
行为:
  aptly repo show ${REPO_NAME} 成功 → log "repo exists; skipping" → 进入 config 校验
  否则 aptly repo create ${REPO_NAME}

aptly config 校验/生成:
  config 文件 (~/.aptly.conf 或 $APTLY_CONFIG) 存在:
    断言 rootDir == ${BOOTSTRAP_APTLY_ROOT} (/var/aptly)
    断言 gpgKey == ${BOOTSTRAP_GPG_KEYID}
    不匹配 → die "aptly config mismatch; manual review (refuse to auto-rewrite)"
  config 文件不存在:
    生成最小配置 (不要求人工 aptly config edit):
      { "rootDir": "/var/aptly", "gpgProvider": "gpg", "gpgKey": "<KEYID>" }
理由: repo create 幂等可跳过;config 错配影响发布不自动改;缺失则生成最小配置
```

### 2.8 setup_rclone_skeleton(skip-if-exists)

```text
守卫:
  ~/.config/rclone/rclone.conf 已含 [r2] section → log "rclone skeleton exists" → return
行为:
  BOOTSTRAP_R2_ACCOUNT_ID 存在:
    rclone config create r2 s3 provider Cloudflare \
      endpoint https://${BOOTSTRAP_R2_ACCOUNT_ID}.r2.cloudflarestorage.com \
      no_check_bucket true
    (不写 access_key_id / secret_access_key —— 运行时由 r2-sync.sh 从 CI 环境变量注入)
  BOOTSTRAP_R2_ACCOUNT_ID 缺失:
    warn "BOOTSTRAP_R2_ACCOUNT_ID not set; skipping rclone skeleton (r2-sync.sh injects creds at runtime anyway)"
    return  (不 die)
理由: skeleton 可跳过;secrets 绝不落 rclone.conf (与 spec §3.4 一致);ACCOUNT_ID 非强制
```

### 2.9 check_runner(只读,修改 4)

```text
行为 (不注册、不修改):
  RUNNER_DIR=${BOOTSTRAP_RUNNER_DIR:-${HOME}/actions-runner}
  ${RUNNER_DIR}/.runner 存在:
    info "runner already registered at ${RUNNER_DIR}"
    owner != ${BUILDER_USER} → warn "runner dir owner mismatch"
    return  (已注册是重跑正常状态,不 die)
  ${RUNNER_DIR} 存在但无 .runner:
    warn "runner dir exists but not registered; see manual steps"
  ${RUNNER_DIR} 不存在:
    warn "no runner detected; register via GitHub UI (see manual steps)"
理由: bootstrap 不注册 runner (问题 4 锁定);已注册是正常状态
```

### 2.10 check_backups(只读,warn 不 die)

```text
行为 (只检查源路径存在性):
  逐一检查:
    /var/aptly            (aptly DB + snapshot 历史)
    /var/aptly/state      (manifest)
    ~/.gnupg              (signing key)
    /etc/schroot/chroot.d/
    ~/.config/rclone/rclone.conf
    runner config (${RUNNER_DIR})
  路径存在 → info "<path> exists"
  路径缺失 → warn "<path> not found; ensure your backup system covers it"
  永不 die (备份是运维约定,不是 bootstrap 前置;bootstrap 不是备份监控系统)
```

### 2.11 print_manual_github_steps(纯输出,修改 1)

```text
触发条件:
  默认全流程 → 总是执行
  --from-stage <X> → 总是执行 (除非 X 排在它之后)
  --only-stage <X> → 只在 X==print_manual_github_steps 时执行
行为: 打印 5 段清单 (secrets 名称用 CI 实际名,见 §3.3 映射):
  1. 注册 self-hosted runner (GitHub UI 步骤 + labels [self-hosted,builder] + 以 builder 用户跑)
  2. 配置 GitHub secrets (7 个: R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_ACCOUNT_ID/
     R2_BUCKET/CF_API_TOKEN/CF_ZONE_ID/GPG_PASSPHRASE)
  3. gh CLI 命令示例 (gh secret set ...)
  4. 配置 protected environment: production + required reviewers
  5. 验证 runner labels ([self-hosted, builder])
secrets 真实值不要求存在;BOOTSTRAP_GITHUB_RUNNER_URL 若提供则填充示例命令
```

---

## 第 3 节: 文件结构、Makefile 集成、测试与 `.bootstrap.env`

### 3.1 文件清单

```text
新增:
  scripts/bootstrap-build-host.sh        # 主脚本,11 阶段 + main + parse_args + run_cmd
  .bootstrap.env.example                 # 配置模板,入仓
  test/test_bootstrap_helpers.bats       # 纯逻辑 helper 单测

扩展:
  scripts/_common.sh                     # 加 helper (见 §3.2)
  Makefile                               # bootstrap-build-host target (ARGS 传参)
  .gitignore                             # .bootstrap.env
  docs/BUILD_HOST_BOOTSTRAP.md           # 改为指向脚本 + 保留手动清单引用
```

### 3.2 `_common.sh` 新增 helper

```bash
cmd_exists()                 { command -v "$1" >/dev/null 2>&1; }
is_set()                     { [[ -n "${!1:-}" ]]; }
require_var()                { local name="$1"; [[ -n "${!name:-}" ]] || die "required variable missing: ${name}"; }

# read -s 补全缺失的敏感项;不写日志、不 set -x
read_secret_if_missing() {
  local name="$1" prompt="$2"
  if [[ -z "${!name:-}" ]]; then
    read -r -s -p "${prompt}: " "${name}" >&2
    printf '\n' >&2
    export "${name}"
  fi
}

# load_bootstrap_env_defaults <file>
# 只为当前未设置的变量填入 <file> 的值,不覆盖已有环境变量
# key 校验: 只接受 BOOTSTRAP_[A-Z0-9_]+
# 值解析: 用 ${line%%=*} / ${line#*=} 避免 IFS='=' 截断含 = 的 token
load_bootstrap_env_defaults() {
  local file="$1" line key val
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"   # 去外层引号
    [[ "${key}" =~ ^BOOTSTRAP_[A-Z0-9_]+$ ]] || continue
    [[ -n "${!key:-}" ]] || export "${key}=${val}"
  done < "${file}"
}

# check_secret_file_mode <file>  (Linux stat -c;此脚本只在目标机 Linux 跑)
check_secret_file_mode() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local mode owner
  mode="$(stat -c '%a' "${file}")"
  owner="$(stat -c '%U' "${file}")"
  [[ "${mode}" == "600" ]] || die "${file} must be chmod 600 (got ${mode})"
  [[ "${owner}" == "$(id -un)" ]] || die "${file} must be owned by $(id -un) (got ${owner})"
}

# run_cmd: 统一 dry-run 封装;含 secret 的命令不要传给它打印
run_cmd() {
  if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
```

### 3.3 `.bootstrap.env.example`

```ini
# === bootstrap 实际消费 (bootstrap 会用到) ===
# Non-sensitive, 可推导默认
BOOTSTRAP_BUILDER_USER=builder
BOOTSTRAP_APTLY_ROOT=/var/aptly
BOOTSTRAP_REPO_NAME=ocserv-backports
BOOTSTRAP_APT_BASE_URL=https://apt.example.com

# Non-sensitive, reuse/import 模式必填
BOOTSTRAP_GPG_KEYID=

# Sensitive, setup_gpg_key 阶段按需 read -s (可在此预填)
BOOTSTRAP_GPG_PASSPHRASE=

# === bootstrap 不实际消费,仅用于 rclone skeleton / 手动清单 ===
BOOTSTRAP_R2_ACCOUNT_ID=
BOOTSTRAP_R2_BUCKET=apt-thehkus
BOOTSTRAP_GITHUB_RUNNER_URL=

# === 当前 bootstrap 不读这些;仅用于人工清单提示或未来 github-connect.sh ===
# 真正使用者是 CI 的 r2-sync.sh / cf-purge.sh,通过 GitHub secrets 注入
BOOTSTRAP_R2_ACCESS_KEY_ID=
BOOTSTRAP_R2_SECRET_ACCESS_KEY=
BOOTSTRAP_CF_API_TOKEN=
BOOTSTRAP_CF_ZONE_ID=

# BOOTSTRAP_GITHUB_RUNNER_TOKEN is intentionally not required by bootstrap.
# Future github-connect.sh may use it, but bootstrap-build-host.sh will not.
# 短期 token 不鼓励长期落盘。
```

**secrets 名称映射 (print_manual_github_steps 输出时明确):**

```text
BOOTSTRAP_R2_ACCESS_KEY_ID    → GitHub secret R2_ACCESS_KEY_ID
BOOTSTRAP_R2_SECRET_ACCESS_KEY → GitHub secret R2_SECRET_ACCESS_KEY
BOOTSTRAP_GPG_PASSPHRASE      → GitHub secret GPG_PASSPHRASE
(其余同名: R2_ACCOUNT_ID / R2_BUCKET / CF_API_TOKEN / CF_ZONE_ID)
```

### 3.4 Makefile 集成(ARGS 传参,不用 $$@)

```makefile
.PHONY: bootstrap-build-host
bootstrap-build-host: ## Bootstrap the trixie build host (run ON the builder)
	scripts/bootstrap-build-host.sh $(ARGS)
```

**使用:**

```bash
make bootstrap-build-host ARGS="--only-stage install_packages"
make bootstrap-build-host ARGS="--from-stage setup_gpg_key --reuse-gpg-key ABCD1234"
make bootstrap-build-host ARGS="--dry-run --generate-gpg-key"
# 或直接执行 (文档推荐):
scripts/bootstrap-build-host.sh --only-stage install_packages
```

> `$$@` 不可用: make 会把 `--only-stage` 当自己的选项解析,且 make 不给 recipe shell 传位置参。统一用 `ARGS="..."` 或直接跑脚本。

### 3.5 docs/BUILD_HOST_BOOTSTRAP.md 改写

从"10 段手动命令"改为:

```text
- 指向 scripts/bootstrap-build-host.sh 作为主路径
- 保留 .bootstrap.env 配置说明 (复制 .bootstrap.env.example + chmod 600)
- 保留"手动 GitHub 步骤"引用 (脚本也会打印,文档作长期参考)
- 加"何时手跑 vs 何时用脚本": 首次用脚本全流程;日常漂移检查用 --only-stage
```

### 3.6 测试策略

```text
单测范围 (test/test_bootstrap_helpers.bats):
  load_bootstrap_env_defaults: 不覆盖已有环境变量 (修改 3 关键)
  load_bootstrap_env_defaults: 跳过注释行/空行
  load_bootstrap_env_defaults: 去引号
  load_bootstrap_env_defaults: 值含 = 不截断
  load_bootstrap_env_defaults: 拒绝非 BOOTSTRAP_ 前缀的 key
  check_secret_file_mode: mode!=600 die (临时文件)
  check_secret_file_mode: owner!=当前用户 die
  require_var: 缺失 die
  is_set / cmd_exists: 基础行为
  run_cmd: dry-run 下只打印不执行

不单测 (外部系统/需 trixie):
  sbuild-createchroot / aptly repo create / gpg --generate-key / rclone config
  apt-get install / GitHub runner 真实状态
  (mock 这些会变成"测试 mock 本身",收益低)

集成验证 (在目标机上):
  --dry-run 跑一遍全流程,确认无副作用
```

### 3.7 `--dry-run` 语义(修改 2)

```text
BOOTSTRAP_DRY_RUN=1:
  修改状态的命令 (sudo apt-get install / sbuild-createchroot / gpg --generate-key /
    aptly repo create / rclone config / chown): 经 run_cmd 只打印,不执行
  只读检查 (preflight / verify_chroot_sources / config 校验 / check_runner /
    check_backups): 正常执行 (无副作用)
  含 secret 的命令: 不打印 secret 值
    GPG: 打印 "DRY-RUN: would generate GPG signing key for THEHKUS-Backports",
         不打印 keyfile 内容
```

---

## 附录: 实现时待填入的真实值

| 占位符 | 出现位置 | 含义 |
|--------|---------|------|
| `https://apt.example.com` | `BOOTSTRAP_APT_BASE_URL` 默认 | Cloudflare custom domain 指向 R2 bucket (沿用父 spec) |
| `apt-thehkus` | `BOOTSTRAP_R2_BUCKET` 默认 | R2 bucket 实际名 (沿用父 spec) |
| `THEHKUS-Backports` / `master@thehkus.com` | GPG uid 约定 | 签名 key 的 Name-Real / Name-Email (沿用父 spec) |
| `<KEYID>` | reuse/import/generate 输出 | GPG key ID,运行时确定 |

## 附录: 明确不做的事

```text
bootstrap 不自动注册 GitHub runner
bootstrap 不自动 gh secret set
bootstrap 不调用 GitHub API 创建 runner token
bootstrap 不自动覆盖已有 GPG signing key
bootstrap 不自动删除/重建 existing chroot
bootstrap 不自动删除/重建 aptly repo
bootstrap 不自动改写已有 aptly config (错配 die)
bootstrap 不创建 /var/lib/ocserv-backport (那是 staging/prod 主机目录)
bootstrap 不验证备份系统在跑 (只查源路径存在)
bootstrap 不要求 R2/CF/GitHub secrets 存在 (只在手动清单提示)
```
