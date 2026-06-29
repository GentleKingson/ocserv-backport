#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  AUTO_REPO="$(mktemp -d)"
  AUTO_REPO="$(cd -- "${AUTO_REPO}" && pwd -P)"
  FAKEBIN="$(mktemp -d)"
  mkdir -p "${AUTO_REPO}/scripts"
  cp "${REPO_ROOT}/scripts/_common.sh" "${AUTO_REPO}/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/_target_paths.sh" "${AUTO_REPO}/scripts/_target_paths.sh"
  cp "${REPO_ROOT}/scripts/_dscverify.sh" "${AUTO_REPO}/scripts/_dscverify.sh"
  if [[ -f "${REPO_ROOT}/scripts/debian-auto-build.sh" ]]; then
    cp "${REPO_ROOT}/scripts/debian-auto-build.sh" "${AUTO_REPO}/scripts/debian-auto-build.sh"
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
  ln -s /bin/cat "${FAKEBIN}/cat"
  ln -s /bin/date "${FAKEBIN}/date"
  ln -s /usr/bin/find "${FAKEBIN}/find"
  ln -s /bin/mkdir "${FAKEBIN}/mkdir"
  ln -s /usr/bin/mktemp "${FAKEBIN}/mktemp"
  ln -s /bin/rm "${FAKEBIN}/rm"
  ln -s /usr/bin/sort "${FAKEBIN}/sort"
  ln -s /usr/bin/touch "${FAKEBIN}/touch"
  cat > "${FAKEBIN}/chmod" <<'SH'
#!/usr/bin/env bash
/bin/chmod "$@"
SH
  /bin/chmod +x "${FAKEBIN}/chmod"
  for cmd in git curl gpg dpkg-buildpackage dscverify dpkg-source dh sbuild schroot debootstrap lintian bats shellcheck docker dpkg make sleep sudo apt-get systemctl sbuild-adduser sbuild-createchroot newgrp; do
    cat > "${FAKEBIN}/${cmd}" <<'SH'
#!/usr/bin/env bash
case "$(basename "$0")" in
  dpkg) [[ "${1:-}" == "--print-architecture" ]] && echo amd64 ;;
  gpg) exit 0 ;;
  sbuild) echo "trixie-amd64-sbuild" ;;
  schroot) echo "chroot:trixie-amd64-sbuild" ;;
  docker)
    case "${1:-}" in
      info) exit 0 ;;
      run) echo "unexpected docker run: $*" >&2; exit 99 ;;
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
  cat > "${FAKEBIN}/dpkg-query" <<SH
#!/usr/bin/env bash
installed="\${FAKE_DPKG_QUERY_INSTALLED:-docker-ce docker-ce-cli containerd.io}"
if [[ -f "${AUTO_REPO}/dpkg-query-installed" ]]; then
  IFS= read -r installed < "${AUTO_REPO}/dpkg-query-installed"
fi
package="\${*: -1}"
printf 'dpkg-query %s\n' "\$*" >> "${AUTO_REPO}/dpkg-query-calls"
if [[ " \${installed} " == *" \${package} "* ]]; then
  printf 'install ok installed'
  exit 0
fi
exit 1
SH
  cat > "${FAKEBIN}/sbuild" <<SH
#!/usr/bin/env bash
printf 'sbuild %s\n' "\$*" >> "${AUTO_REPO}/sbuild-calls"
case "\${1:-}" in
  --list-chroots)
    echo "trixie-amd64-sbuild"
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
    echo "chroot:trixie-amd64-sbuild"
    exit 0
    ;;
  -c)
    if [[ "\${1:-}" == "-c" && "\${2:-}" == "trixie-amd64-sbuild" && "\${3:-}" == "-u" && "\${4:-}" == "root" && "\${5:-}" == "--" && "\${6:-}" == "true" ]]; then
      exit 0
    fi
    echo "unexpected schroot command: \$*" >&2
    exit 99
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
  -g) echo 1000 ;;
  -nG) echo "users sbuild" ;;
  *) /usr/bin/id "$@" ;;
esac
SH
  cat > "${FAKEBIN}/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then exit 0; fi
