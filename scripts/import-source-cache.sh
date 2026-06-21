#!/usr/bin/env bash
# Import a verified source-cache bundle into build/source-cache/<name>/<version>/.
# Runs on the builder or an internal cache node (NOT the prefetch node).
# Zero Python, zero YAML/JSON parsing, zero network. Spec §3.7.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=_dsc.sh
. "${SCRIPT_DIR}/_dsc.sh"
# shellcheck source=_lock_tsv.sh
. "${SCRIPT_DIR}/_lock_tsv.sh"
# shellcheck source=_cache_meta.sh
. "${SCRIPT_DIR}/_cache_meta.sh"

REPO_ROOT="$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel)"
CACHE_ROOT="${REPO_ROOT}/build/source-cache"

_sha256() { sha256sum "$1" | awk '{print $1}'; }

usage() { cat >&2 <<EOF
Usage: $0 [--expected-sha256 <64hex>] <bundle>
EOF
  exit 2; }

# parse_sidecar <sidecar_path> <bundle_basename>  — echo the hash, die on malformed.
parse_sidecar() {
  local sidecar="$1" basename="$2"
  local n
  n="$(wc -l <"${sidecar}" | tr -d ' ')"
  [[ "${n}" -eq 1 ]] || die "sidecar must be exactly one line (got ${n}): ${sidecar}"
  local line; line="$(cat "${sidecar}")"
  # Strict: ^<64hex>  <basename><LF>$
  [[ "${line}" =~ ^([0-9a-f]{64})[[:space:]][[:space:]]([^[:space:]]+)$ ]] \
    || die "sidecar malformed: ${sidecar}"
  local h="${BASH_REMATCH[1]}" nm="${BASH_REMATCH[2]}"
  [[ "${nm}" == "${basename}" ]] || die "sidecar names '${nm}' != bundle basename '${basename}'"
  [[ "${nm}" != *"\\"* ]] || die "sidecar name has backslash escape"
  printf '%s' "${h}"
}

