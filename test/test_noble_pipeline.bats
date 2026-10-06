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
  cp "${REPO_ROOT}/scripts/_pipeline.sh" "${NOBLE_REPO}/scripts/_pipeline.sh"
  cp "${REPO_ROOT}/scripts/_target_arch.sh" "${NOBLE_REPO}/scripts/_target_arch.sh"
  cp "${REPO_ROOT}/scripts/_target_paths.sh" "${NOBLE_REPO}/scripts/_target_paths.sh"
  cp "${REPO_ROOT}/scripts/_dsc.sh" "${NOBLE_REPO}/scripts/_dsc.sh"
  if [[ -f "${REPO_ROOT}/scripts/_sbuild.sh" ]]; then
    cp "${REPO_ROOT}/scripts/_sbuild.sh" "${NOBLE_REPO}/scripts/_sbuild.sh"
  fi
  if [[ -f "${REPO_ROOT}/scripts/noble-env.sh" ]]; then
    cp "${REPO_ROOT}/scripts/noble-env.sh" "${NOBLE_REPO}/scripts/noble-env.sh"
    cp "${REPO_ROOT}/scripts/_versions.sh" "${NOBLE_REPO}/scripts/_versions.sh"
  fi
  if [[ -d "${REPO_ROOT}/packaging" ]]; then
    cp -R "${REPO_ROOT}/packaging" "${NOBLE_REPO}/packaging"
  fi
  cp "${REPO_ROOT}/Makefile" "${NOBLE_REPO}/Makefile"
  local script
  for script in \
    noble-build.sh \
    noble-rewrap-changelog.sh \
    noble-build-source-package.sh \
    noble-build-binary-ocserv.sh \
    noble-smoke-test.sh; do
    if [[ -f "${REPO_ROOT}/scripts/${script}" ]]; then
      cp "${REPO_ROOT}/scripts/${script}" "${NOBLE_REPO}/scripts/${script}"
    fi
  done
  SYSTEM_MAKE="$(command -v make)"
  FAKEBIN="$(mktemp -d)"
  install_fake_arch_commands
}

install_fake_arch_commands() {
  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture)
    if [[ "${FAKE_DPKG_STATUS:-0}" != "0" ]]; then
      exit "${FAKE_DPKG_STATUS}"
    fi
    if [[ "${FAKE_DPKG_ARCH+x}" == x ]]; then
      printf '%s\n' "${FAKE_DPKG_ARCH}"
    else
      printf 'amd64\n'
    fi
    ;;
  *)
    echo "unexpected dpkg command: $*" >&2
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m)
    printf '%s\n' "${FAKE_UNAME_M:-x86_64}"
    ;;
  *)
    echo "unexpected uname command: $*" >&2
    exit 99
    ;;
esac
SH
  chmod +x "${FAKEBIN}/dpkg" "${FAKEBIN}/uname"
}

install_fake_make() {
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
target="\${1:-}"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "\${target}" \
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
  */source/ocserv/ocserv-*)
    dsc="\${PWD%/*}/ocserv_\${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.2}.dsc"
    printf 'Source: ocserv\nVersion: %s\n' "\${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.2}" > "\${dsc}"
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

  chmod +x "${FAKEBIN}/dpkg-buildpackage" "${FAKEBIN}/id"
  [[ "${with_dh}" != 1 ]] || chmod +x "${FAKEBIN}/dh"
}

create_noble_source_tree() {
  local package="$1"
  local version="$2"
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/${package}/${package}-${version}"
}

