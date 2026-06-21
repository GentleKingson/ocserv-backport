#!/usr/bin/env bash
# Prefetch a Debian source package from snapshot.debian.org into a verified
# versioned cache + transport bundle. Runs ONLY on a prefetch node with
# snapshot access. Spec §3.6, §3.6.2, §3.4, §3.8, §3.9.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=_dsc.sh
. "${SCRIPT_DIR}/_dsc.sh"
# shellcheck source=_lock_tsv.sh
. "${SCRIPT_DIR}/_lock_tsv.sh"
# shellcheck source=_cache_meta.sh
. "${SCRIPT_DIR}/_cache_meta.sh"

REPO_ROOT="$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel)"
BUILD_ROOT="${REPO_ROOT}/build"
CACHE_ROOT="${BUILD_ROOT}/source-cache"
BUNDLE_ROOT="${BUILD_ROOT}/source-bundles"

# Dscverify fixed trust root (advisory A + review fix #4): all 4 official keyrings.
DSCVERIFY_KEYRINGS=(
  /usr/share/keyrings/debian-keyring.gpg
  /usr/share/keyrings/debian-maintainers.gpg
  /usr/share/keyrings/debian-nonupload.gpg
  /usr/share/keyrings/debian-tag2upload.pgp
)

dscverify_cmd() {
  local dsc="$1"; local -a args=(dscverify --no-conf --no-default-keyrings)
  local kr; for kr in "${DSCVERIFY_KEYRINGS[@]}"; do args+=(--keyring "${kr}"); done
  args+=("${dsc}"); "${args[@]}"
}

# download_artifact <url> <destination> <logfile>   (spec §3.6.2, curl, no retry)
download_artifact() {
  local url="$1" dest="$2" logfile="$3"
  if ! curl --fail --show-error --location --output "${dest}" "${url}" >"${logfile}" 2>&1; then
    cat "${logfile}" >&2
    return 1
  fi
}

usage() { cat >&2 <<EOF
Usage: $0 --lock <yaml> | --source <name> --debian-version <ver>
EOF
  exit 2
}

_sha256() { sha256sum "$1" | awk '{print $1}'; }

LOCK_YAML=""

# load_lock <yaml_path>
# Spec §3.6 step 3: run parser to temp TSV, cmp -s committed companion .lock.tsv,
# then read_lock_tsv the companion. Dies before any network on drift/missing.
load_lock() {
  local yaml="$1"
  local companion="${yaml%.yaml}.lock.tsv"
  local proj; proj="$(mktemp)"
  if ! python3 "${SCRIPT_DIR}/read-source-lock.py" --lock "${yaml}" >"${proj}" 2>/dev/null; then
    rm -f "${proj}"; die "lock YAML failed to parse: ${yaml}"
  fi
  if [[ ! -f "${companion}" ]]; then
    rm -f "${proj}"; die "companion .lock.tsv missing for ${yaml} (run CI projection guard)"
  fi
  if ! cmp -s "${proj}" "${companion}"; then
    rm -f "${proj}"
    die "YAML/.lock.tsv drift for ${yaml}; regenerate the projection and commit both"
  fi
  rm -f "${proj}"
  # Derive the expect-version from the YAML's debian_version (authoritative for the
  # 3-way identity: yaml version == META version == companion path). read_lock_tsv
  # then asserts META.debian_version == expect AND META.source == ocserv.
  local expect_ver
  expect_ver="$(python3 "${SCRIPT_DIR}/read-source-lock.py" --lock "${yaml}" \
    | awk -F'\t' '/^META/{print $2}')" \
    || die "could not extract debian_version from ${yaml}"
  [[ -n "${expect_ver}" ]] || die "lock has empty debian_version: ${yaml}"
  read_lock_tsv "${companion}" "${expect_ver}"
}

# _keyring_prov_json  — emit the dscverify_keyrings[] JSON array to stdout via python.
# Each entry: {path, sha256, package, package_version}. Ordered by DSCVERIFY_KEYRINGS.
_keyring_prov_json() {
  local pkg sha ver
  local -a entries=()
  local kr
  for kr in "${DSCVERIFY_KEYRINGS[@]}"; do
    [[ -f "${kr}" ]] || die "keyring not found: ${kr} (install debian-keyring / debian-tag2upload-keyring)"
    sha="$(_sha256 "${kr}")"
    case "${kr}" in
      *debian-tag2upload.pgp) pkg="debian-tag2upload-keyring" ;;
      *)                      pkg="debian-keyring" ;;
    esac
    ver="$(dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null || echo unknown)"
    entries+=( "$(printf '{"path":"%s","sha256":"%s","package":"%s","package_version":"%s"}' \
                   "${kr}" "${sha}" "${pkg}" "${ver}")" )
  done
  printf '%s\n' "${entries[@]}" | python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))'
}

