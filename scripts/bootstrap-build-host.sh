#!/usr/bin/env bash
set -euo pipefail
# Resolve _common.sh relative to this script (BASH_SOURCE works under `source`
# in bats tests, where $0 would be bats's path).
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# bootstrap-build-host.sh — staged trixie builder init. Spec v2.
# Run ON the target builder as BOOTSTRAP_BUILDER_USER with passwordless sudo.

# Defaults applied AFTER .bootstrap.env is loaded; never override caller env.
load_defaults_and_aliases() {
  : "${BOOTSTRAP_BUILDER_USER:=builder}"
  : "${BOOTSTRAP_APTLY_ROOT:=/var/aptly}"
  : "${BOOTSTRAP_REPO_NAME:=ocserv-backports}"
  : "${BOOTSTRAP_APT_BASE_URL:=https://apt.example.com}"
  : "${BOOTSTRAP_R2_BUCKET:=apt-thehkus}"
  export BOOTSTRAP_BUILDER_USER BOOTSTRAP_APTLY_ROOT BOOTSTRAP_REPO_NAME \
         BOOTSTRAP_APT_BASE_URL BOOTSTRAP_R2_BUCKET
  # Unified internal aliases (spec implementation rule 2). Read-only.
  readonly BUILDER_USER="${BOOTSTRAP_BUILDER_USER}"
  readonly APTLY_ROOT="${BOOTSTRAP_APTLY_ROOT}"
  readonly REPO_NAME="${BOOTSTRAP_REPO_NAME}"
  readonly APT_BASE_URL="${BOOTSTRAP_APT_BASE_URL}"
  readonly R2_BUCKET="${BOOTSTRAP_R2_BUCKET}"
  export BUILDER_USER APTLY_ROOT REPO_NAME APT_BASE_URL R2_BUCKET
}

# Safe wrapper: write heredoc content to a temp file, run a command on it,
# capturing combined stdout+stderr (for error messages). In dry-run, prints
# "DRY-RUN: would run <cmd>" WITHOUT the heredoc content.
# Usage: out="$(run_safe_heredoc <tempfile> <content> <cmd...>)"
run_safe_heredoc() {
  local tmpfile="$1" content="$2"; shift 2
  if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN: would run'
    printf ' %q' "$@"
    printf ' (with heredoc input, content suppressed)\n' >&2
    return
  fi
  printf '%s' "${content}" > "${tmpfile}"
  "$@" "${tmpfile}" 2>&1
  local rc=$?
  rm -f "${tmpfile}"
  return $rc
}

# Stage: load_config (runs FIRST; preflight depends on these values).
stage_load_config() {
  log "stage: load_config"
  if [[ -f .bootstrap.env ]]; then
    check_secret_file_mode .bootstrap.env
    load_bootstrap_env_defaults .bootstrap.env
  fi
  load_defaults_and_aliases
}

# ---- stages (spec §1.2 order) ---------------------------------------------
STAGES=(load_config preflight install_packages prepare_directories \
        setup_sbuild_chroot setup_gpg_key setup_aptly \
        setup_rclone_skeleton check_runner check_backups \
        print_manual_github_steps)

valid_stage() {
  local s="$1"
  local st
  for st in "${STAGES[@]}"; do [[ "$st" == "$s" ]] && return 0; done
  return 1
}

# ---- arg parsing ----------------------------------------------------------
BOOTSTRAP_DRY_RUN=0
# GPG_MODE / GPG_IMPORT_PATH / GPG_REUSE_KEYID are consumed by stage_setup_gpg_key
# (implemented in a later task); per-line shellcheck disables at the case arms below.
GPG_MODE=""
GPG_IMPORT_PATH=""
GPG_REUSE_KEYID=""
FROM_STAGE=""
ONLY_STAGE=""

