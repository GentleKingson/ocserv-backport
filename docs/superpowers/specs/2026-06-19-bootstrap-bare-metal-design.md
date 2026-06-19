# bootstrap-bare-metal.sh 设计

- 状态: 已确认 v1 (待 writing-plans)
- 日期: 2026-06-19
- 类型: 可执行脚本设计
- 范围: 新增 `scripts/bootstrap-bare-metal.sh`, 覆盖 runbook 第 1 步 (裸机 root 准备),
  补齐现有自动化的唯一手工缺口
- 上游 runbook: `docs/trixie-builder-dryrun-runbook.md` 第 1 步
- 关联脚本: `scripts/bootstrap-build-host.sh` (本脚本产出的 builder 用户是其 preflight 前置)

---

## 0. 背景与定位

### 0.1 为什么要这个脚本

现有自动化覆盖:

```text
runbook 第 1 步 (裸机 root 准备)    → 全手敲 (建 builder / sudo / SSH / clone)  ← 唯一缺口
runbook 第 2 步 (bootstrap 配置/预演) → bootstrap-build-host.sh --dry-run        (已自动)
runbook 第 3 步 (bootstrap 真实运行) → bootstrap-build-host.sh (分段, 见下)     (已自动)
runbook 第 4 步 (make dry-run)       → make dry-run                             (已自动)
```

本脚本精确补齐第 1 步。完成后, 整个流程的自动化覆盖变成:
root 一键 → ssh → builder 一键 (dry-run 预演) → ssh 重连 → builder 一键 (真实运行) → builder 一键 (dry-run)。
**5 次命令全部自动化, 仅 sbuild group 重连是人工动作 (无法绕过)。**

### 0.2 职责边界

```text
root 执行, 只负责:
  - 检查 Debian trixie / x86_64 / root 身份 / 磁盘
  - 安装 sudo / git / ca-certificates (最小集)
  - 创建 builder 用户 (幂等)
  - 配置 passwordless sudo (临时文件 + visudo -cf 验证)
  - 配置 builder SSH authorized_keys (追加去重, 不覆盖)
  - 可选 clone 仓库 (--repo-url)
  - 打印下一步交接命令

不负责 (明确排除):
  - 运行 bootstrap-build-host.sh
  - 运行 make dry-run
  - 生成 GPG
  - 创建 sbuild chroot
  - 注册 GitHub runner
  - 配置 R2 / CF / secrets
  - 尝试绕过 sbuild group 重新登录
```

### 0.3 sbuild group 硬限制 (为什么不能一键到底)

```text
技术事实 (修正后的精确表述):
  已经启动的 builder 进程不能自动获得后来新增的 supplementary group。

故障链 (runbook 第 3 步分段跑的根因):
  bootstrap install_packages 调 sudo sbuild-adduser builder
    → builder 加入 sbuild 组
    → 但当前 builder 进程的 supplementary group 集不会更新
    → 同一进程继续跑 setup_sbuild_chroot 时读 chroot (root:sbuild 0640) 失败

理论上的伪绕过 (root wrapper 在 sbuild-adduser 后重新 spawn builder login 进程)
不采用: 会变成复杂状态机, 与全流程 wrapper 的问题相同。

结论: 本脚本在 root 阶段完成后明确停止, 交由 builder 身份跑 bootstrap。
```

---

## 1. 脚本入口与参数

### 1.1 脚本路径与执行环境

```text
scripts/bootstrap-bare-metal.sh
执行用户: root (SSH 登录即 root, 或云平台控制台账号)
执行环境: 目标 trixie amd64 裸机本机 (不是从远程控制机跑)
```

### 1.2 参数

```text
必选 (SSH 公钥, 三选一, 不能多给, 不能一个都没有):
  --ssh-pubkey-file <path>    从文件读公钥 (支持多行, 每行一个 key)
  --ssh-pubkey <string>       直接传单个公钥字符串
  ADMIN_PUBKEY (环境变量)      环境变量传入单个公钥

可选:
  --builder-user <name>       builder 用户名, 默认 builder
  --repo-url <url>            提供则 clone 到 <builder-home>/ocserv-backport; 不提供则跳过
  --host-hint <host>          仅用于打印下一步 ssh 命令; 不参与实际连接 (默认 <host> 占位符)
  -h, --help
```

