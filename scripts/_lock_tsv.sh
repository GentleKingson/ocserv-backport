#!/usr/bin/env bash
# Source-only restricted .lock.tsv parser. Spec §4.3.1.
# read_lock_tsv <file> <expect_version>  — fills META_* globals + ARTIFACT_* arrays.
# write_expected_sha256sums <out_file>     — emit expected SHA256SUMS from current META/ARTIFACT.
set -euo pipefail

RE_TSV_SOURCE='^[a-z0-9][a-z0-9+.\-]*$'
RE_TSV_VERSION='^[A-Za-z0-9.+~\-]+$'
RE_TSV_SHA='^[0-9a-f]{64}$'

_tsv_die() { echo "lock.tsv error: $*" >&2; return 1; }

read_lock_tsv() {
  local file="$1" expect_ver="$2"
  [[ -f "${file}" ]] || _tsv_die "file not found: ${file}"
  # Reject CRLF.
  if grep -q $'\r' "${file}"; then _tsv_die "CRLF present"; fi

  META_SOURCE=""; META_DEBIAN_VERSION=""; META_ALLOWED_SOURCES=""
  META_SNAPSHOT_TS=""; META_POOL_PATH=""; META_DSC_NAME=""; META_DSC_SIZE=""; META_DSC_SHA256=""
  ARTIFACT_NAME=(); ARTIFACT_SIZE=(); ARTIFACT_SHA256=()
  local lineno=0 meta_seen=0
  local seen_art=""   # newline-delimited seen artifact names (portable to bash 3.2)
  local rectype f1 f2 f3 f4 f5 f6 f7 f8 rest
  while IFS=$'\t' read -r rectype f1 f2 f3 f4 f5 f6 f7 f8 rest || [[ -n "${rectype}" ]]; do
    lineno=$((lineno+1))
    [[ -z "${rest}" ]] || _tsv_die "line ${lineno}: extra fields"
    case "${rectype}" in
      META)
        [[ "${meta_seen}" -eq 0 ]] || _tsv_die "multiple META records"
        [[ "${lineno}" -eq 1 ]] || _tsv_die "META must be first line"
        meta_seen=1
        # exactly 9 columns: rectype + 8
        [[ -n "${f1}${f2}${f3}${f4}${f5}${f6}${f7}${f8}" ]] || _tsv_die "META missing fields"
        META_SOURCE="${f1}"; META_DEBIAN_VERSION="${f2}"
        export META_ALLOWED_SOURCES="${f3}"   # consumed cross-file by prefetch/fetch (export silences SC2034)
        META_SNAPSHOT_TS="${f4}"; META_POOL_PATH="${f5}"
        META_DSC_NAME="${f6}"; META_DSC_SIZE="${f7}"; META_DSC_SHA256="${f8}"
        [[ "${META_SNAPSHOT_TS}" == "-" ]] && META_SNAPSHOT_TS=""
        [[ "${META_POOL_PATH}" == "-" ]] && META_POOL_PATH=""
        [[ "${META_SOURCE}" =~ ${RE_TSV_SOURCE} ]] || _tsv_die "bad source"
        [[ "${META_DEBIAN_VERSION}" =~ ${RE_TSV_VERSION} ]] || _tsv_die "bad debian_version"
        [[ "${META_DSC_SHA256}" =~ ${RE_TSV_SHA} ]] || _tsv_die "bad dsc sha256"
        [[ "${META_DSC_SIZE}" =~ ^[0-9]+$ ]] || _tsv_die "bad dsc size"
        ;;
      ARTIFACT)
        [[ "${meta_seen}" -eq 1 ]] || _tsv_die "ARTIFACT before META"
        [[ -n "${f1}${f2}${f3}" ]] || _tsv_die "ARTIFACT missing fields"
        [[ -z "${f4}" ]] || _tsv_die "ARTIFACT extra fields"
        [[ -n "${f1}" && "${f1}" != *"/"* && "${f1}" != *"\\"* && "${f1}" != *" "* && "${f1}" != -* ]] \
          || _tsv_die "bad artifact name: ${f1}"
        [[ "${f1}" != "${META_DSC_NAME}" ]] || _tsv_die "artifact == dsc name"
        [[ "${f2}" =~ ^[0-9]+$ ]] || _tsv_die "bad artifact size"
        [[ "${f3}" =~ ${RE_TSV_SHA} ]] || _tsv_die "bad artifact sha256"
        if printf '%s\n' "${seen_art}" | grep -qxF -- "${f1}"; then
          _tsv_die "dup artifact: ${f1}"
        fi
        seen_art="${seen_art}${f1}"$'\n'
        ARTIFACT_NAME+=("${f1}"); ARTIFACT_SIZE+=("${f2}"); ARTIFACT_SHA256+=("${f3}")
        ;;
      *) _tsv_die "unknown record type: ${rectype}" ;;
    esac
  done < "${file}"

  [[ "${meta_seen}" -eq 1 ]] || _tsv_die "no META record"
  [[ "${#ARTIFACT_NAME[@]}" -ge 1 ]] || _tsv_die "no ARTIFACT records"
  # 3-way identity: expect_version == META version (caller also checks lock path <ver>)
  [[ "${META_DEBIAN_VERSION}" == "${expect_ver}" ]] \
    || _tsv_die "expect_version '${expect_ver}' != META debian_version '${META_DEBIAN_VERSION}'"
  [[ "${META_SOURCE}" == "ocserv" ]] || _tsv_die "META source != ocserv"
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
