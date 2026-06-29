#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/debian-env.sh
. "${SCRIPT_DIR}/debian-env.sh"
cd -- "${REPO_ROOT}"

OCSERV_VERSION="${OCSERV_VERSION:-1.5.0-1~debian13.1}"
export OCSERV_VERSION TARGET_FAMILY TARGET_SUITE TARGET_ARCH

fail() {
  log "SOURCE-CI FAILED at: $*"
  exit 1
}

run_stage() {
  local number="$1" target="$2"
  log "== ${number}. ${target} =="
  if [[ "${target}" == "fetch" ]]; then
    OCSERV_SKIP_FETCH_VERIFY_LOCK=1 make "${target}" || fail "${target}"
  else
    make "${target}" || fail "${target}"
  fi
}

run_stage 1 verify-lock

rm -rf -- "${TARGET_SOURCE_ROOT}"

run_stage 2 fetch
run_stage 3 rewrap
run_stage 4 src-pkg

log "SOURCE-CI PASSED: source package build completed."
