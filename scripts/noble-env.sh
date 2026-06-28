#!/usr/bin/env bash
# Shared Noble backport defaults and path helpers. Source this file.
set -euo pipefail

: "${NODE_UNDICI_DEBIAN_VERSION:=7.3.0+dfsg1+~cs24.12.11-1}"
: "${NODE_UNDICI_NOBLE_VERSION:=${NODE_UNDICI_DEBIAN_VERSION}}"
OCSERV_DEBIAN_VERSION="${OCSERV_DEBIAN_VERSION:-1.5.0-1}"
OCSERV_NOBLE_VERSION="${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.1}"
TARGET_FAMILY="${TARGET_FAMILY:-ubuntu}"
TARGET_SUITE="${TARGET_SUITE:-${TARGET_DISTRIBUTION:-noble}}"
NOBLE_ENV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

normalize_target_arch() {
  case "$1" in
    amd64|x86_64)
      printf '%s\n' "amd64"
      ;;
    arm64|aarch64)
      printf '%s\n' "arm64"
      ;;
    *)
      return 1
      ;;
  esac
}

detect_native_arch() {
  local raw_arch=""

  if command -v dpkg >/dev/null 2>&1; then
    raw_arch="$(dpkg --print-architecture 2>/dev/null || true)"
  fi

  if [[ -z "${raw_arch}" ]]; then
    raw_arch="$(uname -m 2>/dev/null || true)"
  fi

  [[ -n "${raw_arch}" ]] || return 1
  normalize_target_arch "${raw_arch}"
}

resolve_target_arch() {
  local requested_arch="${TARGET_ARCH:-}"
  local resolved_arch=""

  NOBLE_NATIVE_ARCH="$(detect_native_arch || true)"
  export NOBLE_NATIVE_ARCH

  if [[ -n "${requested_arch}" ]]; then
    if ! resolved_arch="$(normalize_target_arch "${requested_arch}")"; then
      printf 'Unsupported TARGET_ARCH: %s\n' "${requested_arch}" >&2
      printf 'Supported architectures: amd64, arm64\n' >&2
      exit 1
    fi
  else
    if [[ -z "${NOBLE_NATIVE_ARCH}" ]]; then
      printf 'Unable to detect supported native architecture\n' >&2
      printf 'Supported architectures: amd64, arm64\n' >&2
      exit 1
    fi
    resolved_arch="${NOBLE_NATIVE_ARCH}"
  fi

  TARGET_ARCH="${resolved_arch}"
  export TARGET_ARCH
}

warn_if_non_native_target() {
  if [[ -z "${NOBLE_NATIVE_ARCH:-}" || -z "${TARGET_ARCH:-}" ]]; then
    return 0
  fi

  if [[ "${TARGET_ARCH}" == "${NOBLE_NATIVE_ARCH}" ]]; then
    return 0
  fi

  if [[ "${NOBLE_NON_NATIVE_WARNING_PRINTED:-0}" == 1 ]]; then
    return 0
  fi

  printf 'WARNING: TARGET_ARCH=%s differs from native architecture %s.\n' \
    "${TARGET_ARCH}" "${NOBLE_NATIVE_ARCH}" >&2
  printf 'This script does not set up cross-build, QEMU, or binfmt.\n' >&2
  printf 'Continuing with explicit TARGET_ARCH; build requires a matching native-capable chroot/runner.\n' >&2
  NOBLE_NON_NATIVE_WARNING_PRINTED=1
  export NOBLE_NON_NATIVE_WARNING_PRINTED
}

resolve_target_arch

# shellcheck source=scripts/_target_paths.sh
. "${NOBLE_ENV_DIR}/_target_paths.sh"
TARGET_DISTRIBUTION="${TARGET_SUITE}"

export NODE_UNDICI_DEBIAN_VERSION NODE_UNDICI_NOBLE_VERSION
export OCSERV_DEBIAN_VERSION OCSERV_NOBLE_VERSION
export TARGET_DISTRIBUTION TARGET_ARCH

NOBLE_SBUILD_CHROOT="${TARGET_DISTRIBUTION}-${TARGET_ARCH}"
export NOBLE_SBUILD_CHROOT

NOBLE_BUILD_ROOT="${TARGET_BUILD_ROOT}"
NOBLE_REPO_DIR="${TARGET_REPO_ROOT}"
export NOBLE_BUILD_ROOT NOBLE_REPO_DIR

noble_package_vars() {
  local package="$1"
  case "${package}" in
    node-undici)
      PKG_SOURCE="node-undici"
      PKG_DEBIAN_VERSION="${NODE_UNDICI_DEBIAN_VERSION}"
      PKG_NOBLE_VERSION="${NODE_UNDICI_NOBLE_VERSION}"
      ;;
    ocserv)
      PKG_SOURCE="ocserv"
      PKG_DEBIAN_VERSION="${OCSERV_DEBIAN_VERSION}"
      PKG_NOBLE_VERSION="${OCSERV_NOBLE_VERSION}"
      ;;
    *)
      die "usage: ${0##*/} node-undici|ocserv"
      ;;
  esac

  PKG_UPSTREAM_VERSION="${PKG_DEBIAN_VERSION%-*}"
  PKG_SOURCE_ROOT="${TARGET_SOURCE_ROOT}/${PKG_SOURCE}"
  PKG_SOURCE_TREE="${PKG_SOURCE_ROOT}/${PKG_SOURCE}-${PKG_UPSTREAM_VERSION}"
  PKG_BINARY_DIR="${TARGET_BINARY_ROOT}/${PKG_SOURCE}"
  PKG_LOCK_TSV="${REPO_ROOT}/source-lock/${PKG_SOURCE}/${PKG_DEBIAN_VERSION}.lock.tsv"

  export PKG_SOURCE PKG_DEBIAN_VERSION PKG_NOBLE_VERSION PKG_UPSTREAM_VERSION
  export PKG_SOURCE_ROOT PKG_SOURCE_TREE PKG_BINARY_DIR PKG_LOCK_TSV
}
