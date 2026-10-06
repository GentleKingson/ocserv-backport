#!/usr/bin/env bats
load helpers/bats-helper.bash

versions() {
  run env -i PATH="${PATH}" "$@" bash -c '
    set -euo pipefail
    . scripts/_versions.sh
    printf "%s\n" "${OCSERV_DEBIAN_VERSION}" "${OCSERV_UPSTREAM_VERSION}" "${OCSERV_VERSION}" \
      "${OCSERV_NOBLE_VERSION}"
  '
}

@test "_versions.sh defaults match the committed source locks" {
  versions
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "1.5.0-1" ]
  [ "${lines[1]}" = "1.5.0" ]
  [ "${lines[2]}" = "1.5.0-1~debian13.1" ]
  [ "${lines[3]}" = "1.5.0-1~ubuntu24.04.1" ]
  [ "${#lines[@]}" -eq 4 ]
  [ -f "source-lock/ocserv/${lines[0]}.yaml" ]
  [ ! -e source-lock/node-undici ]
}

@test "_versions.sh derives backport and upstream versions from the Debian version" {
  versions OCSERV_DEBIAN_VERSION=1.6.1-2
  [ "${status}" -eq 0 ]
  [ "${lines[1]}" = "1.6.1" ]
  [ "${lines[2]}" = "1.6.1-2~debian13.1" ]
  [ "${lines[3]}" = "1.6.1-2~ubuntu24.04.1" ]
}

@test "_versions.sh applies BACKPORT_REVISION to both backport versions" {
  versions BACKPORT_REVISION=2
  [ "${status}" -eq 0 ]
  [ "${lines[2]}" = "1.5.0-1~debian13.2" ]
  [ "${lines[3]}" = "1.5.0-1~ubuntu24.04.2" ]
}

@test "_versions.sh keeps explicit backport version overrides" {
  versions OCSERV_VERSION=1.5.0-1~bpo13+1 OCSERV_NOBLE_VERSION=1.5.0-1~ubuntu24.04.2
  [ "${status}" -eq 0 ]
  [ "${lines[2]}" = "1.5.0-1~bpo13+1" ]
  [ "${lines[3]}" = "1.5.0-1~ubuntu24.04.2" ]
}

@test "package version literals live only in scripts/_versions.sh" {
  local output
  output="$(
    grep -n -E '1\.5\.0' Makefile scripts/* \
      | grep -v '^scripts/_versions\.sh:' \
      | grep -v '^scripts/_fetch\.sh:.*snapshot\.debian\.org' \
      || true
  )"
  [ -z "${output}" ] || {
    printf '%s\n' "${output}" >&2
    return 1
  }
}