### 1.3 参数约束

```text
SSH 公钥输入来源三选一 (互斥, 不允许多个):
  --ssh-pubkey-file / --ssh-pubkey / ADMIN_PUBKEY
  提供多个 → die
  一个都没有 → die

--ssh-pubkey-file 与 --ssh-pubkey 显式互斥。

--builder-user:
  默认 builder
  校验 ^[a-z_][a-z0-9_-]*[$]?$ (POSIX 用户名)
  禁止 root
  校验失败 → die
  若改非默认值, 后续 .bootstrap.env 的 BOOTSTRAP_BUILDER_USER 必须一致 (打印提醒)

--repo-url:
  不提供 → 跳过 clone
  提供 → clone 到 <builder-home>/ocserv-backport (home 由 get_builder_home 取)

--host-hint:
  默认 <host> 占位符
  仅用于 print_next_steps 打印 ssh 命令, 不参与实际连接, 不校验可达性
  解析后存入 HOST_HINT 变量供 print_next_steps 读取

未知参数 → die, 列出合法参数 (与 bootstrap-build-host.sh 一致)
```

### 1.4 SSH 公钥校验 (输入防呆, 非密码学验证)

```text
读取所有非空、非注释行;
每一行都必须匹配支持的 key type 前缀 (case 匹配):
  ssh-ed25519
  ssh-rsa
  ecdsa-sha2-nistp256 / ecdsa-sha2-nistp384 / ecdsa-sha2-nistp521
  sk-ssh-ed25519@openssh.com
  sk-ecdsa-sha2-nistp256@openssh.com

不支持 (判失败):
  ssh-dss (太旧, 现代 OpenSSH 默认不该用, 提示改用 ed25519)
  authorized_keys 的 command= / from= 等 options 前缀 (降低误配置风险)
  空行 / 注释行 (# 开头) → 跳过不校验

字段数要求:
  至少 2 个字段 (<keytype> <base64>)
  第 3 字段 comment 可选

实现: case "$line" in "ssh-ed25519 "*|...|*) return 1 ;; esac
  注意每个分支末尾的空格: "ssh-ed25519 " 带尾空格, 确保匹配 "ssh-ed25519 AAAA" 而非 "ssh-ed25519xxx"
```

### 1.5 参数解析风格

```text
while + case + die, 与 bootstrap-build-host.sh 保持一致
不引入 getopt / getopts (现有脚本没用)
```

---

## 2. 执行流程

### 2.1 阶段总览

```text
执行顺序 (幂等, 任一步失败 die 并指明原因):
  parse_args              输入校验, 最先跑 (副作用前)
  run_preflight           root preflight (早失败)
  install_minimal_packages 装最小包
  ensure_builder_user     创建 builder 用户
  configure_passwordless_ 配 passwordless sudo
    sudo
  configure_authorized_   配 SSH authorized_keys
    keys
  clone_repo_if_requested 可选 clone
  print_next_steps        打印下一步交接
```

### 2.2 run_preflight

```bash
# 1a. 必须是 root (与 bootstrap 的 "禁止 root" 相反, 这是裸机专属检查)
[[ "$(id -u)" -eq 0 ]] || die "must run as root (this is the bare-metal setup script)"

# 1b. OS / codename / arch (与 bootstrap preflight 一致, 早失败)
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "OS must be debian (got '${ID:-empty}')"
[[ "${VERSION_CODENAME:-}" == "trixie" ]] || die "codename must be trixie (got '${VERSION_CODENAME:-empty}')"
[[ "$(uname -m)" == "x86_64" ]] || die "arch must be x86_64 (got $(uname -m))"

# 1c. 磁盘 (早失败, 复用 bootstrap 的阈值语义)
check_disk_threshold /var/aptly        # 不存在则逐级回退到已存在父目录
check_disk_threshold /var/lib/sbuild
```