# run_strong_verification <staging_dir> <base_url>
# Spec §3.6 step 5 (authoritative 8-step ordering) + §4.6 pool ordering.
run_strong_verification() {
  local staging="$1" base_url="$2"
  local dsc="${staging}/${META_DSC_NAME}"
  local logfile
  # a. download .dsc
  logfile="$(mktemp)"
  if ! download_artifact "${base_url}/${META_DSC_NAME}" "${dsc}" "${logfile}"; then
    cat "${logfile}" >&2; rm -f "${logfile}"
    die "snapshot download failed for ${META_DSC_NAME} (change egress or retry later)"
  fi
  rm -f "${logfile}"
  # b. verify .dsc size + sha256 == lock
  local got_size got_sha
  got_size="$(wc -c <"${dsc}" | tr -d ' ')"
  got_sha="$(_sha256 "${dsc}")"
  [[ "${got_size}" == "${META_DSC_SIZE}" ]] || die ".dsc size ${got_size} != lock ${META_DSC_SIZE}"
  [[ "${got_sha}" == "${META_DSC_SHA256}" ]] || die ".dsc sha256 ${got_sha} != lock"
  # c-d. parse .dsc + cross-check Files/Checksums-Sha256/lock mapping (dsc_artifacts_match_lock)
  dsc_artifacts_match_lock "${dsc}" || die ".dsc artifact mapping != lock"
  # e. download all artifacts
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    local nm="${ARTIFACT_NAME[${i}]}"
    local dest="${staging}/${nm}"
    logfile="$(mktemp)"
    if ! download_artifact "${base_url}/${nm}" "${dest}" "${logfile}"; then
      cat "${logfile}" >&2; rm -f "${logfile}"
      die "snapshot download failed for ${nm} (change egress or retry later)"
    fi
    rm -f "${logfile}"
    # f. verify actual artifact size + sha256 == lock
    got_size="$(wc -c <"${dest}" | tr -d ' ')"
    got_sha="$(_sha256 "${dest}")"
    [[ "${got_size}" == "${ARTIFACT_SIZE[${i}]}" ]] || die "${nm} size ${got_size} != lock"
    [[ "${got_sha}" == "${ARTIFACT_SHA256[${i}]}" ]] || die "${nm} sha256 mismatch"
  done
  # g. dscverify with fixed trust root (artifacts now present)
  dscverify_cmd "${dsc}" || die "dscverify failed for ${META_DSC_NAME}"
  # h. dpkg-source strong unpack (internal integrity confirmation only)
  dpkg-source --require-valid-signature --require-strong-checksums -x "${dsc}" "${staging}/ocserv-extract-check" \
    || die "dpkg-source -x failed (strong checksum/signature)"
  rm -rf "${staging}/ocserv-extract-check"
}

