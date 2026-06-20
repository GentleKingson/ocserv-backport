#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }

# Source the script (SOURCE_GUARD prevents main from running) then call helpers.
call_func() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/fetch-source.sh'; $*"
}

# ---- is_509_failure (spec §3.3) ----

@test "is_509_failure: matches curl '(22) ... error: 509'" {
  call_func "is_509_failure \"dget: curl ocserv_1.5.0-1.dsc ... failed
curl: (22) The requested URL returned error: 509\""
  [ "$status" -eq 0 ]
}

@test "is_509_failure: matches 'HTTP Error 509'" {
  call_func "is_509_failure 'HTTP Error 509'"
  [ "$status" -eq 0 ]
}

@test "is_509_failure: matches 'HTTP/2 509'" {
  call_func "is_509_failure 'HTTP/2 509'"
  [ "$status" -eq 0 ]
}

@test "is_509_failure: does NOT match bare exit code 22 / 404 / 403" {
  call_func "is_509_failure 'curl: (22) The requested URL returned error: 404'"
  [ "$status" -ne 0 ]
  call_func "is_509_failure '403 Forbidden'"
  [ "$status" -ne 0 ]
  call_func "is_509_failure 'connection timed out'"
  [ "$status" -ne 0 ]
}
