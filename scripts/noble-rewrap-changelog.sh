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

install_noble_patch_overlays() {
  local overlay_dir patch patch_name series
  local -a patches

  [[ "${PKG_SOURCE}" == "node-undici" ]] || return 0

  overlay_dir="${REPO_ROOT}/packaging/noble/${PKG_SOURCE}/patches"
  [[ -d "${overlay_dir}" ]] || die "missing Noble patch overlay directory: ${overlay_dir}"

  shopt -s nullglob
  patches=("${overlay_dir}"/*.patch)
  shopt -u nullglob
  [[ "${#patches[@]}" -gt 0 ]] || die "no Noble patch overlays found in ${overlay_dir}"

  mkdir -p debian/patches
  series="debian/patches/series"
  touch "${series}"

  for patch in "${patches[@]}"; do
    patch_name="${patch##*/}"
    cp -- "${patch}" "debian/patches/${patch_name}"
    if ! grep -Fxq -- "${patch_name}" "${series}"; then
      printf '%s\n' "${patch_name}" >> "${series}"
    fi
    log "Noble patch overlay: ${patch_name}"
  done
}

install_noble_patch_overlays

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
