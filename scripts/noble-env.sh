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

# shellcheck source=scripts/_target_arch.sh
. "${NOBLE_ENV_DIR}/_target_arch.sh"

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
NOBLE_NATIVE_ARCH="${HOST_ARCH}"
export NOBLE_NATIVE_ARCH

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
