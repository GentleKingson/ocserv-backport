#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  TARGET_PATHS_TMP=""
}

teardown() {
  [[ -z "${TARGET_PATHS_TMP:-}" ]] || rm -rf "${TARGET_PATHS_TMP}"
}

run_target_paths() {
  local family="$1" suite="$2" arch="$3" repo_root="${4:-}"

  if [[ -n "${repo_root}" ]]; then
    run bash -c "TARGET_FAMILY='${family}'; TARGET_SUITE='${suite}'; TARGET_ARCH='${arch}'; REPO_ROOT='${repo_root}'; source '${REPO_ROOT}/scripts/_target_paths.sh'; printf '%s\n' \"\${REPO_ROOT}\" \"\${TARGET_BUILD_ROOT_REL}\" \"\${TARGET_BUILD_ROOT}\" \"\${TARGET_SOURCE_ROOT}\" \"\${TARGET_BINARY_ROOT}\" \"\${TARGET_REPO_ROOT}\" \"\${TARGET_KEYRING_ROOT}\" \"\${TARGET_DEBIAN_KEYRING_DIR}\""
  else
    run bash -c "TARGET_FAMILY='${family}'; TARGET_SUITE='${suite}'; TARGET_ARCH='${arch}'; source '${REPO_ROOT}/scripts/_target_paths.sh'; printf '%s\n' \"\${REPO_ROOT}\" \"\${TARGET_BUILD_ROOT_REL}\" \"\${TARGET_BUILD_ROOT}\" \"\${TARGET_SOURCE_ROOT}\" \"\${TARGET_BINARY_ROOT}\" \"\${TARGET_REPO_ROOT}\" \"\${TARGET_KEYRING_ROOT}\" \"\${TARGET_DEBIAN_KEYRING_DIR}\""
  fi
}

@test "target paths compute Debian trixie amd64 roots" {
  run_target_paths debian trixie amd64

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${REPO_ROOT}" ]
  [ "${lines[1]}" = "build/debian/trixie/amd64" ]
  [ "${lines[2]}" = "${REPO_ROOT}/build/debian/trixie/amd64" ]
  [ "${lines[3]}" = "${REPO_ROOT}/build/debian/trixie/amd64/source" ]
  [ "${lines[4]}" = "${REPO_ROOT}/build/debian/trixie/amd64/binary" ]
  [ "${lines[5]}" = "${REPO_ROOT}/build/debian/trixie/amd64/repo" ]
  [ "${lines[6]}" = "${REPO_ROOT}/build/debian/trixie/amd64/keyrings" ]
  [ "${lines[7]}" = "${REPO_ROOT}/build/debian/trixie/amd64/keyrings/debian" ]
}

@test "target paths compute Ubuntu Noble arm64 roots" {
  run_target_paths ubuntu noble arm64

  [ "${status}" -eq 0 ]
  [ "${lines[1]}" = "build/ubuntu/noble/arm64" ]
  [ "${lines[2]}" = "${REPO_ROOT}/build/ubuntu/noble/arm64" ]
  [ "${lines[7]}" = "${REPO_ROOT}/build/ubuntu/noble/arm64/keyrings/debian" ]
}

@test "target paths canonicalize explicit REPO_ROOT override" {
  TARGET_PATHS_TMP="$(mktemp -d)"
  mkdir -p "${TARGET_PATHS_TMP}/repo/subdir"
  expected_repo_root="$(cd -- "${TARGET_PATHS_TMP}/repo" && pwd -P)"

  run_target_paths debian trixie arm64 "${TARGET_PATHS_TMP}/repo/subdir/.."

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${expected_repo_root}" ]
  [ "${lines[1]}" = "build/debian/trixie/arm64" ]
  [ "${lines[2]}" = "${expected_repo_root}/build/debian/trixie/arm64" ]
}

@test "target paths reject missing inputs" {
  run bash -c "unset TARGET_FAMILY TARGET_SUITE TARGET_ARCH; TARGET_SUITE=trixie; TARGET_ARCH=amd64; source '${REPO_ROOT}/scripts/_target_paths.sh'"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"TARGET_FAMILY is required"* ]]

  run bash -c "unset TARGET_FAMILY TARGET_SUITE TARGET_ARCH; TARGET_FAMILY=debian; TARGET_ARCH=amd64; source '${REPO_ROOT}/scripts/_target_paths.sh'"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"TARGET_SUITE is required"* ]]

  run bash -c "unset TARGET_FAMILY TARGET_SUITE TARGET_ARCH; TARGET_FAMILY=debian; TARGET_SUITE=trixie; source '${REPO_ROOT}/scripts/_target_paths.sh'"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"TARGET_ARCH is required"* ]]
}

@test "target paths reject unsupported family suite combinations" {
  run_target_paths debian noble amd64
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unsupported target family/suite: debian/noble"* ]]

  run_target_paths ubuntu trixie amd64
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unsupported target family/suite: ubuntu/trixie"* ]]
}

@test "target paths reject unsupported arch" {
  run_target_paths debian trixie riscv64

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unsupported TARGET_ARCH: riscv64"* ]]
}

@test "target paths helper has no mkdir side effects" {
  TARGET_PATHS_TMP="$(mktemp -d)"
  mkdir -p "${TARGET_PATHS_TMP}/repo"

  run_target_paths ubuntu noble amd64 "${TARGET_PATHS_TMP}/repo"

  [ "${status}" -eq 0 ]
  [ ! -e "${TARGET_PATHS_TMP}/repo/build" ]
}