create_noble_rewrap_source_tree() {
  local package="$1"
  local upstream_version="$2"
  local debian_version="$3"
  local distribution="${4:-unstable}"
  local source_tree="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/${package}/${package}-${upstream_version}"

  mkdir -p "${source_tree}/debian" "${source_tree}/src/llhttp"
  : > "${source_tree}/src/llhttp/llhttp.c"
  cat > "${source_tree}/debian/rules" <<'EOF'
#!/usr/bin/make -f

%:
	dh $@

override_dh_auto_configure:
	dh_auto_configure -- \
	    -Dsystemd=enabled \
	    -Dlocal-llhttp=false \
	    -Dtun-tests=false
EOF
  chmod +x "${source_tree}/debian/rules"
  cat > "${source_tree}/debian/changelog" <<EOF
${package} (${debian_version}) ${distribution}; urgency=medium

  * Debian source.

 -- Debian Maintainer <maintainer@example.invalid>  Thu, 01 Jan 1970 00:00:00 +0000
EOF

  cat > "${source_tree}/debian/control" <<'EOF'
Source: ocserv
Build-Depends: debhelper-compat (= 13),
               libcjose-dev,
               libkrb5-dev,
               libllhttp-dev,
               liblz4-dev,
               meson

Package: ocserv
Architecture: any
Depends: ${shlibs:Depends}, ${misc:Depends}
Description: test package
EOF
  cat > "${source_tree}/debian/ocserv.sysusers" <<'EOF'
u! ocserv - "OpenConnect VPN server" /run/ocserv
EOF
}

install_fake_rewrap_commands() {
  ln -s /bin/bash "${FAKEBIN}/bash"
  ln -s "$(command -v dirname)" "${FAKEBIN}/dirname"
  ln -s "$(command -v date)" "${FAKEBIN}/date"

  cat > "${FAKEBIN}/dpkg-parsechangelog" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
field=""
case "${1:-}" in
  -S*) field="${1#-S}" ;;
  *) echo "unexpected dpkg-parsechangelog command: $*" >&2; exit 99 ;;
esac
first_line="$(head -n1 debian/changelog)"
case "${field}" in
  Version)
    printf '%s\n' "${first_line#*(}" | sed 's/).*//'
    ;;
  Distribution)
    printf '%s\n' "${first_line#*) }" | awk '{gsub(/;/, "", $1); print $1}'
    ;;
  *)
    echo "unexpected dpkg-parsechangelog field: ${field}" >&2
    exit 99
    ;;
esac
SH

  cat > "${FAKEBIN}/dch" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
distribution=""
version=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --distribution)
      distribution="$2"
      shift 2
      ;;
    -v)
      version="$2"
      shift 2
      ;;
    --force-distribution|--force-bad-version)
      shift
      ;;
    *)
      message="$1"
      shift
      ;;
  esac
done
source_name="$(head -n1 debian/changelog | sed 's/ .*//')"
old_changelog="$(cat debian/changelog)"
cat > debian/changelog <<EOF
${source_name} (${version}) ${distribution}; urgency=medium

  * ${message}

 -- Test Maintainer <test@example.invalid>  Thu, 01 Jan 1970 00:00:00 +0000

${old_changelog}
EOF
SH

  chmod +x "${FAKEBIN}/dpkg-parsechangelog" "${FAKEBIN}/dch"
}

@test "noble-build executes the seven Noble stages in order" {
  setup_noble_repo
  install_fake_make
  run_noble_build_direct
  [ "${status}" -eq 0 ]
  calls="$(make_call_targets)"
  [ "${calls}" = $'noble-verify-locks\nnoble-fetch-ocserv\nnoble-rewrap-ocserv\nnoble-src-pkg-ocserv\nnoble-binary-ocserv\nnoble-lint\nnoble-smoke-basic' ]
}

@test "noble-build exports Noble default versions and amd64 architecture" {
  setup_noble_repo
  install_fake_make
  run_noble_build_direct
  [ "${status}" -eq 0 ]
  vars="$(unique_make_env_rows)"
  [ "${vars}" = $'1.5.0-1\t1.5.0-1~ubuntu24.04.2\tnoble\tamd64' ]
}

@test "noble-build preserves TARGET_ARCH override without cross-build setup" {
  setup_noble_repo
  install_fake_make
  run_noble_build_direct_with_arch arm64
  [ "${status}" -eq 0 ]
  vars="$(unique_make_env_rows)"
  [ "${vars}" = $'1.5.0-1\t1.5.0-1~ubuntu24.04.2\tnoble\tarm64' ]
  [[ ! -e "${NOBLE_REPO}/cross-build-requested" ]]
}