# write_cache <staging_dir>  — assemble <name>/<version>/ with artifacts, SHA256SUMS,
# source-manifest.json (via python json.dumps), cache.meta.
write_cache() {
  local staging="$1"
  local cache="${staging}/${META_SOURCE}/${META_DEBIAN_VERSION}"
  mkdir -p "${cache}"
  cp -- "${staging}/${META_DSC_NAME}" "${cache}/${META_DSC_NAME}"
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    cp -- "${staging}/${ARTIFACT_NAME[${i}]}" "${cache}/${ARTIFACT_NAME[${i}]}"
  done
  # SHA256SUMS: dsc first, then artifacts in lock order.
  {
    printf '%s  %s\n' "${META_DSC_SHA256}" "${META_DSC_NAME}"
    for i in "${!ARTIFACT_NAME[@]}"; do
      printf '%s  %s\n' "${ARTIFACT_SHA256[${i}]}" "${ARTIFACT_NAME[${i}]}"
    done
  } > "${cache}/SHA256SUMS"
  local content_sha manifest_sha
  content_sha="$(_sha256 "${cache}/SHA256SUMS")"
  # source-manifest.json via python json.dumps (never bash concat).
  local lock_sha pyyaml_ver keyrings_json
  lock_sha="$(_sha256 "${LOCK_YAML}")"
  pyyaml_ver="$(python3 -c 'import yaml;print(yaml.__version__)' 2>/dev/null || echo unknown)"
  keyrings_json="$(_keyring_prov_json)"
  local dscverify_ver dpkg_src_ver
  dscverify_ver="$(dscverify --version 2>/dev/null | head -1 || echo unknown)"
  dpkg_src_ver="$(dpkg-source --version 2>/dev/null | head -1 || echo unknown)"
  local base_url="https://snapshot.debian.org/archive/debian/${META_SNAPSHOT_TS}/pool/${META_POOL_PATH:-main/o/ocserv}"
  python3 - "${cache}/source-manifest.json" "${META_SOURCE}" "${META_DEBIAN_VERSION}" \
           "${META_SNAPSHOT_TS}" "${META_POOL_PATH}" "${META_ALLOWED_SOURCES}" \
           "${META_DSC_NAME}" "${META_DSC_SIZE}" "${META_DSC_SHA256}" \
           "${LOCK_YAML}" "${lock_sha}" "${pyyaml_ver}" "${keyrings_json}" \
           "${dscverify_ver}" "${dpkg_src_ver}" "${base_url}" "${ARTIFACT_NAME[*]}" "${ARTIFACT_SIZE[*]}" "${ARTIFACT_SHA256[*]}" <<'PY'
import json, sys
(out, src, ver, ts, pp, allowed, dn, ds, dsh, lp, lsh, pyv, krj, dv, dsv, base, an, asz, ash) = sys.argv[1:]
an, asz, ash = an.split(), asz.split(), ash.split()
manifest = {
    "manifest_schema_version": 1,
    "source": src, "debian_version": ver,
    "snapshot_timestamp": ts or None, "pool_path": pp or None,
    "allowed_sources": allowed.split(",") if allowed else [],
    "dsc": {"name": dn, "size": int(ds), "sha256": dsh},
    "artifacts": [{"name": n, "size": int(s), "sha256": h} for n, s, h in zip(an, asz, ash)],
    "provenance": {
        "lock_path": lp, "lock_sha256": lsh,
        "read_source_lock_path": "scripts/read-source-lock.py",
        "pyyaml_version": pyv,
        "fetched_at_utc": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "fetch_source_kind": "snapshot",
        "original_urls": [f"{base}/{dn}"],
        "verification": {"dscverify_version": dv, "dpkg_source_version": dsv,
                         "dscverify_keyrings": json.loads(krj)},
    },
}
with open(out, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=False)
    f.write("\n")
PY
  manifest_sha="$(_sha256 "${cache}/source-manifest.json")"
  {
    printf 'meta_format_version=1\n'
    printf 'bundle_format_version=1\n'
    printf 'source=%s\n' "${META_SOURCE}"
    printf 'debian_version=%s\n' "${META_DEBIAN_VERSION}"
    printf 'content_sha256=%s\n' "${content_sha}"
    printf 'manifest_sha256=%s\n' "${manifest_sha}"
    printf 'manifest_schema_version=1\n'
  } > "${cache}/cache.meta"
  printf '%s' "${cache}"   # echo cache dir for caller
}

# atomic_install <staging_cache_dir> <target_cache_dir>  — spec §3.8 idempotence.
atomic_install() {
  local src_cache="$1" target="$2"
  if [[ ! -d "${target}" ]]; then
    mkdir -p "$(dirname "${target}")"
    mv "${src_cache}" "${target}"
    log "installed cache: ${target}"
    return 0
  fi
  # target exists: fully verify it, then compare identity.
  read_cache_meta "${target}/cache.meta" \
    || die "existing cache ${target} is corrupt (bad cache.meta); refusing overwrite"
  ( cd "${target}" && verify_cache_meta_versions && verify_manifest_hash "${target}" \
      && sha256sum -c --status SHA256SUMS ) \
    || die "existing cache ${target} is corrupt (version/hash/SHA256SUMS); refusing overwrite"
  local dsc_name="${META_DSC_NAME}"
  validate_dsc_metadata "${target}/${dsc_name}" "${META_SOURCE}" "${META_DEBIAN_VERSION}" \
    || die "existing cache ${target} .dsc metadata mismatch; refusing overwrite"
  # identity: source/version/content_sha256
  local existing_content
  existing_content="$(read_cache_meta "${target}/cache.meta" >/dev/null 2>&1; printf '%s' "${CM_CONTENT_SHA256}")"
  local new_content; new_content="$(_sha256 "${src_cache}/SHA256SUMS")"
  if [[ "${existing_content}" == "${new_content}" ]]; then
    log "cache already present and identical: ${target} (idempotent)"
    rm -rf "${src_cache}"
    return 0
  fi
  die "cache ${target} exists with different content_sha256; refusing overwrite"
}