exit 0
SH
  chmod +x "${FAKEBIN}/dpkg-query" "${FAKEBIN}/sbuild" "${FAKEBIN}/schroot" "${FAKEBIN}/id" "${FAKEBIN}/python3"
}

allow_fake_provision_commands() {
  cat > "${FAKEBIN}/sudo" <<SH
#!/usr/bin/env bash
printf 'sudo %s\n' "\$*" >> "${AUTO_REPO}/sudo-calls"
"\$@"
SH
  cat > "${FAKEBIN}/install" <<SH
#!/usr/bin/env bash
printf 'install %s\n' "\$*" >> "${AUTO_REPO}/install-calls"
/usr/bin/install "\$@"
SH
  cat > "${FAKEBIN}/curl" <<SH
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "${AUTO_REPO}/curl-calls"
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
  mkdir -p "\$(dirname -- "\${output}")"
  : > "\${output}"
fi
exit 0
SH
  cat > "${FAKEBIN}/tee" <<SH
#!/usr/bin/env bash
printf 'tee %s\n' "\$*" >> "${AUTO_REPO}/tee-calls"
/usr/bin/tee "\$@"
SH
  cat > "${FAKEBIN}/apt-get" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf 'apt-get %s\n' "\$*" >> "${AUTO_REPO}/apt-get-calls"
if [[ "\${1:-}" != "-q=1" || "\${2:-}" != "-o=Dpkg::Use-Pty=0" ]]; then
  echo "missing quiet apt flags: \$*" >&2
  exit 99
fi
shift 2
echo "apt progress output should be hidden"
if [[ -n "\${FAKE_APT_FAIL_COMMAND:-}" && "\${FAKE_APT_FAIL_COMMAND}" == "\${1:-}" ]]; then
  echo "apt stdout before failure"
  echo "apt stderr failure for \${1:-unknown}" >&2
  exit 100
fi
case "\${1:-}" in
  update)
    exit 0
    ;;
  remove)
    installed="\${FAKE_DPKG_QUERY_INSTALLED:-docker-ce docker-ce-cli containerd.io}"
    if [[ -f "${AUTO_REPO}/dpkg-query-installed" ]]; then
      IFS= read -r installed < "${AUTO_REPO}/dpkg-query-installed"
    fi
    for package in "\${@:2}"; do
      [[ "\${package}" == -* ]] && continue
      installed=" \${installed} "
      installed="\${installed// \${package} / }"
      installed="\${installed#" "}"
      installed="\${installed%" "}"
    done
    printf '%s\n' "\${installed}" > "${AUTO_REPO}/dpkg-query-installed"
    exit 0
    ;;
  install)
    installed="\${FAKE_DPKG_QUERY_INSTALLED:-docker-ce docker-ce-cli containerd.io}"
    if [[ -f "${AUTO_REPO}/dpkg-query-installed" ]]; then
      IFS= read -r installed < "${AUTO_REPO}/dpkg-query-installed"
    fi
    for package in "\${@:2}"; do
      [[ "\${package}" == -* ]] && continue
      if [[ " \${installed} " != *" \${package} "* ]]; then
        installed="\${installed} \${package}"
      fi
    done
    printf '%s\n' "\${installed}" > "${AUTO_REPO}/dpkg-query-installed"
    if [[ " \$* " == *" docker-ce "* ]]; then
      if [[ "\${FAKE_APT_DOCKER_CONFLICT:-0}" == 1 ]]; then
        echo "containerd.io : Conflicts: containerd" >&2
        exit 100
      fi
      cat > "${FAKEBIN}/docker" <<'DOCKER'
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
    if [[ "\${FAKE_APT_DOCKER_INFO_FIRST_STATUS:-0}" != 0 && "\${count}" -eq 1 ]]; then
      exit "\${FAKE_APT_DOCKER_INFO_FIRST_STATUS}"
    fi
    exit 0
    ;;
  run)
    mount=""
    while [[ "\$#" -gt 0 ]]; do
      case "\$1" in
        -v)
          mount="\$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    out_dir="\${mount%:/out}"
    if [[ -n "\${out_dir}" && "\${out_dir}" != "\${mount}" ]]; then
      mkdir -p "\${out_dir}/root/usr/share/keyrings"
      : > "\${out_dir}/root/usr/share/keyrings/debian-keyring.gpg"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