> 为什么裸机也做 OS/arch/磁盘检查: bootstrap preflight 也会查, 但裸机阶段早失败能省掉
> "建完用户配完 sudo 才发现机器不对" 的返工。两个脚本查同样的事不冲突, 是双重保险。
> 注意: 裸机 preflight 不检查 passwordless sudo (root 本身就是 root, 无意义) 和
> user==builder (此时 builder 还没建) —— 这两项是 bootstrap preflight 专属。

### 2.3 check_disk_threshold (本地定义, 不 source bootstrap-build-host.sh)

```bash
# 对不存在路径逐级回退到已存在父目录 (不是只 dirname 一次)
_resolve_disk_path() {
  local p="$1"
  while [[ ! -d "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
  printf '%s' "$p"
}

# check_disk_threshold_inner <avail_gb>: 纯逻辑, 输出字符串 (不返回码, 避免踩 set -e)
# 输出: ok / warn / die
check_disk_threshold_inner() {
  local avail_gb="$1"
  if   (( avail_gb < 15 )); then printf 'die'
  elif (( avail_gb < 30 )); then printf 'warn'
  else printf 'ok'
  fi
}

# check_disk_threshold <path>: 副作用包装 (取 GB + 调 inner + log/die)
check_disk_threshold() {
  local path avail_kb avail_gb status
  path="$(_resolve_disk_path "$1")"
  avail_kb="$(df -Pk "$path" 2>/dev/null | awk 'NR==2{print $4}')"
  # 校验 df 输出是整数, 避免空/异常值导致 arithmetic error
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

> 为什么输出字符串而非返回码: 返回码 1 表示 warn 会在 set -e 下被当失败退出。
> 输出 ok/warn/die 字符串, 调用方用 case 包住, 干净避开 set -e 冲突。
> 为什么逐级回退而非只 dirname 一次: /var/aptly 不存在时, dirname 一次得 /var (通常
> 存在); 但 /var/lib/sbuild 不存在时, dirname 一次得 /var/lib (可能也不存在)。逐级
> 回退到最近的已存在目录, 最稳。

### 2.4 install_minimal_packages

```bash
install_minimal_packages() {
  log "installing minimal packages (sudo ca-certificates git)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y sudo ca-certificates git
}
```

> 为什么只装这三个: sudo 是 bootstrap preflight 要求 (builder 要 sudo -n true);
> git + ca-certificates 是 clone 仓库必需。完整工具链 (sbuild/aptly/docker 等) 全部
> 交给 bootstrap-build-host.sh 的 install_packages, 保持单一事实源, 避免两个脚本各自
> 维护包列表导致 drift。
> 不用 -qq: 裸机初始化失败时需要可读日志排障, -qq 会减少信息。

### 2.5 ensure_builder_user

```bash
ensure_builder_user() {
  if id -u "${BUILDER_USER}" >/dev/null 2>&1; then
    log "user ${BUILDER_USER} already exists, skipping useradd"
  else
    # -U: 创建同名主组 (新用户保证主组 = 用户名)
    useradd -m -s /bin/bash -U "${BUILDER_USER}"
    log "created user ${BUILDER_USER}"
  fi
}
```

### 2.5b get_builder_home (不假设 home 是 /home/${BUILDER_USER})

```bash
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

> 为什么不硬编码 /home/${BUILDER_USER}: 新建用户 (useradd -m) 默认建 /home/<name>,
> 但已存在用户的 home 可能是 /srv/builder、/home/build 或其他。getent passwd 读实际
> home, 对新建和已存在两种情况都正确。和 id -gn (§2.7) 不假设组名同理。
> 校验非空 + 绝对路径 + 目录存在: 防 getent 返回空或 home 未创建的边界情况早失败。
> 此函数在 ensure_builder_user 之后调用 (用户必须已存在, getent 才有结果)。

### 2.6 configure_passwordless_sudo (临时文件 + visudo -cf + install)