@test "noble env only knows the ocserv source package" {
  setup_noble_repo

  run bash -c "cd '${NOBLE_REPO}' && REPO_ROOT='${NOBLE_REPO}' bash -c '. scripts/_common.sh; . scripts/noble-env.sh; noble_package_vars node-undici'"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"usage:"*"ocserv"* ]]
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

@test "make noble-build without TARGET_ARCH lets noble script auto-detect architecture" {
  setup_noble_repo
  install_fake_make

  run bash -c "cd '${NOBLE_REPO}' && unset TARGET_ARCH && FAKE_DPKG_ARCH=arm64 PATH='${FAKEBIN}:${PATH}' '${SYSTEM_MAKE}' noble-build"

  [ "${status}" -eq 0 ]
  vars="$(unique_make_env_rows)"
  [ "${vars}" = $'1.5.0-1\t1.5.0-1~ubuntu24.04.2\tnoble\tarm64' ]
  [[ "${vars}" != *$'\tnoble\t' ]]
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

@test "noble-rewrap-ocserv default version adds a Noble changelog entry" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -eq 0 ]
  changelog="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0/debian/changelog"
  [ "$(head -n1 "${changelog}")" = "ocserv (1.5.0-1~ubuntu24.04.2) noble; urgency=medium" ]
  grep -Fq -- "ocserv (1.5.0-1) unstable; urgency=medium" "${changelog}"
}

@test "noble-rewrap-ocserv rejects an already rewrapped changelog" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1~ubuntu24.04.2" noble

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already rewrapped"* ]]
}

@test "noble-rewrap-ocserv same-version override rewrites distribution only" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1"

  run bash -c "cd '${NOBLE_REPO}' && OCSERV_NOBLE_VERSION=1.5.0-1 PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -eq 0 ]
  changelog="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0/debian/changelog"
  [ "$(head -n1 "${changelog}")" = "ocserv (1.5.0-1) noble; urgency=medium" ]
  grep -Fq -- "-Dlocal-llhttp=true" "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0/debian/rules"
}

@test "noble-rewrap-ocserv same-version override rejects already Noble changelog" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1" noble

  run bash -c "cd '${NOBLE_REPO}' && OCSERV_NOBLE_VERSION=1.5.0-1 PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already rewrapped"* ]]
}

@test "noble-rewrap-ocserv switches the build to the bundled llhttp" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"configured to build with bundled llhttp"* ]]
  source_tree="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0"
  grep -Fq -- "-Dlocal-llhttp=true \\" "${source_tree}/debian/rules"
  ! grep -Fq -- "-Dlocal-llhttp=false" "${source_tree}/debian/rules"
  ! grep -Fq -- "libllhttp" "${source_tree}/debian/control"
  grep -Fxq -- "               libkrb5-dev," "${source_tree}/debian/control"
  grep -Fxq -- "               liblz4-dev," "${source_tree}/debian/control"
}

@test "noble-rewrap-ocserv removes a qualified inline libllhttp-dev build dependency" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1"
  control_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0/debian/control"
  cat > "${control_file}" <<'EOF'
Source: ocserv
Build-Depends: debhelper-compat (= 13), libcjose-dev, libllhttp-dev (>= 9) <!nocheck>, meson

Package: ocserv
Architecture: any
Depends: libllhttp9.2, ${misc:Depends}
Description: test package
EOF

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "Build-Depends: debhelper-compat (= 13), libcjose-dev," "${control_file}"
  grep -Fxq -- "               libssl-dev, meson" "${control_file}"
  ! grep -Eq -- "^Build-Depends:.*libllhttp" "${control_file}"
  # Only Build-Depends is rewritten.
  grep -Fxq -- 'Depends: libllhttp9.2, ${misc:Depends}' "${control_file}"
}

