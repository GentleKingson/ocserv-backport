#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"
noble_package_vars node-undici

SRC_DIR="${PKG_BINARY_DIR}"
DEST_DIR="${NOBLE_REPO_DIR}"
[[ -d "${SRC_DIR}" ]] || die "missing node-undici binary dir: ${SRC_DIR}"

shopt -s nullglob
runtime_debs=("${SRC_DIR}"/libllhttp9.2_*.deb)
dev_debs=("${SRC_DIR}"/libllhttp-dev_*.deb)
shopt -u nullglob

[[ "${#runtime_debs[@]}" -eq 1 ]] || die "expected exactly one libllhttp9.2 deb in ${SRC_DIR} (found ${#runtime_debs[@]})"
[[ "${#dev_debs[@]}" -eq 1 ]] || die "expected exactly one libllhttp-dev deb in ${SRC_DIR} (found ${#dev_debs[@]})"

rm -rf -- "${DEST_DIR}"
mkdir -p "${DEST_DIR}"
cp -- "${runtime_debs[0]}" "${DEST_DIR}/"
cp -- "${dev_debs[0]}" "${DEST_DIR}/"

cd "${DEST_DIR}"
dpkg-scanpackages . /dev/null > Packages
gzip -c Packages > Packages.gz

grep -q '^Package: libllhttp9\.2$' Packages || die "repo Packages missing libllhttp9.2"
grep -q '^Package: libllhttp-dev$' Packages || die "repo Packages missing libllhttp-dev"

log "local Noble libllhttp repo ready: ${DEST_DIR}"