```bash
configure_passwordless_sudo() {
  local sudoers_file="/etc/sudoers.d/bootstrap-${BUILDER_USER}"
  local tmp
  tmp="$(mktemp)"

  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${BUILDER_USER}" >"${tmp}"

  # 先验证临时文件, 避免坏内容进入 /etc/sudoers.d
  if ! visudo -cf "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    die "generated sudoers file failed validation"
  fi

  # 验证通过才安装到最终路径 (覆盖式, 幂等)
  # install 失败也要清理临时文件 (set -e 下失败会直接退出, 必须显式 if 包住)
  if ! install -o root -g root -m 0440 "${tmp}" "${sudoers_file}"; then
    rm -f "${tmp}"
    die "failed to install sudoers file: ${sudoers_file}"
  fi
  rm -f "${tmp}"

  # 安装后再做一次系统级全量校验
  visudo -c >/dev/null || die "system sudoers validation failed after installing ${sudoers_file}"
}
```

> 为什么临时文件 + visudo -cf: 直接 cat 到 /etc/sudoers.d 再 visudo -c, 若内容有 bug,
> 坏文件已进入系统。先在临时文件验证, 验证通过才 install, 保证 /etc/sudoers.d 不会
> 处于污染状态。
> visudo 在 sudo 包里, 所以 install_minimal_packages 必须在它之前执行 (见 2.9 依赖)。

### 2.7 configure_authorized_keys (追加去重, owner 用 id -gn)

```bash
configure_authorized_keys() {
  local builder_home ssh_dir auth_file builder_group
  builder_home="$(get_builder_home)"              # 不假设 home 是 /home/<name>
  ssh_dir="${builder_home}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  builder_group="$(id -gn "${BUILDER_USER}")"     # 不假设主组名 == 用户名

  install -d -o "${BUILDER_USER}" -g "${builder_group}" -m 0700 "${ssh_dir}"
  touch "${auth_file}"
  chown "${BUILDER_USER}:${builder_group}" "${auth_file}"
  chmod 0600 "${auth_file}"

  # 逐行追加 + 精确去重 (grep -x 整行匹配, 不覆盖已有 key)
  local key_line
  while IFS= read -r key_line; do
    [[ -n "${key_line}" ]] || continue
    if grep -qxF -- "${key_line}" "${auth_file}" 2>/dev/null; then
      log "pubkey already present, skipping: ${key_line%% *}"
    else
      printf '%s\n' "${key_line}" >>"${auth_file}"
      log "added pubkey: ${key_line%% *}"
    fi
  done <<< "${PUBKEYS}"   # PUBKEYS = parse_args 解析并校验过的所有合法公钥 (多行)
}
```

> 为什么不覆盖 authorized_keys: 机器可能已有云平台控制台或其他管理员配的 key。
> 逐行追加 + grep -qxF 精确整行去重 (-x 整行匹配, 避免子串误判), 不踢掉已有访问。
> 为什么 owner 用 id -gn 而非 ${BUILDER_USER}:${BUILDER_USER}: 新建用户 (-U) 主组
> 确实等于用户名, 但已存在用户的主组未必。id -gn 读取实际主组, 对两种情况都正确。

### 2.8 clone_repo_if_requested (失败 die, 半成品保留供排障)

```bash
clone_repo_if_requested() {
  if [[ -z "${REPO_URL:-}" ]]; then
    log "no --repo-url provided, skipping clone"
    return
  fi

  local builder_home repo_dir
  builder_home="$(get_builder_home)"
  repo_dir="${builder_home}/ocserv-backport"
  if [[ -d "${repo_dir}/.git" ]]; then
    log "repo already cloned at ${repo_dir}, skipping"
    return
  fi

  if [[ -e "${repo_dir}" ]]; then
    # 目录存在但不是 git repo: 不清空, 留作排障, 提示手动处理
    die "${repo_dir} exists but is not a git repo; inspect it or remove it manually:
  rm -rf ${repo_dir}"
  fi

  # -H: 以 builder 的 HOME 环境 clone; 文件 owner 直接是 builder 不是 root
  sudo -H -u "${BUILDER_USER}" git clone "${REPO_URL}" "${repo_dir}" \
    || die "git clone failed: ${REPO_URL}"
  log "cloned ${REPO_URL} -> ${repo_dir}"
}
```

> 为什么 clone 失败 die: 显式提供 --repo-url 却失败, 说明网络/URL/权限/host key 有
> 问题, 早暴露比静默继续好。
> 为什么半成品不清空: git clone 失败常因网络中断, 半成品目录的 partial clone 有
> 排障价值。下次重跑会因 "目录存在但非 git" die 并提示 rm -rf, 操作者决定清理或修复。

