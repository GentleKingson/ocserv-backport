#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/bin"
}

teardown() {
  rm -rf "${WORK}"
}

# Run one install.sh function in a fresh bash with the script sourced.
call() {
  run env PATH="${WORK}/bin:${PATH}" OCSERV_INSTALL_SOURCE_ONLY=1 \
    bash -c '. ./install.sh; "$@"' _ "$@"
}

os_release() {
  printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s"\n' "$1" "$2" "$3" \
    > "${WORK}/os-release"
}

stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "${WORK}/bin/$1"
  chmod +x "${WORK}/bin/$1"
}

sums() {
  printf '%s\n' \
    "aaaa  ocserv_2.0.0-1.debian13.3_amd64.deb" \
    "bbbb  ocserv_2.0.0-1.debian13.3_arm64.deb" \
    "cccc  ocserv_2.0.0-1.ubuntu24.04.3_amd64.deb" \
    "dddd *ocserv_2.0.0-1.ubuntu24.04.3_arm64.deb" \
    > "${WORK}/SHA256SUMS"
}

@test "install.sh is executable and passes bash syntax" {
  [ -x install.sh ]
  [ "$(git ls-files --stage install.sh | awk '{print $1}')" = 100755 ]
  bash -n install.sh
}

@test "install.sh runs main only on its last line" {
  # A truncated download through a pipe must not run anything.
  [ "$(tail -n 3 install.sh)" = "$(printf '%s\n' \
    'if [[ "${OCSERV_INSTALL_SOURCE_ONLY:-0}" != 1 ]]; then' \
    '  main "$@"' \
    'fi')" ]
}

@test "--help prints usage and exits 0" {
  run bash install.sh --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage: install.sh"* ]]
  [[ "${output}" == *"--release <tag>"* ]]
}

@test "unknown options and bad values are rejected" {
  run bash install.sh --bogus
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown option: --bogus"* ]]

  call parse_args --release
  [ "${status}" -ne 0 ]

  call parse_args --release 'x;rm'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid release tag"* ]]

  call parse_args --repo not-a-repo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid repository"* ]]
}

@test "options set release, repository and download-only" {
  run env OCSERV_INSTALL_SOURCE_ONLY=1 bash -c '
    . ./install.sh
    parse_args --release 2.0.0-3 --repo=me/fork --download-only
    printf "%s %s %s\n" "${OCSERV_RELEASE}" "${OCSERV_REPO}" "${OCSERV_DOWNLOAD_ONLY}"'
  [ "${status}" -eq 0 ]
  [ "${output}" = "2.0.0-3 me/fork 1" ]
}

@test "detect_distro maps Debian 13 and Ubuntu 24.04" {
  os_release debian 13 "Debian GNU/Linux 13 (trixie)"
  OS_RELEASE_FILE="${WORK}/os-release" call detect_distro
  [ "${status}" -eq 0 ]
  [ "${output}" = debian13 ]

  os_release ubuntu 24.04 "Ubuntu 24.04.3 LTS"
  OS_RELEASE_FILE="${WORK}/os-release" call detect_distro
  [ "${status}" -eq 0 ]
  [ "${output}" = ubuntu24.04 ]
}

@test "detect_distro rejects other systems" {
  local -a cases=(
    "debian|12|Debian GNU/Linux 12 (bookworm)"
    "ubuntu|22.04|Ubuntu 22.04.5 LTS"
    "ubuntu|24.10|Ubuntu 24.10"
    "linuxmint|22|Linux Mint 22"
  )
  local entry id version pretty
  for entry in "${cases[@]}"; do
    IFS='|' read -r id version pretty <<< "${entry}"
    os_release "${id}" "${version}" "${pretty}"
    OS_RELEASE_FILE="${WORK}/os-release" call detect_distro
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"unsupported system: ${pretty}"* ]]
  done

  OS_RELEASE_FILE="${WORK}/missing" call detect_distro
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot read"* ]]
}

@test "detect_arch accepts amd64 and arm64 only" {
  stub dpkg 'echo arm64'
  call detect_arch
  [ "${status}" -eq 0 ]
  [ "${output}" = arm64 ]

  stub dpkg 'echo armhf'
  call detect_arch
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unsupported architecture: armhf"* ]]
}

@test "select_asset picks the package for the distro and arch" {
  sums
  call select_asset "${WORK}/SHA256SUMS" debian13 arm64
  [ "${status}" -eq 0 ]
  [ "${output}" = ocserv_2.0.0-1.debian13.3_arm64.deb ]

  call select_asset "${WORK}/SHA256SUMS" ubuntu24.04 arm64
  [ "${status}" -eq 0 ]
  [ "${output}" = ocserv_2.0.0-1.ubuntu24.04.3_arm64.deb ]
}

