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
  cp "${REPO_ROOT}/scripts/_target_arch.sh" "${NOBLE_REPO}/scripts/_target_arch.sh"
  cp "${REPO_ROOT}/scripts/_target_paths.sh" "${NOBLE_REPO}/scripts/_target_paths.sh"
  cp "${REPO_ROOT}/scripts/_dsc.sh" "${NOBLE_REPO}/scripts/_dsc.sh"
  if [[ -f "${REPO_ROOT}/scripts/_noble_sbuild.sh" ]]; then
    cp "${REPO_ROOT}/scripts/_noble_sbuild.sh" "${NOBLE_REPO}/scripts/_noble_sbuild.sh"
  fi
  if [[ -f "${REPO_ROOT}/scripts/noble-env.sh" ]]; then
    cp "${REPO_ROOT}/scripts/noble-env.sh" "${NOBLE_REPO}/scripts/noble-env.sh"
  fi
  if [[ -d "${REPO_ROOT}/packaging" ]]; then
    cp -R "${REPO_ROOT}/packaging" "${NOBLE_REPO}/packaging"
  fi
  cp "${REPO_ROOT}/Makefile" "${NOBLE_REPO}/Makefile"
  local script
  for script in \
    noble-build.sh \
    noble-rewrap-changelog.sh \
    noble-build-repo.sh \
    noble-build-source-package.sh \
    noble-build-binary-node-undici.sh \
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
    version="\${NODE_UNDICI_NOBLE_VERSION:-7.3.0+dfsg1+~cs24.12.11-1}"
    dsc="\${PWD%/*}/node-undici_\${version}.dsc"
    printf 'Source: node-undici\nVersion: %s\n' "\${version}" > "\${dsc}"
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
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/${package}/${package}-${version}"
}

create_noble_rewrap_source_tree() {
  local package="$1"
  local upstream_version="$2"
  local debian_version="$3"
  local distribution="${4:-unstable}"
  local source_tree="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/${package}/${package}-${upstream_version}"

  mkdir -p "${source_tree}/debian"
  cat > "${source_tree}/debian/rules" <<'EOF'
#!/usr/bin/make -f

%:
	dh $@
EOF
  chmod +x "${source_tree}/debian/rules"
  cat > "${source_tree}/debian/changelog" <<EOF
${package} (${debian_version}) ${distribution}; urgency=medium

  * Debian source.

 -- Debian Maintainer <maintainer@example.invalid>  Thu, 01 Jan 1970 00:00:00 +0000
EOF

  if [[ "${package}" == "ocserv" ]]; then
    cat > "${source_tree}/debian/control" <<'EOF'
Source: ocserv
Build-Depends: debhelper-compat (= 13),
               libcjose-dev,
               meson

Package: ocserv
Architecture: any
Depends: ${shlibs:Depends}, ${misc:Depends}
Description: test package
EOF
    cat > "${source_tree}/debian/ocserv.sysusers" <<'EOF'
u! ocserv - "OpenConnect VPN server" /run/ocserv
EOF
  else
    cat > "${source_tree}/debian/control" <<'EOF'
Source: node-undici
Build-Depends: debhelper-compat (= 13),
               dh-sequence-nodejs

Package: node-undici
Architecture: all
Depends: ${misc:Depends}
Description: test package
EOF
  fi

  # node-undici carries llparse component tsconfigs upstream; the Noble
  # configure hook injects paths mappings into each one that compiles TS.
  if [[ "${package}" == "node-undici" ]]; then
    local component
    for component in fastify-busboy llhttp llparse llparse-builder llparse-frontend; do
      mkdir -p "${source_tree}/${component}"
      cat > "${source_tree}/${component}/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "strict": true,
    "target": "es2017",
    "module": "commonjs",
    "moduleResolution": "node",
    "outDir": "./lib",
    "declaration": true,
    "pretty": true,
    "sourceMap": true
  },
  "include": [
    "src/**/*.ts"
  ]
}
JSON
    done
  fi
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
  [ "${vars}" = $'7.3.0+dfsg1+~cs24.12.11-1\t7.3.0+dfsg1+~cs24.12.11-1\t1.5.0-1\t1.5.0-1~ubuntu24.04.1\tnoble\tamd64' ]
}