DOCKER
      chmod +x "${FAKEBIN}/docker"
    fi
    exit 0
    ;;
  *)
    echo "unexpected apt-get command: \$*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/systemctl" <<SH
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "${AUTO_REPO}/systemctl-calls"
exit 0
SH
  chmod +x "${FAKEBIN}/sudo" "${FAKEBIN}/install" "${FAKEBIN}/curl" "${FAKEBIN}/tee" "${FAKEBIN}/apt-get" "${FAKEBIN}/systemctl"
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
  run)
    echo "unexpected docker run: \$*" >&2
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

install_fake_docker_keyring_refresh() {
  cat > "${FAKEBIN}/docker" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "\$*" >> "${AUTO_REPO}/docker-calls"
case "\${1:-}" in
  info)
    exit 0
    ;;
  run)
    mount=""
    while [[ "\$#" -gt 0 ]]; do
      case "\$1" in
        -v)
          mount="\$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    out_dir="\${mount%:/out}"
    if [[ -z "\${out_dir}" || "\${out_dir}" == "\${mount}" ]]; then
      echo "missing keyring output mount: \$*" >&2
      exit 99
    fi
    mkdir -p "\${out_dir}/root/usr/share/keyrings"
    : > "\${out_dir}/root/usr/share/keyrings/debian-keyring.gpg"
    : > "\${out_dir}/root/usr/share/keyrings/debian-maintainers.gpg"
    exit 0
    ;;
  *)
    echo "unexpected docker command: \$*" >&2
    exit 99
    ;;
esac
SH
  chmod +x "${FAKEBIN}/docker"
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
  chmod +x "${FAKEBIN}/schroot" "${FAKEBIN}/sbuild"
}

install_fake_stale_registered_chroot() {
  cat > "${FAKEBIN}/schroot" <<SH
#!/usr/bin/env bash
printf 'schroot %s\n' "\$*" >> "${AUTO_REPO}/schroot-calls"
case "\${1:-}" in
  -l|--list)
    echo "chroot:trixie-amd64-sbuild"
    exit 0
    ;;
  -c)
    if [[ "\${1:-}" == "-c" && "\${2:-}" == "trixie-amd64-sbuild" && "\${3:-}" == "-u" && "\${4:-}" == "root" && "\${5:-}" == "--" && "\${6:-}" == "true" ]]; then
      echo "E: 10mount: error: Directory '/srv/chroot/trixie-amd64-sbuild' does not exist" >&2
      exit 1
    fi
    echo "unexpected schroot command: \$*" >&2
    exit 99
    ;;
  *)
    echo "unexpected schroot command: \$*" >&2
    exit 99
    ;;
esac
SH
  chmod +x "${FAKEBIN}/schroot"
}

install_fake_sbuild_createchroot() {
  cat > "${FAKEBIN}/schroot" <<SH
#!/usr/bin/env bash
printf 'schroot %s\n' "\$*" >> "${AUTO_REPO}/schroot-calls"
case "\${1:-}" in
  -l|--list)
    if [[ -f "${AUTO_REPO}/chroot-created" ]]; then
      echo "chroot:trixie-amd64-sbuild"
    fi
    exit 0
    ;;
  -c)
    if [[ -f "${AUTO_REPO}/chroot-created" && "\${1:-}" == "-c" && "\${2:-}" == "trixie-amd64-sbuild" && "\${3:-}" == "-u" && "\${4:-}" == "root" && "\${5:-}" == "--" && "\${6:-}" == "true" ]]; then
      exit 0
    fi
    echo "unexpected schroot command: \$*" >&2
    exit 99
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
      echo "trixie-amd64-sbuild"
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

install_fake_groups() {
  local groups="$1"
  cat > "${FAKEBIN}/id" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  -u) echo 1000 ;;
  -g) echo 1000 ;;
  -nG) echo "${groups}" ;;
  *) /usr/bin/id "\$@" ;;
