#!/usr/bin/env bats
load helpers/bats-helper.bash

SCRIPT="ansible/roles/ocserv_backport/files/assert-apt-policy.sh"

@test "passes on good fixture (candidate=THEHKUS-Backports, prio 1001)" {
  run bash "${SCRIPT}" \
    --package ocserv --expected-version 1.5.0-1~bpo13+1 \
    --expected-origin THEHKUS-Backports --expected-suite trixie-production \
    --expected-priority 1001 \
    --input test/fixtures/apt-policy/good.txt
  [ "$status" -eq 0 ]
}

@test "fails when candidate is from Debian official" {
  run bash "${SCRIPT}" \
    --package ocserv --expected-version 1.5.0-1~bpo13+1 \
    --expected-origin THEHKUS-Backports --expected-suite trixie-production \
    --expected-priority 1001 \
    --input test/fixtures/apt-policy/bad-origin.txt
  [ "$status" -ne 0 ]
}
