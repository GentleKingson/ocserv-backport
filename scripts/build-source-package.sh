#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_dsc.sh
. "${SCRIPT_DIR}/_dsc.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~debian13.1}"
# shellcheck source=scripts/debian-env.sh
. "${SCRIPT_DIR}/debian-env.sh"
SOURCE_NAME="ocserv"
SRCDIR="${TARGET_SOURCE_ROOT}/ocserv-${BACKPORT_VERSION%%-*}"
[[ -d "${SRCDIR}" ]] || die "missing rewrapped source tree: ${SRCDIR} (run 'make rewrap' first)"

rm -f -- "${TARGET_SOURCE_ROOT}/ocserv_${BACKPORT_VERSION}"*

cd "${SRCDIR}"
dpkg-buildpackage -S -d -us -uc
cd - >/dev/null
DSC="${TARGET_SOURCE_ROOT}/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "expected dsc not found: ${DSC}"
validate_dsc_metadata "${DSC}" "${SOURCE_NAME}" "${BACKPORT_VERSION}" \
  || die "generated dsc metadata mismatch: ${DSC}"
log "source package: ${DSC}"