esac
SH
  chmod +x "${FAKEBIN}/id"
}

allow_fake_sbuild_adduser() {
  cat > "${FAKEBIN}/sbuild-adduser" <<SH
#!/usr/bin/env bash
printf 'sbuild-adduser %s\n' "\$*" >> "${AUTO_REPO}/sbuild-adduser-calls"
exit 0
SH
  chmod +x "${FAKEBIN}/sbuild-adduser"
}

install_fake_successful_make() {
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s DEBIAN_DOCKER_CMD=%s\n' "\$*" "\${DEBIAN_DOCKER_CMD:-}" >> "${AUTO_REPO}/make-calls"
printf '%s\n' "\${DSCVERIFY_KEYRING_PATHS:-}" > "${AUTO_REPO}/make-dscverify-keyrings"
printf '%s\n' "\${LINTIAN_PROFILE:-}" > "${AUTO_REPO}/make-lintian-profile"
if [[ "\$*" != "build" ]]; then
  echo "unexpected make command: \$*" >&2
  exit 99
fi
/bin/mkdir -p "${AUTO_REPO}/build/debian/trixie/amd64/source" "${AUTO_REPO}/build/debian/trixie/amd64/binary"
/usr/bin/touch \
  "${AUTO_REPO}/build/debian/trixie/amd64/source/ocserv_1.5.0-1~debian13.1.dsc" \
  "${AUTO_REPO}/build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.deb" \
  "${AUTO_REPO}/build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.changes" \
  "${AUTO_REPO}/build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.buildinfo"
SH
  chmod +x "${FAKEBIN}/make"
}

install_fake_make_without_artifacts() {
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s DEBIAN_DOCKER_CMD=%s\n' "\$*" "\${DEBIAN_DOCKER_CMD:-}" >> "${AUTO_REPO}/make-calls"
printf '%s\n' "\${LINTIAN_PROFILE:-}" > "${AUTO_REPO}/make-lintian-profile"
if [[ "\$*" != "build" ]]; then
  echo "unexpected make command: \$*" >&2
  exit 99
fi
SH
  chmod +x "${FAKEBIN}/make"
}

run_auto_isolated() {
  local env_args=(
    "PATH=${FAKEBIN}"
    "DEBIAN_AUTO_BUILD_OS_RELEASE_PATH=${AUTO_REPO}/os-release"
    "DEBIAN_AUTO_BUILD_DOCKER_KEYRING_PATH=${DEBIAN_AUTO_BUILD_DOCKER_KEYRING_PATH:-${AUTO_REPO}/docker.asc}"
    "DEBIAN_AUTO_BUILD_DOCKER_SOURCE_PATH=${DEBIAN_AUTO_BUILD_DOCKER_SOURCE_PATH:-${AUTO_REPO}/docker.sources}"
  )
  if [[ "${DSCVERIFY_KEYRING_PATHS+x}" == x ]]; then
    env_args+=("DSCVERIFY_KEYRING_PATHS=${DSCVERIFY_KEYRING_PATHS}")
  fi
  if [[ "${TARGET_ARCH+x}" == x ]]; then
    env_args+=("TARGET_ARCH=${TARGET_ARCH}")
  fi
  if [[ "${DEBIAN_AUTO_BUILD_SKIP_NEWGRP+x}" == x ]]; then
    env_args+=("DEBIAN_AUTO_BUILD_SKIP_NEWGRP=${DEBIAN_AUTO_BUILD_SKIP_NEWGRP}")
  fi
  if [[ "${DEBIAN_AUTO_BUILD_CHROOT_BASE+x}" == x ]]; then
    env_args+=("DEBIAN_AUTO_BUILD_CHROOT_BASE=${DEBIAN_AUTO_BUILD_CHROOT_BASE}")
  fi
  if [[ "${FAKE_APT_FAIL_COMMAND+x}" == x ]]; then
    env_args+=("FAKE_APT_FAIL_COMMAND=${FAKE_APT_FAIL_COMMAND}")
  fi
  if [[ "${FAKE_APT_DOCKER_CONFLICT+x}" == x ]]; then
    env_args+=("FAKE_APT_DOCKER_CONFLICT=${FAKE_APT_DOCKER_CONFLICT}")
  fi
  if [[ "${FAKE_APT_DOCKER_INFO_FIRST_STATUS+x}" == x ]]; then
    env_args+=("FAKE_APT_DOCKER_INFO_FIRST_STATUS=${FAKE_APT_DOCKER_INFO_FIRST_STATUS}")
  fi
  if [[ "${FAKE_DPKG_QUERY_INSTALLED+x}" == x ]]; then
    env_args+=("FAKE_DPKG_QUERY_INSTALLED=${FAKE_DPKG_QUERY_INSTALLED}")
  fi
  if [[ "${USER+x}" == x ]]; then
    env_args+=("USER=${USER}")
  fi

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
      printf "%s" "${input}" | env "${env_args[@]}" /bin/bash -c '"'"'cd "$1" || exit; shift; /bin/bash scripts/debian-auto-build.sh "$@"'"'"' _ "${repo}" "$@"
    ' _ "${RUN_AUTO_INPUT}" "${AUTO_REPO}" "${env_count}" "${env_args[@]}" "$@"
  else
    run env "${env_args[@]}" /bin/bash -c 'cd "$1" || exit; shift; /bin/bash scripts/debian-auto-build.sh "$@"' _ "${AUTO_REPO}" "$@"
  fi
}

