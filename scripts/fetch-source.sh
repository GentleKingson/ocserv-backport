#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/_common.sh"

# Spec §2.4. dget from snapshot.debian.org fixed timestamp; chroot never sees sid.
UPSTREAM="${OCSERV_UPSTREAM_VERSION:-1.5.0}"
REVISION="${OCSERV_DEBIAN_REVISION:-1}"
SRC_VER="${UPSTREAM}-${REVISION}"

fetch_via_snapshot_staged() {
  # Spec §3.2 + §3.1. Snapshot path: dget in SNAPSHOT_STAGE, log to logfile arg.
  # Arg 1: snapshot_stage dir.  Arg 2: logfile path (caller always re-echoes it
  # for success-path observability + failure-classification diagnostics).
  local snapshot_stage="$1" logfile="$2"
  if [[ -f .env ]]; then set -a; source .env; set +a; fi
  local ts="${DEBIAN_SNAPSHOT_TIMESTAMP:?DEBIAN_SNAPSHOT_TIMESTAMP must be set (.env or env)}"
  local base="https://snapshot.debian.org/archive/debian/${ts}"
  local dsc_url="${base}/pool/main/o/ocserv/ocserv_${SRC_VER}.dsc"
  {
    log "dget ${dsc_url}"
    ( cd "$snapshot_stage" && dget -x -u "$dsc_url" )
  } >"$logfile" 2>&1
}

# Spec §3.3. Detect explicit HTTP 509 in dget's captured log text.
# Returns 0 (true) if any 509 marker matches; 1 otherwise.
# Arg 1: the log text (stdout+stderr) from dget.
is_509_failure() {
  local log_text="$1"
  # Match explicit 509 markers as they appear in real curl/wget output.
  # Do NOT match bare '22' (covers 404/403/500) or generic 'error'/'failed'.
  if printf '%s' "$log_text" | grep -qE 'curl: \(22\) The requested URL returned error: 509|HTTP Error 509|HTTP/1\.1 509|HTTP/2 509'; then
    return 0
  fi
  return 1
}


# Spec §5. Read a single-line Deb822 field (Source/Version) from a .dsc via an
# awk-scoped parser. PGP-aware: a signed .dsc wraps the body in
#   -----BEGIN PGP SIGNED MESSAGE----- / ... / -----BEGIN SIGNATURE-----
# We only parse the signed body (between the header line and -----BEGIN
# SIGNATURE-----). The field is matched at column 0 (^Field:) so it cannot be a
# continuation line or a substring of another field's value.
# Arg 1: .dsc file path.  Arg 2: field name (e.g. Source).  Prints the value.
_dsc_field() {
  local dsc_path="$1" field="$2"
  awk -v f="$field" '
    /^-----BEGIN PGP SIGNED MESSAGE-----/ { insigned=1; next }
    insigned && /^Hash:/ { next }                 # armor Hash header line
    /^-----BEGIN SIGNATURE-----/ { exit }         # stop at signature block
    insigned || /^Source:|^Version:|^Format:|^Files:|^Checksums-Sha256:|^Build-Depends:|^Architecture:/ {
      if ($0 ~ "^" f ":") { sub("^" f ": *", ""); print; exit }
    }
  ' "$dsc_path" 2>/dev/null
}

# Spec §3.4b + §5. Validate cached .dsc metadata via Deb822-aware parsing.
# Arg 1: .dsc file path.  Arg 2: expected Source.  Arg 3: expected Version.
# Dies on mismatch.
validate_dsc_metadata() {
  local dsc_path="$1" want_src="$2" want_ver="$3"
  [[ -f "$dsc_path" ]] || die "cached .dsc not found: ${dsc_path}"
  local got_src got_ver
  got_src="$(_dsc_field "$dsc_path" Source)"
  got_ver="$(_dsc_field "$dsc_path" Version)"
  [[ -n "$got_src" ]] || die "could not parse Source from ${dsc_path}"
  [[ -n "$got_ver" ]] || die "could not parse Version from ${dsc_path}"
  [[ "$got_src" == "$want_src" ]] || die "cached .dsc Source mismatch: got '${got_src}', expected '${want_src}'"
  [[ "$got_ver" == "$want_ver" ]] || die "cached .dsc Version mismatch: got '${got_ver}', expected '${want_ver}'"
}

