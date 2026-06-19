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
stage_preflight()               { log "TODO stage_preflight"; }
stage_install_packages()        { log "TODO stage_install_packages"; }
stage_prepare_directories()     { log "TODO stage_prepare_directories"; }
stage_setup_sbuild_chroot()     { log "TODO stage_setup_sbuild_chroot"; }
stage_setup_gpg_key()           { log "TODO stage_setup_gpg_key"; }
stage_setup_aptly()             { log "TODO stage_setup_aptly"; }
stage_setup_rclone_skeleton()   { log "TODO stage_setup_rclone_skeleton"; }
stage_check_runner()            { log "TODO stage_check_runner"; }
stage_check_backups()           { log "TODO stage_check_backups"; }
stage_print_manual_github_steps() { log "TODO stage_print_manual_github_steps"; }

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
  for s in "${run[@]}"; do
    run_stage "$s"
  done
}

# Run main only when executed directly, not when sourced (for bats tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