# make_bundle <cache_dir>  — spec §3.9: regular-file-only ustar, env -u TAR_OPTIONS.
make_bundle() {
  local cache="$1"
  mkdir -p "${BUNDLE_ROOT}"
  local bundle="${BUNDLE_ROOT}/${META_SOURCE}_${META_DEBIAN_VERSION}.source-cache.tar.zst"
  local arcbase="${META_SOURCE}/${META_DEBIAN_VERSION}"
  local -a arcpaths=( "${arcbase}/${META_DSC_NAME}" )
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do arcpaths+=( "${arcbase}/${ARTIFACT_NAME[${i}]}" ); done
  arcpaths+=( "${arcbase}/SHA256SUMS" "${arcbase}/source-manifest.json" "${arcbase}/cache.meta" )
  # tar run from the cache parent so member paths are <name>/<ver>/<file>.
  ( cd "$(dirname "${cache}")" && \
    env -u TAR_OPTIONS LC_ALL=C tar --create --format=ustar --zstd --no-recursion \
      --file "${bundle}" "${arcpaths[@]}" ) \
    || die "bundle creation failed (ustar limit? explicit fail, no auto-downgrade to GNU/PAX)"
  # sidecar
  printf '%s  %s\n' "$(_sha256 "${bundle}")" "$(basename "${bundle}")" > "${bundle}.sha256"
  log "bundle: ${bundle} (+ ${bundle}.sha256)"
}

main() {
  # Fail fast if the prefetch node is missing required commands. Spec
  # docs/superpowers/specs/2026-06-21-build-pipeline-dependency-check-design.md
  # Checked in main() (not at source top-level) so unit tests that source this
  # script for its functions are unaffected.
  require_cmds \
    dscverify:devscripts \
    dpkg-source:dpkg-dev \
    curl:curl \
    sha256sum:coreutils \
    gpg:gnupg

  local LOCK_YAML_LOCAL=""
  # 1. arg parse (--lock XOR --source/--debian-version)
  if [[ "$1" == "--lock" ]]; then
    [[ $# -eq 2 ]] || usage
    LOCK_YAML_LOCAL="$2"
  elif [[ "$1" == "--source" && "$3" == "--debian-version" ]]; then
    LOCK_YAML_LOCAL="source-lock/$2/$4.yaml"
  else
    usage
  fi
  LOCK_YAML="${LOCK_YAML_LOCAL}"
  # 2. snapshot ∈ allowed_sources: peek via parser.
  local allowed_check
  allowed_check="$(python3 "${SCRIPT_DIR}/read-source-lock.py" --lock "${LOCK_YAML}" \
    | awk -F'\t' '/^META/{print $4}' 2>/dev/null)" \
    || die "lock failed to parse: ${LOCK_YAML}"
  [[ ",${allowed_check}," == *",snapshot,"* ]] \
    || die "this lock does not authorize snapshot; use FETCH_SOURCE=pool on the builder"
  # 3. drift gate + read companion .lock.tsv (load_lock derives expect-version from yaml)
  load_lock "${LOCK_YAML}"
  # 4. provenance computed inside write_cache.
  [[ -n "${META_SNAPSHOT_TS}" ]] || die "snapshot_timestamp required for snapshot prefetch"
  local base_url="https://snapshot.debian.org/archive/debian/${META_SNAPSHOT_TS}/pool/${META_POOL_PATH:-main/o/ocserv}"
  # 5. download + strong verification into staging.
  local STAGING; STAGING="$(mktemp -d)"
  if ! run_strong_verification "${STAGING}" "${base_url}"; then
    rm -rf "${STAGING}"; exit 1
  fi
  # 7. assemble cache content.
  local staging_cache; staging_cache="$(write_cache "${STAGING}")"
  # 8. atomic install.
  local target="${CACHE_ROOT}/${META_SOURCE}/${META_DEBIAN_VERSION}"
  atomic_install "${staging_cache}" "${target}"
  # 9. bundle (from canonical target).
  make_bundle "${target}"
  rm -rf "${STAGING}"
  log "prefetch complete: ${META_SOURCE}/${META_DEBIAN_VERSION} from snapshot ${META_SNAPSHOT_TS}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
