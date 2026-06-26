#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  AUTO_REPO="$(mktemp -d)"
  FAKEBIN="$(mktemp -d)"
  mkdir -p "${AUTO_REPO}/scripts"
  cp "${REPO_ROOT}/scripts/_common.sh" "${AUTO_REPO}/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/_dscverify.sh" "${AUTO_REPO}/scripts/_dscverify.sh"
  if [[ -f "${REPO_ROOT}/scripts/noble-auto-build.sh" ]]; then
    cp "${REPO_ROOT}/scripts/noble-auto-build.sh" "${AUTO_REPO}/scripts/noble-auto-build.sh"
  fi
}

teardown() {
  [[ -n "${AUTO_REPO:-}" ]] && rm -rf "${AUTO_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
}

write_os_release() {
  cat > "${AUTO_REPO}/os-release" <<EOF
ID=$1
VERSION_CODENAME=$2
UBUNTU_CODENAME=$2
EOF
}

install_minimal_valid_fakebin() {
  local cmd
  ln -s /bin/bash "${FAKEBIN}/bash"
  ln -s /usr/bin/basename "${FAKEBIN}/basename"
  ln -s /usr/bin/dirname "${FAKEBIN}/dirname"
  ln -s /bin/date "${FAKEBIN}/date"
  for cmd in git curl gpg dpkg-buildpackage dscverify dpkg-source sbuild schroot debootstrap lintian bats shellcheck docker dpkg make sleep sudo apt-get systemctl sbuild-adduser sbuild-createchroot newgrp; do
    cat > "${FAKEBIN}/${cmd}" <<'SH'
#!/usr/bin/env bash
case "$(basename "$0")" in
  dpkg) echo amd64 ;;
  sbuild) echo "noble-amd64" ;;
  schroot) echo "chroot:noble-amd64" ;;
  docker)
    case "${1:-}" in
      info) exit 0 ;;
      pull) echo "unexpected docker pull: $*" >&2; exit 99 ;;
      *) exit 0 ;;
    esac
    ;;
  make)
    printf '%s\n' "$*" > make-calls
    mkdir -p build/noble/amd64/binary/node-undici build/noble/amd64/binary/ocserv build/noble/amd64/repo
    touch build/noble/amd64/binary/node-undici/libllhttp9.2_fake_amd64.deb
    touch build/noble/amd64/binary/node-undici/libllhttp-dev_fake_amd64.deb
    touch build/noble/amd64/binary/ocserv/ocserv_fake_amd64.deb
    touch build/noble/amd64/repo/Packages
    ;;
  sudo|apt-get|systemctl|sbuild-adduser|sbuild-createchroot|newgrp)
    echo "unexpected host command: $(basename "$0") $*" >&2
    exit 99
    ;;
esac
SH
    chmod +x "${FAKEBIN}/${cmd}"
  done
  cat > "${FAKEBIN}/id" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -u) echo 1000 ;;
  -nG) echo "users sbuild" ;;
  *) /usr/bin/id "$@" ;;
esac
SH
  cat > "${FAKEBIN}/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then exit 0; fi
exit 0
SH
  chmod +x "${FAKEBIN}/id" "${FAKEBIN}/python3"
}

allow_fake_provision_commands() {
  cat > "${FAKEBIN}/sudo" <<SH
#!/usr/bin/env bash
printf 'sudo %s\n' "\$*" >> "${AUTO_REPO}/sudo-calls"
"\$@"
SH
  cat > "${FAKEBIN}/apt-get" <<SH
#!/usr/bin/env bash
printf 'apt-get %s\n' "\$*" >> "${AUTO_REPO}/apt-get-calls"
case "\${1:-}" in
  update)
    exit 0
    ;;
  install)
    : > "\${DSCVERIFY_KEYRING_PATHS%%:*}"
    exit 0
    ;;
  *)
    echo "unexpected apt-get command: \$*" >&2
    exit 99
    ;;
esac
SH
  chmod +x "${FAKEBIN}/sudo" "${FAKEBIN}/apt-get"
}

