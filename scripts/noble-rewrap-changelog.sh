#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"

[[ "$#" -eq 1 ]] || die "usage: noble-rewrap-changelog.sh node-undici|ocserv"
noble_package_vars "$1"

MAINTAINER_NAME="${MAINTAINER_NAME:-Thehkus Admin}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-master@thehkus.com}"

[[ -d "${PKG_SOURCE_TREE}" ]] || die "missing source tree: ${PKG_SOURCE_TREE}"
cd "${PKG_SOURCE_TREE}"

install_node_undici_types_package_hook() {
  local marker rules types_version

  [[ "${PKG_SOURCE}" == "node-undici" ]] || return 0

  rules="debian/rules"
  types_version="${PKG_UPSTREAM_VERSION%%+*}"
  marker="# Noble backport: generate undici-types package metadata during build."
  [[ -f "${rules}" ]] || die "missing packaging rules file: ${PKG_SOURCE_TREE}/${rules}"

  if grep -Fq -- "${marker}" "${rules}"; then
    log "Noble node-undici rules hook already installed"
    return 0
  fi

  cat >> "${rules}" <<EOF

# Noble backport: generate undici-types package metadata during build.
execute_before_dh_auto_build::
	mkdir -p types
	printf '%s\n' \
		'{' \
		'  "name": "undici-types",' \
		'  "version": "${types_version}",' \
		'  "description": "A stand-alone types package for Undici",' \
		'  "license": "MIT",' \
		'  "types": "index.d.ts",' \
		'  "files": ["*.d.ts"]' \
		'}' > types/package.json
EOF
  log "Noble node-undici rules hook installed"
}

install_node_undici_types_package_hook

current_version="$(dpkg-parsechangelog -SVersion)"
if [[ "${current_version}" == "${PKG_NOBLE_VERSION}" ]]; then
  die "changelog already rewrapped to ${PKG_NOBLE_VERSION}; rerun noble-fetch-${PKG_SOURCE} before rewrap"
fi
[[ "${current_version}" == "${PKG_DEBIAN_VERSION}" ]] \
  || die "unexpected changelog version ${current_version}; expected ${PKG_DEBIAN_VERSION}"

export DEBEMAIL="${MAINTAINER_EMAIL}"
export DEBFULLNAME="${MAINTAINER_NAME}"

dch --distribution "${TARGET_DISTRIBUTION}" --force-distribution \
    --force-bad-version \
    -v "${PKG_NOBLE_VERSION}" \
    "Backport ${PKG_SOURCE} ${PKG_DEBIAN_VERSION} for Ubuntu 24.04 Noble."

new_version="$(dpkg-parsechangelog -SVersion)"
new_distribution="$(dpkg-parsechangelog -SDistribution)"
[[ "${new_version}" == "${PKG_NOBLE_VERSION}" ]] \
  || die "changelog version ${new_version} != ${PKG_NOBLE_VERSION}"
[[ "${new_distribution}" == "${TARGET_DISTRIBUTION}" ]] \
  || die "changelog distribution ${new_distribution} != ${TARGET_DISTRIBUTION}"

log "changelog top version: ${new_version}"
log "changelog distribution: ${new_distribution}"
