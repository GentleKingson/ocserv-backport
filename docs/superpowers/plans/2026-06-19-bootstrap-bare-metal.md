# bootstrap-bare-metal.sh 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 `scripts/bootstrap-bare-metal.sh` 裸机 root 准备脚本, 补齐 runbook 第 1 步的自动化缺口, 并配套 bats 单测与 runbook 集成。

**Architecture:** TDD 分层 — 先实现 3 个纯函数 (validate_builder_user_name / validate_pubkey_line / check_disk_threshold_inner) 并配 bats 测试 (可 CI 跑), 再实现副作用函数 (preflight/装包/建用户/sudoers/SSH/clone/交接), 最后集成 Makefile test target 与 runbook 第 1 步改写。SOURCE_GUARD 模式让脚本能被 bats source 测函数而不执行 main。

**Tech Stack:** Bash (set -euo pipefail), bats 测试框架, getent/visudo/useradd/apt-get (Linux trixie 副作用)。

**Spec 来源:** `docs/superpowers/specs/2026-06-19-bootstrap-bare-metal-design.md` (已确认 v1, 含 6 处审阅修正)

---

## 约束 (所有 task 必须遵守)

```text
- 严格按 spec 实现, 不擅自扩展 (YAGNI)
- 副作用函数不单测 (靠 set -e + die + 真机验证), 只测纯函数
- 所有副作用必须在 main 调用链里, source 脚本时不触发 (SOURCE_GUARD)
- 不绕过 sbuild group 重新登录 (脚本在 root 阶段完成后明确停止)
- check_disk_threshold_inner 输出 ok/warn/die 字符串, 不用返回码 (避开 set -e)
- home 路径用 get_builder_home (getent passwd), 不假设 /home/<name>
- authorized_keys owner 用 id -gn, 不假设组名 == 用户名
- sudoers 先写临时文件 + visudo -cf 验证, 再 install (install 失败也要 rm tmp)
- validate_pubkey_line 拆字段, body 非空 + base64 字符集
- 不引入 getopt/getopts (while + case + die, 与 bootstrap-build-host.sh 一致)
```

## 文件结构

```text
创建:
  scripts/bootstrap-bare-metal.sh          主交付物 (root 裸机准备脚本)
  test/test_bootstrap_bare_metal.bats      纯函数 bats 测试

修改:
  Makefile                                 新增 test target (bats test/)
  docs/trixie-builder-dryrun-runbook.md    第 1 步主路径改脚本, 手敲移附录 C

不修改:
  scripts/bootstrap-build-host.sh          (只交接, 不接管)
  scripts/_common.sh                       (只复用 log/die, 不改)
  test/helpers/bats-helper.bash            (复用, 不改)
```

---

## Task 1: 创建脚本骨架 (头部 + SOURCE_GUARD + main 空壳)

**Files:**
- Create: `scripts/bootstrap-bare-metal.sh`

建立可运行但只做参数解析的骨架, 确保头部约束、_common.sh source、SOURCE_GUARD 正确。后续 task 往里填函数。

- [ ] **1.1 创建脚本骨架**

创建 `scripts/bootstrap-bare-metal.sh`:

```bash
#!/usr/bin/env bash
# scripts/bootstrap-bare-metal.sh
# Bare-metal root setup for the trixie builder (runbook step 1).
# Automates: install sudo/git/ca-certificates, create builder user, configure
# passwordless sudo, configure SSH authorized_keys, optional repo clone.
# Stops before bootstrap-build-host.sh (sbuild group relogin cannot be bypassed).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/_common.sh"

# ---- parameters (set by parse_args) -----------------------------------------
BUILDER_USER="builder"
SSH_PUBKEY_FILE=""
SSH_PUBKEY=""
REPO_URL=""
HOST_HINT="<host>"
PUBKEYS=""   # multi-line string of validated pubkey lines, populated by parse_args

usage() {
  cat >&2 <<EOF
Usage: $0 --ssh-pubkey-file <path> | --ssh-pubkey <string> | ADMIN_PUBKEY=<string> [options]

Required (exactly one of):
  --ssh-pubkey-file <path>   read SSH public keys from file (multi-line ok)
  --ssh-pubkey <string>      single SSH public key string
  ADMIN_PUBKEY               env var: single SSH public key string

Optional:
  --builder-user <name>      builder username (default: builder; must not be root)
  --repo-url <url>           clone repo to <builder-home>/ocserv-backport (skip if absent)
  --host-hint <host>         host shown in next-steps ssh hint (default: <host>)
  -h, --help                 show this help
EOF
}

# ---- pure functions (defined here, tested by bats) --------------------------
# (filled in Task 2)

# ---- side-effect functions ---------------------------------------------------
# (filled in Tasks 3-5)

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-pubkey-file) SSH_PUBKEY_FILE="${2:-}"; shift 2 ;;
      --ssh-pubkey)      SSH_PUBKEY="${2:-}"; shift 2 ;;
      --builder-user)    BUILDER_USER="${2:-}"; shift 2 ;;
      --repo-url)        REPO_URL="${2:-}"; shift 2 ;;
      --host-hint)       HOST_HINT="${2:-}"; shift 2 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 usage; die "unknown argument: $1" ;;
    esac
  done
  # (full validation filled in Task 3)
}

main() {
  parse_args "$@"
  # (stages filled in Tasks 3-5)
  :
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **1.2 设置可执行权限**

```bash
chmod +x scripts/bootstrap-bare-metal.sh
```

- [ ] **1.3 验证骨架可运行 (bash 语法检查)**

```bash
bash -n scripts/bootstrap-bare-metal.sh && echo "syntax OK"
scripts/bootstrap-bare-metal.sh --help
```

Expected: `syntax OK`, 然后打印 usage 文本并 exit 0。

- [ ] **1.4 提交骨架**

```bash
git add scripts/bootstrap-bare-metal.sh
git commit -m "feat(bare-metal): script skeleton with header, SOURCE_GUARD, arg parsing shell"
```

---

## Task 2: 纯函数 + bats 测试 (TDD)

**Files:**
- Modify: `scripts/bootstrap-bare-metal.sh` (在 "pure functions" 区块填入 3 个函数)
- Create: `test/test_bootstrap_bare_metal.bats`

先写测试 (TDD), 再实现函数让测试通过。

- [ ] **2.1 创建 bats 测试文件 (含全部用例, 此时函数未实现会失败)**

创建 `test/test_bootstrap_bare_metal.bats`:

```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }

# 共用: 在 run 子进程里 source 脚本并调函数, 隔离 _common.sh 的 set 约束
call_func() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/bootstrap-bare-metal.sh'; $*"
}

# ---- validate_builder_user_name ----

@test "validate_builder_user_name: accepts default 'builder'" {
  call_func "validate_builder_user_name builder"
  [ "$status" -eq 0 ]
}

@test "validate_builder_user_name: accepts 'my_builder' and 'builder\$'" {
  call_func "validate_builder_user_name my_builder"
  [ "$status" -eq 0 ]
  call_func 'validate_builder_user_name "builder\$"'
  [ "$status" -eq 0 ]
}

@test "validate_builder_user_name: rejects 'root'" {
  call_func "validate_builder_user_name root"
  [ "$status" -ne 0 ]
}

@test "validate_builder_user_name: rejects uppercase / digit-start / spaces" {
  call_func "validate_builder_user_name Builder"
  [ "$status" -ne 0 ]
  call_func "validate_builder_user_name 1builder"
  [ "$status" -ne 0 ]
  call_func 'validate_builder_user_name "bu il der"'
  [ "$status" -ne 0 ]
}

# ---- validate_pubkey_line ----

@test "validate_pubkey_line: accepts modern key types" {
  call_func 'validate_pubkey_line "ssh-ed25519 AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "ssh-rsa AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "ecdsa-sha2-nistp256 AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "ecdsa-sha2-nistp384 AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "ecdsa-sha2-nistp521 AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "sk-ssh-ed25519@openssh.com AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "sk-ecdsa-sha2-nistp256@openssh.com AAAA"'
  [ "$status" -eq 0 ]
}

