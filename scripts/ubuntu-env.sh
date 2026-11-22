#!/usr/bin/env bash
# Shared Ubuntu backport defaults and path helpers (noble, resolute). Source this file.
set -euo pipefail

UBUNTU_ENV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_versions.sh
. "${UBUNTU_ENV_DIR}/_versions.sh"
TARGET_FAMILY="${TARGET_FAMILY:-ubuntu}"
TARGET_SUITE="${TARGET_SUITE:-${TARGET_DISTRIBUTION:-noble}}"

case "${TARGET_SUITE}" in
  noble)
    UBUNTU_RELEASE_VERSION="24.04"
    UBUNTU_SUITE_LABEL="Noble"
    UBUNTU_DESCRIPTION="Ubuntu 24.04 Noble"
    UBUNTU_ENV_PREFIX="NOBLE"
    UBUNTU_DOCKER_IMAGE="ubuntu:24.04"
    UBUNTU_OCSERV_VERSION="${OCSERV_NOBLE_VERSION}"
    UBUNTU_BUNDLED_LLHTTP=1
    UBUNTU_DOWNGRADE_SYSUSERS=1
    UBUNTU_ADD_LIBSSL_DEV=1
    ;;
  resolute)
    UBUNTU_RELEASE_VERSION="26.04"
    UBUNTU_SUITE_LABEL="Resolute"
    UBUNTU_DESCRIPTION="Ubuntu 26.04 Resolute"
    UBUNTU_ENV_PREFIX="RESOLUTE"
    UBUNTU_DOCKER_IMAGE="ubuntu:26.04"
    UBUNTU_OCSERV_VERSION="${OCSERV_RESOLUTE_VERSION}"
    UBUNTU_BUNDLED_LLHTTP=0
    UBUNTU_DOWNGRADE_SYSUSERS=0
    UBUNTU_ADD_LIBSSL_DEV=1
    ;;
  *)
    die "unsupported Ubuntu suite: ${TARGET_SUITE} (supported: noble, resolute)"
    ;;
esac

# shellcheck source=scripts/_target_arch.sh
. "${UBUNTU_ENV_DIR}/_target_arch.sh"

warn_if_non_native_target() {
  if [[ -z "${UBUNTU_NATIVE_ARCH:-}" || -z "${TARGET_ARCH:-}" ]]; then
    return 0
  fi

  if [[ "${TARGET_ARCH}" == "${UBUNTU_NATIVE_ARCH}" ]]; then
    return 0
  fi

  if [[ "${UBUNTU_NON_NATIVE_WARNING_PRINTED:-0}" == 1 ]]; then
    return 0
  fi

  printf 'WARNING: TARGET_ARCH=%s differs from native architecture %s.\n' \
    "${TARGET_ARCH}" "${UBUNTU_NATIVE_ARCH}" >&2
  printf 'This script does not set up cross-build, QEMU, or binfmt.\n' >&2
  printf 'Continuing with explicit TARGET_ARCH; build requires a matching native-capable chroot/runner.\n' >&2
  UBUNTU_NON_NATIVE_WARNING_PRINTED=1
  export UBUNTU_NON_NATIVE_WARNING_PRINTED
}

resolve_target_arch
UBUNTU_NATIVE_ARCH="${HOST_ARCH}"
export UBUNTU_NATIVE_ARCH

# shellcheck source=scripts/_target_paths.sh
. "${UBUNTU_ENV_DIR}/_target_paths.sh"
TARGET_DISTRIBUTION="${TARGET_SUITE}"

export TARGET_DISTRIBUTION TARGET_ARCH
export UBUNTU_RELEASE_VERSION UBUNTU_SUITE_LABEL UBUNTU_DESCRIPTION
export UBUNTU_ENV_PREFIX UBUNTU_DOCKER_IMAGE UBUNTU_OCSERV_VERSION
export UBUNTU_BUNDLED_LLHTTP UBUNTU_DOWNGRADE_SYSUSERS UBUNTU_ADD_LIBSSL_DEV

UBUNTU_SBUILD_CHROOT="${TARGET_DISTRIBUTION}-${TARGET_ARCH}"
export UBUNTU_SBUILD_CHROOT

UBUNTU_BUILD_ROOT="${TARGET_BUILD_ROOT}"
export UBUNTU_BUILD_ROOT

ubuntu_package_vars() {
  local package="$1"
  case "${package}" in
    ocserv)
      PKG_SOURCE="ocserv"
      PKG_DEBIAN_VERSION="${OCSERV_DEBIAN_VERSION}"
      PKG_PACKAGING_VERSION="${OCSERV_PACKAGING_VERSION}"
      PKG_UBUNTU_VERSION="${UBUNTU_OCSERV_VERSION}"
      ;;
    *)
      die "usage: ${0##*/} ocserv"
      ;;
  esac

  PKG_UPSTREAM_VERSION="${PKG_DEBIAN_VERSION%-*}"
  PKG_SOURCE_ROOT="${TARGET_SOURCE_ROOT}"
  PKG_SOURCE_TREE="${PKG_SOURCE_ROOT}/${PKG_SOURCE}-${PKG_UPSTREAM_VERSION}"
  PKG_BINARY_DIR="${TARGET_BINARY_ROOT}"
  PKG_LOCK_TSV="${REPO_ROOT}/source-lock/${PKG_SOURCE}/${PKG_PACKAGING_VERSION}.lock.tsv"

  export PKG_SOURCE PKG_DEBIAN_VERSION PKG_PACKAGING_VERSION PKG_UBUNTU_VERSION PKG_UPSTREAM_VERSION
  export PKG_SOURCE_ROOT PKG_SOURCE_TREE PKG_BINARY_DIR PKG_LOCK_TSV
}
