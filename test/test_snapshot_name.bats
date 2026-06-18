#!/usr/bin/env bats
load helpers/bats-helper.bash

@test "CI env produces gh<N> suffix" {
  GITHUB_RUN_NUMBER=123 run scripts/snapshot-name.sh
  [ "$status" -eq 0 ]
  [ "$output" = "ocserv-1.5.0-1~bpo13+1-build-gh123" ]
}

@test "local env produces local-<timestamp> suffix" {
  unset GITHUB_RUN_NUMBER
  run scripts/snapshot-name.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^ocserv-1\.5\.0-1~bpo13\+1-build-local-[0-9]{8}T[0-9]{6}$ ]]
}