@test "select_asset fails unless exactly one package matches" {
  sums
  echo "eeee  ocserv_2.0.0-1.debian13.4_amd64.deb" >> "${WORK}/SHA256SUMS"
  call select_asset "${WORK}/SHA256SUMS" debian13 amd64
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"found 2"* ]]

  call select_asset "${WORK}/SHA256SUMS" debian13 riscv64
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"found 0"* ]]
}

@test "resolve_release follows the latest release redirect" {
  stub curl 'echo -n "https://github.com/me/fork/releases/tag/2.0.0-3"'
  call resolve_release
  [ "${status}" -eq 0 ]
  [ "${output}" = 2.0.0-3 ]

  stub curl 'echo -n "https://github.com/me/fork/releases"'
  call resolve_release
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot find the latest release"* ]]

  stub curl 'exit 22'
  OCSERV_RELEASE=1.5.0-2 call resolve_release
  [ "${status}" -eq 0 ]
  [ "${output}" = 1.5.0-2 ]
}

@test "policy-rc.d blocks only ocserv and is removed afterwards" {
  run env OCSERV_INSTALL_SOURCE_ONLY=1 WORK="${WORK}" bash -c '
    . ./install.sh
    set +e
    POLICY_RC_D="${WORK}/policy-rc.d"
    WORK_DIR="${WORK}"
    block_service_start
    "${POLICY_RC_D}" ocserv start; echo "ocserv=$?"
    "${POLICY_RC_D}" ocserv.service start; echo "unit=$?"
    "${POLICY_RC_D}" dbus.service start; echo "dbus=$?"
    restore_service_start
    [[ -e "${POLICY_RC_D}" ]] && echo left || echo removed'
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf '%s\n' ocserv=101 unit=101 dbus=0 removed)" ]
}

@test "policy-rc.d delegates to and restores an existing policy" {
  printf '#!/bin/sh\nexit 104\n' > "${WORK}/policy-rc.d"
  chmod 0755 "${WORK}/policy-rc.d"
  run env OCSERV_INSTALL_SOURCE_ONLY=1 WORK="${WORK}" bash -c '
    . ./install.sh
    set +e
    POLICY_RC_D="${WORK}/policy-rc.d"
    mkdir "${WORK}/tmp"
    WORK_DIR="${WORK}/tmp"
    block_service_start
    "${POLICY_RC_D}" ocserv start; echo "ocserv=$?"
    "${POLICY_RC_D}" dbus.service start; echo "dbus=$?"
    restore_service_start
    cat "${POLICY_RC_D}"'
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf '%s\n' ocserv=101 dbus=104 '#!/bin/sh' 'exit 104')" ]
}

@test "install.sh never starts ocserv itself" {
  # Messages may mention "systemctl start"; commands may only enable or stop.
  run grep -Eo -- '^ *(if .*&& )?systemctl [a-z-]+' install.sh
  [ "${status}" -eq 0 ]
  ! grep -Ev -- 'systemctl (enable|stop|is-active)$' <<< "${output}"
  grep -Fqx -- '  systemctl enable ocserv.service' install.sh
  ! grep -Fq -- 'enable --now' install.sh
}

@test "README has the one-line installer command" {
  grep -Fq -- \
    'curl -fsSL https://raw.githubusercontent.com/GentleKingson/ocserv-backport/main/install.sh | sudo bash' \
    README.md
}

@test "install-script workflow lints and tests every supported target" {
  workflow=".github/workflows/install-script.yml"

  grep -Fq -- "- 'install.sh'" "${workflow}"
  grep -Fq -- "workflows: [release]" "${workflow}"
  grep -Fq -- "github.event.workflow_run.conclusion == 'success'" "${workflow}"
  grep -Fq -- "shellcheck -x install.sh scripts/install-e2e-test.sh" "${workflow}"
  grep -Fq -- "make install-test" "${workflow}"
  grep -Fq -- "- debian:trixie" "${workflow}"
  grep -Fq -- "- ubuntu:24.04" "${workflow}"
  grep -Fq -- "runner: ubuntu-24.04-arm" "${workflow}"
  grep -Fq -- 'scripts/install-e2e-test.sh "${IMAGE}"' "${workflow}"
  grep -Fq -- "readme-command:" "${workflow}"
  grep -Fq -- '[[ "${active}" == inactive ]]' "${workflow}"
  [ -x scripts/install-e2e-test.sh ]
}
