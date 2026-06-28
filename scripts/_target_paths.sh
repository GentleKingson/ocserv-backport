#!/usr/bin/env bash
# Bash-only target build path helper. Source this after setting
# TARGET_FAMILY, TARGET_SUITE, and TARGET_ARCH.

_target_paths_fail() {
  printf '%s\n' "$*" >&2
  exit 2
}

if [[ -z "${BASH_VERSION:-}" ]]; then
  _target_paths_fail "scripts/_target_paths.sh must be sourced by bash"
fi

[[ -n "${TARGET_FAMILY+x}" && -n "${TARGET_FAMILY}" ]] \
  || _target_paths_fail "TARGET_FAMILY is required"
[[ -n "${TARGET_SUITE+x}" && -n "${TARGET_SUITE}" ]] \
  || _target_paths_fail "TARGET_SUITE is required"
[[ -n "${TARGET_ARCH+x}" && -n "${TARGET_ARCH}" ]] \
  || _target_paths_fail "TARGET_ARCH is required"

case "${TARGET_FAMILY}:${TARGET_SUITE}" in
  debian:trixie|ubuntu:noble)
    ;;
  *)
    _target_paths_fail "unsupported target family/suite: ${TARGET_FAMILY}/${TARGET_SUITE}"
    ;;
esac

case "${TARGET_ARCH}" in
  amd64|arm64)
    ;;
  *)
    _target_paths_fail "unsupported TARGET_ARCH: ${TARGET_ARCH}"
    ;;
esac

if [[ -z "${REPO_ROOT:-}" ]]; then
  _target_paths_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
    || _target_paths_fail "failed to resolve scripts directory"
  REPO_ROOT="$(cd -- "${_target_paths_dir}/.." && pwd -P)" \
    || _target_paths_fail "failed to resolve repository root"
else
  REPO_ROOT="$(cd -- "${REPO_ROOT}" && pwd -P)" \
    || _target_paths_fail "failed to resolve REPO_ROOT: ${REPO_ROOT}"
fi

TARGET_BUILD_ROOT_REL="build/${TARGET_FAMILY}/${TARGET_SUITE}/${TARGET_ARCH}"
TARGET_BUILD_ROOT="${REPO_ROOT}/${TARGET_BUILD_ROOT_REL}"
# shellcheck disable=SC2034
TARGET_SOURCE_ROOT="${TARGET_BUILD_ROOT}/source"
# shellcheck disable=SC2034
TARGET_BINARY_ROOT="${TARGET_BUILD_ROOT}/binary"
# shellcheck disable=SC2034
TARGET_REPO_ROOT="${TARGET_BUILD_ROOT}/repo"
TARGET_KEYRING_ROOT="${TARGET_BUILD_ROOT}/keyrings"
# Debian archive/source keyrings used by this pipeline, even for Ubuntu targets.
# shellcheck disable=SC2034
TARGET_DEBIAN_KEYRING_DIR="${TARGET_KEYRING_ROOT}/debian"

unset _target_paths_dir
