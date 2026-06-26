#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  NOBLE_REPO=""
  FAKEBIN=""
  OUTSIDE_DIR=""
  SYSTEM_MAKE=""
}

teardown() {
  if [[ -n "${NOBLE_REPO:-}" ]]; then rm -rf "${NOBLE_REPO}"; fi
  if [[ -n "${FAKEBIN:-}" ]]; then rm -rf "${FAKEBIN}"; fi
  if [[ -n "${OUTSIDE_DIR:-}" ]]; then rm -rf "${OUTSIDE_DIR}"; fi
}

setup_noble_repo() {
  NOBLE_REPO="$(mktemp -d)"
  mkdir -p "${NOBLE_REPO}/scripts"
  cp "${REPO_ROOT}/scripts/_common.sh" "${NOBLE_REPO}/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/_dsc.sh" "${NOBLE_REPO}/scripts/_dsc.sh"
  if [[ -f "${REPO_ROOT}/scripts/noble-env.sh" ]]; then
    cp "${REPO_ROOT}/scripts/noble-env.sh" "${NOBLE_REPO}/scripts/noble-env.sh"
  fi
  cp "${REPO_ROOT}/Makefile" "${NOBLE_REPO}/Makefile"
  local script
  for script in \
    noble-build.sh \
    noble-build-repo.sh \
    noble-build-source-package.sh \
    noble-build-binary-ocserv.sh \
    noble-smoke-test.sh; do
    if [[ -f "${REPO_ROOT}/scripts/${script}" ]]; then
      cp "${REPO_ROOT}/scripts/${script}" "${NOBLE_REPO}/scripts/${script}"
    fi
  done
  SYSTEM_MAKE="$(command -v make)"
  FAKEBIN="$(mktemp -d)"
}

install_fake_make() {
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
target="\${1:-}"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "\${target}" \
  "\${NODE_UNDICI_DEBIAN_VERSION:-}" \
  "\${NODE_UNDICI_NOBLE_VERSION:-}" \
  "\${OCSERV_DEBIAN_VERSION:-}" \
  "\${OCSERV_NOBLE_VERSION:-}" \
  "\${TARGET_DISTRIBUTION:-}" \
  "\${TARGET_ARCH:-}" >> "${NOBLE_REPO}/make-calls"
SH
  chmod +x "${FAKEBIN}/make"
}

run_noble_build_direct() {
  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build.sh"
}

run_noble_build_direct_with_arch() {
  local arch="$1"
  run bash -c "cd '${NOBLE_REPO}' && TARGET_ARCH='${arch}' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build.sh"
}

make_call_targets() {
  cut -f1 "${NOBLE_REPO}/make-calls"
}

unique_make_env_rows() {
  cut -f2- "${NOBLE_REPO}/make-calls" | sort -u
}

install_fake_source_package_commands() {
  local with_dh="${1:-1}"
  local with_pkgjs_pjson="${2:-1}"

  ln -s /bin/bash "${FAKEBIN}/bash"
  ln -s "$(command -v dirname)" "${FAKEBIN}/dirname"
  ln -s "$(command -v date)" "${FAKEBIN}/date"
  ln -s "$(command -v awk)" "${FAKEBIN}/awk"
  ln -s "$(command -v rm)" "${FAKEBIN}/rm"

  cat > "${FAKEBIN}/dpkg-buildpackage" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf 'dpkg-buildpackage %s\n' "\$*" >> "${NOBLE_REPO}/dpkg-buildpackage-calls"
case "\${PWD}" in
  */source/node-undici/node-undici-*)
    dsc="\${PWD%/*}/node-undici_\${NODE_UNDICI_NOBLE_VERSION:-7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1}.dsc"
    printf 'Source: node-undici\nVersion: %s\n' "\${NODE_UNDICI_NOBLE_VERSION:-7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1}" > "\${dsc}"
    ;;
  */source/ocserv/ocserv-*)
    dsc="\${PWD%/*}/ocserv_\${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.1}.dsc"
    printf 'Source: ocserv\nVersion: %s\n' "\${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.1}" > "\${dsc}"
    ;;
  *)
    echo "unexpected source package cwd: \${PWD}" >&2
    exit 99
    ;;
esac
SH

  cat > "${FAKEBIN}/id" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -u) echo 1000 ;;
  *) /usr/bin/id "$@" ;;
