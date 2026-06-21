#!/usr/bin/env bats
load helpers/bats-helper.bash

@test ".env.example has valid FETCH_SOURCE and no DEBIAN_SNAPSHOT_TIMESTAMP" {
  [[ -f "${REPO_ROOT}/.env.example" ]]
  grep -qE '^FETCH_SOURCE=(pool|cache)' "${REPO_ROOT}/.env.example"
  ! grep -q 'DEBIAN_SNAPSHOT_TIMESTAMP' "${REPO_ROOT}/.env.example"
}
