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
  local rules types_version marker legacy_marker

  [[ "${PKG_SOURCE}" == "node-undici" ]] || return 0

  rules="debian/rules"
  types_version="${PKG_UPSTREAM_VERSION%%+*}"
  marker="# Noble backport: generate undici-types package metadata before dh-nodejs links components."
  legacy_marker="# Noble backport: generate undici-types package metadata during build."
  [[ -f "${rules}" ]] || die "missing packaging rules file: ${PKG_SOURCE_TREE}/${rules}"

  if grep -Fq -- "${marker}" "${rules}"; then
    log "Noble node-undici rules hook already installed"
    return 0
  fi

  if grep -Fq -- "${legacy_marker}" "${rules}"; then
    perl -0pi -e '
      s/\n?\Q# Noble backport: generate undici-types package metadata during build.\E\nexecute_before_dh_auto_build::\n(?:\t[^\n]*\n)+//
    ' "${rules}"
    log "Noble node-undici legacy build hook migrated to configure hook"
  fi

  cat >> "${rules}" <<EOF

# Noble backport: generate undici-types package metadata before dh-nodejs links components.
execute_before_dh_auto_configure::
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

rewrite_same_version_changelog_distribution() {
  PKG_SOURCE="${PKG_SOURCE}" \
  PKG_DEBIAN_VERSION="${PKG_DEBIAN_VERSION}" \
  TARGET_DISTRIBUTION="${TARGET_DISTRIBUTION}" \
    perl -0pi -e '
      my $src = $ENV{"PKG_SOURCE"};
      my $ver = $ENV{"PKG_DEBIAN_VERSION"};
      my $dist = $ENV{"TARGET_DISTRIBUTION"};
      s/\A(\Q$src\E \(\Q$ver\E\) )\S+(; urgency=.*?\n)/${1}$dist$2/
        or die "failed to rewrite top changelog distribution\n";
    ' debian/changelog
}

current_version="$(dpkg-parsechangelog -SVersion)"
current_distribution="$(dpkg-parsechangelog -SDistribution)"

export DEBEMAIL="${MAINTAINER_EMAIL}"
export DEBFULLNAME="${MAINTAINER_NAME}"

if [[ "${PKG_NOBLE_VERSION}" == "${PKG_DEBIAN_VERSION}" ]]; then
  [[ "${current_version}" == "${PKG_DEBIAN_VERSION}" ]] \
    || die "unexpected changelog version ${current_version}; expected ${PKG_DEBIAN_VERSION}"
  if [[ "${current_distribution}" == "${TARGET_DISTRIBUTION}" ]]; then
    die "changelog already rewrapped to ${PKG_NOBLE_VERSION} for ${TARGET_DISTRIBUTION}; rerun noble-fetch-${PKG_SOURCE} before rewrap"
  fi
  install_node_undici_types_package_hook
  rewrite_same_version_changelog_distribution
else
  if [[ "${current_version}" == "${PKG_NOBLE_VERSION}" ]]; then
    die "changelog already rewrapped to ${PKG_NOBLE_VERSION}; rerun noble-fetch-${PKG_SOURCE} before rewrap"
  fi
  [[ "${current_version}" == "${PKG_DEBIAN_VERSION}" ]] \
    || die "unexpected changelog version ${current_version}; expected ${PKG_DEBIAN_VERSION}"
  install_node_undici_types_package_hook
  dch --distribution "${TARGET_DISTRIBUTION}" --force-distribution \
      --force-bad-version \
      -v "${PKG_NOBLE_VERSION}" \
      "Backport ${PKG_SOURCE} ${PKG_DEBIAN_VERSION} for Ubuntu 24.04 Noble."
fi

new_version="$(dpkg-parsechangelog -SVersion)"
new_distribution="$(dpkg-parsechangelog -SDistribution)"
[[ "${new_version}" == "${PKG_NOBLE_VERSION}" ]] \
  || die "changelog version ${new_version} != ${PKG_NOBLE_VERSION}"
[[ "${new_distribution}" == "${TARGET_DISTRIBUTION}" ]] \
  || die "changelog distribution ${new_distribution} != ${TARGET_DISTRIBUTION}"

log "changelog top version: ${new_version}"
log "changelog distribution: ${new_distribution}"