@test "validate_pubkey_line: accepts key with comment (3rd field)" {
  call_func 'validate_pubkey_line "ssh-ed25519 AAAA user@host"'
  [ "$status" -eq 0 ]
}

@test "validate_pubkey_line: rejects ssh-dss / empty / options / garbage / keytype-only" {
  call_func 'validate_pubkey_line "ssh-dss AAAA"'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line ""'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "command=foo ssh-ed25519 AAAA"'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "not-a-key"'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "ssh-ed25519"'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "ssh-ed25519 "'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "ssh-ed25519 body with spaces"'
  [ "$status" -ne 0 ]
}

# ---- check_disk_threshold_inner ----

@test "check_disk_threshold_inner: die <15, warn 15-29, ok >=30" {
  call_func "check_disk_threshold_inner 10"
  [ "$output" = "die" ]
  call_func "check_disk_threshold_inner 14"
  [ "$output" = "die" ]
  call_func "check_disk_threshold_inner 15"
  [ "$output" = "warn" ]
  call_func "check_disk_threshold_inner 29"
  [ "$output" = "warn" ]
  call_func "check_disk_threshold_inner 30"
  [ "$output" = "ok" ]
  call_func "check_disk_threshold_inner 100"
  [ "$output" = "ok" ]
}
```

- [ ] **2.2 运行测试, 确认全部失败 (函数未定义)**

```bash
bats test/test_bootstrap_bare_metal.bats
```

Expected: 所有 `@test` 失败 (validate_builder_user_name / validate_pubkey_line / check_disk_threshold_inner 未定义, bash 报 command not found)。

- [ ] **2.3 实现三个纯函数 (填入脚本的 "pure functions" 区块)**

在 `scripts/bootstrap-bare-metal.sh` 的 `# ---- pure functions` 注释下, 替换 `(filled in Task 2)` 为:

```bash
validate_builder_user_name() {
  local name="$1"
  [[ "${name}" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || return 1
  [[ "${name}" != "root" ]] || return 1
  return 0
}

validate_pubkey_line() {
  local line="$1"
  local key_type key_body rest
  # 拆字段: 第一字段必须直接是 key type (不支持 command=/from= 等 options 前缀)
  read -r key_type key_body rest <<<"${line}"
  # key type 和 key body 都必须非空 (拒绝 "ssh-ed25519 " / "ssh-ed25519")
  [[ -n "${key_type:-}" && -n "${key_body:-}" ]] || return 1
  case "${key_type}" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
      ;;
    *)
      return 1
      ;;
  esac
  # 基础防呆: public key body 不应含空格, base64 字符集
  [[ "${key_body}" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  return 0
}

check_disk_threshold_inner() {
  local avail_gb="$1"
  if   (( avail_gb < 15 )); then printf 'die'
  elif (( avail_gb < 30 )); then printf 'warn'
  else printf 'ok'
  fi
}
```

- [ ] **2.4 运行测试, 确认全部通过**

```bash
bats test/test_bootstrap_bare_metal.bats
```

Expected: 所有 `@test` 通过 (20+ 用例全绿)。

- [ ] **2.5 提交**

```bash
git add scripts/bootstrap-bare-metal.sh test/test_bootstrap_bare_metal.bats
git commit -m "feat(bare-metal): pure functions (validate_*, check_disk_threshold_inner) with bats tests"
```

---

## Task 3: 磁盘检查 + 参数解析 + run_preflight

**Files:**
- Modify: `scripts/bootstrap-bare-metal.sh`

实现 parse_args 完整校验、check_disk_threshold (含 _resolve_disk_path 和 df 整数校验)、run_preflight、get_builder_home。

- [ ] **3.1 实现 check_disk_threshold 系列 (填入 pure functions 区块后)**

在 `scripts/bootstrap-bare-metal.sh` 的 `check_disk_threshold_inner` 函数后追加:

