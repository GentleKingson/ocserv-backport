#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~debian13.1}"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TARGET_FAMILY="${TARGET_FAMILY:-debian}"
TARGET_SUITE="${TARGET_SUITE:-trixie}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
# shellcheck source=scripts/_target_paths.sh
. "${SCRIPT_DIR}/_target_paths.sh"
TARGET_DISTRIBUTION="${TARGET_SUITE}"
[[ "${TARGET_ARCH}" == "amd64" ]] || die "unsupported TARGET_ARCH=${TARGET_ARCH}; supported architectures: amd64"

DSC="${TARGET_SOURCE_ROOT}/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "missing dsc: ${DSC} (run 'make src-pkg' first)"
mkdir -p "${TARGET_BINARY_ROOT}"
BUILD_DIR="$(cd -- "${TARGET_BINARY_ROOT}" && pwd)"
rm -f -- "${BUILD_DIR}/ocserv_${BACKPORT_VERSION}_${TARGET_ARCH}".*

sbuild \
  --chroot-mode=schroot \
  -d "${TARGET_DISTRIBUTION}" \
  --arch="${TARGET_ARCH}" \
  --build-dir "${BUILD_DIR}" \
  --no-run-lintian \
  "${DSC}"

DEB="${BUILD_DIR}/ocserv_${BACKPORT_VERSION}_${TARGET_ARCH}.deb"
CHANGES="${BUILD_DIR}/ocserv_${BACKPORT_VERSION}_${TARGET_ARCH}.changes"
BUILDINFO="${BUILD_DIR}/ocserv_${BACKPORT_VERSION}_${TARGET_ARCH}.buildinfo"
[[ -f "${DEB}" ]] || die "expected deb not found: ${DEB}"
[[ -f "${CHANGES}" ]] || die "expected changes not found: ${CHANGES}"
[[ -f "${BUILDINFO}" ]] || die "expected buildinfo not found: ${BUILDINFO}"

log "binary built: ${DEB}"