# Spec §3.4c + §5. Parse Files (F) and Checksums-Sha256 (S) from a .dsc using
# Deb822-aware bounded stanza parsing (NO broad whole-file grep, NO dpkg tools).
# Arg 1: .dsc file path.
# Prints two lines: line 1 = F, line 2 = S. Each is space-separated basenames,
# ORDER PRESERVED, DUPLICATES KEPT (review fix #3: do not sort -u here; the
# caller validates basenames incl. dupes before normalizing to sorted-unique).
# Dies if Checksums-Sha256 stanza is absent.
parse_dsc_artifacts() {
  local dsc_path="$1"
  local f_set s_set
  # awk-scoped: skip PGP armor, then for each target stanza set a flag at the
  # header line (^Field:) and collect continuation lines (leading space) until
  # the next column-0 field or stanza separator. Filename = last whitespace-
  # separated field on each continuation line. NOTE: no sort -u — preserve dupes.
  f_set="$(awk '
    /^-----BEGIN PGP SIGNED MESSAGE-----/ { insigned=1; next }
    insigned && /^Hash:/ { next }
    /^-----BEGIN SIGNATURE-----/ { exit }
    /^Files:/ { flag=1; next }
    /^Checksums-Sha256:/ { flag=0; next }
    /^[^ ]/ { flag=0; next }
    flag && NF>0 { print $NF }
  ' "$dsc_path" 2>/dev/null | tr '\n' ' ')"
  s_set="$(awk '
    /^-----BEGIN PGP SIGNED MESSAGE-----/ { insigned=1; next }
    insigned && /^Hash:/ { next }
    /^-----BEGIN SIGNATURE-----/ { exit }
    /^Checksums-Sha256:/ { flag=1; next }
    /^[^ ]/ { flag=0; next }
    flag && NF>0 { print $NF }
  ' "$dsc_path" 2>/dev/null | tr '\n' ' ')"
  [[ -n "$s_set" ]] || die "cached .dsc lacks Checksums-Sha256 stanza (too weak): ${dsc_path}"
  printf '%s\n%s\n' "$f_set" "$s_set"
}

