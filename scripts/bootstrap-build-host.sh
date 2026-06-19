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

# Placeholder DRY_RUN parse — full arg parsing lands in Task 4.
BOOTSTRAP_DRY_RUN=0
for a in "$@"; do [[ "$a" == "--dry-run" ]] && BOOTSTRAP_DRY_RUN=1; done
export BOOTSTRAP_DRY_RUN

main() {
  stage_load_config
  log "load_config done (BUILDER_USER=${BUILDER_USER}, APTLY_ROOT=${APTLY_ROOT})"
}

# Run main only when executed directly, not when sourced (for bats tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
