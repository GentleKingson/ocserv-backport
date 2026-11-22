#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/ubuntu-env.sh
. "${SCRIPT_DIR}/ubuntu-env.sh"
ubuntu_package_vars ocserv

CHANGES="${PKG_BINARY_DIR}/ocserv_${PKG_UBUNTU_VERSION}_${TARGET_ARCH}.changes"
[[ -f "${CHANGES}" ]] || die "missing .changes: ${CHANGES} (run ${TARGET_SUITE}-binary-ocserv first)"

log "lintian ${CHANGES}"
lintian --fail-on error "${CHANGES}" || die "lintian reported errors"
log "lintian: no errors"
