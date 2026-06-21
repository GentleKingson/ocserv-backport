#!/usr/bin/env bash
# Fetch the ocserv source tree into build/source/. Spec §4.
# FETCH_SOURCE=pool  : fetch locked version from deb.debian.org/debian/pool/<pool_path>/
# FETCH_SOURCE=cache : read verified build/source-cache/<name>/<version>/ (zero network)
# No automatic fallback. No snapshot access on the builder.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"
# shellcheck source=_dsc.sh
. "$SCRIPT_DIR/_dsc.sh"
# shellcheck source=_lock_tsv.sh
. "$SCRIPT_DIR/_lock_tsv.sh"
# shellcheck source=_cache_meta.sh
. "$SCRIPT_DIR/_cache_meta.sh"

# Fail fast if the builder is missing required commands (e.g. dscverify from
# devscripts when bootstrap-build-host.sh was not fully run). Spec
# docs/superpowers/specs/2026-06-21-build-pipeline-dependency-check-design.md
require_cmds \
  dscverify:devscripts \
  dpkg-source:dpkg-dev \
  curl:curl \
  sha256sum:coreutils \
  gpg:gnupg \
  quilt:quilt

REPO_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
BUILD_ROOT="$REPO_ROOT/build"
CACHE_ROOT="$BUILD_ROOT/source-cache"
SOURCE_ROOT="$BUILD_ROOT/source"

# Load repo-root .env (if present) so FETCH_SOURCE / OCSERV_UPSTREAM_VERSION /
# OCSERV_DEBIAN_REVISION set there take effect when run via `make fetch` / dry-run.
# `set -a` exports every assignment while sourcing. NOTE: sourcing .env OVERWRITES
# any same-named variable already in the environment — .env wins over a pre-exported
# value. To override per-invocation, set the var on the command line AFTER the script
# resolves .env is not possible; instead, edit .env or unset the var in .env. This
# matches the pre-refactor fetch-source.sh semantics.
# Spec §4.3 + §5.1: .env is operator input for the builder.
ENV_FILE="$REPO_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090,SC1091  # .env is trusted repo-root operator input
  . "$ENV_FILE"
  set +a
fi

UPSTREAM="${OCSERV_UPSTREAM_VERSION:-1.5.0}"
REVISION="${OCSERV_DEBIAN_REVISION:-1}"
REQUEST_VER="${UPSTREAM}-${REVISION}"
LOCK_TSV="${REPO_ROOT}/source-lock/ocserv/${REQUEST_VER}.lock.tsv"

# dscverify fixed trust root (advisory A + review fix #4): all 4 official keyrings.
DSCVERIFY_KEYRINGS=(
  /usr/share/keyrings/debian-keyring.gpg
  /usr/share/keyrings/debian-maintainers.gpg
  /usr/share/keyrings/debian-nonupload.gpg
  /usr/share/keyrings/debian-tag2upload.pgp
)
dscverify_cmd() {
  local dsc="$1"; local -a args=(dscverify --no-conf --no-default-keyrings)
  local kr; for kr in "${DSCVERIFY_KEYRINGS[@]}"; do args+=(--keyring "$kr"); done
  args+=("$dsc"); "${args[@]}"
}

# download_artifact <url> <destination> <logfile>  (spec §3.6.2; shared with prefetch)
download_artifact() {
  local url="$1" dest="$2" logfile="$3"
  if ! curl --fail --show-error --location --output "$dest" "$url" >"$logfile" 2>&1; then
    cat "$logfile" >&2; return 1
  fi
}
_sha256() { sha256sum "$1" | awk '{print $1}'; }

# Spec §3.7. Publish validated source tree with swap-with-rollback (policy B).
# Retained verbatim from pre-refactor fetch-source.sh.
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