### 2.9 print_next_steps (不自动继续, host 用占位符)

```bash
print_next_steps() {
  local host_hint="${HOST_HINT:-<host>}"   # --host-hint 解析值, 或占位符
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
  log "  ssh ${BUILDER_USER}@${host_hint}"
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

> 为什么 host 用占位符 / --host-hint: hostname 不一定是公网 DNS 或用户实际 SSH 地址。
> --host-hint (可选参数, 仅用于打印 ssh 命令, 不参与实际连接) 让操作者填真实地址;
> 未提供则用 <host> 占位符。
> 为什么不自动继续: 裸机脚本边界到此 (runbook 第 1 步)。下一步必须切 builder 身份,
> 且后续 GPG 模式 / .bootstrap.env 是操作者决策。

### 2.10 阶段间硬依赖 (main 调用顺序)

```text
parse_args               ← 无前置 (最先, 副作用前校验输入)
  ↓
run_preflight            ← 无前置依赖
  ↓
install_minimal_packages ← 依赖 preflight 通过 (OS 正确); 提供 visudo (sudo 包)
  ↓
ensure_builder_user      ← 依赖 sudo 包已装 (虽不直接用 visudo, 但顺序上紧跟)
  ↓
configure_passwordless_  ← 依赖 builder 用户存在 + sudo 包 (visudo -cf)
  sudo
  ↓
configure_authorized_    ← 依赖 builder 用户存在 (id -gn 才能成功)
  keys
  ↓
clone_repo_if_requested  ← 依赖 git + ca-certificates 已装 + builder 用户存在
  ↓
print_next_steps         ← 无前置依赖 (最后, 纯输出)
```

main() 严格按此顺序调用, 不允许打乱。

### 2.11 main 结构

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

---

## 3. set 约束、幂等性与错误处理

### 3.1 头部 (BASH_SOURCE + 显式 set + source _common.sh)

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/_common.sh"
```

> 为什么 BASH_SOURCE 而非 $0: $0 在被 symlink / 被其他脚本调用时不稳。BASH_SOURCE[0]
> 始终指向当前脚本文件, 配合 cd 拿绝对 SCRIPT_DIR 最稳。
> 为什么显式 set 而非依赖 _common.sh: 脚本自身的执行约束应清楚可见, 不靠 _common.sh
> 的副作用。即使 _common.sh 变动, 本脚本的 set 约束不变。
> 不调用 _common.sh 的 check_secret_file_mode (Linux 专用, 本脚本不需要)。

### 3.2 SOURCE_GUARD (允许 bats source 测函数而不执行 main)

```bash
# 脚本末尾
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

> bats 测试 source 脚本时, BASH_SOURCE != ${0}, main 不触发。脚本被 source 时只定义
> 函数和变量, 所有副作用 (apt-get/useradd/visudo/git clone) 都在 main 调用链里, 不会
> 在 source 时执行。
> 约束: source 时顶部的 set + SCRIPT_DIR + source _common.sh 仍会执行。若 _common.sh
> 的 set -euo pipefail 对 bats 有干扰, 测试文件应在 run 子进程里 source:
>   run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line ...'
> 不要为测试把 source _common.sh 放进 guard 内 (否则直接执行时函数缺少 log/die)。

### 3.3 幂等性总则

```text
阶段                    幂等策略
─────────────────────────────────────────────────────
run_preflight           纯只读检查, 天然幂等
install_minimal_packages apt-get install -y 对已装包是 no-op, 天然幂等
ensure_builder_user     id -u 存在则 skip, 否则 useradd -U
configure_passwordless_ 临时文件 + visudo -cf + install 覆盖相同内容, 幂等
  sudo
configure_authorized_   逐行追加 + grep -qxF 精确去重, 不覆盖已有 key
  keys
clone_repo_if_requested .git 存在则 skip; 目录存在非 git 则 die (提示 rm -rf)
print_next_steps        纯输出, 天然幂等
```

### 3.4 错误处理总则

```text
1. 任一阶段失败 → die 并指明原因 (set -e 自动 exit, die 补人类可读信息)