usage() {
  cat >&2 <<EOF
Usage: bootstrap-build-host.sh [options]
  --from-stage <stage>      start from this stage
  --only-stage <stage>      run a single stage
  --generate-gpg-key        GPG: generate a new signing key (fail-if-exists)
  --import-gpg-key <path>   GPG: import an existing private key
  --reuse-gpg-key <KEYID>   GPG: reuse a key already in this keyring
  --dry-run                 print actions, do not modify state
  -h, --help
Stages: ${STAGES[*]}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-stage) FROM_STAGE="$2"; shift 2 ;;
    --only-stage) ONLY_STAGE="$2"; shift 2 ;;
    --generate-gpg-key) GPG_MODE="generate"; shift ;;
    --import-gpg-key) GPG_MODE="import"; GPG_IMPORT_PATH="$2"; shift 2 ;;
    --reuse-gpg-key) GPG_MODE="reuse"; GPG_REUSE_KEYID="$2"; shift 2 ;;
    --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1 (see -h)" ;;
  esac
done
export BOOTSTRAP_DRY_RUN

# GPG mode summary (also a real use of GPG_* vars so shellcheck sees them consumed;
# validation of "no mode chosen" still happens lazily inside stage_setup_gpg_key).
log "args: dry_run=${BOOTSTRAP_DRY_RUN} gpg_mode=${GPG_MODE:-none} from=${FROM_STAGE:-none} only=${ONLY_STAGE:-none}"
case "${GPG_MODE}" in
  import) log "gpg import path: ${GPG_IMPORT_PATH}" ;;
  reuse)  log "gpg reuse keyid: ${GPG_REUSE_KEYID}" ;;
  *) ;;
esac

# --from / --only are mutually exclusive
[[ -n "${FROM_STAGE}" && -n "${ONLY_STAGE}" ]] && die "--from-stage and --only-stage are mutually exclusive"
[[ -n "${FROM_STAGE}" ]] && { valid_stage "${FROM_STAGE}" || { usage; die "unknown stage: ${FROM_STAGE}"; }; }
[[ -n "${ONLY_STAGE}" ]] && { valid_stage "${ONLY_STAGE}" || { usage; die "unknown stage: ${ONLY_STAGE}"; }; }

# GPG mode is a single string set by at most one of the 3 flags (so count is
# inherently 0 or 1). The three flags are mutually exclusive by construction.
# "No mode chosen" is validated lazily inside stage_setup_gpg_key.

# ---- stage runner ---------------------------------------------------------
run_stage() {
  local s="$1"
  if ! declare -F "stage_${s}" >/dev/null; then
    die "stage function not implemented: stage_${s}"
  fi
  log "==== stage: ${s} ===="
  "stage_${s}"
}

# ---- stub stages (replaced in Tasks 5-7) ----------------------------------
stage_preflight() {
  log "stage: preflight"
  # OS + codename
  local id codename
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; codename="${VERSION_CODENAME:-}"
  fi
  [[ "${id}" == "debian" ]] || die "OS must be debian (got '${id:-empty}')"
  [[ "${codename}" == "trixie" ]] || die "codename must be trixie (got '${codename:-empty}')"

  # arch
  [[ "$(uname -m)" == "x86_64" ]] || die "arch must be x86_64 (got $(uname -m))"

  # current user == BUILDER_USER (spec §2.1; prevents ubuntu/builder role confusion)
  local cur; cur="$(id -un)"
  [[ "${cur}" != "root" ]] || die "do not run as root; run as ${BUILDER_USER} with passwordless sudo"
  [[ "${cur}" == "${BUILDER_USER}" ]] \
    || die "current user is '${cur}'; run as ${BUILDER_USER} with passwordless sudo"

  # passwordless sudo
  sudo -n true 2>/dev/null || die "passwordless sudo required for ${BUILDER_USER}"

  # disk: APTLY_ROOT fs + chroot parent fs (spec §2.1 two-level threshold)
  check_disk_threshold "${APTLY_ROOT}"
  check_disk_threshold /var/lib/sbuild
}