@test "noble-build preserves TARGET_ARCH override without cross-build setup" {
  setup_noble_repo
  install_fake_make
  run_noble_build_direct_with_arch arm64
  [ "${status}" -eq 0 ]
  vars="$(unique_make_env_rows)"
  [ "${vars}" = $'7.3.0+dfsg1+~cs24.12.11-1\t7.3.0+dfsg1+~cs24.12.11-1\t1.5.0-1\t1.5.0-1~ubuntu24.04.1\tnoble\tarm64' ]
  [[ ! -e "${NOBLE_REPO}/cross-build-requested" ]]
}

@test "noble env defaults node-undici Noble version to Debian version" {
  setup_noble_repo

  run bash -c "cd '${NOBLE_REPO}' && REPO_ROOT='${NOBLE_REPO}' bash -c '. scripts/_common.sh; . scripts/noble-env.sh; printf \"%s\\n\" \"\${NODE_UNDICI_NOBLE_VERSION}\"'"

  [ "${status}" -eq 0 ]
  [ "${output}" = "7.3.0+dfsg1+~cs24.12.11-1" ]
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
  [ "${vars}" = $'7.3.0+dfsg1+~cs24.12.11-1\t7.3.0+dfsg1+~cs24.12.11-1\t1.5.0-1\t1.5.0-1~ubuntu24.04.1\tnoble\tarm64' ]
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

@test "noble-rewrap-node-undici installs undici-types tsconfig paths injection hook once" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -eq 0 ]
  rules_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11/debian/rules"
  [ -f "${rules_file}" ]
  # New marker present exactly once (idempotency across rewrap runs).
  grep -Fq -- "before dh-nodejs configure" "${rules_file}"
  # tsconfig paths injection recipe present.
  grep -Fq -- 'paths["undici-types"]=["../types"]' "${rules_file}"
  grep -Fq -- 'readdirSync(".")' "${rules_file}"
  grep -Fq -- "types/package.json" "${rules_file}"
  grep -Fq -- '"name": "undici-types"' "${rules_file}"
  grep -Fq -- '"version": "7.3.0"' "${rules_file}"

  # Rewrap is idempotent: second run does not duplicate the hook block.
  PATH="${FAKEBIN}:${PATH}" bash "${NOBLE_REPO}/scripts/noble-rewrap-changelog.sh" node-undici >/tmp/rewrap-again.out 2>&1 || true
  [ "$(grep -Fc -- "before dh-nodejs configure" "${rules_file}")" = "1" ]

  # Simulate the binary-build configure hook on the rewrapped source tree.
  source_tree="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11"
  run bash -c "cd '${source_tree}' && make -f debian/rules execute_before_dh_auto_configure"
  [ "${status}" -eq 0 ]
  # paths injected with the expected mapping; no baseUrl; no marker field.
  # One CommonJS node -e line emits four pipe-separated facts, asserted in one line:
  # undici-types mapping | undici-types/* mapping | baseUrl absent | marker field absent.
  for component in fastify-busboy llhttp llparse llparse-builder llparse-frontend; do
    run bash -c "cd '${source_tree}' && node -e 'var c=process.argv[1];var j=require(\"./\"+c+\"/tsconfig.json\");var p=j.compilerOptions.paths;process.stdout.write(JSON.stringify(p[\"undici-types\"])+\"|\"+JSON.stringify(p[\"undici-types/*\"])+\"|\"+(j.compilerOptions.baseUrl===undefined)+\"|\"+(j._nobleUndiciTypesPaths===undefined)+\"\n\")' '${component}'"
    [ "${output}" = '["../types"]|["../types/*"]|true|true' ]
  done
}