```bash
_resolve_disk_path() {
  local p="$1"
  while [[ ! -d "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
  printf '%s' "$p"
}

check_disk_threshold() {
  local path avail_kb avail_gb status
  path="$(_resolve_disk_path "$1")"
  avail_kb="$(df -Pk "$path" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ "${avail_kb}" =~ ^[0-9]+$ ]] \
    || die "failed to determine free disk space for ${path}"
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  status="$(check_disk_threshold_inner "$avail_gb")"
  case "$status" in
    die)  die "less than 15GB free on ${path} (have ${avail_gb}GB)" ;;
    warn) log "WARN: only ${avail_gb}GB free on ${path} (recommended >=30GB)" ;;
    ok)   log "disk OK: ${avail_gb}GB free on ${path}" ;;
  esac
}
```

- [ ] **3.2 实现 parse_args 完整校验 (替换 Task 1 的 parse_args 空壳)**

替换 `scripts/bootstrap-bare-metal.sh` 里的 `parse_args() { ... }` 为:

```bash
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-pubkey-file) SSH_PUBKEY_FILE="${2:-}"; shift 2 ;;
      --ssh-pubkey)      SSH_PUBKEY="${2:-}"; shift 2 ;;
      --builder-user)    BUILDER_USER="${2:-}"; shift 2 ;;
      --repo-url)        REPO_URL="${2:-}"; shift 2 ;;
      --host-hint)       HOST_HINT="${2:-}"; shift 2 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 usage; die "unknown argument: $1" ;;
    esac
  done

  # builder-user 校验
  validate_builder_user_name "${BUILDER_USER}" \
    || die "invalid --builder-user: '${BUILDER_USER}' (must match ^[a-z_][a-z0-9_-]*\$?$ and not be root)"

  # SSH 公钥来源互斥 (三选一, 不能多给, 不能一个都没有)
  local sources=0
  [[ -n "${SSH_PUBKEY_FILE}" ]] && sources=$((sources+1))
  [[ -n "${SSH_PUBKEY}" ]]      && sources=$((sources+1))
  [[ -n "${ADMIN_PUBKEY:-}" ]]  && sources=$((sources+1))
  [[ "${sources}" -eq 1 ]] \
    || die "provide exactly one SSH pubkey source: --ssh-pubkey-file / --ssh-pubkey / ADMIN_PUBKEY (got ${sources})"

  # 解析公钥到 PUBKEYS (逐行读取 + 校验)
  local raw=""
  if [[ -n "${SSH_PUBKEY_FILE}" ]]; then
    [[ -r "${SSH_PUBKEY_FILE}" ]] || die "cannot read --ssh-pubkey-file: ${SSH_PUBKEY_FILE}"
    raw="$(cat "${SSH_PUBKEY_FILE}")"
  elif [[ -n "${SSH_PUBKEY}" ]]; then
    raw="${SSH_PUBKEY}"
  else
    raw="${ADMIN_PUBKEY}"
  fi

  PUBKEYS=""
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue   # 跳过空行/注释
    validate_pubkey_line "${line}" \
      || die "invalid SSH public key line: ${line%% *}"
    PUBKEYS+="${line}"$'\n'
  done <<< "${raw}"
  [[ -n "${PUBKEYS}" ]] || die "no valid SSH public keys provided"

  if [[ "${BUILDER_USER}" != "builder" ]]; then
    log "NOTE: --builder-user=${BUILDER_USER}; ensure BOOTSTRAP_BUILDER_USER in .bootstrap.env matches"
  fi
}
```

- [ ] **3.3 实现 run_preflight 和 get_builder_home (填入 side-effect 区块)**

替换 `# ---- side-effect functions` 下的 `(filled in Tasks 3-5)` 注释, 加入:

```bash
run_preflight() {
  log "stage: preflight"
  [[ "$(id -u)" -eq 0 ]] || die "must run as root (this is the bare-metal setup script)"
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "OS must be debian (got '${ID:-empty}')"
  [[ "${VERSION_CODENAME:-}" == "trixie" ]] || die "codename must be trixie (got '${VERSION_CODENAME:-empty}')"
  [[ "$(uname -m)" == "x86_64" ]] || die "arch must be x86_64 (got $(uname -m))"
  check_disk_threshold /var/aptly
  check_disk_threshold /var/lib/sbuild
}

get_builder_home() {
  local home
  home="$(getent passwd "${BUILDER_USER}" | cut -d: -f6)"
  [[ -n "${home}" && "${home}" = /* ]] \
    || die "cannot determine home directory for ${BUILDER_USER}"
  [[ -d "${home}" ]] \
    || die "home directory for ${BUILDER_USER} does not exist: ${home}"
  printf '%s' "${home}"
}
```

