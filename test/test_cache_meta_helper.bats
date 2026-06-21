#!/usr/bin/env bats
load helpers/bats-helper.bash

call_cm() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/_cache_meta.sh'; $*"
}

VALID_META=$'meta_format_version=1\nbundle_format_version=1\nsource=ocserv\ndebian_version=1.5.0-1\ncontent_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nmanifest_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nmanifest_schema_version=1'

@test "read_cache_meta: valid meta fills globals" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_META" > "$tmp"
  call_cm "read_cache_meta '$tmp'; echo \$CM_SOURCE \$CM_DEBIAN_VERSION \$CM_META_FORMAT_VERSION"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ocserv 1.5.0-1 1"* ]]
}

@test "read_cache_meta: dies on duplicate field" {
  tmp="$(mktemp)"; printf '%s\n%s\n' "$VALID_META" "source=evil" > "$tmp"
  call_cm "read_cache_meta '$tmp'"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_cache_meta: dies on unknown field" {
  tmp="$(mktemp)"; printf '%s\n%s\n' "$VALID_META" "bogus=1" > "$tmp"
  call_cm "read_cache_meta '$tmp'"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_cache_meta: dies on epoch in version" {
  tmp="$(mktemp)"; printf '%s\n' "${VALID_META/debian_version=1.5.0-1/debian_version=1:1.5.0-1}" > "$tmp"
  call_cm "read_cache_meta '$tmp'"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "verify_cache_meta_versions: dies when bundle_format_version != 1" {
  tmp="$(mktemp)"; printf '%s\n' "${VALID_META/bundle_format_version=1/bundle_format_version=2}" > "$tmp"
  call_cm "read_cache_meta '$tmp' && verify_cache_meta_versions"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "verify_cache_meta_versions: passes when all == 1" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_META" > "$tmp"
  call_cm "read_cache_meta '$tmp' && verify_cache_meta_versions"; rm -f "$tmp"; [ "$status" -eq 0 ]
}

@test "verify_manifest_hash: dies on mismatch" {
  tmpd="$(mktemp -d)"; printf '%s\n' "$VALID_META" > "$tmpd/cache.meta"
  echo "{}" > "$tmpd/source-manifest.json"
  call_cm "read_cache_meta '$tmpd/cache.meta' && verify_manifest_hash '$tmpd'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}
