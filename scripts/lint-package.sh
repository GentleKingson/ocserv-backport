#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §6.3 step 5. lintian on .changes; treat Errors as fatal.
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
CHANGES="$(ls build/binary/ocserv_${BACKPORT_VERSION}_amd64.changes 2>/dev/null || true)"
[[ -n "${CHANGES}" ]] || die "no .changes found in build/binary"

log "lintian ${CHANGES}"
# --fail-on error: nonzero exit (status 2) if any E: tag. Warnings are printed
# but pass. ('error' is lintian's default severity; explicit for clarity.)
# NOTE: --fail-on <level>, NOT --fail-on-error (invalid option on lintian >=2.5).
lintian --fail-on error "${CHANGES}" || die "lintian reported errors"
log "lintian: no errors"
