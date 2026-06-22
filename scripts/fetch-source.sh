#!/usr/bin/env bash
# Fetch the locked ocserv sid source from Debian pool into build/source/.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_dsc.sh
. "${SCRIPT_DIR}/_dsc.sh"
# shellcheck source=scripts/_lock_tsv.sh
. "${SCRIPT_DIR}/_lock_tsv.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/build"
SOURCE_ROOT="${BUILD_ROOT}/source"
UPSTREAM_VERSION="1.5.0"
SOURCE_VERSION="1.5.0-1"
LOCK_TSV="${REPO_ROOT}/source-lock/ocserv/${SOURCE_VERSION}.lock.tsv"
TMP_ROOT=""

DSCVERIFY_KEYRINGS=(
  /usr/share/keyrings/debian-keyring.gpg
  /usr/share/keyrings/debian-maintainers.gpg
  /usr/share/keyrings/debian-nonupload.gpg
  /usr/share/keyrings/debian-tag2upload.pgp
)

cleanup_fetch_tmp() {
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf -- "${TMP_ROOT}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

dscverify_cmd() {
  local dsc="$1"
  local -a args=(dscverify --no-conf --no-default-keyrings)
  local keyring
  for keyring in "${DSCVERIFY_KEYRINGS[@]}"; do
    args+=(--keyring "${keyring}")
  done
  args+=("${dsc}")
  "${args[@]}"
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

  "${SCRIPT_DIR}/verify-source-lock.sh"
  read_lock_tsv "${LOCK_TSV}" "${SOURCE_VERSION}"

  mkdir -p "${BUILD_ROOT}"
  TMP_ROOT="$(mktemp -d "${BUILD_ROOT}/.fetch-tmp.XXXXXX")"
  trap cleanup_fetch_tmp EXIT
  local staging="${TMP_ROOT}/staging"
  mkdir -p "${staging}"

  local base_url="https://deb.debian.org/debian/pool/${META_POOL_PATH}"
  local dsc="${staging}/${META_DSC_NAME}"

  download_artifact "${base_url}/${META_DSC_NAME}" "${dsc}" "${META_DSC_NAME}"
  assert_size_sha256 "${dsc}" "${META_DSC_NAME}" "${META_DSC_SIZE}" "${META_DSC_SHA256}"
  validate_dsc_metadata "${dsc}" "${META_SOURCE}" "${META_DEBIAN_VERSION}" \
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
  dpkg-source --require-valid-signature --require-strong-checksums -x "${dsc}" "${staging}/ocserv-${UPSTREAM_VERSION}" \
    || die "dpkg-source -x failed for ${META_DSC_NAME}"

  install_source_tree "${staging}/ocserv-${UPSTREAM_VERSION}" "${SOURCE_ROOT}/ocserv-${UPSTREAM_VERSION}"
  install_orig_tarballs "${staging}" "${SOURCE_ROOT}"
  log "source tree ready: ${SOURCE_ROOT}/ocserv-${UPSTREAM_VERSION}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
