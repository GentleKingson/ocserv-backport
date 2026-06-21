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
  # shellcheck disable=SC2206 # intentional word-split of a space-separated, space-validated name list
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
# Requires Files stanza and Checksums-Sha256 stanza; dies if either missing.
# Strict cross-check (review fix #2): Files set must EXACTLY equal Checksums-Sha256
# set — rejects (a) a file in Checksums but not Files, (b) a file in Files but not
# Checksums, (c) duplicate filenames within either stanza, (d) rows that are not
# exactly 3 whitespace-separated fields. Records not matching the pipeline-wide
# safe-basename rule are also rejected.
parse_dsc_full() {
  local dsc_path="$1"
  local tmp; tmp="$(mktemp)"
  awk '
    function bad(msg) { print msg > "/dev/stderr"; exit 1 }
    function safe_name(nm) {
      if (nm == "" || nm == "." || nm == "..") return 0
      if (index(nm, "/") > 0) return 0
      if (index(nm, "\\") > 0) return 0
      if (nm ~ /[^ -~]/) return 0            # reject control chars + non-ASCII
      if (substr(nm,1,1) == " " || substr(nm,length(nm),1) == " ") return 0
      if (substr(nm,1,1) == "-") return 0
      return 1
    }
    /^-----BEGIN PGP SIGNATURE-----/ { exit }
    /^-----BEGIN PGP SIGNED MESSAGE-----/ { in_hdr=1; next }
    in_hdr && /^Hash:/ { next }
    in_hdr && /^$/ { in_hdr=0; next }
    in_hdr { next }
    /^Files:/ { sec="files"; next }
    /^Checksums-Sha256:/ { sec="csum"; next }
    /^[^[:space:]]/ { sec=""; next }
    sec=="files" && /^[[:space:]]/ {
      line=$0; sub(/^[[:space:]]+/,"",line); n=split(line,p," ");
      if (n != 3) bad("Files row not 3 fields: " line)
      nm=p[3]
      if (!safe_name(nm)) bad("unsafe filename in Files: " nm)
      if (nm in files_name) bad("duplicate filename in Files: " nm)
      files_name[nm]=p[2]; files_order[++fc]=nm; next
    }
    sec=="csum" && /^[[:space:]]/ {
      line=$0; sub(/^[[:space:]]+/,"",line); n=split(line,p," ");
      if (n != 3) bad("Checksums-Sha256 row not 3 fields: " line)
      nm=p[3]
      if (!safe_name(nm)) bad("unsafe filename in Checksums-Sha256: " nm)
      if (nm in csum_sha) bad("duplicate filename in Checksums-Sha256: " nm)
      csum_sha[nm]=p[1]; csum_size[nm]=p[2]; csum_seen[++cc]=nm; next
    }
    END {
      if (fc == 0) bad("no Files stanza entries")
      # 1. every Files entry must be in Checksums-Sha256 with matching size
      for (i=1;i<=fc;i++) {
        nm=files_order[i]
        if (!(nm in csum_sha)) bad("file in Files but not Checksums-Sha256: " nm)
        if (files_name[nm] != csum_size[nm]) bad("size mismatch " nm)
      }
      # 2. every Checksums-Sha256 entry must be in Files (reject extras)
      for (i=1;i<=cc;i++) {
        nm=csum_seen[i]
        if (!(nm in files_name)) bad("file in Checksums-Sha256 but not Files: " nm)
      }
      # emit
      for (i=1;i<=fc;i++) {
        nm=files_order[i]
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
