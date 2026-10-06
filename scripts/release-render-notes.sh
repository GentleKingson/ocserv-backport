#!/usr/bin/env bash
# Render the release notes header to stdout. GitHub appends the generated
# list of merged pull requests (see .github/release.yml) when publishing.
#
# Usage: TAG=<tag> OCSERV_DEBIAN13=<version> OCSERV_NOBLE=<version> \
#          release-render-notes.sh [notes-dir]
#
# Output order:
#   1. <notes-dir>/<tag>.md, if present: hand-written highlights, upgrade notes
#      or known issues for this release only.
#   2. <notes-dir>/template.md with ${TAG}, ${OCSERV_DEBIAN13} and
#      ${OCSERV_NOBLE} substituted.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

notes_dir="${1:-${SCRIPT_DIR}/../.github/release-notes}"
template="${notes_dir}/template.md"
[[ -f "${template}" ]] || die "missing release notes template: ${template}"

for var in TAG OCSERV_DEBIAN13 OCSERV_NOBLE; do
  [[ -n "${!var:-}" ]] || die "${var} must be set"
done

release_notes="${notes_dir}/${TAG}.md"
if [[ -f "${release_notes}" ]]; then
  cat -- "${release_notes}"
  printf '\n'
fi

# shellcheck disable=SC2016 # literal placeholders
{
  body="$(< "${template}")"
  body="${body//'${TAG}'/${TAG}}"
  body="${body//'${OCSERV_DEBIAN13}'/${OCSERV_DEBIAN13}}"
  body="${body//'${OCSERV_NOBLE}'/${OCSERV_NOBLE}}"
  printf '%s\n' "${body}"
}
