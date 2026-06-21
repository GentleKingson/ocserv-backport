#!/usr/bin/env bats
load helpers/bats-helper.bash

call_tsv() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/_lock_tsv.sh'; $*"
}

# A valid TSV fixture matching parser output schema.
VALID_TSV=$'META\tocserv\t1.5.0-1\tpool,snapshot\t20260101T000000Z\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2234\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t100\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

@test "read_lock_tsv: valid tsv fills globals + 3-way identity passes" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_TSV" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1; echo SRC=\$META_SOURCE VER=\$META_DEBIAN_VERSION"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SRC=ocserv VER=1.5.0-1"* ]]
}

@test "read_lock_tsv: dies when expect_version != META version" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_TSV" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 9.9.9-9"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies when META source != ocserv" {
  # Use a real tab in the pattern (bash ${var/\\t/x} matches literal backslash-t,
  # not a tab — so build the replacement with an actual TAB char).
  tmp="$(mktemp)"
  printf '%s\n' "$VALID_TSV" | sed $'s/^META\tocserv\t/META\totherpkg\t/' > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies on CRLF" {
  tmp="$(mktemp)"; printf '%s\r\n' "$VALID_TSV" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies on duplicate ARTIFACT name" {
  tmp="$(mktemp)"
  printf '%s\n%s\n' "$VALID_TSV" "$(printf '%s\n' "$VALID_TSV" | tail -1)" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies on META not first line" {
  tmp="$(mktemp)"
  { printf '%s\n' "$VALID_TSV" | tail -1; printf '%s\n' "$VALID_TSV" | head -1; } > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies on unknown record type" {
  tmp="$(mktemp)"; printf '%s\nBOGUS\tx\n' "$VALID_TSV" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "write_expected_sha256sums: dsc first, then artifacts in lock order" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_TSV" > "$tmp"
  out="$(mktemp)"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1 && write_expected_sha256sums '$out'; cat '$out'"
  rm -f "$tmp" "$out"
  [ "$status" -eq 0 ]
  # Line 1 = dsc, line 2 = first artifact
  [ "${lines[0]}" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ocserv_1.5.0-1.dsc" ]
  [ "${lines[1]}" == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  ocserv_1.5.0.orig.tar.xz" ]
}

# ---- read_lock_tsv full schema validation (review fix #3) ----
# These cover allowed_sources / binding / pool_path grammar / basename safety
# that the spec requires the TSV parser to mirror from the YAML schema.

# A valid pool-only TSV (sentinel for absent snapshot_timestamp/pool_path).
VALID_POOL_TSV=$'META\tocserv\t1.5.0-1\tpool\t-\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2234\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t100\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

@test "read_lock_tsv: rejects allowed_sources with unknown value" {
  tmp="$(mktemp)"
  printf '%s\n' "${VALID_TSV/pool,snapshot/pool,evil}" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects unsorted allowed_sources (snapshot,pool)" {
  tmp="$(mktemp)"
  printf '%s\n' "${VALID_TSV/pool,snapshot/snapshot,pool}" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects duplicate allowed_sources (pool,pool)" {
  tmp="$(mktemp)"
  printf '%s\n' "${VALID_POOL_TSV/pool/pool,pool}" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects snapshot_timestamp present but snapshot not allowed (pool-only)" {
  # VALID_POOL_TSV has pool-only but timestamp field is '-' (absent). Inject a real ts
  # using sed with a real tab (bash ${var/\\t/x} matches literal backslash-t, not a tab).
  tmp="$(mktemp)"
  printf '%s\n' "$VALID_POOL_TSV" | sed $'s/\tpool\t-\t/\tpool\t20260101T000000Z\t/' > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects pool_path present but pool not allowed (snapshot-only)" {
  tmp="$(mktemp)"
  # VALID_TSV is pool,snapshot — make a snapshot-only variant but keep pool_path.
  snap_only="${VALID_TSV/pool,snapshot/snapshot}"
  printf '%s\n' "$snap_only" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects pool_path with ../ segment" {
  tmp="$(mktemp)"
  printf '%s\n' "${VALID_POOL_TSV/main\/o\/ocserv/main\/..\/etc}" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects pool_path as full URL" {
  tmp="$(mktemp)"
  printf '%s\n' "${VALID_POOL_TSV/main\/o\/ocserv/https:\/\/evil.invalid\/x}" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects dsc.name not ending .dsc" {
  tmp="$(mktemp)"
  printf '%s\n' "${VALID_TSV/ocserv_1.5.0-1.dsc/ocserv_1.5.0-1.txt}" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects dsc.name containing slash" {
  tmp="$(mktemp)"
  printf '%s\n' "${VALID_TSV/ocserv_1.5.0-1.dsc/sub\/dir\/x.dsc}" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects artifact name with control char" {
  tmp="$(mktemp)"
  # Inject a tab into the artifact name (control char). Build via printf.
  printf 'META\tocserv\t1.5.0-1\tpool,snapshot\t20260101T000000Z\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2234\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nARTIFACT\tbad\tname\t100\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: rejects malformed snapshot_timestamp (8-digit time, not 6)" {
  tmp="$(mktemp)"
  # 20260101T00000000Z (8 digits) instead of 6.
  bad_ts="META	ocserv	1.5.0-1	pool,snapshot	20260101T00000000Z	main/o/ocserv	ocserv_1.5.0-1.dsc	2234	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ARTIFACT	ocserv_1.5.0.orig.tar.xz	100	bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  printf '%s\n' "$bad_ts" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"; rm -f "$tmp"; [ "$status" -ne 0 ]
}
