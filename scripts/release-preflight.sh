#!/usr/bin/env bash
# Check that a release tag matches the packaged versions before any build
# starts, and print the versions as key=value lines for $GITHUB_OUTPUT.
#
# Usage: release-preflight.sh <tag> [published-asset-names-file]
#
# The tag must be the upstream ocserv version (X.Y.Z) or start with it
# followed by "-" or "." (X.Y.Z-2, X.Y.Z.1). When a file of already
# published release asset names is given, the ocserv backport versions
# must not appear in it: a rebuild has to bump BACKPORT_REVISION in
# scripts/_versions.sh so apt sees it as an upgrade.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_versions.sh
. "${SCRIPT_DIR}/_versions.sh"

tag="${1:-}"
published="${2:-}"
[[ -n "${tag}" ]] || die "usage: release-preflight.sh <tag> [published-asset-names-file]"

case "${tag}" in
  "${OCSERV_UPSTREAM_VERSION}" | "${OCSERV_UPSTREAM_VERSION}-"* | "${OCSERV_UPSTREAM_VERSION}."*) ;;
  *) die "tag ${tag} does not match packaged ocserv ${OCSERV_UPSTREAM_VERSION} (scripts/_versions.sh)" ;;
esac

if [[ -n "${published}" ]]; then
  [[ -f "${published}" ]] || die "missing published asset list: ${published}"
  # GitHub stores release asset names with "~" replaced by ".".
  for version in "${OCSERV_VERSION}" "${OCSERV_NOBLE_VERSION}"; do
    prefix="ocserv_${version//\~/.}_"
    if grep -Fq -- "${prefix}" "${published}"; then
      die "ocserv ${version} is already published; bump BACKPORT_REVISION in scripts/_versions.sh"
    fi
  done
fi

printf 'ocserv_debian13=%s\n' "${OCSERV_VERSION}"
printf 'ocserv_noble=%s\n' "${OCSERV_NOBLE_VERSION}"
printf 'node_undici_noble=%s\n' "${NODE_UNDICI_NOBLE_VERSION}"
