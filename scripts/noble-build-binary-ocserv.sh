#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_sbuild.sh
. "${SCRIPT_DIR}/_sbuild.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"
noble_package_vars ocserv

DSC="${PKG_SOURCE_ROOT}/${PKG_SOURCE}_${PKG_NOBLE_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "missing dsc: ${DSC} (run noble-src-pkg-ocserv first)"

mkdir -p "${PKG_BINARY_DIR}"
rm -f -- "${PKG_BINARY_DIR}"/*

run_sbuild \
  --chroot-mode=schroot \
  --chroot="${NOBLE_SBUILD_CHROOT}" \
  -d "${TARGET_DISTRIBUTION}" \
  --arch="${TARGET_ARCH}" \
  --build-dir "${PKG_BINARY_DIR}" \
  --no-run-lintian \
  "${DSC}"

DEB="${PKG_BINARY_DIR}/ocserv_${PKG_NOBLE_VERSION}_${TARGET_ARCH}.deb"
CHANGES="${PKG_BINARY_DIR}/ocserv_${PKG_NOBLE_VERSION}_${TARGET_ARCH}.changes"
BUILDINFO="${PKG_BINARY_DIR}/ocserv_${PKG_NOBLE_VERSION}_${TARGET_ARCH}.buildinfo"
[[ -f "${DEB}" ]] || die "expected deb not found: ${DEB}"
[[ -f "${CHANGES}" ]] || die "expected changes not found: ${CHANGES}"
[[ -f "${BUILDINFO}" ]] || die "expected buildinfo not found: ${BUILDINFO}"

log "ocserv binary built: ${DEB}"
