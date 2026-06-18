#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Single source of snapshot name. Spec §1.5 / §2.2.
OCSERV_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"

if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
  build_no="gh${GITHUB_RUN_NUMBER}"
else
  build_no="local-$(date -u +%Y%m%dT%H%M%S)"
fi
printf 'ocserv-%s-build-%s\n' "${OCSERV_VERSION}" "${build_no}"
