#!/usr/bin/env bash
# Pool-only .lock.tsv parser. Source with: . scripts/_lock_tsv.sh
set -euo pipefail

RE_TSV_SOURCE='^[a-z0-9][a-z0-9+.\-]*$'
RE_TSV_VERSION='^[A-Za-z0-9.+~\-]+$'
RE_TSV_SHA='^[0-9a-f]{64}$'
RE_TSV_POOL_SEG='^[A-Za-z0-9][A-Za-z0-9+._\-]*$'

_tsv_die() { echo "lock.tsv error: $*" >&2; return 1; }

_tsv_safe_basename() {
  local name="$1"
  [[ -n "${name}" && "${name}" != "." && "${name}" != ".." \
    && "${name}" != *"/"* && "${name}" != *"\\"* \
    && ! "${name}" =~ [[:space:]] && ! "${name}" =~ [[:cntrl:]] \
    && "${name}" != -* ]]
}

_tsv_check_pool_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 1
  [[ "${path}" != /* && "${path}" != */ ]] || return 1
  [[ "${path}" != *"\\"* ]] || return 1
  [[ ! "${path}" =~ [[:space:]] && ! "${path}" =~ [[:cntrl:]] ]] || return 1
  [[ "${path}" != *"://"* && "${path}" != *"?"* && "${path}" != *"#"* && "${path}" != *"%"* ]] || return 1
  local IFS='/'
  # shellcheck disable=SC2206 # intentional split on validated path segments
  local -a segs=( ${path} )
  local seg
  for seg in "${segs[@]}"; do
    [[ -n "${seg}" && "${seg}" != "." && "${seg}" != ".." ]] || return 1
    [[ "${seg}" =~ ${RE_TSV_POOL_SEG} ]] || return 1
  done
}

read_lock_tsv() {
  local file="$1" expect_ver="$2"
  [[ -f "${file}" ]] || _tsv_die "file not found: ${file}"
  grep -q $'\r' "${file}" && _tsv_die "CRLF present"

  META_SOURCE=""
  META_DEBIAN_VERSION=""
  META_POOL_PATH=""
  META_DSC_NAME=""
  META_DSC_SIZE=""
  META_DSC_SHA256=""
  ARTIFACT_NAME=()
  ARTIFACT_SIZE=()
  ARTIFACT_SHA256=()

  local lineno=0 meta_seen=0 seen_art=""
  local rectype f1 f2 f3 f4 f5 f6 rest
  while IFS=$'\t' read -r rectype f1 f2 f3 f4 f5 f6 rest || [[ -n "${rectype}" ]]; do
    lineno=$((lineno + 1))
    case "${rectype}" in
      META)
        [[ "${lineno}" -eq 1 ]] || _tsv_die "META must be first line"
        [[ "${meta_seen}" -eq 0 ]] || _tsv_die "multiple META records"
        [[ -z "${rest:-}" ]] || _tsv_die "line ${lineno}: extra fields"
        [[ -n "${f1:-}" && -n "${f2:-}" && -n "${f3:-}" && -n "${f4:-}" && -n "${f5:-}" && -n "${f6:-}" ]] \
          || _tsv_die "META missing fields"
        meta_seen=1
        META_SOURCE="${f1}"
        META_DEBIAN_VERSION="${f2}"
        META_POOL_PATH="${f3}"
        META_DSC_NAME="${f4}"
        META_DSC_SIZE="${f5}"
        META_DSC_SHA256="${f6}"
        [[ "${META_SOURCE}" =~ ${RE_TSV_SOURCE} ]] || _tsv_die "bad source"
        [[ "${META_SOURCE}" == "ocserv" ]] || _tsv_die "META source != ocserv"
        [[ "${META_DEBIAN_VERSION}" =~ ${RE_TSV_VERSION} ]] || _tsv_die "bad debian_version"
        [[ "${META_DEBIAN_VERSION}" == "1.5.0-1" ]] || _tsv_die "META version must be 1.5.0-1"
        [[ "${META_DEBIAN_VERSION}" == "${expect_ver}" ]] \
          || _tsv_die "expect_version '${expect_ver}' != META debian_version '${META_DEBIAN_VERSION}'"
        _tsv_check_pool_path "${META_POOL_PATH}" || _tsv_die "bad pool_path: ${META_POOL_PATH}"
        _tsv_safe_basename "${META_DSC_NAME}" || _tsv_die "bad dsc name: ${META_DSC_NAME}"
        [[ "${META_DSC_NAME}" == *.dsc ]] || _tsv_die "dsc.name must end with .dsc: ${META_DSC_NAME}"
        [[ "${META_DSC_SIZE}" =~ ^[0-9]+$ ]] || _tsv_die "bad dsc size"
        [[ "${META_DSC_SHA256}" =~ ${RE_TSV_SHA} ]] || _tsv_die "bad dsc sha256"
        ;;
      ARTIFACT)
        [[ "${meta_seen}" -eq 1 ]] || _tsv_die "ARTIFACT before META"
        [[ -z "${f4:-}${f5:-}${f6:-}${rest:-}" ]] || _tsv_die "line ${lineno}: ARTIFACT extra fields"
        [[ -n "${f1:-}" && -n "${f2:-}" && -n "${f3:-}" ]] || _tsv_die "ARTIFACT missing fields"
        _tsv_safe_basename "${f1}" || _tsv_die "bad artifact name: ${f1}"
        [[ "${f1}" != "${META_DSC_NAME}" ]] || _tsv_die "artifact == dsc name"
        [[ "${f2}" =~ ^[0-9]+$ ]] || _tsv_die "bad artifact size"
        [[ "${f3}" =~ ${RE_TSV_SHA} ]] || _tsv_die "bad artifact sha256"
        if printf '%s\n' "${seen_art}" | grep -qxF -- "${f1}"; then
          _tsv_die "dup artifact: ${f1}"
        fi
        seen_art="${seen_art}${f1}"$'\n'
        ARTIFACT_NAME+=("${f1}")
        ARTIFACT_SIZE+=("${f2}")
        ARTIFACT_SHA256+=("${f3}")
        ;;
      *) _tsv_die "unknown record type: ${rectype}" ;;
    esac
  done < "${file}"

  [[ "${meta_seen}" -eq 1 ]] || _tsv_die "no META record"
  [[ "${#ARTIFACT_NAME[@]}" -ge 1 ]] || _tsv_die "no ARTIFACT records"
}

write_expected_sha256sums() {
  local out="$1"
  : > "${out}"
  printf '%s  %s\n' "${META_DSC_SHA256}" "${META_DSC_NAME}" >> "${out}"
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    printf '%s  %s\n' "${ARTIFACT_SHA256[${i}]}" "${ARTIFACT_NAME[${i}]}" >> "${out}"
  done
}