esac
SH

  if [[ "${with_dh}" == 1 ]]; then
    cat > "${FAKEBIN}/dh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fi

  if [[ "${with_pkgjs_pjson}" == 1 ]]; then
    cat > "${FAKEBIN}/pkgjs-pjson" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fi

  chmod +x "${FAKEBIN}/dpkg-buildpackage" "${FAKEBIN}/id"
  [[ "${with_dh}" != 1 ]] || chmod +x "${FAKEBIN}/dh"
  [[ "${with_pkgjs_pjson}" != 1 ]] || chmod +x "${FAKEBIN}/pkgjs-pjson"
}

create_noble_source_tree() {
  local package="$1"
  local version="$2"
  mkdir -p "${NOBLE_REPO}/build/noble/amd64/source/${package}/${package}-${version}"
}

@test "noble-build executes the twelve Noble stages in order" {
  setup_noble_repo
  install_fake_make
  run_noble_build_direct
  [ "${status}" -eq 0 ]
  calls="$(make_call_targets)"
  [ "${calls}" = $'noble-verify-locks\nnoble-fetch-node-undici\nnoble-rewrap-node-undici\nnoble-src-pkg-node-undici\nnoble-binary-node-undici\nnoble-repo\nnoble-fetch-ocserv\nnoble-rewrap-ocserv\nnoble-src-pkg-ocserv\nnoble-binary-ocserv\nnoble-lint\nnoble-smoke-basic' ]
}

@test "noble-build exports Noble default versions and amd64 architecture" {
  setup_noble_repo
  install_fake_make
  run_noble_build_direct
  [ "${status}" -eq 0 ]
  vars="$(unique_make_env_rows)"
  [ "${vars}" = $'7.3.0+dfsg1+~cs24.12.11-1\t7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1\t1.5.0-1\t1.5.0-1~ubuntu24.04.1\tnoble\tamd64' ]
}

@test "noble-build preserves TARGET_ARCH override without cross-build setup" {
  setup_noble_repo
  install_fake_make
  run_noble_build_direct_with_arch arm64
  [ "${status}" -eq 0 ]
  vars="$(unique_make_env_rows)"
  [ "${vars}" = $'7.3.0+dfsg1+~cs24.12.11-1\t7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1\t1.5.0-1\t1.5.0-1~ubuntu24.04.1\tnoble\tarm64' ]
  [[ ! -e "${NOBLE_REPO}/cross-build-requested" ]]
}

@test "make noble-build delegates to scripts/noble-build.sh" {
  setup_noble_repo
  cat > "${NOBLE_REPO}/scripts/noble-build.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\${TARGET_ARCH:-}" > "${NOBLE_REPO}/noble-build-target-arch"
SH
  chmod +x "${NOBLE_REPO}/scripts/noble-build.sh"
  run bash -c "cd '${NOBLE_REPO}' && TARGET_ARCH=arm64 '${SYSTEM_MAKE}' noble-build"
  [ "${status}" -eq 0 ]
  [ "$(cat "${NOBLE_REPO}/noble-build-target-arch")" = "arm64" ]
}

@test "make noble-auto-build delegates to scripts/noble-auto-build.sh" {
  setup_noble_repo
  cat > "${NOBLE_REPO}/scripts/noble-auto-build.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\${TARGET_ARCH:-}" > "${NOBLE_REPO}/noble-auto-build-target-arch"
SH
  chmod +x "${NOBLE_REPO}/scripts/noble-auto-build.sh"
  run bash -c "cd '${NOBLE_REPO}' && TARGET_ARCH=arm64 '${SYSTEM_MAKE}' noble-auto-build"
  [ "${status}" -eq 0 ]
  [ "$(cat "${NOBLE_REPO}/noble-auto-build-target-arch")" = "arm64" ]
}

@test "noble source package fails before deleting artifacts when node-undici pkgjs-pjson is missing" {
  setup_noble_repo
  install_fake_source_package_commands 1 0
  create_noble_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11"
  old_artifact="${NOBLE_REPO}/build/noble/amd64/source/node-undici/node-undici_7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1.old"
  : > "${old_artifact}"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}' /bin/bash scripts/noble-build-source-package.sh node-undici"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing required source package command: pkgjs-pjson"* ]]
  [[ "${output}" == *"sudo apt-get install -y --no-install-recommends debhelper dh-nodejs"* ]]
  [ -f "${old_artifact}" ]
  [ ! -e "${NOBLE_REPO}/dpkg-buildpackage-calls" ]
}