@test "noble-rewrap-ocserv fails when the bundled llhttp source is missing" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1"
  source_tree="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0"
  rm -r "${source_tree}/src/llhttp"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing bundled llhttp source"* ]]
  [ "$(head -n1 "${source_tree}/debian/changelog")" = "ocserv (1.5.0-1) unstable; urgency=medium" ]
}

@test "noble-rewrap-ocserv adds explicit libssl build dependency" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -eq 0 ]
  control_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0/debian/control"
  grep -Fq -- "libcjose-dev," "${control_file}"
  grep -Fq -- "libssl-dev," "${control_file}"
}

@test "noble-rewrap-ocserv downgrades sysusers strict user syntax for Noble" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -eq 0 ]
  sysusers_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0/debian/ocserv.sysusers"
  grep -Fq -- 'u ocserv - "OpenConnect VPN server" /run/ocserv' "${sysusers_file}"
  ! grep -Fq -- "u!" "${sysusers_file}"
}

@test "noble source package fails early when ocserv dh is missing" {
  setup_noble_repo
  install_fake_source_package_commands 0
  create_noble_source_tree ocserv "1.5.0"
  old_artifact="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv_1.5.0-1~ubuntu24.04.2.old"
  : > "${old_artifact}"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}' /bin/bash scripts/noble-build-source-package.sh ocserv"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing required source package command: dh"* ]]
  [[ "${output}" == *"sudo apt-get install -y --no-install-recommends debhelper"* ]]
  [[ "${output}" != *"dh-nodejs"* ]]
  [ -f "${old_artifact}" ]
  [ ! -e "${NOBLE_REPO}/dpkg-buildpackage-calls" ]
}

@test "noble source package builds dsc when host clean commands exist" {
  setup_noble_repo
  install_fake_source_package_commands 1
  create_noble_source_tree ocserv "1.5.0"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}' /bin/bash scripts/noble-build-source-package.sh ocserv"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "dpkg-buildpackage -S -d -us -uc" "${NOBLE_REPO}/dpkg-buildpackage-calls"
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv_1.5.0-1~ubuntu24.04.2.dsc" ]
}

install_fake_smoke_tools() {
  cat > "${FAKEBIN}/dpkg-deb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
field="${3:-}"
case "${field}" in
  Package) printf '%s\n' "ocserv" ;;
  Version) printf '%s\n' "1.5.0-1~ubuntu24.04.2" ;;
  Architecture) printf '%s\n' "${TARGET_ARCH:?TARGET_ARCH not exported}" ;;
  Depends) printf '%s\n' "${FAKE_DEB_DEPENDS:-libc6, libgnutls30t64}" ;;
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
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.2_amd64.deb"

  run bash -c "cd '${NOBLE_REPO}' && NOBLE_DOCKER_CMD='sudo docker' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-smoke-test.sh"

  [ "${status}" -eq 0 ]
  grep -Fq -- "sudo docker run --rm" "${NOBLE_REPO}/sudo-calls"
  grep -Fq -- " bash ocserv_1.5.0-1~ubuntu24.04.2_amd64.deb 1.5.0-1~ubuntu24.04.2 amd64 1.5.0" "${NOBLE_REPO}/sudo-calls"
  # No local libllhttp APT repo is mounted into the smoke container.
  ! grep -Fq -- ":/repo:ro" "${NOBLE_REPO}/sudo-calls"
  [ ! -e "${NOBLE_REPO}/docker-calls" ]
}

@test "noble-smoke-basic rejects an ocserv deb that depends on libllhttp" {
  setup_noble_repo
  install_fake_smoke_tools
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.2_amd64.deb"

  run bash -c "cd '${NOBLE_REPO}' && FAKE_DEB_DEPENDS='libc6, libllhttp9.2 (>= 9.2)' NOBLE_DOCKER_CMD='sudo docker' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-smoke-test.sh"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unexpectedly includes libllhttp"* ]]
  [ ! -e "${NOBLE_REPO}/sudo-calls" ]
}

@test "noble-smoke-basic logs host dpkg architecture before container smoke" {
  setup_noble_repo
  install_fake_smoke_tools
  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture) printf '%s\n' "amd64" ;;
  *) exit 99 ;;
