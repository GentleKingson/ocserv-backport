#!/usr/bin/env bash
# Stage ocserv source and binary build outputs for CI artifact upload.
#
# Usage: ci-stage-build-artifacts.sh <target-root> <staging-dir>
#   target-root: relative path such as build/debian/trixie/amd64
#   staging-dir: destination directory (recreated cleanly)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

target_root="${1:-}"
staging="${2:-}"
[[ -n "${target_root}" && -n "${staging}" ]] \
  || die "usage: ci-stage-build-artifacts.sh <target-root> <staging-dir>"

staged_root="${staging}/${target_root}"
rm -rf -- "${staging}"
mkdir -p -- "${staged_root}/source" "${staged_root}/binary"

find "${target_root}/source" \
  -maxdepth 1 \
  -type f \
  \( \
    -name 'ocserv_*.dsc' \
    -o -name 'ocserv_*.debian.tar.*' \
    -o -name 'ocserv_*.orig.tar.*' \
    -o -name 'ocserv_*_source.changes' \
    -o -name 'ocserv_*_source.buildinfo' \
  \) \
  -exec cp -- {} "${staged_root}/source/" \;

find "${target_root}/binary" \
  -maxdepth 1 \
  -type f \
  \( \
    -name 'ocserv_*.deb' \
    -o -name 'ocserv_*.changes' \
    -o -name 'ocserv_*.buildinfo' \
  \) \
  -exec cp -- {} "${staged_root}/binary/" \;