@test "noble-rewrap-node-undici migrates legacy build hook to configure hook" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1"

  rules_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11/debian/rules"
  # Seed the exact legacy block produced by commit dcb7443.
  cat >> "${rules_file}" <<'LEGACY'

# Noble backport: generate undici-types package metadata during build.
execute_before_dh_auto_build::
	mkdir -p types
	printf '%s\n' \
		'{' \
		'  "name": "undici-types",' \
		'  "version": "7.3.0",' \
		'  "description": "A stand-alone types package for Undici",' \
		'  "license": "MIT",' \
		'  "types": "index.d.ts",' \
		'  "files": ["*.d.ts"]' \
		'}' > types/package.json
LEGACY

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -eq 0 ]
  [ -f "${rules_file}" ]
  # Legacy build hook must be gone.
  ! grep -Fq -- "execute_before_dh_auto_build::" "${rules_file}"
  ! grep -Fq -- "during build" "${rules_file}"
  # New complete hook present exactly once.
  [ "$(grep -Fc -- "before dh-nodejs configure" "${rules_file}")" = "1" ]
  grep -Fq -- 'paths["undici-types"]=["../types"]' "${rules_file}"
  grep -Fq -- "types/package.json" "${rules_file}"
  grep -Fq -- '"name": "undici-types"' "${rules_file}"
  grep -Fq -- '"version": "7.3.0"' "${rules_file}"
}

@test "noble-rewrap-node-undici upgrades builder-only tsconfig hook to cover llparse components" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1"

  rules_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11/debian/rules"
  # Seed the first tsconfig-paths hook variant: it had the final marker, but
  # only injected llparse-builder/tsconfig.json.
  cat >> "${rules_file}" <<'LEGACY'

# Noble backport: generate undici-types metadata and TypeScript paths before dh-nodejs configure.
execute_before_dh_auto_configure::
	mkdir -p types
	printf '%s\n' '{' '  "name": "undici-types",' '  "version": "7.3.0",' '  "description": "A stand-alone types package for Undici",' '  "license": "MIT",' '  "types": "index.d.ts",' '  "files": ["*.d.ts"]' '}' > types/package.json
	node -e 'const fs=require("fs"),p="llparse-builder/tsconfig.json";const j=JSON.parse(fs.readFileSync(p,"utf8"));j.compilerOptions=j.compilerOptions||{};j.compilerOptions.paths=j.compilerOptions.paths||{};if(JSON.stringify(j.compilerOptions.paths["undici-types"])===JSON.stringify(["../types"])){process.exit(0);}j.compilerOptions.paths["undici-types"]=["../types"];j.compilerOptions.paths["undici-types/*"]=["../types/*"];fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n");'
LEGACY

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -eq 0 ]
  [ "$(grep -Fc -- "before dh-nodejs configure" "${rules_file}")" = "1" ]
  grep -Fq -- 'readdirSync(".")' "${rules_file}"
  ! grep -Fq -- 'p="llparse-builder/tsconfig.json"' "${rules_file}"

  source_tree="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11"
  run bash -c "cd '${source_tree}' && make -f debian/rules execute_before_dh_auto_configure"
  [ "${status}" -eq 0 ]
  for component in fastify-busboy llhttp llparse llparse-builder llparse-frontend; do
    run bash -c "cd '${source_tree}' && node -e 'var c=process.argv[1];var j=require(\"./\"+c+\"/tsconfig.json\");var p=j.compilerOptions.paths;process.stdout.write(JSON.stringify(p[\"undici-types\"])+\"|\"+JSON.stringify(p[\"undici-types/*\"])+\"\n\")' '${component}'"
    [ "${output}" = '["../types"]|["../types/*"]' ]
  done
}