@test "debian-auto-build --help prints usage" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  run_auto_isolated --help
  [ "${status}" -eq 0 ]
  grep -Fq -- "Usage: scripts/debian-auto-build.sh [--provision]" <<<"${output}"
}

@test "debian-auto-build rejects unknown options" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  run_auto_isolated --bad-option
  [ "${status}" -ne 0 ]
  grep -Fq -- "Usage: scripts/debian-auto-build.sh [--provision]" <<<"${output}"
  [[ "${output}" == *"unknown option: --bad-option"* ]]
}

@test "debian-auto-build accepts Ubuntu Noble as GitHub runner host" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -eq 0 ]
  grep -Fxq -- "make build DEBIAN_DOCKER_CMD=docker" "${AUTO_REPO}/make-calls"
}

@test "debian-auto-build rejects unsupported hosts" {
  write_os_release ubuntu jammy
  install_minimal_valid_fakebin
  run_auto_isolated
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"requires Debian 13 trixie or Ubuntu 24.04 Noble"* ]]
}

@test "debian-auto-build rejects unsupported TARGET_ARCH" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  TARGET_ARCH=arm64 run_auto_isolated
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unsupported TARGET_ARCH=arm64"* ]]
  [[ "${output}" == *"amd64"* ]]
}

@test "debian-auto-build default mode reports missing core command without sudo side effects" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  rm "${FAKEBIN}/curl"
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing required command: curl"* ]]
  [[ "${output}" == *"apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends"* ]]
  [[ "${output}" == *"scripts/debian-auto-build.sh --provision"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/apt-get-calls" ]
}

@test "debian-auto-build --provision installs core packages" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_docker_info_sequence 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated --provision

  [ "${status}" -eq 0 ]
  grep -Fq -- "apt-get -q=1 -o=Dpkg::Use-Pty=0 update" "${AUTO_REPO}/apt-get-calls"
  install_call="$(grep -F -- "apt-get -q=1 -o=Dpkg::Use-Pty=0 install" "${AUTO_REPO}/apt-get-calls")"
  for package in git curl gnupg build-essential fakeroot devscripts dpkg-dev debhelper debian-keyring sbuild schroot debootstrap lintian libdistro-info-perl python3 python3-yaml bats shellcheck make; do
    if [[ "${install_call}" != *" ${package}"* && "${install_call}" != *" ${package} "* ]]; then
      echo "missing expected core package in provision install call: ${package}" >&2
      return 1
    fi
  done
  [[ "${output}" != *"apt progress output should be hidden"* ]]
}

