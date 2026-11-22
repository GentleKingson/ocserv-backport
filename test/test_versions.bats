#!/usr/bin/env bats
load helpers/bats-helper.bash

versions() {
  run env -i PATH="${PATH}" "$@" bash -c '
    set -euo pipefail
    . scripts/_versions.sh
    printf "%s\n" "${OCSERV_DEBIAN_VERSION}" "${OCSERV_UPSTREAM_VERSION}" "${OCSERV_VERSION}" \
      "${OCSERV_NOBLE_VERSION}" "${OCSERV_RESOLUTE_VERSION}" "${OCSERV_PACKAGING_VERSION}"
  '
}

@test "_versions.sh defaults match the committed source locks" {
  versions
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "1.6.0-3" ]
  [ "${lines[1]}" = "1.6.0" ]
  [ "${lines[2]}" = "1.6.0-3~debian13.1" ]
  [ "${lines[3]}" = "1.6.0-3~ubuntu24.04.1" ]
  [ "${lines[4]}" = "1.6.0-3~ubuntu26.04.1" ]
  [ "${lines[5]}" = "1.6.0-3" ]
  [ "${#lines[@]}" -eq 6 ]
  [ -f "source-lock/ocserv/${lines[5]}.yaml" ]
  [ -f "source-lock/ocserv/${lines[5]}.lock.tsv" ]
  [ ! -e source-lock/node-undici ]
}

@test "_versions.sh defaults upgrade prior backports and sort below official 1.6.0-3" {
  versions
  [ "${status}" -eq 0 ]
  dpkg --compare-versions 1.6.0-0local1~debian13.1 lt "${lines[2]}"
  dpkg --compare-versions 1.6.0-0local1~ubuntu24.04.1 lt "${lines[3]}"
  dpkg --compare-versions "${lines[3]}" lt "${lines[4]}"
  dpkg --compare-versions "${lines[2]}" lt 1.6.0-3
  dpkg --compare-versions "${lines[3]}" lt 1.6.0-3
  dpkg --compare-versions "${lines[4]}" lt 1.6.0-3
}

@test "_versions.sh derives backport and upstream versions from the Debian version" {
  versions OCSERV_DEBIAN_VERSION=1.6.1-2
  [ "${status}" -eq 0 ]
  [ "${lines[1]}" = "1.6.1" ]
  [ "${lines[2]}" = "1.6.1-2~debian13.1" ]
  [ "${lines[3]}" = "1.6.1-2~ubuntu24.04.1" ]
  [ "${lines[4]}" = "1.6.1-2~ubuntu26.04.1" ]
}

@test "_versions.sh applies BACKPORT_REVISION to all backport versions" {
  versions BACKPORT_REVISION=3
  [ "${status}" -eq 0 ]
  [ "${lines[2]}" = "1.6.0-3~debian13.3" ]
  [ "${lines[3]}" = "1.6.0-3~ubuntu24.04.3" ]
  [ "${lines[4]}" = "1.6.0-3~ubuntu26.04.3" ]
}

@test "_versions.sh keeps explicit backport version overrides" {
  versions OCSERV_VERSION=1.5.0-1~bpo13+1 OCSERV_NOBLE_VERSION=1.5.0-1~ubuntu24.04.9 \
    OCSERV_RESOLUTE_VERSION=1.5.0-1~ubuntu26.04.9
  [ "${status}" -eq 0 ]
  [ "${lines[2]}" = "1.5.0-1~bpo13+1" ]
  [ "${lines[3]}" = "1.5.0-1~ubuntu24.04.9" ]
  [ "${lines[4]}" = "1.5.0-1~ubuntu26.04.9" ]
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
