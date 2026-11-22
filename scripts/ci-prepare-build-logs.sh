#!/usr/bin/env bash
# Copy build logs into a staging directory with GitHub-artifact-safe filenames
# (replacing ":" with "_").
#
# Usage: ci-prepare-build-logs.sh <search-root> <upload-dir>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

search_root="${1:-}"
upload_dir="${2:-}"
[[ -n "${search_root}" && -n "${upload_dir}" ]] \
  || die "usage: ci-prepare-build-logs.sh <search-root> <upload-dir>"

rm -rf -- "${upload_dir}"
mkdir -p -- "${upload_dir}"

while IFS= read -r -d '' log_path; do
  rel="${log_path#./}"
  safe_name="${rel//:/_}"
  mkdir -p -- "${upload_dir}/$(dirname -- "${safe_name}")"
  cp -- "${log_path}" "${upload_dir}/${safe_name}"
done < <(
  find "${search_root}" \
    -type f \
    \( -name '*.build' -o -name '*.buildlog' -o -name '*.log' \) \
    -print0 2>/dev/null || true
)