@test "noble-rewrap-node-undici migrates configure-only hook to tsconfig-paths hook" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1"

  rules_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11/debian/rules"
  # Seed the configure-only block produced by commit ddec814 (no tsconfig paths).
  cat >> "${rules_file}" <<'LEGACY'

# Noble backport: generate undici-types package metadata before dh-nodejs links components.
execute_before_dh_auto_configure::
	mkdir -p types
	printf '%s\n' \
		'{' \
		'  "name": "undici-types",' \
		'  "version": "7.3.0",' \
		'  "description": "A stand-alone types package for Undici",' \
		'  "license": "MIT",' \
		'  "types": "index.d.ts",' \
		'  "files": ["*.d.ts"]' \
		'}' > types/package.json
LEGACY

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -eq 0 ]
  [ -f "${rules_file}" ]
  # Configure-only legacy marker must be gone, replaced by the complete hook.
  ! grep -Fq -- "before dh-nodejs links components" "${rules_file}"
  [ "$(grep -Fc -- "before dh-nodejs configure" "${rules_file}")" = "1" ]
  grep -Fq -- 'paths["undici-types"]=["../types"]' "${rules_file}"
}

@test "noble-rewrap-node-undici migrates both legacy hook blocks at once" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1"

  rules_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11/debian/rules"
  # Seed BOTH legacy blocks (a tree rewrapped at dcb7443 then again at ddec814).
  cat >> "${rules_file}" <<'LEGACY'

# Noble backport: generate undici-types package metadata during build.
execute_before_dh_auto_build::
	mkdir -p types
	printf '%s\n' '{' '  "name": "undici-types",' '}' > types/package.json

# Noble backport: generate undici-types package metadata before dh-nodejs links components.
execute_before_dh_auto_configure::
	mkdir -p types
	printf '%s\n' '{' '  "name": "undici-types",' '}' > types/package.json
LEGACY

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -eq 0 ]
  [ -f "${rules_file}" ]
  # Both legacy blocks must be gone.
  ! grep -Fq -- "during build" "${rules_file}"
  ! grep -Fq -- "before dh-nodejs links components" "${rules_file}"
  ! grep -Fq -- "execute_before_dh_auto_build::" "${rules_file}"
  # Exactly one complete new hook, no duplicate configure target.
  [ "$(grep -Fc -- "before dh-nodejs configure" "${rules_file}")" = "1" ]
  [ "$(grep -Fc -- "execute_before_dh_auto_configure::" "${rules_file}")" = "1" ]
  grep -Fq -- 'paths["undici-types"]=["../types"]' "${rules_file}"
}

@test "noble-rewrap-node-undici same-version path rewrites distribution only" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -eq 0 ]
  changelog="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11/debian/changelog"
  [ "$(head -n1 "${changelog}")" = "node-undici (7.3.0+dfsg1+~cs24.12.11-1) noble; urgency=medium" ]
}

@test "noble-rewrap-node-undici same-version path rejects already Noble changelog" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1" noble

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already rewrapped"* ]]
}

@test "noble-rewrap-node-undici explicit Noble version override keeps dch path" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1"

  run bash -c "cd '${NOBLE_REPO}' && NODE_UNDICI_NOBLE_VERSION='7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -eq 0 ]
  changelog="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici-7.3.0+dfsg1+~cs24.12.11/debian/changelog"
  [ "$(head -n1 "${changelog}")" = "node-undici (7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1) noble; urgency=medium" ]
  grep -Fq -- "node-undici (7.3.0+dfsg1+~cs24.12.11-1) unstable; urgency=medium" "${changelog}"
}

@test "noble-rewrap-node-undici explicit Noble version override rejects already rewrapped changelog" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11" "7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1" noble

  run bash -c "cd '${NOBLE_REPO}' && NODE_UNDICI_NOBLE_VERSION='7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh node-undici"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already rewrapped"* ]]
}

