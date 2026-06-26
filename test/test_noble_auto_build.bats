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
  for cmd in git curl gpg dpkg-buildpackage dscverify dpkg-source sbuild schroot debootstrap lintian bats shellcheck docker dpkg dpkg-query make sleep sudo apt-get systemctl sbuild-adduser sbuild-createchroot newgrp; do
    cat > "${FAKEBIN}/${cmd}" <<'SH'
#!/usr/bin/env bash
case "$(basename "$0")" in
  dpkg) echo amd64 ;;
  dpkg-query)
    echo "dpkg-query stub was not replaced" >&2
    exit 99
    ;;
  sbuild) echo "noble-${TARGET_ARCH:-amd64}" ;;
  schroot) echo "chroot:noble-${TARGET_ARCH:-amd64}" ;;
  docker)
    case "${1:-}" in
      info) exit 0 ;;
      pull) echo "unexpected docker pull: $*" >&2; exit 99 ;;
      *) echo "unexpected docker command: $*" >&2; exit 99 ;;
    esac
    ;;
  make)
    echo "unexpected make command: $*" >&2
    exit 99
    ;;
  sudo|apt-get|systemctl|sbuild-adduser|sbuild-createchroot|newgrp)
    echo "unexpected host command: $(basename "$0") $*" >&2
    exit 99
    ;;
esac
SH
    chmod +x "${FAKEBIN}/${cmd}"
  done
  cat > "${FAKEBIN}/sbuild" <<SH
#!/usr/bin/env bash
printf 'sbuild %s\n' "\$*" >> "${AUTO_REPO}/sbuild-calls"
case "\${1:-}" in
  --list-chroots)
    echo "noble-\${TARGET_ARCH:-amd64}"
    exit 0
    ;;
  *)
    echo "unexpected sbuild command: \$*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/schroot" <<SH
#!/usr/bin/env bash
printf 'schroot %s\n' "\$*" >> "${AUTO_REPO}/schroot-calls"
case "\${1:-}" in
  -l|--list)
    echo "chroot:noble-\${TARGET_ARCH:-amd64}"
    exit 0
    ;;
  *)
    echo "unexpected schroot command: \$*" >&2
    exit 99
    ;;
esac
SH
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
  chmod +x "${FAKEBIN}/sbuild" "${FAKEBIN}/schroot" "${FAKEBIN}/id" "${FAKEBIN}/python3"
  install_fake_dpkg_query
}

install_fake_dpkg_query() {
  cat > "${FAKEBIN}/dpkg-query" <<SH
#!/usr/bin/env bash
printf 'dpkg-query %s\n' "\$*" >> "${AUTO_REPO}/dpkg-query-calls"
package="\${!#}"
installed=" \${FAKE_DPKG_QUERY_INSTALLED:-docker-ce docker-ce-cli containerd.io} "
case "\$*" in
  *"--print-avail"*)
    echo "unexpected dpkg-query command: \$*" >&2
    exit 99
    ;;
esac
if [[ "\${installed}" == *" \${package} "* ]]; then
  printf 'install ok installed\n'
  exit 0
fi
exit 1
SH
  chmod +x "${FAKEBIN}/dpkg-query"
}

install_fake_groups() {
  local groups="$1"
  cat > "${FAKEBIN}/id" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  -u) echo 1000 ;;
  -nG) echo "${groups}" ;;
  *) /usr/bin/id "\$@" ;;
esac
SH
  chmod +x "${FAKEBIN}/id"
}

install_fake_root_user() {
  cat > "${FAKEBIN}/id" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -u) echo 0 ;;
  -nG) echo "root adm" ;;
  *) /usr/bin/id "$@" ;;
esac
SH
  chmod +x "${FAKEBIN}/id"
}

install_fake_missing_chroot() {
  cat > "${FAKEBIN}/schroot" <<SH
#!/usr/bin/env bash
printf 'schroot %s\n' "\$*" >> "${AUTO_REPO}/schroot-calls"
case "\${1:-}" in
  -l|--list)
    exit 0
    ;;
  *)
    echo "unexpected schroot command: \$*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/sbuild" <<SH
