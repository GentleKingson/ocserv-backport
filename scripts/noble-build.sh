#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"
cd -- "${REPO_ROOT}"

fail() {
  log "NOBLE BUILD FAILED at: $*"
  exit 1
}

run_stage() {
  local number="$1" target="$2"
  log "== ${number}. ${target} =="
  case "${target}" in
    noble-fetch-node-undici|noble-fetch-ocserv)
      NOBLE_SKIP_FETCH_VERIFY_LOCK=1 make "${target}" || fail "${target}"
      ;;
    *)
      make "${target}" || fail "${target}"
      ;;
  esac
}

run_stage 1 noble-verify-locks

rm -rf -- "${NOBLE_BUILD_ROOT}/source" "${NOBLE_BUILD_ROOT}/binary" "${NOBLE_BUILD_ROOT}/repo"

run_stage 2 noble-fetch-node-undici
run_stage 3 noble-rewrap-node-undici
run_stage 4 noble-src-pkg-node-undici
run_stage 5 noble-binary-node-undici
run_stage 6 noble-repo
run_stage 7 noble-fetch-ocserv
run_stage 8 noble-rewrap-ocserv
run_stage 9 noble-src-pkg-ocserv
run_stage 10 noble-binary-ocserv
run_stage 11 noble-lint
run_stage 12 noble-smoke-basic

log "NOBLE BUILD PASSED: build and local validation completed."