# Move the upstream orig tarball(s) — needed by the quilt 3.0 source rebuild.
# Retained verbatim from pre-refactor fetch-source.sh.
publish_orig_tarball() {
  local staging_dir="$1" target_dir="$2"
  local moved=0
  local f name
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

# Global TMP_ROOT + cleanup trap. Retained verbatim.
TMP_ROOT=""
cleanup_fetch_tmp() {
  [[ -n "${TMP_ROOT:-}" ]] && rm -rf -- "${TMP_ROOT}"
}

# fetch_via_pool <staging>  — spec §4.1 + §3.6-step-5 8-step ordering.
# Pool URL = https://deb.debian.org/debian/pool/<pool_path>/<file>.
fetch_via_pool() {
  local staging="$1"
  # allowed_sources gate (zero-network if pool unauthorized)
  [[ ",$META_ALLOWED_SOURCES," == *",pool,"* ]] \
    || die "lock does not authorize pool source for ocserv/${REQUEST_VER}"
  [[ -n "$META_POOL_PATH" ]] || die "lock missing pool_path"
  local base="https://deb.debian.org/debian/pool/${META_POOL_PATH}"
  local dsc="$staging/$META_DSC_NAME" logfile
  # 1. download .dsc
  logfile="$(mktemp)"
  download_artifact "$base/$META_DSC_NAME" "$dsc" "$logfile" \
    || { cat "$logfile" >&2; rm -f "$logfile"; die "pool download failed for $META_DSC_NAME"; }
  rm -f "$logfile"
  # 2. verify .dsc size+sha256 == lock
  local s h; s="$(wc -c <"$dsc" | tr -d ' ')"; h="$(_sha256 "$dsc")"
  [[ "$s" == "$META_DSC_SIZE" ]] || die "pool .dsc size $s != lock $META_DSC_SIZE"
  [[ "$h" == "$META_DSC_SHA256" ]] || die "pool .dsc sha256 mismatch"
  # 3-4. parse + cross-check Files/Checksums-Sha256/lock
  dsc_artifacts_match_lock "$dsc" || die "pool .dsc artifact mapping != lock"
  # 5. download artifacts
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    local nm="${ARTIFACT_NAME[$i]}"
    local dest="$staging/$nm"
    logfile="$(mktemp)"
    download_artifact "$base/$nm" "$dest" "$logfile" \
      || { cat "$logfile" >&2; rm -f "$logfile"; die "pool download failed for $nm"; }
    rm -f "$logfile"
    # 6. verify actual size+sha256 == lock
    s="$(wc -c <"$dest" | tr -d ' ')"; h="$(_sha256 "$dest")"
    [[ "$s" == "${ARTIFACT_SIZE[$i]}" ]] || die "$nm size $s != lock"
    [[ "$h" == "${ARTIFACT_SHA256[$i]}" ]] || die "$nm sha256 mismatch"
  done
  # 7. dscverify (fixed trust root)
  dscverify_cmd "$dsc" || die "dscverify failed for $META_DSC_NAME"
  # 8. dpkg-source strong unpack into staging/ocserv-<UPSTREAM>
  dpkg-source --require-valid-signature --require-strong-checksums -x "$dsc" "$staging/ocserv-${UPSTREAM}" \
    || die "dpkg-source -x failed"
}

# fetch_via_cache <staging>  — spec §4.4 11-step identity closure. Zero network.
fetch_via_cache() {
  local staging="$1"
  local cache="$CACHE_ROOT/$META_SOURCE/$META_DEBIAN_VERSION"
  [[ -d "$cache" ]] || die "cache missing: $cache (run prefetch + import on a prefetch node)"
  # 2. read cache.meta
  read_cache_meta "$cache/cache.meta"
  # 3. version assertions (all three)
  verify_cache_meta_versions
  # 4. cache.meta source/version == lock META (4-way: env→META→lock path→cache dir)
  [[ "$CM_SOURCE" == "$META_SOURCE" && "$CM_DEBIAN_VERSION" == "$META_DEBIAN_VERSION" ]] \
    || die "cache.meta source/version != lock META"
  # 5. content_sha256 == sha256(SHA256SUMS)  (cache.meta self-consistent)
  [[ "$CM_CONTENT_SHA256" == "$(_sha256 "$cache/SHA256SUMS")" ]] \
    || die "cache content_sha256 self-inconsistent"
  # 6-7. identity anchor: expected (from lock) == actual SHA256SUMS
  local expected; expected="$(mktemp)"
  write_expected_sha256sums "$expected"
  cmp -s "$expected" "$cache/SHA256SUMS" \
    || { rm -f "$expected"; die "cache SHA256SUMS != lock projection (identity mismatch)"; }
  rm -f "$expected"
  # 8. sha256sum -c on actual artifact bytes
  ( cd "$cache" && sha256sum -c --status SHA256SUMS ) || die "cache SHA256SUMS verification failed"
  # 9. manifest integrity (internal consistency only)
  verify_manifest_hash "$cache" || die "cache manifest hash mismatch"
  # 10. .dsc artifact mapping == lock
  dsc_artifacts_match_lock "$cache/$META_DSC_NAME" || die "cache .dsc mapping != lock"
  # 11. dpkg-source strong unpack into staging (re-verifies signature)
  cp -- "$cache/$META_DSC_NAME" "$staging/"
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do cp -- "$cache/${ARTIFACT_NAME[$i]}" "$staging/"; done
  dpkg-source --require-valid-signature --require-strong-checksums -x "$staging/$META_DSC_NAME" "$staging/ocserv-${UPSTREAM}" \
    || die "dpkg-source -x failed (cache)"
}

main() {
  local mode="${FETCH_SOURCE:-pool}"
  case "$mode" in
    pool|cache) ;;
    *) die "FETCH_SOURCE must be pool|cache, got: $mode" ;;
  esac
  # read lock + 3-way identity (env version == META version == lock path <ver>; META source == ocserv)
  read_lock_tsv "$LOCK_TSV" "$REQUEST_VER"
  [[ "$META_DEBIAN_VERSION" == "$REQUEST_VER" ]] \
    || die "env version '$REQUEST_VER' != lock META debian_version '$META_DEBIAN_VERSION'"
  [[ "$META_SOURCE" == "ocserv" ]] || die "lock META source '$META_SOURCE' != ocserv"

  mkdir -p "$BUILD_ROOT"
  TMP_ROOT="$(mktemp -d "$BUILD_ROOT/.fetch-tmp.XXXXXX")"
  trap cleanup_fetch_tmp EXIT
  local staging="$TMP_ROOT/staging"; mkdir -p "$staging"

  case "$mode" in
    pool)  fetch_via_pool  "$staging" ;;
    cache) fetch_via_cache "$staging" ;;
  esac

  publish_source_tree "$staging/ocserv-${UPSTREAM}" "$SOURCE_ROOT/ocserv-${UPSTREAM}"
  publish_orig_tarball "$staging" "$SOURCE_ROOT"
  log "source tree ready: $SOURCE_ROOT/ocserv-${UPSTREAM} (from ${mode})"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