esac
SH
  chmod +x "${FAKEBIN}/dpkg"
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.2_amd64.deb"

  run bash -c "cd '${NOBLE_REPO}' && NOBLE_DOCKER_CMD='sudo docker' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-smoke-test.sh"

  [ "${status}" -eq 0 ]
  grep -Fq -- "noble-smoke-basic: host dpkg architecture: amd64" <<<"${output}"
}

@test "noble-smoke-basic logs unavailable when host architecture lookup fails" {
  setup_noble_repo
  install_fake_smoke_tools
  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture) exit 17 ;;
  *) exit 99 ;;
esac
SH
  chmod +x "${FAKEBIN}/dpkg"
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.2_amd64.deb"

  run bash -c "cd '${NOBLE_REPO}' && NOBLE_DOCKER_CMD='sudo docker' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-smoke-test.sh"

  [ "${status}" -eq 0 ]
  grep -Fq -- "noble-smoke-basic: host dpkg architecture: unavailable" <<<"${output}"
}

@test "noble-smoke-basic matches version output without pipefail-sensitive pipeline" {
  grep -Fq -- 'version_output="$(ocserv --version 2>&1 || true)"' "${REPO_ROOT}/scripts/noble-smoke-test.sh"
  grep -Fq -- 'printf' "${REPO_ROOT}/scripts/noble-smoke-test.sh"
  grep -Fq -- '${version_output}' "${REPO_ROOT}/scripts/noble-smoke-test.sh"
  ! grep -Fq -- 'ocserv --version | grep -F "1.5.0"' "${REPO_ROOT}/scripts/noble-smoke-test.sh"
}

install_fake_noble_binary_sbuild() {
  local exit_status="${1:-0}"
  cat > "${FAKEBIN}/sbuild" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > "${NOBLE_REPO}/sbuild-args"
printf '%s\n' "Installing build dependencies"
printf '%s\n' "Reading package lists..."
printf '%s\n' "Building dependency tree..." >&2
if [[ "${exit_status}" -ne 0 ]]; then
  exit "${exit_status}"
fi
build_dir=""
arch="\${TARGET_ARCH:?TARGET_ARCH not exported}"
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
case "\${*: -1}" in
  *ocserv_*.dsc)
    version="\${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.2}"
    touch "\${build_dir}/ocserv_\${version}_\${arch}.deb"
    touch "\${build_dir}/ocserv_\${version}_\${arch}.changes"
    touch "\${build_dir}/ocserv_\${version}_\${arch}.buildinfo"
    ;;
  *)
    echo "unexpected dsc argument: \${*: -1}" >&2
    exit 99
    ;;
esac
SH
  chmod +x "${FAKEBIN}/sbuild"
}

install_fake_failing_sbuild_with_build_log() {
  cat > "${FAKEBIN}/sbuild" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > "${NOBLE_REPO}/sbuild-args"
build_dir=""
prev=""
for arg in "\$@"; do
  if [[ "\${prev}" == "--build-dir" ]]; then build_dir="\${arg}"; fi
  case "\${arg}" in
    --build-dir=*) build_dir="\${arg#--build-dir=}" ;;
  esac
  prev="\${arg}"
done
mkdir -p "\${build_dir}"
printf '%s\n' \
  "dh_auto_build --buildsystem=meson" \
  "../src/worker-http.c:42:10: fatal error: llhttp.h: No such file or directory" \
  "dpkg-buildpackage: error: debian/rules binary subprocess returned exit status 2" \
  > "\${build_dir}/ocserv_1.5.0-1~ubuntu24.04.2_amd64.build"
printf '%s\n' "E: Build failure (dpkg-buildpackage died)" >&2
exit 42
SH
  chmod +x "${FAKEBIN}/sbuild"
}

create_ocserv_dsc() {
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv_1.5.0-1~ubuntu24.04.2.dsc"
}

