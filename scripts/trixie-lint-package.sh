#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~debian13.1}"
# shellcheck source=scripts/trixie-env.sh
. "${SCRIPT_DIR}/trixie-env.sh"

cd -- "${REPO_ROOT}"
CHANGES="${TARGET_BUILD_ROOT_REL}/binary/ocserv_${BACKPORT_VERSION}_${TARGET_ARCH}.changes"
LINTIAN_SUPPRESS_TAGS="${LINTIAN_SUPPRESS_TAGS-bad-distribution-in-changes-file}"
LINTIAN_ARGS=()
[[ -f "${CHANGES}" ]] || die "missing .changes: ${CHANGES} (run 'make trixie-binary-ocserv' first)"

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
