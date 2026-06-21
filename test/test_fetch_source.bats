#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }

# Source the script (the BASH_SOURCE==$0 guard prevents main from running on
# source) then call helpers. Retained from pre-refactor: the helper unit tests
# (validate_dsc_metadata / validate_artifact_basenames) still work because
# fetch-source.sh sources _dsc.sh which defines them.
call_func() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/fetch-source.sh'; $*"
}

# ---- validate_dsc_metadata (retained; now via _dsc.sh) ----

@test "validate_dsc_metadata: accepts Source=ocserv Version=1.5.0-1" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Format: 3.0 (quilt)
Source: ocserv
Version: 1.5.0-1
DSC
  call_func "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -eq 0 ]
}

@test "validate_dsc_metadata: rejects wrong Source" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Source: otherpkg
Version: 1.5.0-1
DSC
  call_func "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "validate_dsc_metadata: rejects wrong Version" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Source: ocserv
Version: 1.4.0-1
DSC
  call_func "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

# ---- validate_artifact_basenames (retained; now via _dsc.sh) ----

@test "validate_artifact_basenames: accepts normal basenames" {
  call_func "validate_artifact_basenames 'ocserv_1.5.0.orig.tar.xz ocserv_1.5.0-1.debian.tar.xz'"
  [ "$status" -eq 0 ]
}

@test "validate_artifact_basenames: rejects path traversal (../)" {
  call_func "validate_artifact_basenames 'ocserv_1.5.0.orig.tar.xz ../../etc/passwd'"
  [ "$status" -ne 0 ]
}

@test "validate_artifact_basenames: rejects filename containing slash" {
  call_func "validate_artifact_basenames 'sub/dir/file.tar.xz'"
  [ "$status" -ne 0 ]
}

@test "validate_artifact_basenames: rejects empty and duplicates" {
  call_func "validate_artifact_basenames ''"
  [ "$status" -ne 0 ]
  call_func "validate_artifact_basenames 'a.tar a.tar'"
  [ "$status" -ne 0 ]
}

# ---- FETCH_SOURCE dispatch (new; spec §4) ----
# These execute the rewritten fetch-source.sh via a throwaway git repo so its
# REPO_ROOT/lock resolution lands inside the temp repo. scripts are COPIED
# (not symlinked) so SCRIPT_DIR resolves there.

setup_fetch_repo() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/source-lock/ocserv"
  for f in _common.sh _dsc.sh _lock_tsv.sh _cache_meta.sh fetch-source.sh; do
    cp "${REPO_ROOT}/scripts/$f" "$root/scripts/$f"   # copy not symlink (REPO_ROOT must resolve here)
  done
  git -C "$root" init -q
  git -C "$root" add -A && git -C "$root" -c user.email=t@t -c user.name=t commit -qm init
}

# write_lock <repo> <allowed_comma>  — yaml + committed .lock.tsv pair (matching projection).
write_lock() {
  local repo="$1" allowed="$2"
  local dsc_sha="0000000000000000000000000000000000000000000000000000000000000000"
  local art_sha="1111111111111111111111111111111111111111111111111111111111111111"
  {
    echo 'schema_version: 1'
    echo 'source: ocserv'
    echo 'debian_version: "1.5.0-1"'
    printf 'allowed_sources: [%s]\n' "$allowed"
    [[ ",$allowed," == *",snapshot,"* ]] && echo 'snapshot_timestamp: "20260101T000000Z"'
    [[ ",$allowed," == *",pool,"* ]] && echo 'pool_path: "main/o/ocserv"'
    printf 'dsc: {name: ocserv_1.5.0-1.dsc, size: 5, sha256: "%s"}\n' "$dsc_sha"
    printf 'artifacts: [{name: ocserv_1.5.0.orig.tar.xz, size: 3, sha256: "%s"}]\n' "$art_sha"
  } > "$repo/source-lock/ocserv/1.5.0-1.yaml"
  printf 'META\tocserv\t1.5.0-1\t%s\t' "$allowed" > "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  if [[ ",$allowed," == *",snapshot,"* ]]; then
    printf '20260101T000000Z\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  else
    printf -- '-\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  fi
  if [[ ",$allowed," == *",pool,"* ]]; then
    printf 'main/o/ocserv\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  else
    printf -- '-\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  fi
  printf 'ocserv_1.5.0-1.dsc\t5\t%s\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t3\t%s\n' "$dsc_sha" "$art_sha" >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
}