- [ ] **3.4 接入 main (调用 run_preflight)**

替换 `main()` 里的 `:` 占位为:

```bash
main() {
  parse_args "$@"
  run_preflight
  # (后续 stages 在 Task 4-5 接入)
}
```

- [ ] **3.5 验证语法 + 测试仍通过**

```bash
bash -n scripts/bootstrap-bare-metal.sh && echo "syntax OK"
bats test/test_bootstrap_bare_metal.bats
```

Expected: `syntax OK`; 测试全绿 (纯函数测试不受副作用函数影响)。

- [ ] **3.6 提交**

```bash
git add scripts/bootstrap-bare-metal.sh
git commit -m "feat(bare-metal): parse_args validation, check_disk_threshold, run_preflight, get_builder_home"
```

---

## Task 4: 装包 + 建用户 + sudoers + authorized_keys

**Files:**
- Modify: `scripts/bootstrap-bare-metal.sh`

实现 install_minimal_packages / ensure_builder_user / configure_passwordless_sudo / configure_authorized_keys。

- [ ] **4.1 实现四个副作用函数 (在 get_builder_home 后追加)**

```bash
install_minimal_packages() {
  log "stage: install_minimal_packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y sudo ca-certificates git
}

ensure_builder_user() {
  log "stage: ensure_builder_user"
  if id -u "${BUILDER_USER}" >/dev/null 2>&1; then
    log "user ${BUILDER_USER} already exists, skipping useradd"
  else
    useradd -m -s /bin/bash -U "${BUILDER_USER}"
    log "created user ${BUILDER_USER}"
  fi
}

configure_passwordless_sudo() {
  log "stage: configure_passwordless_sudo"
  local sudoers_file="/etc/sudoers.d/bootstrap-${BUILDER_USER}"
  local tmp
  tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${BUILDER_USER}" >"${tmp}"
  if ! visudo -cf "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    die "generated sudoers file failed validation"
  fi
  if ! install -o root -g root -m 0440 "${tmp}" "${sudoers_file}"; then
    rm -f "${tmp}"
    die "failed to install sudoers file: ${sudoers_file}"
  fi
  rm -f "${tmp}"
  visudo -c >/dev/null || die "system sudoers validation failed after installing ${sudoers_file}"
}

configure_authorized_keys() {
  log "stage: configure_authorized_keys"
  local builder_home ssh_dir auth_file builder_group
  builder_home="$(get_builder_home)"
  ssh_dir="${builder_home}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  builder_group="$(id -gn "${BUILDER_USER}")"
  install -d -o "${BUILDER_USER}" -g "${builder_group}" -m 0700 "${ssh_dir}"
  touch "${auth_file}"
  chown "${BUILDER_USER}:${builder_group}" "${auth_file}"
  chmod 0600 "${auth_file}"
  local key_line
  while IFS= read -r key_line; do
    [[ -n "${key_line}" ]] || continue
    if grep -qxF -- "${key_line}" "${auth_file}" 2>/dev/null; then
      log "pubkey already present, skipping: ${key_line%% *}"
    else
      printf '%s\n' "${key_line}" >>"${auth_file}"
      log "added pubkey: ${key_line%% *}"
    fi
  done <<< "${PUBKEYS}"
}
```

- [ ] **4.2 接入 main**

更新 `main()`:

```bash
main() {
  parse_args "$@"
  run_preflight
  install_minimal_packages
  ensure_builder_user
  configure_passwordless_sudo
  configure_authorized_keys
  # (clone + next_steps 在 Task 5 接入)
}
```

- [ ] **4.3 验证语法 + 测试仍通过**

```bash
bash -n scripts/bootstrap-bare-metal.sh && echo "syntax OK"
bats test/test_bootstrap_bare_metal.bats
```

Expected: `syntax OK`; 测试全绿。

- [ ] **4.4 提交**

