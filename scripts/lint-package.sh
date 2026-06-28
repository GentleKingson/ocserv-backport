#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~debian13.1}"
CHANGES="build/binary/ocserv_${BACKPORT_VERSION}_amd64.changes"
LINTIAN_SUPPRESS_TAGS="${LINTIAN_SUPPRESS_TAGS-bad-distribution-in-changes-file}"
LINTIAN_ARGS=()
[[ -f "${CHANGES}" ]] || die "missing .changes: ${CHANGES} (run 'make binary' first)"

if [[ -n "${LINTIAN_PROFILE:-}" ]]; then
  LINTIAN_ARGS+=(--profile "${LINTIAN_PROFILE}")
fi

if [[ -n "${LINTIAN_SUPPRESS_TAGS}" ]]; then
  LINTIAN_ARGS+=(--suppress-tags "${LINTIAN_SUPPRESS_TAGS}")
fi

LINTIAN_ARGS+=(--fail-on error "${CHANGES}")

log "lintian ${LINTIAN_ARGS[*]}"
lintian "${LINTIAN_ARGS[@]}" || die "lintian reported errors"
log "lintian: no errors"
