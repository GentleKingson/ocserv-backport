#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §2.6. Regenerate backport .dsc; never feed sid .dsc to sbuild.
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
SRCDIR="build/source/ocserv-${BACKPORT_VERSION%%-*}"
cd "${SRCDIR}"
dpkg-buildpackage -S -us -uc
cd - >/dev/null
DSC="build/source/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "expected dsc not found: ${DSC}"
log "source package: ${DSC}"
