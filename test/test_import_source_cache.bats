#!/usr/bin/env bats
load helpers/bats-helper.bash

# The bundle create + tar --list --verbose prescan in import-source-cache.sh
# requires GNU tar semantics (ustar format, GNU verbose column layout,
# --no-recursion). macOS ships bsdtar which differs. Skip the bundle-dependent
# tests unless GNU tar is the active `tar` (Linux builder) or `gtar` exists.
have_gnu_tar() {
  if tar --version 2>/dev/null | grep -qi 'gnu tar'; then return 0; fi
  command -v gtar >/dev/null 2>&1 && return 0
  return 1
}

setup_import_repo() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/source-lock/ocserv"
  for f in _common.sh _dsc.sh _lock_tsv.sh _cache_meta.sh import-source-cache.sh; do
    cp "${REPO_ROOT}/scripts/$f" "$root/scripts/$f"   # copy not symlink (REPO_ROOT must resolve here)
  done
  git -C "$root" init -q
  git -C "$root" add -A && git -C "$root" -c user.email=t@t -c user.name=t commit -qm init
}

# write_lock <repo_root>  — writes a consistent yaml + committed .lock.tsv pair
# (matching projection) into <repo>/source-lock/ocserv/1.5.0-1.{yaml,lock.tsv}.
write_lock() {
  local repo="$1"
  local dsc_sha="0000000000000000000000000000000000000000000000000000000000000000"
  local art_sha="1111111111111111111111111111111111111111111111111111111111111111"
  cat > "$repo/source-lock/ocserv/1.5.0-1.yaml" <<YAML
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [snapshot, pool]
snapshot_timestamp: "20260101T000000Z"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 5, sha256: "$dsc_sha"}
artifacts: [{name: ocserv_1.5.0.orig.tar.xz, size: 3, sha256: "$art_sha"}]
YAML
  printf 'META\tocserv\t1.5.0-1\tpool,snapshot\t20260101T000000Z\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t5\t%s\n' "$dsc_sha" > "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  printf 'ARTIFACT\tocserv_1.5.0.orig.tar.xz\t3\t%s\n' "$art_sha" >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
}

# build_bundle <repo_root> <bundle_out> <content_kind>
# content_kind: "valid" | "bad_shasums" | "symlink_member"
build_bundle() {
  local repo="$1" bundle="$2" kind="$3"
  local srcdir="$repo/.bundle-src"; rm -rf "$srcdir"; mkdir -p "$srcdir/ocserv/1.5.0-1"
  local cdir="$srcdir/ocserv/1.5.0-1"
  local dsc_sha="0000000000000000000000000000000000000000000000000000000000000000"
  local art_sha="1111111111111111111111111111111111111111111111111111111111111111"
  printf 'hello' > "$cdir/ocserv_1.5.0-1.dsc"   # 5 bytes
  printf 'abc'   > "$cdir/ocserv_1.5.0.orig.tar.xz"   # 3 bytes
  if [[ "$kind" == "bad_shasums" ]]; then
    printf '%s  %s\n' "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "ocserv_1.5.0-1.dsc" > "$cdir/SHA256SUMS"
  else
    printf '%s  %s\n%s  %s\n' "$dsc_sha" "ocserv_1.5.0-1.dsc" "$art_sha" "ocserv_1.5.0.orig.tar.xz" > "$cdir/SHA256SUMS"
  fi
  printf '{}' > "$cdir/source-manifest.json"
  local manifest_sha content_sha
  manifest_sha="$(sha256sum "$cdir/source-manifest.json" | awk '{print $1}')"
  content_sha="$(sha256sum "$cdir/SHA256SUMS" | awk '{print $1}')"
  printf 'meta_format_version=1\nbundle_format_version=1\nsource=ocserv\ndebian_version=1.5.0-1\ncontent_sha256=%s\nmanifest_sha256=%s\nmanifest_schema_version=1\n' \
    "$content_sha" "$manifest_sha" > "$cdir/cache.meta"
  local -a members=( "ocserv/1.5.0-1/ocserv_1.5.0-1.dsc" "ocserv/1.5.0-1/ocserv_1.5.0.orig.tar.xz" \
                     "ocserv/1.5.0-1/SHA256SUMS" "ocserv/1.5.0-1/source-manifest.json" "ocserv/1.5.0-1/cache.meta" )
  if [[ "$kind" == "symlink_member" ]]; then
    ( cd "$srcdir" && ln -s ocserv_1.5.0-1.dsc ocserv/1.5.0-1/evil && \
      env -u TAR_OPTIONS LC_ALL=C tar --create --format=ustar --zstd --no-recursion \
        --file "$bundle" "${members[@]}" "ocserv/1.5.0-1/evil" )
  else
    ( cd "$srcdir" && env -u TAR_OPTIONS LC_ALL=C tar --create --format=ustar --zstd --no-recursion \
        --file "$bundle" "${members[@]}" )
  fi
  printf '%s  %s\n' "$(sha256sum "$bundle" | awk '{print $1}')" "$(basename "$bundle")" > "$bundle.sha256"
  rm -rf "$srcdir"
}

