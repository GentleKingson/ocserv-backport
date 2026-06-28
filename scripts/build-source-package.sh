#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_dsc.sh
. "${SCRIPT_DIR}/_dsc.sh"

BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~debian13.1}"
SOURCE_NAME="ocserv"
SRCDIR="build/source/ocserv-${BACKPORT_VERSION%%-*}"
[[ -d "${SRCDIR}" ]] || die "missing rewrapped source tree: ${SRCDIR} (run 'make rewrap' first)"

rm -f -- build/source/ocserv_"${BACKPORT_VERSION}"*

cd "${SRCDIR}"
dpkg-buildpackage -S -d -us -uc
cd - >/dev/null
DSC="build/source/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "expected dsc not found: ${DSC}"
validate_dsc_metadata "${DSC}" "${SOURCE_NAME}" "${BACKPORT_VERSION}" \
  || die "generated dsc metadata mismatch: ${DSC}"
log "source package: ${DSC}"