2. die 前不留半成品副作用:
   - sudoers: 临时文件若 visudo -cf 失败, rm 临时文件后 die (不污染 /etc/sudoers.d)
   - authorized_keys: install -d / touch 幂等, 失败点不留损坏文件
   - clone: 失败时 die, 不删半成品 (留排障); 下次重跑因 "目录存在非 git" die 提示清理

3. 不做全局 trap cleanup:
   - 副作用都是 "最终态" 操作 (建用户/写文件), 中途失败要么幂等可重跑, 要么 (clone
     半成品) 故意保留供排障
   - 不像 dry-run.sh 需要清理 mktemp 临时 aptly root
   - sudoers 临时文件用函数内 inline rm 清理 (成功路径 + 失败路径都 rm)
```

### 3.5 set -e 与 grep 无匹配 (易坑点)

```text
grep -qxF 无匹配返回 1, 在 set -e 下会被当失败退出。
本脚本 authorized_keys 去重用 if 分支处理, 不依赖 set -e:
  if grep -qxF -- "$key_line" "$auth_file"; then skip; else append; fi
"无匹配" 是预期的 "key 不存在" 信号, 不是错误。
```

---

## 4. 可测性、测试策略与集成

### 4.1 核心矛盾: 裸机脚本难以端到端测试

```text
副作用几乎全是 root + 系统级:
  useradd / apt-get / visudo / install / authorized_keys / git clone

现有 bats 测试模式 (source _common.sh + 调纯函数) 对此不适用:
  - CI 非 root 容器不能 useradd
  - 不能 mock apt-get / visudo (真实 sudoers 校验必须用真 visudo)
  - authorized_keys 测试需要真实文件系统权限语义
```

### 4.2 可测性设计 (纯函数分离)

```text
层 1: 纯函数 (无副作用, 可 bats 单测)
  - validate_builder_user_name <name>   用户名格式校验 (返回 0/1)
  - validate_pubkey_line <line>         公钥格式校验 (case 匹配, 返回 0/1)
  - check_disk_threshold_inner <gb>     纯逻辑: 输出 ok/warn/die 字符串

层 2: 副作用函数 (root 操作, 不直接单测, 但调用层 1 纯函数)
  - run_preflight                       (调 check_disk_threshold)
  - ensure_builder_user                 (调用前 parse_args 已校验用户名)
  - configure_passwordless_sudo         (调真 visudo)
  - configure_authorized_keys           (调 validate_pubkey_line + 用 PUBKEYS)
  - clone_repo_if_requested             (调真 git)
  - install_minimal_packages            (调真 apt-get)
  - print_next_steps                    (纯输出)

不再抽象更多层。副作用函数靠 set -e + die 早失败 + 真机验证兜底。
```

### 4.3 层 1 纯函数定义

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

### 4.4 测试文件: test/test_bootstrap_bare_metal.bats

```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }

# ---- validate_builder_user_name ----
@test "validate_builder_user_name: accepts 'builder'" {
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_builder_user_name builder'
  [ "$status" -eq 0 ]
}

@test "validate_builder_user_name: rejects 'root'" {
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_builder_user_name root'
  [ "$status" -ne 0 ]
}