@test "import: rejects --expected-sha256 wrong format" {
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/in.tar.zst"; printf 'x' > "$bun"
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' --expected-sha256 nothex '$bun'"
  rm -rf "$repo"
  [ "$status" -ne 0 ]
}

@test "import: sidecar multi-line → die" {
  have_gnu_tar || skip "GNU tar required for bundle ops (bsdtar on macOS differs)"
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" valid
  printf 'aaaa  %s\nbbbb  other\n' "$(basename "$bun")" > "$bun.sha256"
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' '$bun'"
  rm -rf "$repo"
  [ "$status" -ne 0 ]
}

@test "import: tar symlink member → die (prescan)" {
  have_gnu_tar || skip "GNU tar required for bundle ops (bsdtar on macOS differs)"
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" symlink_member
  # Recompute sidecar (bundle changed)
  printf '%s  %s\n' "$(sha256sum "$bun" | awk '{print $1}')" "$(basename "$bun")" > "$bun.sha256"
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' '$bun'"
  rm -rf "$repo"
  [ "$status" -ne 0 ]
}

@test "import: cache vs lock SHA256SUMS mismatch → die (identity closure)" {
  have_gnu_tar || skip "GNU tar required for bundle ops (bsdtar on macOS differs)"
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" bad_shasums
  printf '%s  %s\n' "$(sha256sum "$bun" | awk '{print $1}')" "$(basename "$bun")" > "$bun.sha256"
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' '$bun'"
  rm -rf "$repo"
  [ "$status" -ne 0 ]
}

@test "import: valid bundle → atomic install to build/source-cache" {
  have_gnu_tar || skip "GNU tar required for bundle ops (bsdtar on macOS differs)"
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" valid
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' '$bun'"
  if [[ "$status" -ne 0 ]]; then rm -rf "$repo"; fail "valid import failed (status=$status, output=$output)"; fi
  [ -d "$repo/build/source-cache/ocserv/1.5.0-1" ]
  [ -f "$repo/build/source-cache/ocserv/1.5.0-1/cache.meta" ]
  rm -rf "$repo"
}

@test "import: zero network / zero Python (valid import)" {
  have_gnu_tar || skip "GNU tar required for bundle ops (bsdtar on macOS differs)"
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" valid
  fakebin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho HIT >> "%s/net_hit"\nexit 7\n' "$repo" > "$fakebin/curl"
  printf '#!/usr/bin/env bash\necho HIT >> "%s/py_hit"\nexit 7\n' "$repo" > "$fakebin/python3"
  chmod +x "$fakebin/curl" "$fakebin/python3"
  ( cd "$repo" && PATH="$fakebin:$PATH" bash "$repo/scripts/import-source-cache.sh" "$bun" ) >/dev/null 2>&1 || true
  net_hit="no"; py_hit="no"
  [[ -f "$repo/net_hit" ]] && net_hit="yes"
  [[ -f "$repo/py_hit" ]] && py_hit="yes"
  rm -rf "$repo" "$fakebin"
  [ "$net_hit" == "no" ]
  [ "$py_hit" == "no" ]
}
