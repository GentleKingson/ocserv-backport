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
  local rules types_version marker legacy_markers_re

  [[ "${PKG_SOURCE}" == "node-undici" ]] || return 0

  rules="debian/rules"
  types_version="${PKG_UPSTREAM_VERSION%%+*}"
  marker="# Noble backport: generate undici-types metadata and TypeScript paths before dh-nodejs configure."
  [[ -f "${rules}" ]] || die "missing packaging rules file: ${PKG_SOURCE_TREE}/${rules}"

  if grep -Fq -- "${marker}" "${rules}"; then
    if grep -Fq -- 'readdirSync(".")' "${rules}"; then
      log "Noble node-undici rules hook already installed"
      return 0
    fi
    perl -0pi -e "
      s/\\n?\\Q${marker}\\E\\nexecute_before_dh_auto_configure::\\n(?:\\t[^\\n]*\\n)+//g
    " "${rules}"
    log "Noble node-undici incomplete rules hook migrated to cover all top-level tsconfigs"
  fi

  # Remove any prior (incomplete) Noble undici-types hook block: both the
  # earliest "during build" build-hook variant and the configure-only variant
  # that only generated types/package.json. Match: optional leading newline,
  # the legacy marker comment, the build/configure target line, and all
  # following tab-indented recipe lines.
  legacy_markers_re='\Q# Noble backport: generate undici-types package metadata during build.\E|\Q# Noble backport: generate undici-types package metadata before dh-nodejs links components.\E'
  # Use fixed-string grep per marker: grep -E does not understand Perl's \Q...\E.
  if grep -Fq -- "generate undici-types package metadata during build" "${rules}" \
    || grep -Fq -- "generate undici-types package metadata before dh-nodejs links components" "${rules}"; then
    perl -0pi -e "
      s/\\n?(?:${legacy_markers_re})\\nexecute_before_dh_auto_(?:build|configure)::\\n(?:\\t[^\\n]*\\n)+//g
    " "${rules}"
    log "Noble node-undici legacy hook block migrated to tsconfig-paths hook"
  fi

  cat >> "${rules}" <<EOF

# Noble backport: generate undici-types metadata and TypeScript paths before dh-nodejs configure.
execute_before_dh_auto_configure::
	mkdir -p types
	printf '%s\n' '{' '  "name": "undici-types",' '  "version": "${types_version}",' '  "description": "A stand-alone types package for Undici",' '  "license": "MIT",' '  "types": "index.d.ts",' '  "files": ["*.d.ts"]' '}' > types/package.json
	node -e 'const fs=require("fs");for(const d of fs.readdirSync(".")){const p=d+"/tsconfig.json";if(!fs.existsSync(p)||!fs.statSync(d).isDirectory()){continue;}const j=JSON.parse(fs.readFileSync(p,"utf8"));j.compilerOptions=j.compilerOptions||{};j.compilerOptions.paths=j.compilerOptions.paths||{};j.compilerOptions.paths["undici-types"]=["../types"];j.compilerOptions.paths["undici-types/*"]=["../types/*"];fs.writeFileSync(p,JSON.stringify(j,null,2)+"\\n");}'
EOF
  log "Noble node-undici rules hook installed"
}

control_build_depends_has() {
  local control="$1" dep="$2"
  awk '
    /^Build-Depends:/ { in_field = 1; print; next }
    in_field && /^[[:space:]]/ { print; next }
    in_field { exit }
  ' "${control}" | grep -Eq -- "(^|[[:space:],])${dep}([[:space:],(]|$)"
}

ensure_ocserv_noble_build_deps() {
  local control="debian/control"

  [[ "${PKG_SOURCE}" == "ocserv" ]] || return 0
  [[ -f "${control}" ]] || die "missing packaging control file: ${PKG_SOURCE_TREE}/${control}"

  if control_build_depends_has "${control}" "libssl-dev"; then
    log "Noble ocserv libssl-dev build dependency already present"
    return 0
  fi
  control_build_depends_has "${control}" "libcjose-dev" \
    || die "ocserv Build-Depends is missing libcjose-dev anchor"

  perl -0pi -e '
    s{(^Build-Depends:[^\n]*(?:\n[ \t].*)*?\blibcjose-dev\b(?:\s*(?:\([^)]*\)|\[[^\]]*\]))?\s*,)}
     {$1 . "\n               libssl-dev,"}em
      or die "failed to add libssl-dev after libcjose-dev\n";
  ' "${control}"
  control_build_depends_has "${control}" "libssl-dev" \
    || die "failed to add libssl-dev to ocserv Build-Depends"
  log "Noble ocserv libssl-dev build dependency installed"
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
  ensure_ocserv_noble_build_deps
  rewrite_same_version_changelog_distribution
else
  if [[ "${current_version}" == "${PKG_NOBLE_VERSION}" ]]; then
    die "changelog already rewrapped to ${PKG_NOBLE_VERSION}; rerun noble-fetch-${PKG_SOURCE} before rewrap"
  fi
  [[ "${current_version}" == "${PKG_DEBIAN_VERSION}" ]] \
    || die "unexpected changelog version ${current_version}; expected ${PKG_DEBIAN_VERSION}"
  install_node_undici_types_package_hook
  ensure_ocserv_noble_build_deps
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