# seed_cache <repo> <shasums_kind>  — build/source-cache/ocserv/1.5.0-1/ with
# cache.meta + SHA256SUMS (kind: "match" or "drift") + a valid .dsc + artifact.
# The .dsc is a real Deb822 file (Files/Checksums-Sha256 reference the artifact
# with its real sha256+size) so dsc_artifacts_match_lock passes. The artifact is
# "abc" (3 bytes, sha256 ba7816bf...). The dsc's OWN sha256 is computed from its
# real content; the lock in write_lock_realhash must declare the same value, so
# the two are kept in sync by re-deriving dsc_sha here and using it in BOTH the
# cache SHA256SUMS and (via write_lock_realhash's identical .dsc) the lock.
seed_cache() {
  local repo="$1" kind="$2"
  local cdir="$repo/build/source-cache/ocserv/1.5.0-1"; mkdir -p "$cdir"
  local art_sha="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"   # sha256("abc")
  printf 'abc' > "$cdir/ocserv_1.5.0.orig.tar.xz"
  cat > "$cdir/ocserv_1.5.0-1.dsc" <<DSC
Format: 3.0 (quilt)
Source: ocserv
Version: 1.5.0-1
Files:
 1111 3 ocserv_1.5.0.orig.tar.xz
Checksums-Sha256:
 $art_sha 3 ocserv_1.5.0.orig.tar.xz
DSC
  local dsc_sha; dsc_sha="$(sha256sum "$cdir/ocserv_1.5.0-1.dsc" | awk '{print $1}')"
  if [[ "$kind" == "drift" ]]; then
    printf 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  ocserv_1.5.0-1.dsc\n' > "$cdir/SHA256SUMS"
  else
    printf '%s  ocserv_1.5.0-1.dsc\n%s  ocserv_1.5.0.orig.tar.xz\n' "$dsc_sha" "$art_sha" > "$cdir/SHA256SUMS"
  fi
  printf '{}' > "$cdir/source-manifest.json"
  local manifest_sha content_sha
  manifest_sha="$(sha256sum "$cdir/source-manifest.json" | awk '{print $1}')"
  content_sha="$(sha256sum "$cdir/SHA256SUMS" | awk '{print $1}')"
  printf 'meta_format_version=1\nbundle_format_version=1\nsource=ocserv\ndebian_version=1.5.0-1\ncontent_sha256=%s\nmanifest_sha256=%s\nmanifest_schema_version=1\n' \
    "$content_sha" "$manifest_sha" > "$cdir/cache.meta"
}

# write_lock_realhash <repo> <allowed_comma> — like write_lock but with REAL
# hashes that match seed_cache's deterministic .dsc (816688ee...) + "abc"
# artifact (ba7816bf...). Used by cache-mode tests so the lock identity-matches
# a "match" cache (both derive the same expected-SHA256SUMS).
write_lock_realhash() {
  local repo="$1" allowed="$2"
  local dsc_sha="816688ee5e9a2a5b716ff1185b3153a33792dd3956a56192e6d118f95ace6be3"
  local art_sha="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  local dsc_size=203   # size of the deterministic .dsc seed_cache/test-12 emit
  local art_size=3     # size of "abc"
  {
    echo 'schema_version: 1'
    echo 'source: ocserv'
    echo 'debian_version: "1.5.0-1"'
    printf 'allowed_sources: [%s]\n' "$allowed"
    [[ ",$allowed," == *",snapshot,"* ]] && echo 'snapshot_timestamp: "20260101T000000Z"'
    [[ ",$allowed," == *",pool,"* ]] && echo 'pool_path: "main/o/ocserv"'
    printf 'dsc: {name: ocserv_1.5.0-1.dsc, size: %s, sha256: "%s"}\n' "$dsc_size" "$dsc_sha"
    printf 'artifacts: [{name: ocserv_1.5.0.orig.tar.xz, size: %s, sha256: "%s"}]\n' "$art_size" "$art_sha"
  } > "$repo/source-lock/ocserv/1.5.0-1.yaml"
  printf 'META\tocserv\t1.5.0-1\t%s\t' "$allowed" > "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  if [[ ",$allowed," == *",snapshot,"* ]]; then printf '20260101T000000Z\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  else printf -- '-\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"; fi
  if [[ ",$allowed," == *",pool,"* ]]; then printf 'main/o/ocserv\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  else printf -- '-\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"; fi
  printf 'ocserv_1.5.0-1.dsc\t%s\t%s\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t%s\t%s\n' "$dsc_size" "$dsc_sha" "$art_size" "$art_sha" >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
}

@test "FETCH_SOURCE: unknown value → die" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock "$repo" "pool"
  run bash -c "cd '$repo' && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 FETCH_SOURCE=bogus bash '$repo/scripts/fetch-source.sh'"
  rm -rf "$repo"
  [ "$status" -ne 0 ]
}

