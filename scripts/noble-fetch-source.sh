#!/usr/bin/env bash
# Fetch a locked Debian source package into build/noble/${TARGET_ARCH}/source/.
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

[[ "$#" -eq 1 ]] || die "usage: noble-fetch-source.sh node-undici|ocserv"
noble_package_vars "$1"

TMP_ROOT=""
cleanup_fetch_tmp() {
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf -- "${TMP_ROOT}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

verify_source_lock_unless_internal_skip() {
  if [[ "${NOBLE_SKIP_FETCH_VERIFY_LOCK:-}" == "1" ]]; then
    return 0
  fi
  "${SCRIPT_DIR}/verify-source-lock.sh"
}

download_artifact() {
  local url="$1" dest="$2" name="$3"
  if ! curl --fail --show-error --location --output "${dest}" "${url}"; then
    die "download failed for ${name}: ${url}"
  fi
}

assert_size_sha256() {
  local file="$1" name="$2" expected_size="$3" expected_sha="$4"
  local actual_size actual_sha
  actual_size="$(file_size "${file}")"
  actual_sha="$(sha256_file "${file}")"
  [[ "${actual_size}" == "${expected_size}" ]] \
    || die "${name} size ${actual_size} != expected ${expected_size}"
  [[ "${actual_sha}" == "${expected_sha}" ]] \
    || die "${name} sha256 mismatch"
}

install_source_tree() {
  local staging_tree="$1" target="$2"
  [[ -d "${staging_tree}" ]] || die "validated source tree missing: ${staging_tree}"
  find "${staging_tree}" -mindepth 1 -maxdepth 1 -print -quit | grep -q . \
    || die "validated source tree empty: ${staging_tree}"

  mkdir -p "$(dirname "${target}")"
  if [[ ! -e "${target}" ]]; then
    mv -- "${staging_tree}" "${target}"
    return 0
  fi

  local backup="${target}.old.$$"
  mv -- "${target}" "${backup}"
  if ! mv -- "${staging_tree}" "${target}"; then
    mv -- "${backup}" "${target}"
    die "source tree install failed; restored old tree"
  fi
  rm -rf -- "${backup}"
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

  local base_url="https://deb.debian.org/debian/pool/${META_POOL_PATH}"
  local dsc="${staging}/${META_DSC_NAME}"

  download_artifact "${base_url}/${META_DSC_NAME}" "${dsc}" "${META_DSC_NAME}"
  assert_size_sha256 "${dsc}" "${META_DSC_NAME}" "${META_DSC_SIZE}" "${META_DSC_SHA256}"
  validate_dsc_metadata "${dsc}" "${PKG_SOURCE}" "${PKG_DEBIAN_VERSION}" \
    || die "dsc metadata mismatch for ${META_DSC_NAME}"
  dsc_artifacts_match_lock "${dsc}" || die "dsc artifact mapping mismatch for ${META_DSC_NAME}"

  local i name dest
  for i in "${!ARTIFACT_NAME[@]}"; do
    name="${ARTIFACT_NAME[${i}]}"
    dest="${staging}/${name}"
    download_artifact "${base_url}/${name}" "${dest}" "${name}"
    assert_size_sha256 "${dest}" "${name}" "${ARTIFACT_SIZE[${i}]}" "${ARTIFACT_SHA256[${i}]}"
  done

  dscverify_cmd "${dsc}" || die "dscverify failed for ${META_DSC_NAME}"
  dpkg-source --require-valid-signature --require-strong-checksums -x "${dsc}" "${staging}/${PKG_SOURCE}-${PKG_UPSTREAM_VERSION}" \
    || die "dpkg-source -x failed for ${META_DSC_NAME}"

  install_source_tree "${staging}/${PKG_SOURCE}-${PKG_UPSTREAM_VERSION}" "${PKG_SOURCE_TREE}"
  install_orig_artifacts "${staging}" "${PKG_SOURCE_ROOT}"
  log "source tree ready: ${PKG_SOURCE_TREE}"
}

main "$@"
