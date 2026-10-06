#!/usr/bin/env bash
# Stage runner for the build orchestrators. Source after _common.sh and set
# PIPELINE_FAIL_PREFIX (for example "BUILD FAILED") before calling run_stage.
set -euo pipefail

# run_stage <number> <make-target> [VAR=value...] — run one make target with
# the optional environment assignments; on failure log
# "<PIPELINE_FAIL_PREFIX> at: <target>" and exit 1.
run_stage() {
  local number="$1" target="$2"
  shift 2

  log "== ${number}. ${target} =="
  if ! env "$@" make "${target}"; then
    log "${PIPELINE_FAIL_PREFIX} at: ${target}"
    exit 1
  fi
}