# Spec §3.4c. Validate every artifact filename is a safe basename before cp.
# Arg 1: space-separated filenames. Dies on any unsafe entry.
validate_artifact_basenames() {
  local names="$1"
  [[ -n "$names" ]] || die "no artifacts parsed from cached .dsc"
  local seen="" name
  for name in $names; do
    [[ -n "$name" ]] || die "empty artifact filename in cached .dsc"
    [[ "$name" == "." || "$name" == ".." ]] && die "unsafe artifact filename ('.' or '..') in cached .dsc"
    [[ "$name" == */* || "$name" == *\\* ]] && die "unsafe artifact filename (contains '/' or '\\'): ${name}"
    [[ " ${seen} " == *" ${name} "* ]] && die "duplicate artifact filename in cached .dsc: ${name}"
    seen="${seen} ${name}"
  done
}

# Spec §3.4d. Verify each artifact exists in CACHE_DIR. Dies naming missing ones.
# Arg 1: cache dir.  Arg 2: space-separated filenames.
verify_cache_artifacts() {
  local cache_dir="$1" names="$2" missing=""
  local name
  for name in $names; do
    [[ -f "${cache_dir}/${name}" ]] || missing="${missing} ${name}"
  done
  if [[ -n "$missing" ]]; then
    die "missing cached artifacts:${missing}
Fetch them from https://deb.debian.org/debian/pool/main/o/ocserv/ and place in ${cache_dir}/"
  fi
}
# Spec §3.4. Cache fallback: runs only on confirmed 509.
# Arg 1: cache_stage (isolated staging subdir). Uses global SRC_VER/UPSTREAM.
# Dies on any validation failure; never prints the "ready" log (caller does).
fetch_via_cache() {
  local cache_stage="$1"
  local cache_dir="build/source-cache"
  local dsc_name="ocserv_${SRC_VER}.dsc"
  local dsc_path="${cache_dir}/${dsc_name}"
  [[ -f "$dsc_path" ]] || die "HTTP 509 fallback needs cached .dsc at ${dsc_path}
Obtain it from https://deb.debian.org/debian/pool/main/o/ocserv/ and place in ${cache_dir}/"

  validate_dsc_metadata "$dsc_path" "ocserv" "$SRC_VER"

  local sets f_set s_set
  sets="$(parse_dsc_artifacts "$dsc_path")"
  f_set="$(printf '%s\n' "$sets" | sed -n '1p')"
  s_set="$(printf '%s\n' "$sets" | sed -n '2p')"

  # Validate basenames (incl. duplicates, path traversal) on the RAW f_set/s_set
  # BEFORE any normalization (review fix #3): a .dsc listing the same file twice,
  # or a filename with '/' or '..', is rejected here regardless of F==S outcome.
  validate_artifact_basenames "$f_set"
  validate_artifact_basenames "$s_set"

  # F == S set equality (spec §3.4c, case 9) — normalize to sorted-unique AFTER
  # the raw dup/basename checks above so dedup can't mask a duplicated filename.
  local f_norm s_norm
  f_norm="$(printf '%s' "$f_set" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  s_norm="$(printf '%s' "$s_set" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  [[ "$f_norm" == "$s_norm" ]] || die "cached .dsc Files set != Checksums-Sha256 set (partial SHA-256 coverage)"

  verify_cache_artifacts "$cache_dir" "$f_set"

  # Copy cached .dsc + artifacts into cache_stage (cache stays read-only input).
  cp "${dsc_path}" "${cache_stage}/${dsc_name}"
  local name
  for name in $f_set; do
    cp "${cache_dir}/${name}" "${cache_stage}/${name}"
  done

  log "snapshot.debian.org rate-limited (HTTP 509); extracting from local cache"
  ( cd "$cache_stage" && dpkg-source --require-strong-checksums -x "$dsc_name" "ocserv-${UPSTREAM}" )
  [[ -d "${cache_stage}/ocserv-${UPSTREAM}" ]] || die "cache extraction produced no source tree"
}

# Spec §3.7. Publish validated source tree with swap-with-rollback (policy B).
# Arg 1: staging tree path (must exist, non-empty).  Arg 2: target path.
publish_source_tree() {
  local staging_tree="$1" target="$2"
  [[ -d "$staging_tree" ]] || die "publish: staging tree missing: ${staging_tree}"
  local count; count="$(find "$staging_tree" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | wc -l)"
  [[ "$count" -ge 1 ]] || die "publish: staging tree empty: ${staging_tree}"
  mkdir -p "$(dirname "$target")"
  if [[ ! -e "$target" ]]; then
    mv "$staging_tree" "$target"
  else
    local backup="${target}.old.$$"
    mv "$target" "$backup"
    if ! mv "$staging_tree" "$target"; then
      mv "$backup" "$target"
      die "publish failed; old source tree restored at ${target}"
    fi
    rm -rf "$backup"
  fi
}

# Move the upstream orig tarball(s) — needed by the quilt 3.0 source rebuild
# (dpkg-source -b looks for ../ocserv_<upstream>.orig.tar.* in the parent dir of
# the tree). dget -x and dpkg-source -x both leave the orig tarball as a SIBLING
# of the extracted tree in staging; if we only publish the tree dir, the tarball
# is lost when the EXIT trap wipes TMP_ROOT, and build-source-package.sh fails
# with "no upstream tarball found". The single glob also picks up the matching
# .asc (ocserv_<upstream>.orig.tar.xz.asc). We do NOT move the sid .dsc /
# .debian.tar.* — the backport regenerates those.
# Arg 1: staging dir (parent of the tree, holding the orig tarball siblings).
# Arg 2: target dir (build/source). Dies if no orig tarball is found.
publish_orig_tarball() {
  local staging_dir="$1" target_dir="$2"
  local moved=0
  local f name
  # Feed the while loop via a heredoc (not a pipe) so `moved` is incremented in
  # this shell, not a subshell. `ls` may print nothing when no match (glob nulled
  # by the 2>/dev/null) — the empty-line guard handles that.
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    name="${f##*/}"
    if [[ -f "${f}" ]]; then
      mv "${f}" "${target_dir}/${name}"
      moved=$((moved + 1))
    fi
  done <<EOF
$(ls -1 "${staging_dir}"/ocserv_"${UPSTREAM}".orig.tar.* 2>/dev/null)
EOF
  [[ "${moved}" -ge 1 ]] \
    || die "publish: no orig tarball (ocserv_${UPSTREAM}.orig.tar.*) found in ${staging_dir}; source rebuild will fail"
}

# Spec §3.2. Global TMP_ROOT (single assignment, never reassigned) + cleanup
# function bound to EXIT. Global (not local) so the trap can reference it after
# main() returns (review fix #2: a local would be out of scope at EXIT and under
# set -u the trap expansion could fail, leaking .fetch-tmp.*).
TMP_ROOT=""
cleanup_fetch_tmp() {
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf -- "${TMP_ROOT}"
}

main() {
  mkdir -p build
  TMP_ROOT="$(mktemp -d build/.fetch-tmp.XXXXXX)"
  trap cleanup_fetch_tmp EXIT

  local snapshot_stage="${TMP_ROOT}/snapshot"
  local cache_stage="${TMP_ROOT}/cache"
  local dget_log="${TMP_ROOT}/dget.log"
  mkdir -p "$snapshot_stage" "$cache_stage"

  if fetch_via_snapshot_staged "$snapshot_stage" "$dget_log"; then
    cat "$dget_log"   # re-echo success diagnostics (observability)
    [[ -d "${snapshot_stage}/ocserv-${UPSTREAM}" ]] \
      || die "dget succeeded but source tree missing in staging"
    publish_source_tree "${snapshot_stage}/ocserv-${UPSTREAM}" "build/source/ocserv-${UPSTREAM}"
    publish_orig_tarball "${snapshot_stage}" "build/source"
    log "source tree ready: build/source/ocserv-${UPSTREAM}"
    return 0
  fi

  # Non-zero dget exit: re-emit full log (failure classification needs it),
  # then only fall back on explicit 509 (Task 6 wires the cache branch).
  cat "$dget_log" >&2
  if ! is_509_failure "$(cat "$dget_log")"; then
    die "dget failed (non-509); see log above"
  fi
  log "snapshot.debian.org returned HTTP 509; attempting local source cache fallback"
  fetch_via_cache "$cache_stage"
  publish_source_tree "${cache_stage}/ocserv-${UPSTREAM}" "build/source/ocserv-${UPSTREAM}"
  publish_orig_tarball "${cache_stage}" "build/source"
  log "source tree ready (from local cache; snapshot.debian.org was rate-limited): build/source/ocserv-${UPSTREAM}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
