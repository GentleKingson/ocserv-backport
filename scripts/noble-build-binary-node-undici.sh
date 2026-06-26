#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_noble_sbuild.sh
. "${SCRIPT_DIR}/_noble_sbuild.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"
noble_package_vars node-undici

DSC="${PKG_SOURCE_ROOT}/${PKG_SOURCE}_${PKG_NOBLE_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "missing dsc: ${DSC} (run noble-src-pkg-node-undici first)"

mkdir -p "${PKG_BINARY_DIR}"
rm -f -- "${PKG_BINARY_DIR}"/*

run_noble_sbuild \
  --chroot-mode=schroot \
  -d "${TARGET_DISTRIBUTION}" \
  --arch="${TARGET_ARCH}" \
  --build-dir "${PKG_BINARY_DIR}" \
  --no-run-lintian \
  "${DSC}"

shopt -s nullglob
runtime_debs=("${PKG_BINARY_DIR}"/libllhttp9.2_*.deb)
dev_debs=("${PKG_BINARY_DIR}"/libllhttp-dev_*.deb)
changes=("${PKG_BINARY_DIR}/${PKG_SOURCE}_${PKG_NOBLE_VERSION}_${TARGET_ARCH}.changes")
buildinfo=("${PKG_BINARY_DIR}/${PKG_SOURCE}_${PKG_NOBLE_VERSION}_${TARGET_ARCH}.buildinfo")
shopt -u nullglob

[[ "${#runtime_debs[@]}" -ge 1 ]] || die "expected libllhttp9.2 deb not found in ${PKG_BINARY_DIR}"
[[ "${#dev_debs[@]}" -ge 1 ]] || die "expected libllhttp-dev deb not found in ${PKG_BINARY_DIR}"
[[ "${#changes[@]}" -eq 1 ]] || die "expected node-undici .changes not found in ${PKG_BINARY_DIR}"
[[ "${#buildinfo[@]}" -eq 1 ]] || die "expected node-undici .buildinfo not found in ${PKG_BINARY_DIR}"

log "node-undici binaries built in: ${PKG_BINARY_DIR}"