```bash
git add scripts/bootstrap-bare-metal.sh
git commit -m "feat(bare-metal): install packages, ensure builder user, sudoers (temp+visudo), authorized_keys (append+dedupe)"
```

---

## Task 5: clone + print_next_steps + main 完成

**Files:**
- Modify: `scripts/bootstrap-bare-metal.sh`

实现最后两个副作用函数, 完成 main。

- [ ] **5.1 实现 clone_repo_if_requested 和 print_next_steps**

在 configure_authorized_keys 后追加:

```bash
clone_repo_if_requested() {
  if [[ -z "${REPO_URL:-}" ]]; then
    log "no --repo-url provided, skipping clone"
    return
  fi
  log "stage: clone_repo_if_requested"
  local builder_home repo_dir
  builder_home="$(get_builder_home)"
  repo_dir="${builder_home}/ocserv-backport"
  if [[ -d "${repo_dir}/.git" ]]; then
    log "repo already cloned at ${repo_dir}, skipping"
    return
  fi
  if [[ -e "${repo_dir}" ]]; then
    die "${repo_dir} exists but is not a git repo; inspect it or remove it manually:
  rm -rf ${repo_dir}"
  fi
  sudo -H -u "${BUILDER_USER}" git clone "${REPO_URL}" "${repo_dir}" \
    || die "git clone failed: ${REPO_URL}"
  log "cloned ${REPO_URL} -> ${repo_dir}"
}

print_next_steps() {
  local repo_dir repo_note
  repo_dir="$(get_builder_home)/ocserv-backport"
  if [[ -d "${repo_dir}/.git" ]]; then
    repo_note="(already cloned)"
  else
    repo_note="(clone the repo first, or rerun this script with --repo-url)"
  fi
  log "========================================================"
  log "bare-metal setup complete"
  log "next steps (as ${BUILDER_USER}):"
  log "  ssh ${BUILDER_USER}@${HOST_HINT}"
  log "  cd ~/ocserv-backport   ${repo_note}"
  log "  cp .bootstrap.env.example .bootstrap.env && chmod 600 .bootstrap.env"
  log "  # edit .bootstrap.env (BOOTSTRAP_BUILDER_USER=${BUILDER_USER})"
  log "  scripts/bootstrap-build-host.sh --dry-run --generate-gpg-key"
  log "  # then follow docs/trixie-builder-dryrun-runbook.md step 2-4"
  log "========================================================"
  log "NOTE: this script stops before bootstrap-build-host.sh."
  log "      bootstrap must run as ${BUILDER_USER} (not root)."
}
```

- [ ] **5.2 完成 main**

更新 `main()`:

```bash
main() {
  parse_args "$@"
  run_preflight
  install_minimal_packages
  ensure_builder_user
  configure_passwordless_sudo
  configure_authorized_keys
  clone_repo_if_requested
  print_next_steps
}
```

- [ ] **5.3 验证语法 + 测试仍通过**

```bash
bash -n scripts/bootstrap-bare-metal.sh && echo "syntax OK"
bats test/test_bootstrap_bare_metal.bats
```

Expected: `syntax OK`; 测试全绿。

- [ ] **5.4 验证 SOURCE_GUARD (source 不触发 main)**

```bash
# source 脚本后调用纯函数, 不应有任何副作用输出 (no apt/useradd log)
bash -c 'source scripts/bootstrap-bare-metal.sh; validate_builder_user_name builder && echo "guard OK"'
```

Expected: 输出 `guard OK`, 无 preflight/装包等副作用日志 (证明 source 时 main 不执行)。

- [ ] **5.5 验证无公钥来源时报错**

```bash
scripts/bootstrap-bare-metal.sh 2>&1 | grep -q "provide exactly one SSH pubkey source" && echo "error OK"
```

Expected: 输出 `error OK` (无公钥来源时 die 并提示)。

- [ ] **5.6 提交**

```bash
git add scripts/bootstrap-bare-metal.sh
git commit -m "feat(bare-metal): clone_repo_if_requested, print_next_steps, complete main pipeline"
```

---

## Task 6: Makefile test target

**Files:**
- Modify: `Makefile`

- [ ] **6.1 在 Makefile 添加 test target**