@test "noble source package fails early when ocserv dh is missing" {
  setup_noble_repo
  install_fake_source_package_commands 0 1
  create_noble_source_tree ocserv "1.5.0"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}' /bin/bash scripts/noble-build-source-package.sh ocserv"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing required source package command: dh"* ]]
  [[ "${output}" == *"sudo apt-get install -y --no-install-recommends debhelper dh-nodejs"* ]]
  [ ! -e "${NOBLE_REPO}/dpkg-buildpackage-calls" ]
}

@test "noble source package builds dsc when host clean commands exist" {
  setup_noble_repo
  install_fake_source_package_commands 1 1
  create_noble_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}' /bin/bash scripts/noble-build-source-package.sh node-undici"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "dpkg-buildpackage -S -d -us -uc" "${NOBLE_REPO}/dpkg-buildpackage-calls"
  [ -f "${NOBLE_REPO}/build/noble/amd64/source/node-undici/node-undici_7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1.dsc" ]
}

install_fake_smoke_tools() {
  cat > "${FAKEBIN}/dpkg-deb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
field="${3:-}"
case "${field}" in
  Package) printf '%s\n' "ocserv" ;;
  Version) printf '%s\n' "1.5.0-1~ubuntu24.04.1" ;;
  Architecture) printf '%s\n' "${TARGET_ARCH:-amd64}" ;;
  Depends) printf '%s\n' "libc6, libllhttp9.2 (>= 7.3.0)" ;;
  *)
    echo "unexpected dpkg-deb command: $*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/sudo" <<SH
#!/usr/bin/env bash
printf 'sudo %s\n' "\$*" >> "${NOBLE_REPO}/sudo-calls"
exit 0
SH
  cat > "${FAKEBIN}/docker" <<SH
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >> "${NOBLE_REPO}/docker-calls"
echo "unexpected direct docker command: \$*" >&2
exit 99
SH
  chmod +x "${FAKEBIN}/dpkg-deb" "${FAKEBIN}/sudo" "${FAKEBIN}/docker"
}

@test "noble-smoke-basic honors NOBLE_DOCKER_CMD override" {
  setup_noble_repo
  install_fake_smoke_tools
  mkdir -p "${NOBLE_REPO}/build/noble/amd64/binary/ocserv"
  mkdir -p "${NOBLE_REPO}/build/noble/amd64/repo"
  touch "${NOBLE_REPO}/build/noble/amd64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.1_amd64.deb"
  touch "${NOBLE_REPO}/build/noble/amd64/repo/libllhttp9.2_7.3.0_amd64.deb"

  run bash -c "cd '${NOBLE_REPO}' && NOBLE_DOCKER_CMD='sudo docker' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-smoke-test.sh"

  [ "${status}" -eq 0 ]
  grep -Fq -- "sudo docker run --rm" "${NOBLE_REPO}/sudo-calls"
  [ ! -e "${NOBLE_REPO}/docker-calls" ]
}

install_fake_dpkg_scanpackages() {
  cat > "${FAKEBIN}/dpkg-scanpackages" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "dpkg-scanpackages \$*" >> "${NOBLE_REPO}/scanpackages-calls"
printf '%s\n' \
  "Package: libllhttp9.2" \
  "Version: 7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1" \
  "Architecture: all" \
  "" \
  "Package: libllhttp-dev" \
  "Version: 7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1" \
  "Architecture: all"
SH
  chmod +x "${FAKEBIN}/dpkg-scanpackages"
}

@test "noble-repo copies only libllhttp runtime and development debs" {
  setup_noble_repo
  install_fake_dpkg_scanpackages
  mkdir -p "${NOBLE_REPO}/build/noble/amd64/binary/node-undici"
  touch "${NOBLE_REPO}/build/noble/amd64/binary/node-undici/libllhttp9.2_7.3.0_amd64.deb"
  touch "${NOBLE_REPO}/build/noble/amd64/binary/node-undici/libllhttp-dev_7.3.0_amd64.deb"
  touch "${NOBLE_REPO}/build/noble/amd64/binary/node-undici/node-undici_7.3.0_all.deb"
  touch "${NOBLE_REPO}/build/noble/amd64/binary/node-undici/node-llhttp_7.3.0_all.deb"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-repo.sh"
  [ "${status}" -eq 0 ]
  [ -f "${NOBLE_REPO}/build/noble/amd64/repo/libllhttp9.2_7.3.0_amd64.deb" ]
  [ -f "${NOBLE_REPO}/build/noble/amd64/repo/libllhttp-dev_7.3.0_amd64.deb" ]
  [ ! -e "${NOBLE_REPO}/build/noble/amd64/repo/node-undici_7.3.0_all.deb" ]
  [ ! -e "${NOBLE_REPO}/build/noble/amd64/repo/node-llhttp_7.3.0_all.deb" ]
  [ -f "${NOBLE_REPO}/build/noble/amd64/repo/Packages" ]
  [ -f "${NOBLE_REPO}/build/noble/amd64/repo/Packages.gz" ]
}

