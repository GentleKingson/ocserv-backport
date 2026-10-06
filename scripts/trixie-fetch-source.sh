#!/usr/bin/env bash
# Fetch the locked ocserv sid source from Debian pool into the target source dir.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_dsc.sh
. "${SCRIPT_DIR}/_dsc.sh"
# shellcheck source=scripts/_lock_tsv.sh
. "${SCRIPT_DIR}/_lock_tsv.sh"
# shellcheck source=scripts/_dscverify.sh
. "${SCRIPT_DIR}/_dscverify.sh"
# shellcheck source=scripts/_fetch.sh
. "${SCRIPT_DIR}/_fetch.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/trixie-env.sh
. "${SCRIPT_DIR}/trixie-env.sh"
SOURCE_ROOT="${TARGET_SOURCE_ROOT}"
UPSTREAM_VERSION="1.5.0"
SOURCE_VERSION="1.5.0-1"
LOCK_TSV="${REPO_ROOT}/source-lock/ocserv/${SOURCE_VERSION}.lock.tsv"
TMP_ROOT=""

cleanup_fetch_tmp() {
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf -- "${TMP_ROOT}"
}

verify_source_lock_unless_internal_skip() {
  if [[ "${TRIXIE_SKIP_FETCH_VERIFY_LOCK:-}" == "1" ]]; then
    return 0
  fi
  "${SCRIPT_DIR}/verify-source-lock.sh"
}

install_orig_tarballs() {
  local staging_dir="$1" target_dir="$2"
  shopt -s nullglob
  local -a origs=("${staging_dir}"/ocserv_"${UPSTREAM_VERSION}".orig.tar.*)
  shopt -u nullglob
  [[ "${#origs[@]}" -ge 1 ]] || die "no orig tarball found in validated staging"

  local artifact
  mkdir -p "${target_dir}"
  for artifact in "${origs[@]}"; do
    mv -- "${artifact}" "${target_dir}/$(basename "${artifact}")"
  done
}

main() {
  local legacy_source_var="FETCH""_SOURCE"
  [[ -z "${!legacy_source_var:-}" ]] || die "legacy source mode environment variable is no longer supported; fetch is pool-only"

  verify_source_lock_unless_internal_skip
  read_lock_tsv "${LOCK_TSV}" "${SOURCE_VERSION}"

  mkdir -p "${TARGET_BUILD_ROOT}"
  TMP_ROOT="$(mktemp -d "${TARGET_BUILD_ROOT}/.fetch-tmp.XXXXXX")"
  trap cleanup_fetch_tmp EXIT
  local staging="${TMP_ROOT}/staging"
  mkdir -p "${staging}"

  local dsc="${staging}/${META_DSC_NAME}"

  download_locked_file "${META_DSC_NAME}" "${dsc}" "${META_DSC_SIZE}" "${META_DSC_SHA256}"
  validate_dsc_metadata "${dsc}" "${META_SOURCE}" "${META_DEBIAN_VERSION}" \
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
  dpkg-source --no-check -x "${dsc}" "${staging}/ocserv-${UPSTREAM_VERSION}" \
    || die "dpkg-source -x failed for ${META_DSC_NAME}"

  install_source_tree "${staging}/ocserv-${UPSTREAM_VERSION}" "${SOURCE_ROOT}/ocserv-${UPSTREAM_VERSION}"
  install_orig_tarballs "${staging}" "${SOURCE_ROOT}"
  log "source tree ready: ${SOURCE_ROOT}/ocserv-${UPSTREAM_VERSION}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