@test "FETCH_SOURCE=pool: pool not in allowed_sources → zero-network fail" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock "$repo" "snapshot"
  fakebin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho HIT >> "%s/net"\nexit 7\n' "$repo" > "$fakebin/curl"
  chmod +x "$fakebin/curl"
  run bash -c "cd '$repo' && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 FETCH_SOURCE=pool PATH='$fakebin:$PATH' bash '$repo/scripts/fetch-source.sh'"
  net="no"; [[ -f "$repo/net" ]] && net="yes"
  rm -rf "$repo" "$fakebin"
  [ "$status" -ne 0 ]
  [ "$net" == "no" ]
}

@test "FETCH_SOURCE=cache: identity closure (SHA256SUMS drift) → die, no publish" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock_realhash "$repo" "pool,snapshot"
  seed_cache "$repo" drift
  run bash -c "cd '$repo' && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 FETCH_SOURCE=cache bash '$repo/scripts/fetch-source.sh'"
  published=$([ -d "$repo/build/source/ocserv-1.5.0" ] && echo yes || echo no)
  rm -rf "$repo"
  [ "$status" -ne 0 ]
  [ "$published" == "no" ]
}

@test "FETCH_SOURCE=cache: zero network → publish from cache" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock_realhash "$repo" "pool,snapshot"
  seed_cache "$repo" match
  fakebin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho HIT >> "%s/net"\nexit 7\n' "$repo" > "$fakebin/curl"
  # dpkg-source -x <dsc> <outdir>: create outdir + orig tarball siblings.
  cat > "$fakebin/dpkg-source" <<SH
#!/usr/bin/env bash
out="\${@: -1: 1}"
mkdir -p "\$out"; echo "from-cache" > "\$out/configure.ac"
: > "\$(dirname "\$out")/ocserv_1.5.0.orig.tar.xz"
: > "\$(dirname "\$out")/ocserv_1.5.0.orig.tar.xz.asc"
SH
  chmod +x "$fakebin/curl" "$fakebin/dpkg-source"
  run bash -c "cd '$repo' && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 FETCH_SOURCE=cache PATH='$fakebin:$PATH' bash '$repo/scripts/fetch-source.sh'"
  net="no"; [[ -f "$repo/net" ]] && net="yes"
  published=$([ -d "$repo/build/source/ocserv-1.5.0" ] && echo yes || echo no)
  if [[ "$status" -ne 0 ]]; then rm -rf "$repo" "$fakebin"; fail "cache fetch failed (status=$status output=$output)"; fi
  [ "$net" == "no" ]
  [ "$published" == "yes" ]
}

@test "FETCH_SOURCE=pool: success → publish (stub curl + dscverify + dpkg-source)" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock_realhash "$repo" "pool,snapshot"
  fakebin="$(mktemp -d)"
  # curl serves: the deterministic .dsc (whose sha256 matches the lock) + "abc"
  # artifact (whose sha256 ba7816bf... matches the lock). The .dsc content here
  # must be byte-identical to seed_cache's .dsc so its hash is 816688ee...
  art_sha="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  dsc_content='Format: 3.0 (quilt)
Source: ocserv
Version: 1.5.0-1
Files:
 1111 3 ocserv_1.5.0.orig.tar.xz
Checksums-Sha256:
 '"$art_sha"' 3 ocserv_1.5.0.orig.tar.xz
'
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
dest=""; prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--output" ]]; then dest="\$a"; fi
  prev="\$a"
done
case "\$dest" in
  *.dsc) printf '%s' '$dsc_content' > "\$dest" ;;
  *.tar.xz) printf 'abc' > "\$dest" ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/dscverify"
  cat > "$fakebin/dpkg-source" <<SH
#!/usr/bin/env bash
out="\${@: -1: 1}"
mkdir -p "\$out"; echo "from-pool" > "\$out/configure.ac"
: > "\$(dirname "\$out")/ocserv_1.5.0.orig.tar.xz"
: > "\$(dirname "\$out")/ocserv_1.5.0.orig.tar.xz.asc"
SH
  chmod +x "$fakebin/curl" "$fakebin/dscverify" "$fakebin/dpkg-source"
  run bash -c "cd '$repo' && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 FETCH_SOURCE=pool PATH='$fakebin:$PATH' bash '$repo/scripts/fetch-source.sh'"
  published=$([ -d "$repo/build/source/ocserv-1.5.0" ] && echo yes || echo no)
  rm -rf "$repo" "$fakebin"
  [ "$status" -eq 0 ]
  [ "$published" == "yes" ]
}
