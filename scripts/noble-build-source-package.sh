#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"
# shellcheck source=scripts/_dsc.sh
. "${SCRIPT_DIR}/_dsc.sh"

[[ "$#" -eq 1 ]] || die "usage: noble-build-source-package.sh node-undici|ocserv"
noble_package_vars "$1"

[[ -d "${PKG_SOURCE_TREE}" ]] || die "missing rewrapped source tree: ${PKG_SOURCE_TREE} (run noble-rewrap-${PKG_SOURCE} first)"

shopt -s nullglob
old_artifacts=("${PKG_SOURCE_ROOT}/${PKG_SOURCE}_${PKG_NOBLE_VERSION}"*)
shopt -u nullglob
if [[ "${#old_artifacts[@]}" -gt 0 ]]; then
  rm -f -- "${old_artifacts[@]}"
fi

cd "${PKG_SOURCE_TREE}"
dpkg-buildpackage -S -d -us -uc

DSC="${PKG_SOURCE_ROOT}/${PKG_SOURCE}_${PKG_NOBLE_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "expected dsc not found: ${DSC}"
validate_dsc_metadata "${DSC}" "${PKG_SOURCE}" "${PKG_NOBLE_VERSION}" \
  || die "generated dsc metadata mismatch: ${DSC}"
log "source package: ${DSC}"
