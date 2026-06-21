#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Fail fast if the builder is missing required commands. Spec
# docs/superpowers/specs/2026-06-21-build-pipeline-dependency-check-design.md
require_cmds \
  dpkg-buildpackage:dpkg-dev \
  sbuild:sbuild

# Spec §2.6. Regenerate backport .dsc; never feed sid .dsc to sbuild.
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
SRCDIR="build/source/ocserv-${BACKPORT_VERSION%%-*}"
cd "${SRCDIR}"
dpkg-buildpackage -S -d -us -uc
cd - >/dev/null
DSC="build/source/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "expected dsc not found: ${DSC}"
log "source package: ${DSC}"