在 `Makefile` 的 `.PHONY: help` 区块附近 (或文件末尾的 target 区) 加入。建议放在 `.PHONY: help` 之后, 与其他 `.PHONY` target 风格一致:

```makefile
.PHONY: test
test: ## run bats test suite
	bats test/
```

- [ ] **6.2 验证 test target 跑通全部测试**

```bash
make test
```

Expected: bats 跑完 `test/` 下所有 `.bats` 文件 (含新增的 test_bootstrap_bare_metal.bats 和既有的 5 个), 全部通过。

- [ ] **6.3 验证 help 列出 test**

```bash
make help | grep test
```

Expected: 输出含 `test` 行 (如 `test              run bats test suite`)。

- [ ] **6.4 提交**

```bash
git add Makefile
git commit -m "build: add 'make test' target to run bats suite"
```

---

## Task 7: runbook 第 1 步集成 (脚本为主路径, 手敲移附录 C)

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md`

- [ ] **7.1 读取当前第 1 步内容**

读取 `docs/trixie-builder-dryrun-runbook.md` 的第 1 步 (2.1-2.5 子节) 和附录区, 了解要移动的内容。

- [ ] **7.2 改写第 1 步: 主路径改为脚本**

将第 1 步开头的执行说明 + 2.1-2.5 子节, 替换为以脚本为主路径的新结构。保留 2.1 (机器形态/磁盘验收) 作为 "运行脚本前的只读确认", 然后主路径是跑脚本:

```markdown
## 第 1 步：裸机准备（以 root 执行）

```text
本步执行用户：root（SSH 登录即 root，或用云平台控制台账号）
完成本步后：builder 用户就位、passwordless sudo 生效、（可选）仓库已克隆，
            但 bootstrap 脚本尚未运行
本步产出：正好满足 bootstrap 的 preflight 前置条件
```

### 1.1 运行脚本前的只读确认

先确认机器形态（脚本 preflight 也会查，但提前看一眼省得建完用户才发现机器不对）：

```bash
. /etc/os-release; echo "$ID $VERSION_CODENAME"   # 期望：debian trixie
uname -m                                            # 期望：x86_64
df -h /                                             # 确认根盘 ≥40GB（见磁盘阈值）
```

**磁盘阈值：**

```text
脚本硬阈值：/var/aptly 与 /var/lib/sbuild 所在 fs <15GB 会 die
可运行下限：30GB 左右基本可跑通 dry-run，但后续累积会紧张
培训推荐：root 盘或承载 /var 的磁盘 ≥40GB
```

### 1.2 运行 bootstrap-bare-metal.sh

```bash
# 三种公钥来源任选其一（互斥）：
scripts/bootstrap-bare-metal.sh --ssh-pubkey-file /path/to/id_ed25519.pub --repo-url <仓库 URL>
# 或
scripts/bootstrap-bare-metal.sh --ssh-pubkey 'ssh-ed25519 AAAA...' --repo-url <仓库 URL>
# 或
ADMIN_PUBKEY='ssh-ed25519 AAAA...' scripts/bootstrap-bare-metal.sh --repo-url <仓库 URL>
```

> 脚本做了什么：装 sudo/git/ca-certificates → 建 builder 用户 → 配 passwordless sudo
> （临时文件 + visudo -cf 验证）→ 配 SSH authorized_keys（追加去重，不覆盖已有 key）
> → 可选 clone 仓库。全部幂等，可安全重跑。
> ⚠️ 占位符：公钥和 <仓库 URL> 必须替换为真实值。

✅ 验收（脚本退出码 0 + 以下检查）：

```bash
su - builder -c 'sudo -n true' && echo "sudo OK"
ssh builder@<host> whoami       # 期望 builder（<host> 替换为真实地址）
```

### 1.3 本步退出条件总览

```text
进入第 2 步前，必须全部满足：
  □ bootstrap-bare-metal.sh 退出码 0
  □ builder 用户存在，有 passwordless sudo（sudo -n true 成功）
  □ 能以 builder 身份 SSH 登录
  □ （若提供 --repo-url）~/ocserv-backport 已克隆，git status clean
  □ 当前 shell 身份可切到 builder（准备进入第 2 步）
```