@test "noble-rewrap-ocserv does not install node-undici rules hook" {
  setup_noble_repo
  install_fake_rewrap_commands
  create_noble_rewrap_source_tree ocserv "1.5.0" "1.5.0-1"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-rewrap-changelog.sh ocserv"

  [ "${status}" -eq 0 ]
  rules_file="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv-1.5.0/debian/rules"
  ! grep -Fq -- "execute_before_dh_auto_configure::" "${rules_file}"
  ! grep -Fq -- "undici-types" "${rules_file}"
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

@test "noble source package fails before deleting artifacts when node-undici pkgjs-pjson is missing" {
  setup_noble_repo
  install_fake_source_package_commands 1 0
  create_noble_source_tree node-undici "7.3.0+dfsg1+~cs24.12.11"
  old_artifact="${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici_7.3.0+dfsg1+~cs24.12.11-1.old"
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
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici_7.3.0+dfsg1+~cs24.12.11-1.dsc" ]
}

install_fake_smoke_tools() {
  cat > "${FAKEBIN}/dpkg-deb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
field="${3:-}"
case "${field}" in
  Package) printf '%s\n' "ocserv" ;;
  Version) printf '%s\n' "1.5.0-1~ubuntu24.04.1" ;;
  Architecture) printf '%s\n' "${TARGET_ARCH:?TARGET_ARCH not exported}" ;;
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
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv"
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.1_amd64.deb"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/libllhttp9.2_7.3.0_amd64.deb"

  run bash -c "cd '${NOBLE_REPO}' && NOBLE_DOCKER_CMD='sudo docker' PATH='${FAKEBIN}:${PATH}' bash scripts/noble-smoke-test.sh"

  [ "${status}" -eq 0 ]
  grep -Fq -- "sudo docker run --rm" "${NOBLE_REPO}/sudo-calls"
  [ ! -e "${NOBLE_REPO}/docker-calls" ]
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
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.1_amd64.deb"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/libllhttp9.2_7.3.0_amd64.deb"

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
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/ocserv/ocserv_1.5.0-1~ubuntu24.04.1_amd64.deb"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/libllhttp9.2_7.3.0_amd64.deb"

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

install_fake_dpkg_scanpackages() {
  cat > "${FAKEBIN}/dpkg-scanpackages" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "dpkg-scanpackages \$*" >> "${NOBLE_REPO}/scanpackages-calls"
printf '%s\n' \
  "Package: libllhttp9.2" \
  "Version: 7.3.0+dfsg1+~cs24.12.11-1" \
  "Architecture: all" \
  "" \
  "Package: libllhttp-dev" \
  "Version: 7.3.0+dfsg1+~cs24.12.11-1" \
  "Architecture: all"
SH
  chmod +x "${FAKEBIN}/dpkg-scanpackages"
}

@test "noble-repo copies only libllhttp runtime and development debs" {
  setup_noble_repo
  install_fake_dpkg_scanpackages
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/node-undici"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/node-undici/libllhttp9.2_7.3.0_amd64.deb"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/node-undici/libllhttp-dev_7.3.0_amd64.deb"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/node-undici/node-undici_7.3.0_all.deb"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/node-undici/node-llhttp_7.3.0_all.deb"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-repo.sh"
  [ "${status}" -eq 0 ]
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/libllhttp9.2_7.3.0_amd64.deb" ]
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/libllhttp-dev_7.3.0_amd64.deb" ]
  [ ! -e "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/node-undici_7.3.0_all.deb" ]
  [ ! -e "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/node-llhttp_7.3.0_all.deb" ]
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/Packages" ]
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/Packages.gz" ]
}

@test "noble-repo rejects missing libllhttp runtime or development debs" {
  setup_noble_repo
  install_fake_dpkg_scanpackages
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/node-undici"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/node-undici/libllhttp9.2_7.3.0_amd64.deb"

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-repo.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"libllhttp-dev"* ]]
}

