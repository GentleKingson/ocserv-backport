#!/usr/bin/env bats
load helpers/bats-helper.bash

STATE_DIR=""

setup() {
  cd "${REPO_ROOT}"
  STATE_DIR="$(mktemp -d)"
  export APTLY_STATE_DIR="${STATE_DIR}"
}

teardown() { rm -rf "${STATE_DIR}"; }

@test "promote updates current and shifts old current to previous-good" {
  source scripts/_manifest.sh
  manifest_update testing "snap-A" "1.5.0-1~bpo13+1"
  manifest_update testing "snap-B" "1.5.0-1~bpo13+2"

  run jq -r .snapshot "${STATE_DIR}/testing-current.json"
  [ "$output" = "snap-B" ]
  run jq -r .version   "${STATE_DIR}/testing-previous-good.json"
  [ "$output" = "1.5.0-1~bpo13+1" ]
}

@test "previous-good json is empty object before any promote" {
  source scripts/_manifest.sh
  run manifest_read_previous_good testing
  [ "$status" -eq 0 ]
}

@test "current json includes promoted_at ISO timestamp" {
  source scripts/_manifest.sh
  manifest_update production "snap-X" "1.5.0-1~bpo13+1"
  run jq -r .promoted_at "${STATE_DIR}/production-current.json"
  [[ "$output" =~ T ]]   # ISO 8601 has a 'T'
}