run_auto() {
  # shellcheck disable=SC2016
  run env "PATH=${FAKEBIN}:${PATH}" "NOBLE_AUTO_BUILD_OS_RELEASE_PATH=${AUTO_REPO}/os-release" \
    bash -c 'cd "$1" || exit; shift; bash scripts/noble-auto-build.sh "$@"' _ "${AUTO_REPO}" "$@"
}

run_auto_isolated() {
  local env_args=(
    "PATH=${FAKEBIN}"
    "NOBLE_AUTO_BUILD_OS_RELEASE_PATH=${AUTO_REPO}/os-release"
  )
  if [[ "${DSCVERIFY_KEYRING_PATHS+x}" == x ]]; then
    env_args+=("DSCVERIFY_KEYRING_PATHS=${DSCVERIFY_KEYRING_PATHS}")
  fi

  # shellcheck disable=SC2016
  run env "${env_args[@]}" /bin/bash -c 'cd "$1" || exit; shift; /bin/bash scripts/noble-auto-build.sh "$@"' _ "${AUTO_REPO}" "$@"
}

@test "noble-auto-build --help prints usage" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  run_auto --help
  [ "${status}" -eq 0 ]
  grep -Fq -- "Usage: scripts/noble-auto-build.sh [--provision]" <<<"${output}"
}

@test "noble-auto-build rejects unknown options" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  run_auto --bad-option
  [ "${status}" -ne 0 ]
  grep -Fq -- "Usage: scripts/noble-auto-build.sh [--provision]" <<<"${output}"
  [[ "${output}" == *"unknown option: --bad-option"* ]]

  run_auto -x
  [ "${status}" -ne 0 ]
  grep -Fq -- "Usage: scripts/noble-auto-build.sh [--provision]" <<<"${output}"
  [[ "${output}" == *"unknown option: -x"* ]]
}

@test "noble-auto-build rejects non-Noble hosts" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  run_auto
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"requires Ubuntu 24.04 Noble"* ]]
}

@test "noble-auto-build rejects unsupported TARGET_ARCH" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  run bash -c "cd '${AUTO_REPO}' && TARGET_ARCH=riscv64 PATH='${FAKEBIN}:${PATH}' NOBLE_AUTO_BUILD_OS_RELEASE_PATH='${AUTO_REPO}/os-release' bash scripts/noble-auto-build.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unsupported TARGET_ARCH=riscv64"* ]]
  [[ "${output}" == *"amd64, arm64"* ]]
}

@test "noble-auto-build default mode reports missing core command without sudo side effects" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  rm "${FAKEBIN}/curl"
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing required command: curl"* ]]
  [[ "${output}" == *"sudo apt-get install -y --no-install-recommends"* ]]
  [[ "${output}" == *"curl"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/apt-get-calls" ]
}

@test "noble-auto-build --provision installs core packages and re-checks keyring" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  keyring="${AUTO_REPO}/provisioned-debian-keyring.gpg"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated --provision

  [ "${status}" -eq 0 ]
  grep -Fq -- "apt-get update" "${AUTO_REPO}/apt-get-calls"
  install_call="$(grep -F -- "apt-get install" "${AUTO_REPO}/apt-get-calls")"
  for package in git ca-certificates curl gnupg build-essential fakeroot devscripts dpkg-dev debian-archive-keyring debian-keyring debian-maintainers sbuild schroot debootstrap lintian python3 python3-yaml bats shellcheck; do
    [[ "${install_call}" == *" ${package}"* || "${install_call}" == *" ${package} "* ]]
  done
  grep -Fq -- "sudo apt-get update" "${AUTO_REPO}/sudo-calls"
  [[ "${output}" == *"using Debian dscverify keyring: ${keyring}"* ]]
  [ -r "${keyring}" ]
}

@test "noble-auto-build default mode fails when no Debian keyring is readable" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin

  DSCVERIFY_KEYRING_PATHS="${AUTO_REPO}/missing-one.gpg:${AUTO_REPO}/missing-two.gpg" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no readable Debian dscverify keyrings"* ]]
  [[ "${output}" == *"debian-keyring"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/apt-get-calls" ]
}