@test "noble-repo rejects missing libllhttp runtime or development debs" {
  setup_noble_repo
  install_fake_dpkg_scanpackages
  mkdir -p "${NOBLE_REPO}/build/noble/amd64/binary/node-undici"
  touch "${NOBLE_REPO}/build/noble/amd64/binary/node-undici/libllhttp9.2_7.3.0_amd64.deb"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-repo.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"libllhttp-dev"* ]]
}

@test "noble-repo uses TARGET_ARCH-specific build and repo paths" {
  setup_noble_repo
  install_fake_dpkg_scanpackages
  mkdir -p "${NOBLE_REPO}/build/noble/arm64/binary/node-undici"
  touch "${NOBLE_REPO}/build/noble/arm64/binary/node-undici/libllhttp9.2_7.3.0_arm64.deb"
  touch "${NOBLE_REPO}/build/noble/arm64/binary/node-undici/libllhttp-dev_7.3.0_arm64.deb"

  run bash -c "cd '${NOBLE_REPO}' && TARGET_ARCH=arm64 PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-repo.sh"
  [ "${status}" -eq 0 ]
  [ -f "${NOBLE_REPO}/build/noble/arm64/repo/libllhttp9.2_7.3.0_arm64.deb" ]
  [ -f "${NOBLE_REPO}/build/noble/arm64/repo/libllhttp-dev_7.3.0_arm64.deb" ]
  [ ! -d "${NOBLE_REPO}/build/noble/amd64/repo" ]
}

install_fake_http_python_and_sbuild() {
  cat > "${FAKEBIN}/python3" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "-m" && "\${2:-}" == "http.server" ]]; then
  printf '%s\n' "\$*" > "${NOBLE_REPO}/http-server-args"
  printf '%s\n' "\$\$" > "${NOBLE_REPO}/http-server-pid"
  trap 'exit 0' TERM INT
  while true; do sleep 1; done
fi
printf '%s\n' "43123"
SH
  cat > "${FAKEBIN}/sbuild" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > "${NOBLE_REPO}/sbuild-args"
build_dir=""
arch="\${TARGET_ARCH:-amd64}"
prev=""
for arg in "\$@"; do
  if [[ "\${prev}" == "--build-dir" ]]; then build_dir="\${arg}"; fi
  case "\${arg}" in
    --build-dir=*) build_dir="\${arg#--build-dir=}" ;;
    --arch=*) arch="\${arg#--arch=}" ;;
  esac
  prev="\${arg}"
done
mkdir -p "\${build_dir}"
version="\${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.1}"
touch "\${build_dir}/ocserv_\${version}_\${arch}.deb"
touch "\${build_dir}/ocserv_\${version}_\${arch}.changes"
touch "\${build_dir}/ocserv_\${version}_\${arch}.buildinfo"
SH
  chmod +x "${FAKEBIN}/python3" "${FAKEBIN}/sbuild"
}

@test "noble-binary-ocserv injects a temporary localhost HTTP repo and cleans it up" {
  setup_noble_repo
  install_fake_http_python_and_sbuild
  mkdir -p "${NOBLE_REPO}/build/noble/arm64/source/ocserv"
  mkdir -p "${NOBLE_REPO}/build/noble/arm64/repo"
  touch "${NOBLE_REPO}/build/noble/arm64/source/ocserv/ocserv_1.5.0-1~ubuntu24.04.1.dsc"
  touch "${NOBLE_REPO}/build/noble/arm64/repo/Packages"

  run bash -c "cd '${NOBLE_REPO}' && TARGET_ARCH=arm64 PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-ocserv.sh"
  [ "${status}" -eq 0 ]
  grep -Fq -- "--arch=arm64" "${NOBLE_REPO}/sbuild-args"
  grep -Fq -- "deb [trusted=yes] http://127.0.0.1:43123/ ./" "${NOBLE_REPO}/sbuild-args"
  grep -Fq -- "--bind" "${NOBLE_REPO}/http-server-args"
  grep -Fq -- "127.0.0.1" "${NOBLE_REPO}/http-server-args"
  server_pid="$(cat "${NOBLE_REPO}/http-server-pid")"
  if kill -0 "${server_pid}" 2>/dev/null; then
    echo "HTTP server still running: ${server_pid}" >&2
    return 1
  fi
}