check_disk_threshold() {
  local path="$1"
  [[ -d "$path" ]] || path="$(dirname "$path")"
  local avail_kb avail_gb
  avail_kb="$(df -Pk "${path}" 2>/dev/null | awk 'NR==2{print $4}')"
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  if   (( avail_gb < 15 )); then die "less than 15GB free on ${path} (have ${avail_gb}GB)"
  elif (( avail_gb < 30 )); then log "WARN: only ${avail_gb}GB free on ${path} (recommended >=30GB)"
  else log "disk OK: ${avail_gb}GB free on ${path}"
  fi
}

stage_check_runner() {
  log "stage: check_runner"
  local runner_dir="${BOOTSTRAP_RUNNER_DIR:-${HOME}/actions-runner}"
  if [[ -f "${runner_dir}/.runner" ]]; then
    log "runner already registered at ${runner_dir}"
    local o; o="$(stat -c '%U' "${runner_dir}" 2>/dev/null || echo '?')"
    [[ "$o" == "${BUILDER_USER}" ]] || log "WARN: runner dir owner='${o}' (expected ${BUILDER_USER})"
  elif [[ -d "${runner_dir}" ]]; then
    log "WARN: ${runner_dir} exists but not registered; see manual steps"
  else
    log "WARN: no runner detected at ${runner_dir}; register via GitHub UI (see manual steps)"
  fi
}

stage_check_backups() {
  log "stage: check_backups"
  local runner_dir="${BOOTSTRAP_RUNNER_DIR:-${HOME}/actions-runner}"
  local paths=(
    "${APTLY_ROOT}"
    "${APTLY_ROOT}/state"
    "${HOME}/.gnupg"
    "/etc/schroot/chroot.d"
    "${HOME}/.config/rclone/rclone.conf"
    "${runner_dir}"
  )
  local p
  for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then log "backup source exists: $p"
    else log "WARN: backup source not found: $p (ensure your backup covers it)"; fi
  done
}

stage_print_manual_github_steps() {
  log "stage: print_manual_github_steps"
  cat <<EOF

=== Next manual GitHub steps ===

1. Register self-hosted runner
   GitHub UI: Repo -> Settings -> Actions -> Runners -> New self-hosted runner
   Labels: self-hosted, builder
   Run as user: ${BUILDER_USER}
$([[ -n "${BOOTSTRAP_GITHUB_RUNNER_URL:-}" ]] && echo "   Runner URL hint: ${BOOTSTRAP_GITHUB_RUNNER_URL}")

2. Configure GitHub secrets (repo or environment level):
   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID, R2_BUCKET,
   CF_API_TOKEN, CF_ZONE_ID, GPG_PASSPHRASE

3. gh CLI (if authenticated):
   gh secret set R2_ACCESS_KEY_ID
   gh secret set R2_SECRET_ACCESS_KEY
   gh secret set R2_ACCOUNT_ID
   gh secret set R2_BUCKET
   gh secret set CF_API_TOKEN
   gh secret set CF_ZONE_ID
   gh secret set GPG_PASSPHRASE

4. Protected environment: name 'production', enable required reviewers.

5. Verify runner labels: [self-hosted, builder]

EOF
}
stage_install_packages() {
  log "stage: install_packages"
  run_cmd sudo apt-get update
  run_cmd sudo apt-get install -y \
    sbuild schroot debootstrap \
    build-essential devscripts debhelper debhelper-compat \
    dpkg-dev fakeroot lintian quilt \
    rclone aptly gnupg jq docker.io git curl ca-certificates
  ensure_sbuild_group_membership
}