@test "debian-auto-build --provision refreshes Debian dscverify keyrings when unset" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_docker_keyring_refresh
  install_fake_successful_make

  run_auto_isolated --provision

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"refreshing Debian dscverify keyrings from debian:sid"* ]]
  keyring_root="${AUTO_REPO}/build/debian/trixie/amd64/keyrings/debian"
  grep -Fq -- "docker run --rm" "${AUTO_REPO}/docker-calls"
  grep -Fq -- "-v ${keyring_root}:/out" "${AUTO_REPO}/docker-calls"
  grep -Fq -- "apt-get download debian-archive-keyring debian-keyring" "${AUTO_REPO}/docker-calls"
  ! grep -Fq -- "debian-maintainers" "${AUTO_REPO}/docker-calls"
  [[ "$(cat "${AUTO_REPO}/make-dscverify-keyrings")" == *"${keyring_root}/root/usr/share/keyrings/debian-keyring.gpg"* ]]
}

@test "debian-auto-build default mode fails when no Debian keyring is readable" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0

  DSCVERIFY_KEYRING_PATHS="${AUTO_REPO}/missing-one.gpg:${AUTO_REPO}/missing-two.gpg" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no readable Debian dscverify keyrings"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "debian-auto-build default mode reports missing Docker without sudo side effects" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  rm "${FAKEBIN}/docker"
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Docker CE is required for the Debian auto-build wrapper"* ]]
  [[ "${output}" == *"docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"* ]]
  [[ "${output}" != *"docker.io"* ]]
  [[ "${output}" != *"unexpected host command"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "debian-auto-build default mode rejects missing Docker CE package even when daemon works" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  FAKE_DPKG_QUERY_INSTALLED="docker-ce docker-ce-cli" \
    DSCVERIFY_KEYRING_PATHS="${keyring}" \
    run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Docker CE"* ]]
  [[ "${output}" == *"containerd.io"* ]]
  grep -Fq -- "containerd.io" "${AUTO_REPO}/dpkg-query-calls"
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "debian-auto-build default mode rejects distro Docker packages" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  FAKE_DPKG_QUERY_INSTALLED="docker-ce docker-ce-cli containerd.io docker.io containerd runc" \
    DSCVERIFY_KEYRING_PATHS="${keyring}" \
    run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Docker CE"* ]]
  [[ "${output}" == *"Do not mix distro Docker packages with Docker CE/containerd.io"* ]]
  grep -Fq -- "docker.io" "${AUTO_REPO}/dpkg-query-calls"
  grep -Fq -- "containerd" "${AUTO_REPO}/dpkg-query-calls"
  grep -Fq -- "runc" "${AUTO_REPO}/dpkg-query-calls"
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "debian-auto-build default mode reports Docker daemon repair commands without sudo execution" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 1
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sudo systemctl enable --now docker"* ]]
  [[ "${output}" == *"sudo docker info"* ]]
  grep -Fxq -- "docker info" "${AUTO_REPO}/docker-calls"
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
  [ ! -e "${AUTO_REPO}/systemctl-calls" ]
}

@test "debian-auto-build --provision installs Docker CE from Debian repo" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/docker.asc"
  docker_source="${AUTO_REPO}/docker.sources"
  : > "${keyring}"

  FAKE_DPKG_QUERY_INSTALLED="docker-ce docker-ce-cli containerd.io docker.io containerd runc podman-docker" \
    FAKE_APT_DOCKER_INFO_FIRST_STATUS=1 \
    DSCVERIFY_KEYRING_PATHS="${keyring}" \
    DEBIAN_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    DEBIAN_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    run_auto_isolated --provision

  [ "${status}" -eq 0 ]
  grep -Fq -- "apt-get -q=1 -o=Dpkg::Use-Pty=0 remove -y" "${AUTO_REPO}/apt-get-calls"
  grep -Fq -- "docker.io" "${AUTO_REPO}/apt-get-calls"
  grep -Fq -- "containerd" "${AUTO_REPO}/apt-get-calls"
  grep -Fq -- "runc" "${AUTO_REPO}/apt-get-calls"
  grep -Fq -- "podman-docker" "${AUTO_REPO}/apt-get-calls"
  grep -Fq -- "apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends ca-certificates curl" "${AUTO_REPO}/apt-get-calls"
  grep -Fq -- "apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" "${AUTO_REPO}/apt-get-calls"
  grep -Fxq -- "install -m 0755 -d $(dirname -- "${docker_keyring}")" "${AUTO_REPO}/install-calls"
  grep -Fq -- "curl -fsSL https://download.docker.com/linux/debian/gpg -o ${docker_keyring}" "${AUTO_REPO}/curl-calls"
  grep -Fq -- "tee ${docker_source}" "${AUTO_REPO}/tee-calls"
  grep -Fq -- "URIs: https://download.docker.com/linux/debian" "${docker_source}"
  grep -Fq -- "Suites: trixie" "${docker_source}"
  grep -Fq -- "Components: stable" "${docker_source}"
  grep -Fq -- "Signed-By: ${docker_keyring}" "${docker_source}"
  grep -Fq -- "Architectures: amd64" "${docker_source}"
  grep -Fxq -- "systemctl enable --now docker" "${AUTO_REPO}/systemctl-calls"
  grep -Fxq -- "systemctl enable --now containerd" "${AUTO_REPO}/systemctl-calls"
  grep -Fxq -- "make build DEBIAN_DOCKER_CMD=sudo docker" "${AUTO_REPO}/make-calls"
}