@test "noble-repo uses TARGET_ARCH-specific build and repo paths" {
  setup_noble_repo
  install_fake_dpkg_scanpackages
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/arm64/binary/node-undici"
  touch "${NOBLE_REPO}/build/ubuntu/noble/arm64/binary/node-undici/libllhttp9.2_7.3.0_arm64.deb"
  touch "${NOBLE_REPO}/build/ubuntu/noble/arm64/binary/node-undici/libllhttp-dev_7.3.0_arm64.deb"

  run bash -c "cd '${NOBLE_REPO}' && TARGET_ARCH=arm64 PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-repo.sh"
  [ "${status}" -eq 0 ]
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/arm64/repo/libllhttp9.2_7.3.0_arm64.deb" ]
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/arm64/repo/libllhttp-dev_7.3.0_arm64.deb" ]
  [ ! -d "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo" ]
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
version="\${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.1}"
touch "\${build_dir}/ocserv_\${version}_\${arch}.deb"
touch "\${build_dir}/ocserv_\${version}_\${arch}.changes"
touch "\${build_dir}/ocserv_\${version}_\${arch}.buildinfo"
SH
  chmod +x "${FAKEBIN}/python3" "${FAKEBIN}/sbuild"
}

install_fake_noble_binary_sbuild() {
  local exit_status="${1:-0}"
  cat > "${FAKEBIN}/python3" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "-m" && "\${2:-}" == "http.server" ]]; then
  printf '%s\n' "\$*" > "${NOBLE_REPO}/http-server-args"
  trap 'exit 0' TERM INT
  while true; do sleep 1; done
fi
printf '%s\n' "43123"
SH
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
  *node-undici_*.dsc)
    version="\${NODE_UNDICI_NOBLE_VERSION:-7.3.0+dfsg1+~cs24.12.11-1}"
    touch "\${build_dir}/libllhttp9.2_\${version}_\${arch}.deb"
    touch "\${build_dir}/libllhttp-dev_\${version}_\${arch}.deb"
    touch "\${build_dir}/node-undici_\${version}_\${arch}.changes"
    touch "\${build_dir}/node-undici_\${version}_\${arch}.buildinfo"
    ;;
  *ocserv_*.dsc)
    version="\${OCSERV_NOBLE_VERSION:-1.5.0-1~ubuntu24.04.1}"
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
  chmod +x "${FAKEBIN}/python3" "${FAKEBIN}/sbuild"
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
  "dh_auto_build --buildsystem=nodejs" \
  "error TS2307: Cannot find module 'undici-types' or its corresponding type declarations." \
  "dpkg-buildpackage: error: debian/rules binary subprocess returned exit status 2" \
  > "\${build_dir}/node-undici_7.3.0+dfsg1+~cs24.12.11-1_amd64.build"
printf '%s\n' "E: Build failure (dpkg-buildpackage died)" >&2
exit 42
SH
  chmod +x "${FAKEBIN}/sbuild"
}

create_node_undici_dsc() {
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/node-undici/node-undici_7.3.0+dfsg1+~cs24.12.11-1.dsc"
}