assert_sbuild_common_args() {
  local args_file="$1"
  local expected_arch="${2:-amd64}"
  grep -Fxq -- "--chroot-mode=schroot" "${args_file}"
  grep -Fxq -- "--chroot=noble-${expected_arch}" "${args_file}"
  grep -Fxq -- "-d" "${args_file}"
  grep -Fxq -- "noble" "${args_file}"
  grep -Fq -- "--arch=${expected_arch}" "${args_file}"
  grep -Fxq -- "--build-dir" "${args_file}"
  grep -Fxq -- "--no-run-lintian" "${args_file}"
}

@test "noble-binary-ocserv hides successful sbuild dependency output and passes no extra packages" {
  setup_noble_repo
  install_fake_noble_binary_sbuild
  create_ocserv_dsc

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-ocserv.sh > '${NOBLE_REPO}/script-output' 2>&1"

  [ "${status}" -eq 0 ]
  if grep -Fq -- "Installing build dependencies" "${NOBLE_REPO}/script-output"; then
    cat "${NOBLE_REPO}/script-output" >&2
    return 1
  fi
  if grep -Fq -- "Reading package lists..." "${NOBLE_REPO}/script-output"; then
    cat "${NOBLE_REPO}/script-output" >&2
    return 1
  fi
  if grep -Fq -- "Building dependency tree..." "${NOBLE_REPO}/script-output"; then
    cat "${NOBLE_REPO}/script-output" >&2
    return 1
  fi
  assert_sbuild_common_args "${NOBLE_REPO}/sbuild-args"
  if grep -Eq -- "--extra-(package|repository)" "${NOBLE_REPO}/sbuild-args"; then
    false
  fi
  grep -Fq -- "ocserv_1.5.0-1~ubuntu24.04.2.dsc" "${NOBLE_REPO}/sbuild-args"
}

@test "noble-binary-ocserv prints original sbuild output on failure" {
  setup_noble_repo
  install_fake_noble_binary_sbuild 43
  create_ocserv_dsc

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-ocserv.sh"

  [ "${status}" -eq 43 ]
  [[ "${output}" == *"Installing build dependencies"* ]]
  [[ "${output}" == *"Reading package lists..."* ]]
  [[ "${output}" == *"Building dependency tree..."* ]]
}

@test "noble-binary-ocserv prints latest build log tail on sbuild failure" {
  setup_noble_repo
  install_fake_failing_sbuild_with_build_log
  create_ocserv_dsc

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-ocserv.sh"

  [ "${status}" -eq 42 ]
  [[ "${output}" == *"E: Build failure (dpkg-buildpackage died)"* ]]
  [[ "${output}" == *"latest sbuild build log:"* ]]
  [[ "${output}" == *"ocserv_1.5.0-1~ubuntu24.04.2_amd64.build"* ]]
  [[ "${output}" == *"llhttp.h: No such file or directory"* ]]
}

@test "noble-binary-ocserv uses TARGET_ARCH-specific source and binary paths" {
  setup_noble_repo
  install_fake_noble_binary_sbuild
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/arm64/source/ocserv"
  touch "${NOBLE_REPO}/build/ubuntu/noble/arm64/source/ocserv/ocserv_1.5.0-1~ubuntu24.04.2.dsc"

  run bash -c "cd '${NOBLE_REPO}' && TARGET_ARCH=arm64 PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-ocserv.sh"
  [ "${status}" -eq 0 ]
  assert_sbuild_common_args "${NOBLE_REPO}/sbuild-args" arm64
  ! grep -Fq -- "--extra-package" "${NOBLE_REPO}/sbuild-args"
  [ "$(tail -n 1 "${NOBLE_REPO}/sbuild-args")" = "${NOBLE_REPO}/build/ubuntu/noble/arm64/source/ocserv/ocserv_1.5.0-1~ubuntu24.04.2.dsc" ]
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/arm64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.2_arm64.deb" ]
}

@test "noble-binary-ocserv requires the ocserv source package" {
  setup_noble_repo
  install_fake_noble_binary_sbuild

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-ocserv.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run noble-src-pkg-ocserv first"* ]]
  [ ! -e "${NOBLE_REPO}/sbuild-args" ]
}
