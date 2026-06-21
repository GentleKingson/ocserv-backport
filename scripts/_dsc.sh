#!/usr/bin/env bash
# Source-only Deb822 (.dsc) parser library. Spec §3.6.1.
# Extracted+upgraded from fetch-source.sh (slice 2); fetch-source.sh adopts it in slice 3.
set -euo pipefail

# _dsc_field <dsc_path> <FieldName>  — single-line field, PGP-armor-aware.
_dsc_field() {
  local dsc_path="$1" field="$2"
  awk -v f="${field}" '
    /^-----BEGIN PGP SIGNED MESSAGE-----/ { in_hdr=1; next }
    /^-----BEGIN PGP SIGNATURE-----/ { exit }
    in_hdr && /^Hash:/ { next }
    in_hdr && /^$/ { in_hdr=0; next }
    !in_hdr && $0 ~ "^"f":" { sub("^"f":[[:space:]]*",""); print; exit }
  ' "${dsc_path}"
}

validate_dsc_metadata() {
  local dsc_path="$1" exp_src="$2" exp_ver="$3"
  local got_src got_ver
  got_src="$(_dsc_field "${dsc_path}" Source)"
  got_ver="$(_dsc_field "${dsc_path}" Version)"
  [[ "${got_src}" == "${exp_src}" ]] || { echo "dsc Source '${got_src}' != '${exp_src}'" >&2; return 1; }
  [[ "${got_ver}" == "${exp_ver}" ]] || { echo "dsc Version '${got_ver}' != '${exp_ver}'" >&2; return 1; }
}

# validate_artifact_basenames <space-separated names>
# Portable to bash 3.2 (no associative arrays): track seen names in a
# newline-delimited string with grep -qxF.
validate_artifact_basenames() {
  local names="$1"
  [[ -n "${names}" ]] || { echo "empty artifact list" >&2; return 1; }
  local -a arr=( ${names} )
  local seen="" n
  for n in "${arr[@]}"; do
    [[ "${n}" != *"/"* && "${n}" != *"\\"* && "${n}" != ".." && "${n}" != "." && "${n}" != *[[:cntrl:]]* && "${n}" != *" "* ]] \
      || { echo "bad basename: ${n}" >&2; return 1; }
    if printf '%s\n' "${seen}" | grep -qxF -- "${n}"; then
      { echo "dup basename: ${n}" >&2; return 1; }
    fi
    seen="${seen}${n}"$'\n'
  done
}

# parse_dsc_full <dsc_path> — emit name<TAB>size<TAB>sha256 per artifact, order preserved.
# Requires Files stanza and Checksums-Sha256 stanza; dies if either missing or mismatched.
parse_dsc_full() {
  local dsc_path="$1"
  local tmp; tmp="$(mktemp)"
  awk '
    /^-----BEGIN PGP SIGNATURE-----/ { exit }
    /^-----BEGIN PGP SIGNED MESSAGE-----/ { in_hdr=1; next }
    in_hdr && /^Hash:/ { next }
    in_hdr && /^$/ { in_hdr=0; next }
    in_hdr { next }
    /^Files:/ { sec="files"; next }
    /^Checksums-Sha256:/ { sec="csum"; next }
    /^[^[:space:]]/ { sec=""; next }
    sec=="files" && /^[[:space:]]/ {
      # md5 size name
      line=$0; sub(/^[[:space:]]+/,"",line); n=split(line,p," ");
      files_name[p[3]]=p[2]; files_order[++fc]=p[3]; next
    }
    sec=="csum" && /^[[:space:]]/ {
      line=$0; sub(/^[[:space:]]+/,"",line); n=split(line,p," ");
      csum_sha[p[3]]=p[1]; csum_size[p[3]]=p[2]; next
    }
    END {
      for (i=1;i<=fc;i++) {
        nm=files_order[i]
        if (!(nm in csum_sha)) { print "missing Checksums-Sha256 for "nm > "/dev/stderr"; exit 1 }
        if (files_name[nm] != csum_size[nm]) { print "size mismatch "nm > "/dev/stderr"; exit 1 }
        printf "%s\t%s\t%s\n", nm, files_name[nm], csum_sha[nm]
      }
    }
  ' "${dsc_path}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  cat "${tmp}"; rm -f "${tmp}"
}

# dsc_artifacts_match_lock <dsc_path>
# Caller sets arrays: ARTIFACT_NAME[], ARTIFACT_SIZE[], ARTIFACT_SHA256[] (from lock).
# Validates: Files set == Checksums set == lock set; per-artifact size+sha256 == lock.
# Portable to bash 3.2 (no associative arrays): build a lookup string
# "<name>\t<size>\t<sha256>\n" per lock artifact and grep it.
dsc_artifacts_match_lock() {
  local dsc_path="$1"
  local lock_table="" i
  for i in "${!ARTIFACT_NAME[@]}"; do
    lock_table="${lock_table}${ARTIFACT_NAME[${i}]}"$'\t'"${ARTIFACT_SIZE[${i}]}"$'\t'"${ARTIFACT_SHA256[${i}]}"$'\n'
  done
  local parsed; parsed="$(parse_dsc_full "${dsc_path}")" || return 1
  local name size sha seen=""
  while IFS=$'\t' read -r name size sha; do
    # lock entry for this name?
    local want; want="$(printf '%s' "${lock_table}" | awk -F'\t' -v n="${name}" '$1==n{print $2"\t"$3; exit}')"
    [[ -n "${want}" ]] || { echo "dsc lists ${name} not in lock" >&2; return 1; }
    local want_size want_sha
    want_size="${want%%$'\t'*}"; want_sha="${want#*$'\t'}"
    [[ "${size}" == "${want_size}" ]] || { echo "size mismatch ${name}" >&2; return 1; }
    [[ "${sha}" == "${want_sha}" ]] || { echo "sha256 mismatch ${name}" >&2; return 1; }
    seen="${seen}${name}"$'\n'
  done <<< "${parsed}"
  # All lock artifacts must appear in dsc.
  for i in "${!ARTIFACT_NAME[@]}"; do
    printf '%s\n' "${seen}" | grep -qxF -- "${ARTIFACT_NAME[${i}]}" \
      || { echo "lock lists ${ARTIFACT_NAME[${i}]} not in dsc" >&2; return 1; }
  done
}
