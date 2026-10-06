#!/usr/bin/env bash
# Collect the release .deb files from downloaded build artifacts and write
# SHA256SUMS next to them.
#
# Usage: release-collect-assets.sh <artifacts-dir> <out-dir>
#
# For each of amd64 and arm64 exactly one file is expected for:
#   build/debian/trixie/<arch>/binary/ocserv_<OCSERV_VERSION>_<arch>.deb
#   build/ubuntu/noble/<arch>/binary/ocserv/ocserv_<OCSERV_NOBLE_VERSION>_<arch>.deb
#   build/ubuntu/noble/<arch>/binary/node-undici/libllhttp<soname>_*_<arch>.deb
# Output names replace "~" with "." to match what GitHub stores, so the
# checksums file verifies the files users download.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_versions.sh
. "${SCRIPT_DIR}/_versions.sh"

artifacts="${1:-}"
out="${2:-}"
[[ -n "${artifacts}" && -n "${out}" ]] || die "usage: release-collect-assets.sh <artifacts-dir> <out-dir>"
[[ -d "${artifacts}" ]] || die "missing artifacts directory: ${artifacts}"

RELEASE_ARCHES="${RELEASE_ARCHES:-amd64 arm64}"

collect_one() {
  local path_glob="$1" name_glob="$2"
  local -a matches=()
  local file
  while IFS= read -r -d '' file; do
    matches+=("${file}")
  done < <(find "${artifacts}" -type f -path "${path_glob}" -name "${name_glob}" -print0)
  ((${#matches[@]} == 1)) || die "expected exactly one ${path_glob%/*}/${name_glob}, found ${#matches[@]}"
  file="$(basename -- "${matches[0]}")"
  cp -- "${matches[0]}" "${out}/${file//\~/.}"
}

mkdir -p "${out}"
rm -f -- "${out}"/*.deb "${out}/SHA256SUMS"

for arch in ${RELEASE_ARCHES}; do
  collect_one "*/build/debian/trixie/${arch}/binary/*" "ocserv_${OCSERV_VERSION}_${arch}.deb"
  collect_one "*/build/ubuntu/noble/${arch}/binary/ocserv/*" "ocserv_${OCSERV_NOBLE_VERSION}_${arch}.deb"
  collect_one "*/build/ubuntu/noble/${arch}/binary/node-undici/*" "libllhttp[0-9]*_*_${arch}.deb"
done

(
  cd "${out}"
  sha256sum -- *.deb > SHA256SUMS
)
log "collected $(find "${out}" -maxdepth 1 -name '*.deb' | wc -l) packages in ${out}"
