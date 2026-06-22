#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
TARGET_DISTRIBUTION="trixie"
TARGET_ARCH="amd64"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DSC="${REPO_ROOT}/build/source/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "missing dsc: ${DSC} (run 'make src-pkg' first)"
mkdir -p "${REPO_ROOT}/build/binary"
BUILD_DIR="$(cd -- "${REPO_ROOT}/build/binary" && pwd)"
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