#!/usr/bin/env bash
printf 'sbuild %s\n' "\$*" >> "${AUTO_REPO}/sbuild-calls"
case "\${1:-}" in
  --list-chroots)
    exit 0
    ;;
  *)
    echo "unexpected sbuild command: \$*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/sbuild-createchroot" <<SH
#!/usr/bin/env bash
printf 'sbuild-createchroot %s\n' "\$*" >> "${AUTO_REPO}/sbuild-createchroot-calls"
echo "unexpected sbuild-createchroot command: \$*" >&2
exit 99
SH
  chmod +x "${FAKEBIN}/schroot" "${FAKEBIN}/sbuild" "${FAKEBIN}/sbuild-createchroot"
}

install_fake_source_chroot() {
  cat > "${FAKEBIN}/schroot" <<SH
#!/usr/bin/env bash
printf 'schroot %s\n' "\$*" >> "${AUTO_REPO}/schroot-calls"
case "\${1:-}" in
  -l|--list)
    echo "source:noble-\${TARGET_ARCH:-amd64}"
    exit 0
    ;;
  *)
    echo "unexpected schroot command: \$*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/sbuild" <<SH
#!/usr/bin/env bash
printf 'sbuild %s\n' "\$*" >> "${AUTO_REPO}/sbuild-calls"
case "\${1:-}" in
  --list-chroots)
    exit 0
    ;;
  *)
    echo "unexpected sbuild command: \$*" >&2
    exit 99
    ;;
esac
SH
  chmod +x "${FAKEBIN}/schroot" "${FAKEBIN}/sbuild"
}

allow_fake_sbuild_adduser() {
  cat > "${FAKEBIN}/sbuild-adduser" <<SH
#!/usr/bin/env bash
printf 'sbuild-adduser %s\n' "\$*" >> "${AUTO_REPO}/sbuild-adduser-calls"
exit 0
SH
  chmod +x "${FAKEBIN}/sbuild-adduser"
}

install_fake_sbuild_createchroot() {
  cat > "${FAKEBIN}/schroot" <<SH
#!/usr/bin/env bash
printf 'schroot %s\n' "\$*" >> "${AUTO_REPO}/schroot-calls"
case "\${1:-}" in
  -l|--list)
    if [[ -f "${AUTO_REPO}/chroot-created" ]]; then
      echo "chroot:noble-\${TARGET_ARCH:-amd64}"
    fi
    exit 0
    ;;
  *)
    echo "unexpected schroot command: \$*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/sbuild" <<SH
#!/usr/bin/env bash
printf 'sbuild %s\n' "\$*" >> "${AUTO_REPO}/sbuild-calls"
case "\${1:-}" in
  --list-chroots)
    if [[ -f "${AUTO_REPO}/chroot-created" ]]; then
      echo "noble-\${TARGET_ARCH:-amd64}"
    fi
    exit 0
    ;;
  *)
    echo "unexpected sbuild command: \$*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/sbuild-createchroot" <<SH
#!/usr/bin/env bash
printf 'sbuild-createchroot %s\n' "\$*" >> "${AUTO_REPO}/sbuild-createchroot-calls"
: > "${AUTO_REPO}/chroot-created"
exit 0
SH
  chmod +x "${FAKEBIN}/schroot" "${FAKEBIN}/sbuild" "${FAKEBIN}/sbuild-createchroot"
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
  remove)
    expected="remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc"
    if [[ "\$*" != "\${expected}" ]]; then
      echo "unexpected docker conflict package remove: \$*" >&2
      exit 99
    fi
    exit 0
    ;;
  update)
    exit 0
    ;;
  install)
    if [[ " \$* " == *" docker-ce "* && "\${FAKE_APT_DOCKER_CONFLICT:-0}" == 1 ]]; then
      echo "containerd.io : Conflicts: containerd" >&2
      exit 100
    fi
    if [[ " \$* " == *" docker-ce "* ]]; then
      expected="install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      if [[ "\$*" != "\${expected}" ]]; then
        echo "unexpected docker-ce install: \$*" >&2
        exit 99
      fi
    fi
    : > "\${DSCVERIFY_KEYRING_PATHS%%:*}"
    exit 0
    ;;
  *)
    echo "unexpected apt-get command: \$*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/install" <<SH
