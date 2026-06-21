#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Fail fast if the builder is missing required commands (dch from devscripts).
# Spec docs/superpowers/specs/2026-06-21-build-pipeline-dependency-check-design.md
require_cmds dch:devscripts

# Spec §2.5. Rewrite changelog to backport version + trixie distribution.
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
MAINTAINER_NAME="${MAINTAINER_NAME:-Thehkus Admin}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-master@thehkus.com}"

SRCDIR="build/source/ocserv-${BACKPORT_VERSION%%-*}"   # 1.5.0-1~bpo13+1 -> 1.5.0
[[ -d "${SRCDIR}" ]] || die "missing source tree: ${SRCDIR}"
cd "${SRCDIR}"

export DEBEMAIL="${MAINTAINER_EMAIL}"
export DEBFULLNAME="${MAINTAINER_NAME}"

dch --distribution trixie --force-distribution \
    --force-bad-version \
    -v "${BACKPORT_VERSION}" \
    "Private rebuild for Debian 13 trixie."
log "changelog top version: $(dpkg-parsechangelog -SVersion)"
log "changelog distribution: $(dpkg-parsechangelog -SDistribution)"
