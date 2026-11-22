#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_pipeline.sh
. "${SCRIPT_DIR}/_pipeline.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/ubuntu-env.sh
. "${SCRIPT_DIR}/ubuntu-env.sh"
warn_if_non_native_target
cd -- "${REPO_ROOT}"

PIPELINE_FAIL_PREFIX="${UBUNTU_ENV_PREFIX} BUILD FAILED"

run_stage 1 "${TARGET_SUITE}-verify-locks"

rm -rf -- "${UBUNTU_BUILD_ROOT}/source" "${UBUNTU_BUILD_ROOT}/binary"

run_stage 2 "${TARGET_SUITE}-fetch-ocserv" "${UBUNTU_ENV_PREFIX}_SKIP_FETCH_VERIFY_LOCK=1"
run_stage 3 "${TARGET_SUITE}-rewrap-ocserv"
run_stage 4 "${TARGET_SUITE}-src-pkg-ocserv"
run_stage 5 "${TARGET_SUITE}-binary-ocserv"
run_stage 6 "${TARGET_SUITE}-lint"
run_stage 7 "${TARGET_SUITE}-smoke-basic"

log "${UBUNTU_ENV_PREFIX} BUILD PASSED: build and local validation completed."
