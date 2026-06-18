#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §2.7. sbuild in clean trixie schroot; -d trixie (not trixie-backports).
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
DSC="build/source/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "missing dsc: ${DSC} (run 'make src-pkg' first)"
mkdir -p build/binary

sbuild \
  --chroot-mode=schroot \
  -d trixie \
  --arch=amd64 \
  --build-dir build/binary \
  --no-run-lintian \
  "${DSC}"

log "binary built; artifacts in build/binary"
ls -1 build/binary/*.deb