> 排障 / 理解脚本原理：第 1 步的等价手敲命令见 **附录 C**。
```

- [ ] **7.3 新增附录 C: 第 1 步等价手动操作**

在附录 B 之后新增附录 C, 把原 2.1-2.5 的手敲命令完整搬入 (apt install sudo + useradd + sudoers + authorized_keys + clone), 标注 "排障参考, 非默认路径"。具体内容沿用原 2.1-2.5 的命令块 (含 sudo 前移逻辑、ADMIN_PUBKEY 变量、幂等写法)。

- [ ] **7.4 更新附录 A 速查表第 1 步描述**

附录 A 的第 1 步行 "关键产出" 从 "builder 用户 + sudo + SSH + 仓库" 保持不变 (产出相同), 但可在主题列补注 "(scripts/bootstrap-bare-metal.sh)"。

- [ ] **7.5 更新附录 B 占位符清单**

新增条目（若附录 B 还没有）:

```text
| `/path/to/id_ed25519.pub` | 第 1 步 1.2 --ssh-pubkey-file | 管理员真实 SSH 公钥文件路径 |
```

（SSH 公钥字符串 `ssh-ed25519 AAAA...` 已在附录 B, 无需重复。）

- [ ] **7.6 grep 自查: 占位符提示无遗漏**

```bash
grep -n "占位符" docs/trixie-builder-dryrun-runbook.md | head
```

确认第 1 步的 `<仓库 URL>`、公钥、`<host>` 都有替换提示。

- [ ] **7.7 提交**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs: runbook step 1 main path -> bootstrap-bare-metal.sh; manual cmds -> appendix C"
```

---

## 自审 (计划完成后执行)

**1. Spec 覆盖:**

对照 spec 的 4 节, 确认每项有对应 task:
- spec §1 (入口/参数/公钥校验) → Task 1 骨架 + Task 2 validate_pubkey_line + Task 3 parse_args
- spec §2.2-2.3 (preflight/check_disk) → Task 3
- spec §2.4 (装包) → Task 4
- spec §2.5/2.5b (建用户/get_builder_home) → Task 3 (get_builder_home) + Task 4 (ensure_builder_user)
- spec §2.6 (sudoers 临时文件+visudo) → Task 4
- spec §2.7 (authorized_keys append+dedupe+id -gn) → Task 4
- spec §2.8 (clone + 半成品保留) → Task 5
- spec §2.9 (print_next_steps + --host-hint) → Task 5
- spec §2.10-2.11 (依赖/main) → Task 3/4/5 逐步接入 main
- spec §3.1-3.2 (BASH_SOURCE/set/SOURCE_GUARD) → Task 1 (头部) + Task 5.4 (验证 guard)
- spec §3.3-3.5 (幂等/错误处理/set-e+grep) → 贯穿 Task 2-5 实现
- spec §4.3 (纯函数) → Task 2
- spec §4.4 (bats 测试) → Task 2
- spec §4.5 (Makefile test) → Task 6
- spec §4.6 (runbook 选项 A) → Task 7

无 spec 部分遗漏。

**2. 占位符扫描:**

本计划无 TBD/TODO; 每个 task 步骤都有完整代码/命令。runbook 集成 (Task 7) 的占位符 (<仓库 URL> 等) 是文档内容, 非计划占位符。

**3. 一致性:**

- 函数名跨 task 一致: validate_builder_user_name / validate_pubkey_line / check_disk_threshold_inner / _resolve_disk_path / check_disk_threshold / parse_args / run_preflight / get_builder_home / install_minimal_packages / ensure_builder_user / configure_passwordless_sudo / configure_authorized_keys / clone_repo_if_requested / print_next_steps
- main() 接入顺序跨 task 一致: parse_args → run_preflight → install_minimal_packages → ensure_builder_user → configure_passwordless_sudo → configure_authorized_keys → clone_repo_if_requested → print_next_steps
- 参数变量名一致: BUILDER_USER / SSH_PUBKEY_FILE / SSH_PUBKEY / REPO_URL / HOST_HINT / PUBKEYS
