#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

fail() {
  log "DRY-RUN FAILED at: $*"
  exit 1
}

run_stage() {
  local number="$1" target="$2"
  log "== ${number}. ${target} =="
  make "${target}" || fail "${target}"
}

run_stage 1 verify-lock

rm -rf -- "${REPO_ROOT}/build/source" "${REPO_ROOT}/build/binary"

run_stage 2 fetch
run_stage 3 rewrap
run_stage 4 src-pkg
run_stage 5 binary
run_stage 6 lint
run_stage 7 smoke-basic

log "DRY-RUN PASSED: build and local validation completed."
