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