@test "debian-auto-build --provision installs Docker CE from Ubuntu repo on Noble host" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/docker.asc"
  docker_source="${AUTO_REPO}/docker.sources"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    DEBIAN_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    DEBIAN_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    run_auto_isolated --provision

  [ "${status}" -eq 0 ]
  grep -Fq -- "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o ${docker_keyring}" "${AUTO_REPO}/curl-calls"
  grep -Fq -- "URIs: https://download.docker.com/linux/ubuntu" "${docker_source}"
  grep -Fq -- "Suites: noble" "${docker_source}"
  grep -Fq -- "Components: stable" "${docker_source}"
  grep -Fq -- "Signed-By: ${docker_keyring}" "${docker_source}"
  grep -Fq -- "Architectures: amd64" "${docker_source}"
}

@test "debian-auto-build --provision diagnoses Docker CE containerd conflict" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  docker_keyring="${AUTO_REPO}/docker.asc"
  docker_source="${AUTO_REPO}/docker.sources"
  : > "${keyring}"

  FAKE_APT_DOCKER_CONFLICT=1 \
    DSCVERIFY_KEYRING_PATHS="${keyring}" \
    DEBIAN_AUTO_BUILD_DOCKER_KEYRING_PATH="${docker_keyring}" \
    DEBIAN_AUTO_BUILD_DOCKER_SOURCE_PATH="${docker_source}" \
    run_auto_isolated --provision

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"containerd.io : Conflicts: containerd"* ]]
  [[ "${output}" == *"Do not mix distro Docker packages with Docker CE/containerd.io"* ]]
}

@test "debian-auto-build default mode runs build and prints artifacts" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -eq 0 ]
  grep -Fxq -- "make build DEBIAN_DOCKER_CMD=docker" "${AUTO_REPO}/make-calls"
  [ "$(cat "${AUTO_REPO}/make-lintian-profile")" = "" ]
  [[ "${output}" == *"${AUTO_REPO}/build/debian/trixie/amd64/source/ocserv_1.5.0-1~debian13.1.dsc"* ]]
  [[ "${output}" == *"${AUTO_REPO}/build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.deb"* ]]
  [[ "${output}" == *"${AUTO_REPO}/build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.changes"* ]]
  [[ "${output}" == *"${AUTO_REPO}/build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.buildinfo"* ]]
}

@test "debian-auto-build uses Debian lintian profile on Ubuntu Noble host" {
  write_os_release ubuntu noble
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -eq 0 ]
  grep -Fxq -- "make build DEBIAN_DOCKER_CMD=docker" "${AUTO_REPO}/make-calls"
  [ "$(cat "${AUTO_REPO}/make-lintian-profile")" = "debian" ]
}

@test "debian-auto-build fails after successful make when expected artifacts are missing" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_make_without_artifacts
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  grep -Fxq -- "make build DEBIAN_DOCKER_CMD=docker" "${AUTO_REPO}/make-calls"
  [[ "${output}" == *"expected artifact not found: ${AUTO_REPO}/build/debian/trixie/amd64/source/ocserv_*.dsc"* ]]
}