@test "validate_builder_user_name: rejects uppercase / digit-start / spaces" {
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_builder_user_name Builder'
  [ "$status" -ne 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_builder_user_name 1builder'
  [ "$status" -ne 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_builder_user_name "bu il der"'
  [ "$status" -ne 0 ]
}

# ---- validate_pubkey_line ----
@test "validate_pubkey_line: accepts modern key types" {
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "ssh-ed25519 AAAA"'
  [ "$status" -eq 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "ssh-rsa AAAA"'
  [ "$status" -eq 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "ecdsa-sha2-nistp256 AAAA"'
  [ "$status" -eq 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "sk-ssh-ed25519@openssh.com AAAA"'
  [ "$status" -eq 0 ]
}

@test "validate_pubkey_line: rejects ssh-dss / empty / options prefix / garbage / keytype-only" {
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "ssh-dss AAAA"'
  [ "$status" -ne 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line ""'
  [ "$status" -ne 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "command=foo ssh-ed25519 AAAA"'
  [ "$status" -ne 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "not-a-key"'
  [ "$status" -ne 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "ssh-ed25519"'
  [ "$status" -ne 0 ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; validate_pubkey_line "ssh-ed25519 "'
  [ "$status" -ne 0 ]
}

# ---- check_disk_threshold_inner ----
@test "check_disk_threshold_inner: die <15, warn 15-29, ok >=30" {
  run bash -c 'source scripts/bootstrap-bare-metal.sh; check_disk_threshold_inner 10'
  [ "$output" = "die" ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; check_disk_threshold_inner 15'
  [ "$output" = "warn" ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; check_disk_threshold_inner 29'
  [ "$output" = "warn" ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; check_disk_threshold_inner 30'
  [ "$output" = "ok" ]
  run bash -c 'source scripts/bootstrap-bare-metal.sh; check_disk_threshold_inner 100'
  [ "$output" = "ok" ]
}
```

> 为什么用 run bash -c 'source ...; func ...': 把 source 和函数调用放在 run 子进程里,
> 隔离 _common.sh 的 set -euo pipefail 对 bats 主进程的干扰。这是最稳的 bash 单测模式。
> 测试覆盖: validate_builder_user_name (6 例) + validate_pubkey_line (9 例) +
> check_disk_threshold_inner (5 例) = 20 例, 覆盖所有边界。

### 4.5 Makefile test target (新增)

```makefile
.PHONY: test
test: ## run bats test suite
	bats test/
```

> 注: 若 bats 未安装, 开发者需先装 bats (apt-get install bats 或 brew install bats-core)。
> 裸机运行脚本本身不依赖 bats —— bats 只用于开发/CI 的纯函数测试。

### 4.6 runbook 集成 (选项 A: 脚本为主路径, 手敲移附录)

```text
docs/trixie-builder-dryrun-runbook.md 改动:
  第 1 步主路径: 改为 "以 root 运行 scripts/bootstrap-bare-metal.sh"
    保留: 机器形态/磁盘验收 (脚本 preflight 会查, 但 runbook 仍写给读者看)
    保留: "脚本做了什么" 的简短解释 (1 段)
    去掉: 原 2.1-2.5 的逐条手敲命令作为主路径
  新增附录 C: 第 1 步等价手动操作
    原 2.1-2.5 的手敲命令完整搬入, 作为排障/教学参考
    标注: "若 bootstrap-bare-metal.sh 失败或想理解原理, 参考本附录手动操作"
  第 2-4 步: 不变
```

> 为什么选项 A: runbook 是交接培训文档, 主路径应是最简路径。脚本封装了幂等性和边界
> 校验, 读者照着跑比手敲 20 行命令更可靠。手敲命令保留在附录供排障和理解。
> 本 spec 的交付范围包含 runbook 更新, 与正式 runbook 计划形成闭环。

### 4.7 真机验证 (兜底)

```text
有 trixie 真机时:
  按 runbook 第 1 步脚本路径验证, 确认:
    - 脚本能在一台裸 trixie 上跑通
    - 产出的 builder 用户满足 bootstrap preflight (sudo -n true 成功)
    - authorized_keys 追加正确, 不踢已有 key
    - clone 成功且 owner=builder
无真机:
  注明跳过。层 1 纯函数已 bats 覆盖, 层 2 靠 set -e + die 早失败。
```

---

## 附录: 交付物清单

```text
新增:
  scripts/bootstrap-bare-metal.sh          (本 spec 的主交付物)
  test/test_bootstrap_bare_metal.bats      (层 1 纯函数 bats 测试)

修改:
  Makefile                                 (新增 test target)
  docs/trixie-builder-dryrun-runbook.md    (第 1 步主路径改脚本, 手敲移附录 C)

不修改:
  scripts/bootstrap-build-host.sh          (本脚本不接管它, 只交接)
  scripts/_common.sh                       (只复用 log/die, 不改)
  docs/BUILD_HOST_BOOTSTRAP.md             (无交集, 不改)
```
