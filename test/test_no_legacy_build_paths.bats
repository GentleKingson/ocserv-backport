#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
}

@test "production docs and workflows do not advertise legacy build paths" {
  local output

  output="$(
    grep -R -n -E \
      'build/(source|binary)(/|$)|build/noble(/|$)|build/debian/(\$\{TARGET_ARCH\}|amd64|arm64)/debian-keyrings' \
      scripts \
      .github/workflows \
      README.md \
      docs/build-ocserv-backport-on-debian13.md \
      docs/build-ocserv-backport-on-ubuntu24.04.md \
      2>/dev/null || true
  )"

  [ -z "${output}" ] || {
    printf '%s\n' "${output}" >&2
    return 1
  }
}