#!/usr/bin/env bash
printf 'install %s\n' "\$*" >> "${AUTO_REPO}/install-calls"
/usr/bin/install "\$@"
SH
  cat > "${FAKEBIN}/curl" <<SH
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "${AUTO_REPO}/curl-calls"
case "\$*" in
  "-fsSL https://download.docker.com/linux/ubuntu/gpg -o "*)
    ;;
  *)
    echo "unexpected curl command: \$*" >&2
    exit 99
    ;;
esac
output=""
while [[ "\$#" -gt 0 ]]; do
  case "\$1" in
    -o)
      output="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -n "\${output}" ]]; then
  printf 'fake docker gpg\n' > "\${output}"
fi
SH
  cat > "${FAKEBIN}/chmod" <<SH
#!/usr/bin/env bash
printf 'chmod %s\n' "\$*" >> "${AUTO_REPO}/chmod-calls"
/bin/chmod "\$@"
SH
  cat > "${FAKEBIN}/tee" <<SH
#!/usr/bin/env bash
printf 'tee %s\n' "\$*" >> "${AUTO_REPO}/tee-calls"
/usr/bin/tee "\$@"
SH
  cat > "${FAKEBIN}/systemctl" <<SH
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "${AUTO_REPO}/systemctl-calls"
if [[ " \$* " == *" containerd "* && "\${FAKE_SYSTEMCTL_CONTAINERD_FAIL:-0}" == 1 ]]; then
  exit 1
fi
exit 0
SH
  chmod +x "${FAKEBIN}/sudo" "${FAKEBIN}/apt-get" "${FAKEBIN}/install" "${FAKEBIN}/curl" "${FAKEBIN}/chmod" "${FAKEBIN}/tee" "${FAKEBIN}/systemctl"
}

install_fake_docker_info_sequence() {
  local first_status="$1"
  local second_status="${2:-$1}"
  cat > "${FAKEBIN}/docker" <<SH
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >> "${AUTO_REPO}/docker-calls"
case "\${1:-}" in
  info)
    count=0
    if [[ -f "${AUTO_REPO}/docker-info-count" ]]; then
      IFS= read -r count < "${AUTO_REPO}/docker-info-count"
    fi
    count=\$((count + 1))
    printf '%s\n' "\${count}" > "${AUTO_REPO}/docker-info-count"
    if [[ "\${count}" -eq 1 ]]; then
      exit "${first_status}"
    fi
    exit "${second_status}"
    ;;
  pull|run)
    echo "unexpected docker \${1}: \$*" >&2
    exit 99
    ;;
  *)
    echo "unexpected docker command: \$*" >&2
    exit 99
    ;;
esac
SH
  chmod +x "${FAKEBIN}/docker"
}

install_fake_successful_make() {
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s NOBLE_DOCKER_CMD=%s\n' "\$*" "\${NOBLE_DOCKER_CMD:-}" >> "${AUTO_REPO}/make-calls"
if [[ "\$*" != "noble-build" ]]; then
  echo "unexpected make command: \$*" >&2
  exit 99
fi
/bin/mkdir -p \
  "${AUTO_REPO}/build/noble/\${TARGET_ARCH:-amd64}/binary/node-undici" \
  "${AUTO_REPO}/build/noble/\${TARGET_ARCH:-amd64}/binary/ocserv" \
  "${AUTO_REPO}/build/noble/\${TARGET_ARCH:-amd64}/repo"
/usr/bin/touch \
  "${AUTO_REPO}/build/noble/\${TARGET_ARCH:-amd64}/binary/node-undici/libllhttp9.2_7.3.0_\${TARGET_ARCH:-amd64}.deb" \
  "${AUTO_REPO}/build/noble/\${TARGET_ARCH:-amd64}/binary/node-undici/libllhttp-dev_7.3.0_\${TARGET_ARCH:-amd64}.deb" \
  "${AUTO_REPO}/build/noble/\${TARGET_ARCH:-amd64}/binary/ocserv/ocserv_1.5.0_\${TARGET_ARCH:-amd64}.deb" \
  "${AUTO_REPO}/build/noble/\${TARGET_ARCH:-amd64}/repo/Packages"
SH
  chmod +x "${FAKEBIN}/make"
}

