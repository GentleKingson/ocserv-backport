#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
CHANGES="build/binary/ocserv_${BACKPORT_VERSION}_amd64.changes"
[[ -f "${CHANGES}" ]] || die "missing .changes: ${CHANGES} (run 'make binary' first)"

log "lintian ${CHANGES}"
lintian --fail-on error "${CHANGES}" || die "lintian reported errors"
log "lintian: no errors"
