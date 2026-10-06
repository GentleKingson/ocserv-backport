#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"

[[ "$#" -eq 1 ]] || die "usage: noble-rewrap-changelog.sh ocserv"
noble_package_vars "$1"

MAINTAINER_NAME="${MAINTAINER_NAME:-Thehkus Admin}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-master@thehkus.com}"

[[ -d "${PKG_SOURCE_TREE}" ]] || die "missing source tree: ${PKG_SOURCE_TREE}"
cd "${PKG_SOURCE_TREE}"

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

# Noble has no libllhttp package, so build against the llhttp copy that ships
# in the ocserv upstream tarball (src/llhttp) instead of the system library.
ensure_ocserv_noble_bundled_llhttp() {
  local control="debian/control" rules="debian/rules"

  [[ "${PKG_SOURCE}" == "ocserv" ]] || return 0
  [[ -f "${control}" ]] || die "missing packaging control file: ${PKG_SOURCE_TREE}/${control}"
  [[ -f "${rules}" ]] || die "missing packaging rules file: ${PKG_SOURCE_TREE}/${rules}"
  [[ -f "src/llhttp/llhttp.c" ]] || die "missing bundled llhttp source: ${PKG_SOURCE_TREE}/src/llhttp/llhttp.c"

  if grep -Eq -- '-Dlocal-llhttp=false\b' "${rules}"; then
    perl -pi -e 's/-Dlocal-llhttp=false\b/-Dlocal-llhttp=true/g' "${rules}"
  fi
  if grep -Eq -- '-Dlocal-llhttp=false\b' "${rules}"; then
    die "failed to switch ocserv to the bundled llhttp in ${rules}"
  fi

  if control_build_depends_has "${control}" "libllhttp-dev"; then
    perl -0pi -e '
      s{(^Build-Depends:[^\n]*(?:\n[ \t].*)*)}{
        my $field = $1;
        $field =~ s/^([ \t]*)libllhttp-dev\b(?:\s*(?:\([^)]*\)|\[[^\]]*\]|<[^>]*>))*\s*,[ \t]*\n//m
          or $field =~ s/,\s*libllhttp-dev\b(?:\s*(?:\([^)]*\)|\[[^\]]*\]|<[^>]*>))*//
          or die "failed to remove libllhttp-dev from Build-Depends\n";
        $field;
      }em;
    ' "${control}"
  fi
  if control_build_depends_has "${control}" "libllhttp-dev"; then
    die "failed to remove libllhttp-dev from ocserv Build-Depends"
  fi

  log "Noble ocserv configured to build with bundled llhttp"
}

ensure_ocserv_noble_sysusers_syntax() {
  local file changed=0
  local -a sysusers_files=()

  [[ "${PKG_SOURCE}" == "ocserv" ]] || return 0

  shopt -s nullglob
  sysusers_files=(debian/*.sysusers debian/*.sysusers.in)
  shopt -u nullglob

  for file in "${sysusers_files[@]}"; do
    if grep -Eq -- '^u![[:space:]]+' "${file}"; then
      perl -0pi -e 's/^u!([ \t]+)/u$1/gm' "${file}"
      changed=1
    fi
  done

  [[ "${changed}" -ne 1 ]] || log "Noble ocserv sysusers syntax adjusted"
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
  ensure_ocserv_noble_build_deps
  ensure_ocserv_noble_bundled_llhttp
  ensure_ocserv_noble_sysusers_syntax
  rewrite_same_version_changelog_distribution
else
  if [[ "${current_version}" == "${PKG_NOBLE_VERSION}" ]]; then
    die "changelog already rewrapped to ${PKG_NOBLE_VERSION}; rerun noble-fetch-${PKG_SOURCE} before rewrap"
  fi
  [[ "${current_version}" == "${PKG_DEBIAN_VERSION}" ]] \
    || die "unexpected changelog version ${current_version}; expected ${PKG_DEBIAN_VERSION}"
  ensure_ocserv_noble_build_deps
  ensure_ocserv_noble_bundled_llhttp
  ensure_ocserv_noble_sysusers_syntax
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