# Ensure BUILDER_USER is in the sbuild group so non-sudo sbuild can read the
# chroot (chroot files are root:sbuild, mode 0640). Idempotent.
ensure_sbuild_group_membership() {
  if id -nG "${BUILDER_USER}" | tr ' ' '\n' | grep -qx sbuild; then
    log "${BUILDER_USER} already in sbuild group"
    return
  fi
  run_cmd sudo sbuild-adduser "${BUILDER_USER}"
  log "WARN: ${BUILDER_USER} was added to sbuild group; log out and back in, or run 'newgrp sbuild', before using sbuild without sudo"
}

stage_prepare_directories() {
  log "stage: prepare_directories"
  if [[ -d "${APTLY_ROOT}" && -n "$(ls -A "${APTLY_ROOT}" 2>/dev/null)" ]]; then
    local o; o="$(stat -c '%U' "${APTLY_ROOT}")"
    [[ "$o" == "root" || "$o" == "${BUILDER_USER}" ]] \
      || die "unexpected ${APTLY_ROOT} owner='${o}'; refusing to chown (manual review)"
  fi
  run_cmd sudo mkdir -p "${APTLY_ROOT}/public/testing" "${APTLY_ROOT}/public/prod" \
                        "${APTLY_ROOT}/.locks" "${APTLY_ROOT}/state"
  run_cmd sudo chown -R "${BUILDER_USER}:${BUILDER_USER}" "${APTLY_ROOT}"
  run_cmd sudo chmod 0755 "${APTLY_ROOT}/.locks"
}

stage_setup_sbuild_chroot() {
  log "stage: setup_sbuild_chroot"
  local chroot_dir="/var/lib/sbuild/trixie-amd64-sbuild"
  if [[ -d "${chroot_dir}" ]]; then
    log "chroot exists; verifying sources"
    verify_chroot_sources "${chroot_dir}"
    return
  fi
  log "creating trixie sbuild chroot"
  run_cmd sudo sbuild-createchroot --arch=amd64 --components=main \
    trixie "${chroot_dir}" http://deb.debian.org/debian
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would verify chroot sources after creation"
    return
  fi
  verify_chroot_sources "${chroot_dir}"
}

