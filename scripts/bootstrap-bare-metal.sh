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

# ---- side-effect functions ---------------------------------------------------
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
    || die "invalid --builder-user: '${BUILDER_USER}' (must match ^[a-z_][a-z0-9_-]*\$?\$ and not be root)"

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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