# tar_prescan <bundle> <whitelist_file>
# whitelist_file: one expected member path per line, <name>/<version>/<file>.
# Accepts ONLY regular files (verbose mode first char '-'). Dies on any violation.
tar_prescan() {
  local bundle="$1" whitelist="$2"
  local listing; listing="$(mktemp)"
  env -u TAR_OPTIONS LC_ALL=C tar --list --verbose --zstd --file "${bundle}" >"${listing}" 2>/dev/null \
    || { rm -f "${listing}"; die "tar listing failed: ${bundle}"; }
  local wl_sorted; wl_sorted="$(sort -u "${whitelist}")"
  local modeblank member
  while read -r modeblank member _; do
    [[ -n "${modeblank}" ]] || continue
    local type_char="${modeblank:0:1}"
    [[ "${type_char}" == "-" ]] || { rm -f "${listing}"; die "tar member not regular file: ${member} (type '${type_char}')"; }
    case "${member}" in
      /*)        rm -f "${listing}"; die "tar absolute path: ${member}" ;;
      *../*)     rm -f "${listing}"; die "tar .. in path: ${member}" ;;
      *//*)      rm -f "${listing}"; die "tar empty segment: ${member}" ;;
    esac
    if ! grep -qxF "${member}" "${wl_sorted}"; then
      rm -f "${listing}"; die "tar member not in whitelist: ${member}"
    fi
  done < "${listing}"
  rm -f "${listing}"
}

main() {
  local expected_hash="" bundle=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --expected-sha256) expected_hash="$2"; shift 2 ;;
      --help|-h) usage ;;
      -*) die "unknown option: $1" ;;
      *) [[ -z "${bundle}" ]] || usage; bundle="$1"; shift ;;
    esac
  done
  [[ -n "${bundle}" ]] || usage
  [[ -f "${bundle}" ]] || die "bundle not found: ${bundle}"

  if [[ -n "${expected_hash}" ]]; then
    [[ "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] || die "--expected-sha256 must be 64 lowercase hex"
  fi

  # 2. parse <name>+<version> from bundle basename.
  local bname; bname="$(basename "${bundle}")"
  [[ "${bname}" =~ ^([a-z0-9][a-z0-9+.\-]*)_([A-Za-z0-9.+~\-]+)\.source-cache\.tar\.zst$ ]] \
    || die "bundle name malformed: ${bname}"
  local name="${BASH_REMATCH[1]}" version="${BASH_REMATCH[2]}"

  # 3. cwd-independent checksum. Resolve absolute dir portably (avoid realpath -e,
  # which is GNU-only; macOS BSD realpath lacks -e). sidecar sits beside bundle.
  local bundle_dir bundle_abs
  bundle_dir="$(cd "$(dirname -- "${bundle}")" && pwd)"
  bundle_abs="${bundle_dir}/$(basename -- "${bundle}")"
  if [[ -z "${expected_hash}" ]]; then
    local sidecar="${bundle_abs}.sha256"
    [[ -f "${sidecar}" ]] || die "sidecar missing and no --expected-sha256: ${sidecar}"
    expected_hash="$(parse_sidecar "${sidecar}" "${bname}")"
  fi
  local actual_hash; actual_hash="$(_sha256 "${bundle_abs}")"
  [[ "${actual_hash}" == "${expected_hash}" ]] || die "bundle checksum mismatch (expected ${expected_hash}, got ${actual_hash})"

  # 4. read lock projection; build whitelist + expected-SHA256SUMS.
  local lock_tsv="${REPO_ROOT}/source-lock/${name}/${version}.lock.tsv"
  read_lock_tsv "${lock_tsv}" "${version}"
  local whitelist; whitelist="$(mktemp)"
  {
    printf '%s/%s/%s\n' "${name}" "${version}" "${META_DSC_NAME}"
    local i
    for i in "${!ARTIFACT_NAME[@]}"; do printf '%s/%s/%s\n' "${name}" "${version}" "${ARTIFACT_NAME[${i}]}"; done
    printf '%s/%s/SHA256SUMS\n' "${name}" "${version}"
    printf '%s/%s/source-manifest.json\n' "${name}" "${version}"
    printf '%s/%s/cache.meta\n' "${name}" "${version}"
  } > "${whitelist}"
  local expected_sums; expected_sums="$(mktemp)"
  write_expected_sha256sums "${expected_sums}"

  # 5. tar type prescan (regular files only, whitelist membership).
  tar_prescan "${bundle_abs}" "${whitelist}"

  # 6. extract to empty staging with hardened flags.
  local staging; staging="$(mktemp -d)"
  env -u TAR_OPTIONS LC_ALL=C tar --extract --zstd --file "${bundle_abs}" \
      --directory "${staging}" --no-same-owner --no-same-permissions --no-overwrite-dir \
    || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "tar extract failed"; }

  local staged="${staging}/${name}/${version}"
  [[ -d "${staged}" ]] || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "staged ${staged} missing"; }

  # 7-8. cache.meta + version assertions + identity closure.
  read_cache_meta "${staged}/cache.meta"
  verify_cache_meta_versions
  [[ "${CM_SOURCE}" == "${name}" && "${CM_DEBIAN_VERSION}" == "${version}" ]] \
    || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "cache.meta source/version != bundle name/version"; }
  # identity anchor: expected (from lock) == actual SHA256SUMS (cmp -s, no cwd dep)
  cmp -s "${expected_sums}" "${staged}/SHA256SUMS" \
    || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "cache SHA256SUMS != lock projection (identity mismatch)"; }
  verify_manifest_hash "${staged}" || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "manifest hash mismatch"; }
  ( cd "${staged}" && sha256sum -c --status SHA256SUMS ) \
    || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "SHA256SUMS verification failed"; }
  [[ "${CM_CONTENT_SHA256}" == "$(_sha256 "${staged}/SHA256SUMS")" ]] \
    || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "content_sha256 self-inconsistent"; }
  validate_dsc_metadata "${staged}/${META_DSC_NAME}" "${name}" "${version}" \
    || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die ".dsc metadata mismatch"; }

  # 9. atomic install (idempotence: spec §3.8).
  local target="${CACHE_ROOT}/${name}/${version}"
  if [[ -d "${target}" ]]; then
    read_cache_meta "${target}/cache.meta" \
      || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "existing cache corrupt; refusing overwrite"; }
    ( cd "${target}" && verify_cache_meta_versions && sha256sum -c --status SHA256SUMS ) \
      || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "existing cache corrupt; refusing overwrite"; }
    [[ "${CM_CONTENT_SHA256}" == "$(_sha256 "${staged}/SHA256SUMS")" ]] \
      && { log "cache already present and identical: ${target}"; rm -rf "${staging}" "${whitelist}" "${expected_sums}"; exit 0; } \
      || { rm -rf "${staging}" "${whitelist}" "${expected_sums}"; die "cache ${target} exists with different content; refusing overwrite"; }
  fi
  mkdir -p "$(dirname "${target}")"
  mv "${staged}" "${target}"
  rm -rf "${staging}" "${whitelist}" "${expected_sums}"
  log "imported cache: ${target}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