# verify_chroot_sources <chroot_dir> — scans .list + .sources; skips comments/blanks.
# Allowed: trixie / trixie-updates / trixie-security. Forbidden: sid/unstable/testing/forky.
verify_chroot_sources() {
  local chroot_dir="$1"
  local etc="${chroot_dir}/etc/apt"
  local files=() g
  [[ -f "${etc}/sources.list" ]] && files+=("${etc}/sources.list")
  if [[ -d "${etc}/sources.list.d" ]]; then
    shopt -s nullglob
    g=( "${etc}/sources.list.d"/*.list "${etc}/sources.list.d"/*.sources ); shopt -u nullglob
    files+=("${g[@]}")
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would verify chroot sources after creation (none found yet)"
      return
    fi
    die "no apt sources found in ${etc}"
  fi
  local f line bad=""
  for f in "${files[@]}"; do
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"   # ltrim
      [[ -z "$line" || "$line" == \#* ]] && continue
      if [[ "$line" =~ (sid|unstable|testing|forky) ]]; then
        bad+="${f}: ${line}"$'\n'
      fi
    done < "$f"
  done
  [[ -z "$bad" ]] || die "chroot sources contaminated; manual fix:
${bad}"
  log "chroot sources OK (trixie-only)"
}

stage_setup_gpg_key() {
  log "stage: setup_gpg_key"
  # lazy mode validation (spec §1.1): only here, not at parse time
  [[ -n "${GPG_MODE}" ]] \
    || die "specify one of --generate-gpg-key / --import-gpg-key <path> / --reuse-gpg-key <KEYID>"

  case "${GPG_MODE}" in
    generate) gpg_generate ;;
    import)   gpg_import ;;
    reuse)    gpg_reuse ;;
  esac
  export_pubkey
}

gpg_secret_exists_for_keyid() { gpg --list-secret-keys --with-colons "$1" 2>/dev/null | grep -q '^sec'; }
gpg_secret_exists_for_uid()   { gpg --list-secret-keys --with-colons 2>/dev/null | grep -iE 'THEHKUS-Backports|master@thehkus.com' | grep -q '^uid'; }

gpg_generate() {
  if [[ -n "${BOOTSTRAP_GPG_KEYID:-}" ]] && gpg_secret_exists_for_keyid "${BOOTSTRAP_GPG_KEYID}"; then
    die "key ${BOOTSTRAP_GPG_KEYID} already exists; use --reuse-gpg-key ${BOOTSTRAP_GPG_KEYID} (do NOT regenerate)"
  fi
  if gpg_secret_exists_for_uid; then
    die "signing key already exists for THEHKUS-Backports; use --reuse-gpg-key <KEYID> (do NOT regenerate)"
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would generate GPG signing key for THEHKUS-Backports"
    export BOOTSTRAP_GPG_KEYID="DRYRUN-GPG-KEYID"
    return
  fi
  # Generate an UNPROTECTED key on disk. The dedicated builder relies on disk
  # encryption + gpg-agent for protection; BOOTSTRAP_GPG_PASSPHRASE is NOT used
  # in generate mode (no prompt, no secret collected) — it is a CI secret
  # consumed only when a passphrase-protected key is imported/reused. Spec §2.6.
  local keyfile content err
  keyfile="$(mktemp)"
  content=$(cat <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: THEHKUS-Backports
Name-Email: master@thehkus.com
Expire-Date: 0
%commit
EOF
)
  err="$(run_safe_heredoc "${keyfile}" "${content}" gpg --batch --generate-key)" \
    || die "gpg generate-key failed: ${err}"
  BOOTSTRAP_GPG_KEYID="$(gpg --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/{print $10}' | tail -1)"
  export BOOTSTRAP_GPG_KEYID
  log "generated signing key (unprotected on disk): ${BOOTSTRAP_GPG_KEYID}"
}

gpg_import() {
  require_var BOOTSTRAP_GPG_KEYID
  if gpg_secret_exists_for_keyid "${BOOTSTRAP_GPG_KEYID}"; then
    log "key ${BOOTSTRAP_GPG_KEYID} already in keyring; treating import as reuse"
    return
  fi
  [[ -r "${GPG_IMPORT_PATH}" ]] || die "import file not readable: ${GPG_IMPORT_PATH}"
  # pre-check: confirm the file actually contains this KEYID (spec advice #7)
  if ! gpg --show-keys --with-colons "${GPG_IMPORT_PATH}" 2>/dev/null | grep -q ":${BOOTSTRAP_GPG_KEYID}:"; then
    die "key in ${GPG_IMPORT_PATH} does not match BOOTSTRAP_GPG_KEYID=${BOOTSTRAP_GPG_KEYID}"
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would gpg --import ${GPG_IMPORT_PATH}"
    return
  fi
  gpg --import "${GPG_IMPORT_PATH}" || die "gpg import failed"
  gpg_secret_exists_for_keyid "${BOOTSTRAP_GPG_KEYID}" \
    || die "imported key has no secret part for ${BOOTSTRAP_GPG_KEYID}"
}

gpg_reuse() {
  BOOTSTRAP_GPG_KEYID="${GPG_REUSE_KEYID}"; export BOOTSTRAP_GPG_KEYID
  require_var BOOTSTRAP_GPG_KEYID
  gpg_secret_exists_for_keyid "${BOOTSTRAP_GPG_KEYID}" \
    || die "no secret key for ${BOOTSTRAP_GPG_KEYID}"
}

export_pubkey() {
  require_var BOOTSTRAP_GPG_KEYID
  local out="ansible/roles/ocserv_backport/files/thehkus-backports.asc"
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would export pubkey ${BOOTSTRAP_GPG_KEYID} -> ${out}"
    return
  fi
  gpg --armor --export "${BOOTSTRAP_GPG_KEYID}" > "${out}" || die "pubkey export failed"
  log "exported pubkey -> ${out}"
}

stage_setup_aptly() {
  log "stage: setup_aptly"
  require_var BOOTSTRAP_GPG_KEYID
  local cfg="${APTLY_CONFIG:-${HOME}/.aptly.conf}"

  # 1. config validate or generate (BEFORE repo; spec §2.7)
  if [[ -f "${cfg}" ]]; then
    local root gpgkey
    root="$(jq -r '.rootDir // empty' "${cfg}")"
    gpgkey="$(jq -r '.gpgKey // empty' "${cfg}")"
    [[ "${root}" == "${APTLY_ROOT}" ]] \
      || die "aptly config rootDir='${root}' != ${APTLY_ROOT}; manual review (refuse to rewrite)"
    [[ "${gpgkey}" == "${BOOTSTRAP_GPG_KEYID}" ]] \
      || die "aptly config gpgKey='${gpgkey}' != ${BOOTSTRAP_GPG_KEYID}; manual review"
  else
    if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would generate ${cfg}"
    else
      jq -n --arg root "${APTLY_ROOT}" --arg key "${BOOTSTRAP_GPG_KEYID}" \
        '{rootDir:$root, gpgProvider:"gpg", gpgKey:$key}' > "${cfg}"
      log "generated minimal aptly config -> ${cfg}"
    fi
  fi

  # 2. repo show/create (skip-if-exists)
  if aptly repo show "${REPO_NAME}" >/dev/null 2>&1; then
    log "aptly repo '${REPO_NAME}' exists; skipping"
    return
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would aptly repo create ${REPO_NAME}"
    return
  fi
  aptly repo create "${REPO_NAME}" || die "aptly repo create failed"
  log "created aptly repo '${REPO_NAME}'"
}

stage_setup_rclone_skeleton() {
  log "stage: setup_rclone_skeleton"
  local conf="${HOME}/.config/rclone/rclone.conf"
  if [[ -f "${conf}" ]] && grep -q '^\[r2\]' "${conf}" 2>/dev/null; then
    log "rclone skeleton [r2] already present"
    return
  fi
  if [[ -z "${BOOTSTRAP_R2_ACCOUNT_ID:-}" ]]; then
    log "WARN: BOOTSTRAP_R2_ACCOUNT_ID not set; skipping rclone skeleton (r2-sync.sh injects creds at runtime anyway)"
    return
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would rclone config create r2 s3 (Cloudflare, no secrets)"
    return
  fi
  rclone config create r2 s3 provider Cloudflare \
    endpoint "https://${BOOTSTRAP_R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    no_check_bucket true >/dev/null
  log "rclone skeleton created (no secrets stored)"
}

main() {
  local run=() s started
  if [[ -n "${ONLY_STAGE}" ]]; then
    run=("${ONLY_STAGE}")
  elif [[ -n "${FROM_STAGE}" ]]; then
    started=0
    for s in "${STAGES[@]}"; do
      [[ "$s" == "${FROM_STAGE}" ]] && started=1
      [[ "$started" == "1" ]] && run+=("$s")
    done
  else
    run=("${STAGES[@]}")
  fi

  # load_config is infrastructure: every other stage depends on the aliases it
  # sets (BUILDER_USER/APTLY_ROOT/etc.). Always run it first unless it IS the
  # only requested stage, so --only-stage <other> doesn't trip set -u.
  if [[ "${ONLY_STAGE}" != "load_config" ]]; then
    run_stage load_config
  fi

  for s in "${run[@]}"; do
    # Skip load_config here only if the always-first block already ran it
    # (i.e. the requested set wasn't ONLY load_config).
    [[ "$s" == "load_config" && "${ONLY_STAGE}" != "load_config" ]] && continue
    run_stage "$s"
  done
}

# Run main only when executed directly, not when sourced (for bats tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
