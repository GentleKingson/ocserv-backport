#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/trixie-env.sh
. "${SCRIPT_DIR}/trixie-env.sh"
cd -- "${REPO_ROOT}"

OCSERV_VERSION="${OCSERV_VERSION:-1.5.0-1~debian13.1}"
export OCSERV_VERSION TARGET_FAMILY TARGET_SUITE TARGET_ARCH

fail() {
  log "BUILD FAILED at: $*"
  exit 1
}

run_stage() {
  local number="$1" target="$2"
  log "== ${number}. ${target} =="
  if [[ "${target}" == "trixie-fetch-ocserv" ]]; then
    TRIXIE_SKIP_FETCH_VERIFY_LOCK=1 make "${target}" || fail "${target}"
  else
    make "${target}" || fail "${target}"
  fi
}

run_stage 1 trixie-verify-locks

rm -rf -- "${TARGET_SOURCE_ROOT}" "${TARGET_BINARY_ROOT}"

run_stage 2 trixie-fetch-ocserv
run_stage 3 trixie-rewrap-ocserv
run_stage 4 trixie-src-pkg-ocserv
run_stage 5 trixie-binary-ocserv
run_stage 6 trixie-lint
run_stage 7 trixie-smoke-basic

log "BUILD PASSED: trixie-build and local validation completed."