install_fake_make_without_artifacts() {
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s NOBLE_DOCKER_CMD=%s\n' "\$*" "\${NOBLE_DOCKER_CMD:-}" >> "${AUTO_REPO}/make-calls"
if [[ "\$*" != "noble-build" ]]; then
  echo "unexpected make command: \$*" >&2
  exit 99
fi
SH
  chmod +x "${FAKEBIN}/make"
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
  if [[ "${TARGET_ARCH+x}" == x ]]; then
    env_args+=("TARGET_ARCH=${TARGET_ARCH}")
  fi
  if [[ "${NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH+x}" == x ]]; then
    env_args+=("NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH=${NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH}")
  fi
  if [[ "${NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH+x}" == x ]]; then
    env_args+=("NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH=${NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH}")
  fi
  if [[ "${FAKE_APT_DOCKER_CONFLICT+x}" == x ]]; then
    env_args+=("FAKE_APT_DOCKER_CONFLICT=${FAKE_APT_DOCKER_CONFLICT}")
  fi
  if [[ "${FAKE_SYSTEMCTL_CONTAINERD_FAIL+x}" == x ]]; then
    env_args+=("FAKE_SYSTEMCTL_CONTAINERD_FAIL=${FAKE_SYSTEMCTL_CONTAINERD_FAIL}")
  fi
  if [[ "${FAKE_DPKG_QUERY_INSTALLED+x}" == x ]]; then
    env_args+=("FAKE_DPKG_QUERY_INSTALLED=${FAKE_DPKG_QUERY_INSTALLED}")
  fi
  if [[ "${NOBLE_AUTO_BUILD_SKIP_NEWGRP+x}" == x ]]; then
    env_args+=("NOBLE_AUTO_BUILD_SKIP_NEWGRP=${NOBLE_AUTO_BUILD_SKIP_NEWGRP}")
  fi
  if [[ "${USER+x}" == x ]]; then
    env_args+=("USER=${USER}")
  fi

  # shellcheck disable=SC2016
  if [[ "${RUN_AUTO_INPUT+x}" == x ]]; then
    local env_count="${#env_args[@]}"
    run /bin/bash -c '
      input="$1"
      repo="$2"
      env_count="$3"
      shift 3
      env_args=()
      for ((i = 0; i < env_count; i++)); do
        env_args+=("$1")
        shift
      done
      printf "%s" "${input}" | env "${env_args[@]}" /bin/bash -c '"'"'cd "$1" || exit; shift; /bin/bash scripts/noble-auto-build.sh "$@"'"'"' _ "${repo}" "$@"
    ' _ "${RUN_AUTO_INPUT}" "${AUTO_REPO}" "${env_count}" "${env_args[@]}" "$@"
  else
    run env "${env_args[@]}" /bin/bash -c 'cd "$1" || exit; shift; /bin/bash scripts/noble-auto-build.sh "$@"' _ "${AUTO_REPO}" "$@"
  fi
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
  [[ "${output}" == *"scripts/noble-auto-build.sh --provision"* ]]
  [[ "${output}" == *"curl"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/apt-get-calls" ]
}

@test "noble-auto-build root default mode reports missing core command without sudo prefix" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_root_user
  rm "${FAKEBIN}/curl"
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing required command: curl"* ]]
  [[ "${output}" == *"apt-get update"* ]]
  [[ "${output}" == *"apt-get install -y --no-install-recommends"* ]]
  [[ "${output}" != *"sudo apt-get update"* ]]
  [[ "${output}" != *"sudo apt-get install"* ]]
  [[ "${output}" == *"scripts/noble-auto-build.sh --provision"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/apt-get-calls" ]
}

@test "noble-auto-build --provision installs core packages and re-checks keyring" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_successful_make
  keyring="${AUTO_REPO}/provisioned-debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/apt/keyrings/docker.asc"
  docker_source="${AUTO_REPO}/apt/sources.list.d/docker.sources"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    run_auto_isolated --provision

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

@test "noble-auto-build default mode reports missing Docker CE without docker.io guidance" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  rm "${FAKEBIN}/docker"
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Docker CE"* ]]
  [[ "${output}" == *"docker-ce"* ]]
  [[ "${output}" == *"download.docker.com"* ]]
  [[ "${output}" != *"docker.io"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/apt-get-calls" ]
}

@test "noble-auto-build default mode reports Docker daemon repair commands without sudo execution" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 1
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sudo systemctl enable --now docker"* ]]
  [[ "${output}" == *"sudo docker info"* ]]
  [[ "${output}" != *"docker.io"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  grep -Fxq -- "docker info" "${AUTO_REPO}/docker-calls"
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/systemctl-calls" ]
}

@test "noble-auto-build default mode verifies Docker CE packages and daemon without sudo" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -eq 0 ]
  grep -Fq -- "dpkg-query" "${AUTO_REPO}/dpkg-query-calls"
  grep -Fq -- "docker-ce" "${AUTO_REPO}/dpkg-query-calls"
  grep -Fq -- "docker-ce-cli" "${AUTO_REPO}/dpkg-query-calls"
  grep -Fq -- "containerd.io" "${AUTO_REPO}/dpkg-query-calls"
  grep -Fxq -- "docker info" "${AUTO_REPO}/docker-calls"
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "noble-auto-build default mode runs noble-build and prints artifacts" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -eq 0 ]
  grep -Fxq -- "make noble-build NOBLE_DOCKER_CMD=docker" "${AUTO_REPO}/make-calls"
  [[ "${output}" == *"${AUTO_REPO}/build/noble/amd64/binary/node-undici/libllhttp9.2_7.3.0_amd64.deb"* ]]
  [[ "${output}" == *"${AUTO_REPO}/build/noble/amd64/binary/node-undici/libllhttp-dev_7.3.0_amd64.deb"* ]]
  [[ "${output}" == *"${AUTO_REPO}/build/noble/amd64/binary/ocserv/ocserv_1.5.0_amd64.deb"* ]]
  [[ "${output}" == *"${AUTO_REPO}/build/noble/amd64/repo/Packages"* ]]
}

@test "noble-auto-build fails after successful make when expected artifacts are missing" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_make_without_artifacts
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  grep -Fxq -- "make noble-build NOBLE_DOCKER_CMD=docker" "${AUTO_REPO}/make-calls"
  [[ "${output}" == *"expected artifact not found: ${AUTO_REPO}/build/noble/amd64/binary/node-undici/libllhttp9.2_*.deb"* ]]
}

@test "noble-auto-build default mode reports missing sbuild group commands" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_groups "users adm"
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  expected_group_command="sudo sbuild-adduser \"\$USER\""
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${expected_group_command}"* ]]
  [[ "${output}" == *"newgrp sbuild"* ]]
  [[ "${output}" == *"scripts/noble-auto-build.sh --provision"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "noble-auto-build skips sbuild group handling for root" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_root_user
  allow_fake_sbuild_adduser
  install_fake_docker_info_sequence 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -eq 0 ]
  [ ! -e "${AUTO_REPO}/sbuild-adduser-calls" ]
  [[ "${output}" != *"sudo sbuild-adduser"* ]]
  grep -Fxq -- "schroot -l" "${AUTO_REPO}/schroot-calls"
  grep -Fxq -- "sbuild --list-chroots" "${AUTO_REPO}/sbuild-calls"
  grep -Fxq -- "make noble-build NOBLE_DOCKER_CMD=docker" "${AUTO_REPO}/make-calls"
}

@test "noble-auto-build --provision adds sbuild group and skips real newgrp in tests" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_groups "users adm"
  allow_fake_provision_commands
  allow_fake_sbuild_adduser
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/provisioned-debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/apt/keyrings/docker.asc"
  docker_source="${AUTO_REPO}/apt/sources.list.d/docker.sources"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    USER=builder \
    NOBLE_AUTO_BUILD_SKIP_NEWGRP=1 \
    NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    run_auto_isolated --provision

  [ "${status}" -ne 0 ]
  grep -Fxq -- "sudo sbuild-adduser builder" "${AUTO_REPO}/sudo-calls"
  grep -Fxq -- "sbuild-adduser builder" "${AUTO_REPO}/sbuild-adduser-calls"
  [[ "${output}" == *"newgrp sbuild"* ]]
  [[ "${output}" == *"scripts/noble-auto-build.sh --provision"* ]]
  [[ "${output}" == *"rerun"* ]]
  [ ! -e "${AUTO_REPO}/newgrp-calls" ]
}

