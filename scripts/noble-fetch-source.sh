#!/usr/bin/env bash
# Fetch a locked Debian source package into the Noble target source dir.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"
# shellcheck source=scripts/_dsc.sh
. "${SCRIPT_DIR}/_dsc.sh"
# shellcheck source=scripts/_lock_tsv.sh
. "${SCRIPT_DIR}/_lock_tsv.sh"
# shellcheck source=scripts/_dscverify.sh
. "${SCRIPT_DIR}/_dscverify.sh"
# shellcheck source=scripts/_fetch.sh
. "${SCRIPT_DIR}/_fetch.sh"

[[ "$#" -eq 1 ]] || die "usage: noble-fetch-source.sh node-undici|ocserv"
noble_package_vars "$1"

TMP_ROOT=""
cleanup_fetch_tmp() {
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf -- "${TMP_ROOT}"
}

verify_source_lock_unless_internal_skip() {
  if [[ "${NOBLE_SKIP_FETCH_VERIFY_LOCK:-}" == "1" ]]; then
    return 0
  fi
  "${SCRIPT_DIR}/verify-source-lock.sh"
}

install_orig_artifacts() {
  local staging_dir="$1" target_dir="$2"
  local moved=0 i name
  mkdir -p "${target_dir}"
  for i in "${!ARTIFACT_NAME[@]}"; do
    name="${ARTIFACT_NAME[${i}]}"
    case "${name}" in
      *.orig*)
        mv -- "${staging_dir}/${name}" "${target_dir}/${name}"
        moved=1
        ;;
    esac
  done
  [[ "${moved}" -eq 1 ]] || die "no orig artifacts found in validated staging"
}

main() {
  verify_source_lock_unless_internal_skip
  read_lock_tsv "${PKG_LOCK_TSV}" "${PKG_DEBIAN_VERSION}" "${PKG_SOURCE}"

  mkdir -p "${NOBLE_BUILD_ROOT}"
  TMP_ROOT="$(mktemp -d "${NOBLE_BUILD_ROOT}/.fetch-${PKG_SOURCE}.XXXXXX")"
  trap cleanup_fetch_tmp EXIT
  local staging="${TMP_ROOT}/staging"
  mkdir -p "${staging}"

  local dsc="${staging}/${META_DSC_NAME}"

  download_locked_file "${META_DSC_NAME}" "${dsc}" "${META_DSC_SIZE}" "${META_DSC_SHA256}"
  validate_dsc_metadata "${dsc}" "${PKG_SOURCE}" "${PKG_DEBIAN_VERSION}" \
    || die "dsc metadata mismatch for ${META_DSC_NAME}"
  dsc_artifacts_match_lock "${dsc}" || die "dsc artifact mapping mismatch for ${META_DSC_NAME}"

  local i name dest
  for i in "${!ARTIFACT_NAME[@]}"; do
    name="${ARTIFACT_NAME[${i}]}"
    dest="${staging}/${name}"
    download_locked_file "${name}" "${dest}" "${ARTIFACT_SIZE[${i}]}" "${ARTIFACT_SHA256[${i}]}"
  done

  dscverify_cmd "${dsc}" || die "dscverify failed for ${META_DSC_NAME}"
  # The signature and payload hashes are verified above with locked hashes and
  # dscverify keyrings; dpkg-source cannot use the CI-refreshed keyring list.
  dpkg-source --no-check -x "${dsc}" "${staging}/${PKG_SOURCE}-${PKG_UPSTREAM_VERSION}" \
    || die "dpkg-source -x failed for ${META_DSC_NAME}"

  install_source_tree "${staging}/${PKG_SOURCE}-${PKG_UPSTREAM_VERSION}" "${PKG_SOURCE_TREE}"
  install_orig_artifacts "${staging}" "${PKG_SOURCE_ROOT}"
  log "source tree ready: ${PKG_SOURCE_TREE}"
}

main "$@"