create_ocserv_dsc_and_repo() {
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv"
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/source/ocserv/ocserv_1.5.0-1~ubuntu24.04.1.dsc"
  touch "${NOBLE_REPO}/build/ubuntu/noble/amd64/repo/Packages"
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

@test "noble-binary-node-undici hides successful sbuild dependency output and preserves args" {
  setup_noble_repo
  install_fake_noble_binary_sbuild
  create_node_undici_dsc

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-node-undici.sh > '${NOBLE_REPO}/script-output' 2>&1"

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
  grep -Fq -- "node-undici_7.3.0+dfsg1+~cs24.12.11-1.dsc" "${NOBLE_REPO}/sbuild-args"
  [ -f "${NOBLE_REPO}/build/ubuntu/noble/amd64/binary/node-undici/libllhttp9.2_7.3.0+dfsg1+~cs24.12.11-1_amd64.deb" ]
}

@test "noble-binary-node-undici prints original sbuild output on failure" {
  setup_noble_repo
  install_fake_noble_binary_sbuild 42
  create_node_undici_dsc

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-node-undici.sh"

  [ "${status}" -eq 42 ]
  [[ "${output}" == *"Installing build dependencies"* ]]
  [[ "${output}" == *"Reading package lists..."* ]]
  [[ "${output}" == *"Building dependency tree..."* ]]
}

@test "noble-binary-node-undici prints latest build log tail on sbuild failure" {
  setup_noble_repo
  install_fake_failing_sbuild_with_build_log
  create_node_undici_dsc

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-node-undici.sh"

  [ "${status}" -eq 42 ]
  [[ "${output}" == *"E: Build failure (dpkg-buildpackage died)"* ]]
  [[ "${output}" == *"latest sbuild build log:"* ]]
  [[ "${output}" == *"node-undici_7.3.0+dfsg1+~cs24.12.11-1_amd64.build"* ]]
  [[ "${output}" == *"Cannot find module 'undici-types'"* ]]
}

@test "noble-binary-ocserv hides successful sbuild dependency output and preserves extra repo args" {
  setup_noble_repo
  install_fake_noble_binary_sbuild
  create_ocserv_dsc_and_repo

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' NOBLE_HTTP_STARTUP_SLEEP=0 bash scripts/noble-build-binary-ocserv.sh > '${NOBLE_REPO}/script-output' 2>&1"

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
  grep -Fq -- "--extra-repository=deb [trusted=yes] http://127.0.0.1:" "${NOBLE_REPO}/sbuild-args"
  grep -Fq -- "ocserv_1.5.0-1~ubuntu24.04.1.dsc" "${NOBLE_REPO}/sbuild-args"
}

@test "noble-binary-ocserv prints original sbuild output on failure" {
  setup_noble_repo
  install_fake_noble_binary_sbuild 43
  create_ocserv_dsc_and_repo

  run bash -c "cd '${NOBLE_REPO}' && PATH='${FAKEBIN}:${PATH}' NOBLE_HTTP_STARTUP_SLEEP=0 bash scripts/noble-build-binary-ocserv.sh"

  [ "${status}" -eq 43 ]
  [[ "${output}" == *"Installing build dependencies"* ]]
  [[ "${output}" == *"Reading package lists..."* ]]
  [[ "${output}" == *"Building dependency tree..."* ]]
}

@test "noble-binary-ocserv injects a temporary localhost HTTP repo and cleans it up" {
  setup_noble_repo
  install_fake_http_python_and_sbuild
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/arm64/source/ocserv"
  mkdir -p "${NOBLE_REPO}/build/ubuntu/noble/arm64/repo"
  touch "${NOBLE_REPO}/build/ubuntu/noble/arm64/source/ocserv/ocserv_1.5.0-1~ubuntu24.04.1.dsc"
  touch "${NOBLE_REPO}/build/ubuntu/noble/arm64/repo/Packages"

  run bash -c "cd '${NOBLE_REPO}' && TARGET_ARCH=arm64 PATH='${FAKEBIN}:${PATH}' bash scripts/noble-build-binary-ocserv.sh"
  [ "${status}" -eq 0 ]
  grep -Fq -- "--arch=arm64" "${NOBLE_REPO}/sbuild-args"
  assert_sbuild_common_args "${NOBLE_REPO}/sbuild-args" arm64
  grep -Fq -- "deb [trusted=yes] http://127.0.0.1:43123/ ./" "${NOBLE_REPO}/sbuild-args"
  grep -Fq -- "--bind" "${NOBLE_REPO}/http-server-args"
  grep -Fq -- "127.0.0.1" "${NOBLE_REPO}/http-server-args"
  server_pid="$(cat "${NOBLE_REPO}/http-server-pid")"
  if kill -0 "${server_pid}" 2>/dev/null; then
    echo "HTTP server still running: ${server_pid}" >&2
    return 1
  fi
}