@test "noble-auto-build --provision stops in old non-interactive shell after adding sbuild group" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_groups "users adm"
  allow_fake_provision_commands
  allow_fake_sbuild_adduser
  install_fake_missing_chroot
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/provisioned-debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/apt/keyrings/docker.asc"
  docker_source="${AUTO_REPO}/apt/sources.list.d/docker.sources"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    USER=builder \
    NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    run_auto_isolated --provision

  [ "${status}" -ne 0 ]
  grep -Fxq -- "sudo sbuild-adduser builder" "${AUTO_REPO}/sudo-calls"
  grep -Fxq -- "sbuild-adduser builder" "${AUTO_REPO}/sbuild-adduser-calls"
  [ ! -e "${AUTO_REPO}/schroot-calls" ]
  [ ! -e "${AUTO_REPO}/sbuild-calls" ]
  [ ! -e "${AUTO_REPO}/sbuild-createchroot-calls" ]
  if grep -Fq -- "apt-get remove -y docker.io" "${AUTO_REPO}/apt-get-calls"; then
    false
  fi
}

@test "noble-auto-build default mode reports missing amd64 sbuild chroot command" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_missing_chroot
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sudo sbuild-createchroot --arch=amd64 --chroot-suffix= --include=eatmydata,ccache,gnupg,ca-certificates noble /srv/chroot/noble-amd64 http://archive.ubuntu.com/ubuntu"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  grep -Fxq -- "schroot -l" "${AUTO_REPO}/schroot-calls"
  grep -Fxq -- "sbuild --list-chroots" "${AUTO_REPO}/sbuild-calls"
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/sbuild-createchroot-calls" ]
}