@test "debian-auto-build default mode reports missing sbuild group commands" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_groups "users adm"
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sudo sbuild-adduser \"\$USER\""* ]]
  [[ "${output}" == *"newgrp sbuild"* ]]
  [[ "${output}" == *"scripts/debian-auto-build.sh --provision"* ]]
  [ ! -e "${AUTO_REPO}/sudo-calls" ]
}

@test "debian-auto-build --provision adds sbuild group and stops in old shell" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_groups "users adm"
  allow_fake_provision_commands
  allow_fake_sbuild_adduser
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    USER=builder \
    DEBIAN_AUTO_BUILD_SKIP_NEWGRP=1 \
    run_auto_isolated --provision

  [ "${status}" -ne 0 ]
  grep -Fxq -- "sudo sbuild-adduser builder" "${AUTO_REPO}/sudo-calls"
  grep -Fxq -- "sbuild-adduser builder" "${AUTO_REPO}/sbuild-adduser-calls"
  [[ "${output}" == *"newgrp sbuild"* ]]
  [[ "${output}" == *"rerun"* ]]
}

@test "debian-auto-build default mode reports missing trixie sbuild chroot command" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_docker_info_sequence 0
  install_fake_missing_chroot
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  grep -Fq -- "sudo sbuild-createchroot --arch=amd64 --chroot-suffix=-sbuild --include=eatmydata,ccache,gnupg,ca-certificates trixie /srv/chroot/trixie-amd64-sbuild http://deb.debian.org/debian" <<<"${output}"
  grep -Fxq -- "schroot -l" "${AUTO_REPO}/schroot-calls"
  grep -Fxq -- "sbuild --list-chroots" "${AUTO_REPO}/sbuild-calls"
  [ ! -e "${AUTO_REPO}/sbuild-createchroot-calls" ]
}

@test "debian-auto-build rejects registered but unusable chroot in default mode" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  install_fake_stale_registered_chroot
  install_fake_docker_info_sequence 0
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" run_auto_isolated

  [ "${status}" -ne 0 ]
  grep -Fxq -- "schroot -c trixie-amd64-sbuild -u root -- true" "${AUTO_REPO}/schroot-calls"
  grep -Fq -- "sbuild chroot is registered but unusable: trixie-amd64-sbuild" <<<"${output}"
  grep -Fq -- "sudo ls -ld /srv/chroot/trixie-amd64-sbuild" <<<"${output}"
}

@test "debian-auto-build --provision creates chroot only after literal yes" {
  write_os_release debian trixie
  install_minimal_valid_fakebin
  allow_fake_provision_commands
  install_fake_docker_info_sequence 0
  install_fake_sbuild_createchroot
  install_fake_successful_make
  keyring="${AUTO_REPO}/debian-keyring.gpg"
  : > "${keyring}"

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    RUN_AUTO_INPUT=$'YES\n' \
    run_auto_isolated --provision

  [ "${status}" -ne 0 ]
  [ ! -e "${AUTO_REPO}/sbuild-createchroot-calls" ]

  DSCVERIFY_KEYRING_PATHS="${keyring}" \
    RUN_AUTO_INPUT=$'yes\n' \
    run_auto_isolated --provision

  [ "${status}" -eq 0 ]
  grep -Fxq -- "sudo sbuild-createchroot --arch=amd64 --chroot-suffix=-sbuild --include=eatmydata,ccache,gnupg,ca-certificates trixie /srv/chroot/trixie-amd64-sbuild http://deb.debian.org/debian" "${AUTO_REPO}/sudo-calls"
  grep -Fxq -- "sbuild-createchroot --arch=amd64 --chroot-suffix=-sbuild --include=eatmydata,ccache,gnupg,ca-certificates trixie /srv/chroot/trixie-amd64-sbuild http://deb.debian.org/debian" "${AUTO_REPO}/sbuild-createchroot-calls"
  grep -Fxq -- "make build DEBIAN_DOCKER_CMD=sudo docker" "${AUTO_REPO}/make-calls"
}
