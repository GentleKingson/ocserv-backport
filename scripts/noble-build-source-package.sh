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

print_source_package_host_dependency_guidance() {
  local apt_prefix=""

  if [[ "$(id -u)" -ne 0 ]]; then
    apt_prefix="sudo "
  fi

  printf 'Install Noble source package host dependencies with:\n' >&2
  printf '  %sapt-get update\n' "${apt_prefix}" >&2
  printf '  %sapt-get install -y --no-install-recommends debhelper dh-nodejs\n' "${apt_prefix}" >&2
}

ensure_source_package_host_commands() {
  local cmd missing_count=0
  local -a required_commands=(dh)

  if [[ "${PKG_SOURCE}" == "node-undici" ]]; then
    required_commands+=(pkgjs-pjson)
  fi

  for cmd in "${required_commands[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log "missing required source package command: ${cmd}"
      missing_count=$((missing_count + 1))
    fi
  done

  if [[ "${missing_count}" -gt 0 ]]; then
    print_source_package_host_dependency_guidance
    return 1
  fi
}

ensure_source_package_host_commands || die "missing Noble source package host dependencies"

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