@test "noble-auto-build accepts source sbuild chroot listing" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_source_chroot
  install_fake_docker_info_sequence 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -eq 0 ]
  grep -Fxq -- "schroot -l" "${AUTO_REPO}/schroot-calls"
  grep -Fxq -- "sbuild --list-chroots" "${AUTO_REPO}/sbuild-calls"
  [[ "${output}" != *"Missing sbuild chroot"* ]]
}

@test "noble-auto-build --provision creates chroot only after literal yes" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_docker_info_sequence 0
  install_fake_sbuild_createchroot
  install_fake_successful_make
  keyring="${AUTO_REPO}/provisioned-debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/apt/keyrings/docker.asc"
  docker_source="${AUTO_REPO}/apt/sources.list.d/docker.sources"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    RUN_AUTO_INPUT=$'YES\n' \
    NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    run_auto_isolated --provision

  [ "${status}" -ne 0 ]
  [ ! -e "${AUTO_REPO}/sbuild-createchroot-calls" ]

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    RUN_AUTO_INPUT=$'yes\n' \
    NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    run_auto_isolated --provision

  [ "${status}" -eq 0 ]
  grep -Fxq -- "sudo sbuild-createchroot --arch=amd64 --chroot-suffix= --include=eatmydata,ccache,gnupg,ca-certificates noble /srv/chroot/noble-amd64 http://archive.ubuntu.com/ubuntu" "${AUTO_REPO}/sudo-calls"
  grep -Fxq -- "sbuild-createchroot --arch=amd64 --chroot-suffix= --include=eatmydata,ccache,gnupg,ca-certificates noble /srv/chroot/noble-amd64 http://archive.ubuntu.com/ubuntu" "${AUTO_REPO}/sbuild-createchroot-calls"
  grep -Fxq -- "make noble-build NOBLE_DOCKER_CMD=sudo docker" "${AUTO_REPO}/make-calls"
}

