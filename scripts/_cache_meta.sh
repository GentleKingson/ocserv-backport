#!/usr/bin/env bash
# Source-only cache.meta restricted parser. Spec §3.5.1.
set -euo pipefail

RE_CM_SOURCE='^[a-z0-9][a-z0-9+.\-]*$'
RE_CM_VERSION='^[A-Za-z0-9.+~\-]+$'
RE_CM_SHA='^[0-9a-f]{64}$'

_cm_die() { echo "cache.meta error: $*" >&2; return 1; }

read_cache_meta() {
  local file="$1"
  [[ -f "${file}" ]] || _cm_die "not found: ${file}"
  CM_SOURCE=""; CM_DEBIAN_VERSION=""; CM_CONTENT_SHA256=""; CM_MANIFEST_SHA256=""
  CM_META_FORMAT_VERSION=""; CM_BUNDLE_FORMAT_VERSION=""; CM_MANIFEST_SCHEMA_VERSION=""
  local seen_keys=""   # newline-delimited seen keys (portable to bash 3.2)
  local k v
  while IFS='=' read -r k v || [[ -n "${k}" ]]; do
    [[ -z "${k}" ]] && continue
    case "${k}" in
      meta_format_version|bundle_format_version|source|debian_version|content_sha256|manifest_sha256|manifest_schema_version) ;;
      *) _cm_die "unknown field: ${k}" ;;
    esac
    if printf '%s\n' "${seen_keys}" | grep -qxF -- "${k}"; then
      _cm_die "duplicate field: ${k}"
    fi
    [[ -n "${v}" ]] || _cm_die "empty value: ${k}"
    [[ "${v}" != *[[:cntrl:]]* && "${v}" != *" "* ]] || _cm_die "bad value chars: ${k}"
    seen_keys="${seen_keys}${k}"$'\n'
    case "${k}" in
      source) CM_SOURCE="${v}" ;;
      debian_version) CM_DEBIAN_VERSION="${v}" ;;
      content_sha256) CM_CONTENT_SHA256="${v}" ;;
      manifest_sha256) CM_MANIFEST_SHA256="${v}" ;;
      meta_format_version) CM_META_FORMAT_VERSION="${v}" ;;
      bundle_format_version) CM_BUNDLE_FORMAT_VERSION="${v}" ;;
      manifest_schema_version) CM_MANIFEST_SCHEMA_VERSION="${v}" ;;
    esac
  done < "${file}"
  # All 7 required fields present.
  [[ -n "${CM_SOURCE}" ]] || _cm_die "missing source"
  [[ -n "${CM_DEBIAN_VERSION}" ]] || _cm_die "missing debian_version"
  [[ -n "${CM_CONTENT_SHA256}" ]] || _cm_die "missing content_sha256"
  [[ -n "${CM_MANIFEST_SHA256}" ]] || _cm_die "missing manifest_sha256"
  [[ -n "${CM_META_FORMAT_VERSION}" ]] || _cm_die "missing meta_format_version"
  [[ -n "${CM_BUNDLE_FORMAT_VERSION}" ]] || _cm_die "missing bundle_format_version"
  [[ -n "${CM_MANIFEST_SCHEMA_VERSION}" ]] || _cm_die "missing manifest_schema_version"
  [[ "${CM_SOURCE}" =~ ${RE_CM_SOURCE} ]] || _cm_die "bad source"
  [[ "${CM_DEBIAN_VERSION}" =~ ${RE_CM_VERSION} ]] || _cm_die "bad debian_version (no epoch)"
  [[ "${CM_CONTENT_SHA256}" =~ ${RE_CM_SHA} ]] || _cm_die "bad content_sha256"
  [[ "${CM_MANIFEST_SHA256}" =~ ${RE_CM_SHA} ]] || _cm_die "bad manifest_sha256"
}

verify_cache_meta_versions() {
  [[ "${CM_META_FORMAT_VERSION}" == "1" ]] || _cm_die "meta_format_version != 1"
  [[ "${CM_BUNDLE_FORMAT_VERSION}" == "1" ]] || _cm_die "bundle_format_version != 1"
  [[ "${CM_MANIFEST_SCHEMA_VERSION}" == "1" ]] || _cm_die "manifest_schema_version != 1"
}

# verify_manifest_hash <cache_dir>  — checks source-manifest.json against CM_MANIFEST_SHA256.
verify_manifest_hash() {
  local cache_dir="$1"
  printf '%s  source-manifest.json\n' "${CM_MANIFEST_SHA256}" \
    | ( cd "${cache_dir}" && sha256sum -c --status - ) \
    || _cm_die "manifest_sha256 mismatch"
}