@test "noble-auto-build TARGET_ARCH arm64 reports ports mirror for missing chroot" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_missing_chroot
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    TARGET_ARCH=arm64 \
    run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sudo sbuild-createchroot --arch=arm64 --chroot-suffix= --include=eatmydata,ccache,gnupg,ca-certificates noble /srv/chroot/noble-arm64 http://ports.ubuntu.com/ubuntu-ports"* ]]
}

@test "noble-auto-build default mode rejects missing Docker CE package even when daemon works" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    FAKE_DPKG_QUERY_INSTALLED="docker-ce docker-ce-cli" \
    run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Docker CE"* ]]
  [[ "${output}" == *"containerd.io"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "noble-auto-build default mode rejects Ubuntu docker packages even when daemon works" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    FAKE_DPKG_QUERY_INSTALLED="docker-ce docker-ce-cli containerd.io docker.io containerd runc" \
    run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Docker CE"* ]]
  [[ "${output}" == *"Do not mix Ubuntu docker.io/containerd with Docker CE/containerd.io"* ]]
  grep -Fq -- "docker.io" "${AUTO_REPO}/dpkg-query-calls"
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "noble-auto-build --provision installs Docker CE and repairs daemon" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_docker_info_sequence 1 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/provisioned-debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/apt/keyrings/docker.asc"
  docker_source="${AUTO_REPO}/apt/sources.list.d/docker.sources"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    TARGET_ARCH=arm64 \
    NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    FAKE_SYSTEMCTL_CONTAINERD_FAIL=1 \
    run_auto_isolated --provision

  [ "${status}" -eq 0 ]
  grep -Fq -- "apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc" "${AUTO_REPO}/apt-get-calls"
  grep -Fq -- "apt-get install -y --no-install-recommends ca-certificates curl" "${AUTO_REPO}/apt-get-calls"
  docker_install_call="$(grep -F -- "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" "${AUTO_REPO}/apt-get-calls")"
  [[ "${docker_install_call}" == *"apt-get install"* ]]
  update_count="$(grep -Fc -- "apt-get update" "${AUTO_REPO}/apt-get-calls")"
  [ "${update_count}" -ge 2 ]
  grep -Fq -- "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o ${docker_keyring}" "${AUTO_REPO}/curl-calls"
  grep -Fq -- "chmod a+r ${docker_keyring}" "${AUTO_REPO}/chmod-calls"
  grep -Fq -- "systemctl enable --now docker" "${AUTO_REPO}/systemctl-calls"
  grep -Fq -- "systemctl enable --now containerd" "${AUTO_REPO}/systemctl-calls"
  info_count="$(grep -Fxc -- "docker info" "${AUTO_REPO}/docker-calls")"
  [ "${info_count}" -eq 2 ]
  grep -Fxq -- "sudo docker info" "${AUTO_REPO}/sudo-calls"
  grep -Fq -- "Architectures: amd64" "${docker_source}"
  grep -Fq -- "Suites: noble" "${docker_source}"
  grep -Fq -- "Signed-By: ${docker_keyring}" "${docker_source}"
  if grep -Eq -- "docker (pull|run)" "${AUTO_REPO}/docker-calls"; then
    false
  fi
}

@test "noble-auto-build --provision diagnoses Docker CE containerd conflict" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/provisioned-debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/apt/keyrings/docker.asc"
  docker_source="${AUTO_REPO}/apt/sources.list.d/docker.sources"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    FAKE_APT_DOCKER_CONFLICT=1 \
    run_auto_isolated --provision

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"containerd.io : Conflicts: containerd"* ]]
  [[ "${output}" == *"Do not mix Ubuntu docker.io/containerd with Docker CE/containerd.io"* ]]
}
