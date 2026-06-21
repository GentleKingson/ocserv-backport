load helpers/bats-helper.bash
PROVISIONER="${REPO_ROOT}/scripts/runner-provisioner.sh"
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NAME26="0123456789ABCDEFGHJKMNPQRS"

@test "provisioner is self-contained (sources without _common.sh)" {
  run bash -c "set +e; cd /tmp; source '${PROVISIONER}'; echo sourced-ok"
  echo "$output" | grep -q sourced-ok
}

@test "load_provisioner_config: clears inherited RUNNER_* env; only config provides values" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  # Pre-set a BOGUS inherited value; load must clear it (not inherit).
  run bash -c "set +e; source '${PROVISIONER}'; RUNNER_MEMORY=bogus-inherited; load_provisioner_config '${tmpcfg}'; echo \"MEM=[\${RUNNER_MEMORY}]\""
  echo "$output" | grep -q 'MEM=\[6g\]'
  rm -f "$tmpcfg"
}

@test "load_provisioner_config: rejects unknown RUNNER_* key" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\nRUNNER_EVIL=injected\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: rejects duplicate key" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\nRUNNER_URL=y\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: one-key-per-line; rejects whitespace in value" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_CPUS=2 RUNNER_MEMORY=6g\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: dies on missing file / missing required key" {
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config /nope.conf; echo rc=\$?"
  [ "$status" -ne 0 ]
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: enforces fixed URL/LABEL/NETWORK values" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<EOF
RUNNER_URL=https://evil.example.com
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]   # URL not the fixed repo URL -> rejected
  rm -f "$tmpcfg"
}

@test "generate_runner_name: ci-build-<26 Crockford Base32 incl S/Z>; two differ" {
  run bash -c "set +e; source '${PROVISIONER}'; generate_runner_name"
  echo "$output" | grep -qE '^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$'
  run bash -c "set +e; source '${PROVISIONER}'; printf '%s\n%s\n' \"\$(generate_runner_name)\" \"\$(generate_runner_name)\""
  [ "$(sed -n 1p <<<"$output")" != "$(sed -n 2p <<<"$output")" ]
}

@test "valid_runner_name + parse_timeout_to_seconds bounds [5m,60m]" {
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name ci-build-${NAME26} && echo ok"; echo "$output" | grep -q ok
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 45m"; [ "$output" = "2700" ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 1m; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 90m; echo rc=\$?"; [ "$status" -ne 0 ]
}

# ---- Task 2: parse_args ----

@test "parse_args: --registration-token-stdin / --dry-run" {
  run bash -c "set +e; source '${PROVISIONER}'; TOKEN_STDIN=0; parse_args --registration-token-stdin --dry-run; printf 'T=%s D=%s\n' \"\$TOKEN_STDIN\" \"\$BOOTSTRAP_DRY_RUN\""
  echo "$output" | grep -q 'T=1 D=1'
}

@test "parse_args: --runner-name DRY-RUN only; live FORBIDDEN" {
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=1; parse_args --runner-name ci-build-DRYTEST; printf 'N=%s\n' \"\$RUNNER_NAME\""
  echo "$output" | grep -q 'N=ci-build-DRYTEST'
  # live mode rejects ANY --runner-name, even valid-shape (CSPRNG-only in live)
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=0; parse_args --runner-name ci-build-${NAME26}; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "parse_args: REJECTS all container-weakening flags" {
  for bad in --docker-arg --privileged --mount /x --cap-add SYS_ADMIN --pid host --ipc host --uts host --userns host --network host --image evil --label x --env SECRET --device /dev/sda -v /etc:/etc --volume /root:/root; do
    run bash -c "set +e; source '${PROVISIONER}'; parse_args '$bad'; echo rc=\$?"
    [ "$status" -ne 0 ] || { echo "FAIL: accepted $bad"; exit 1; }
  done
}

@test "parse_args: rejects unknown flag" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_args --bogus; echo rc=\$?"
  [ "$status" -ne 0 ]
}

# ---- Task 3: build_docker_run_args, preflight, cleanup, audit, main ----

mkcfg() {  # one key per line
cat >"$1" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
}
docker_argv_lines() {
  bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '$1'; build_docker_run_args '$2'" \
    | while IFS= read -r -d '' a; do printf '%s\n' "$a"; done
}

@test "build_docker_run_args: -i + --interactive + --stop-timeout + 3 ownership labels + safe params" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"; rm -f "$tmpcfg"
  echo "$out" | grep -qx -- '-i'
  echo "$out" | grep -qx -- '--interactive'
  echo "$out" | grep -q -- '--stop-timeout=10'
  echo "$out" | grep -q -- 'com.ocserv-ci.managed-by=runner-provisioner'
  echo "$out" | grep -q -- 'com.ocserv-ci.phase=1'
  echo "$out" | grep -q -- 'com.ocserv-ci.runner-name=ci-build-TEST'
  for f in --rm --init --read-only --user=10001:10001 --cap-drop=ALL --security-opt=no-new-privileges:true --pull=never; do
    echo "$out" | grep -qx -- "$f" || { echo "MISSING $f"; exit 1; }
  done
  echo "$out" | grep -q -- '--env'
  echo "$out" | grep -q -- 'RUNNER_URL=https://github.com/GentleKingson/ocserv-backport'
  echo "$out" | grep -qx -- "ghcr.io/owner/img@sha256:${DIG64}"
  ! echo "$out" | grep -q -- '--privileged'
  ! echo "$out" | grep -q -- 'docker.sock'
  ! echo "$out" | grep -qE -- '^-v$|--volume'
}

@test "assert_image_is_digest: 64-hex ok; short/tag rejected" {
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'x@sha256:${DIG64}'; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'debian:trixie'; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "assert_config_root_owned: stub _config_metadata; root:root 600 regular pass; others die" {
  tmpf="$(mktemp)"
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata(){ printf 'root:root 600 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata(){ printf 'builder:builder 600 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata(){ printf 'root:root 640 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata(){ printf 'root:root 600 symlink'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"; [ "$status" -ne 0 ]
  rm -f "$tmpf"
}

@test "assert_parent_paths_trusted: stub _path_metadata; root:root 755 directory ok; non-root/symlink/world-writable/missing die" {
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'root:root 755 directory'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'builder:builder 755 directory'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'root:root 777 directory'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'root:root 755 symlink'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'missing'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "preflight_image_cached / preflight_name_free: stubbed docker" {
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ return 0; }; preflight_image_cached 'img@sha256:${DIG64}'; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ return 1; }; preflight_image_cached 'img@sha256:${DIG64}'; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ return 1; }; preflight_name_free ci-build-X; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ return 0; }; preflight_name_free ci-build-X; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "preflight_no_orphan_managed: docker ps FAILS -> die (not masked as empty)" {
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ [[ \"\$1\" == ps ]] && return 1; return 0; }; preflight_no_orphan_managed; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "preflight_no_orphan_managed: docker ps -aq returns exited id -> die" {
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ [[ \"\$1\" == ps ]] && { echo deadid; return 0; }; return 0; }; preflight_no_orphan_managed; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "cleanup_this_container: rm called ONLY when all 3 labels match (real container_label stub)" {
  run_cleanup() {
    local mb="$1" ph="$2" rn="$3" name="$4"
    local marker; marker="$(mktemp)"
    bash -c "set +e; source '${PROVISIONER}'
      container_label(){
        case \"\$2\" in
          com.ocserv-ci.managed-by) printf '%s' \"${mb}\" ;;
          com.ocserv-ci.phase)      printf '%s' \"${ph}\" ;;
          com.ocserv-ci.runner-name)printf '%s' \"${rn}\" ;;
        esac; }
      # Override docker: inspect ok; rm writes to marker file (impl redirects rm stdout).
      docker(){
        [[ \"\$1\" == inspect ]] && return 0
        if [[ \"\$1\" == rm ]]; then echo rm-ran >>'${marker}'; return 0; fi
        return 0; }
      cleanup_this_container '${name}'"
    if [[ -s "${marker}" ]]; then echo "rm-called"; else echo "no-rm"; fi
    rm -f "${marker}"
  }
  # 1. all 3 match -> rm called
  [[ "$(run_cleanup runner-provisioner 1 ci-build-X ci-build-X)" == "rm-called" ]]
  # 2/3/4. each label mismatch -> no rm
  [[ "$(run_cleanup evil 1 ci-build-X ci-build-X)" == "no-rm" ]]
  [[ "$(run_cleanup runner-provisioner 9 ci-build-X ci-build-X)" == "no-rm" ]]
  [[ "$(run_cleanup runner-provisioner 1 ci-build-OTHER ci-build-X)" == "no-rm" ]]
}

@test "cleanup_this_container: container absent -> safe return, no rm" {
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ [[ \"\$1\" == inspect ]] && return 1; echo rm-ran; return 0; }; cleanup_this_container ci-build-X; echo rc=\$?"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'rm-ran'
}

@test "acquire_single_slot: live 2nd rejected; dry-run skips" {
  tmplock="$(mktemp)"; ( flock -n 9 && sleep 2 ) 9>"${tmplock}" & sleep 0.3
  run bash -c "set +e; source '${PROVISIONER}'; SINGLE_SLOT_LOCK='${tmplock}'; BOOTSTRAP_DRY_RUN=0; acquire_single_slot; echo rc=\$?"; [ "$status" -ne 0 ]
  wait; rm -f "${tmplock}"
  tmplock="$(mktemp)"; ( flock -n 9 && sleep 2 ) 9>"${tmplock}" & sleep 0.3
  run bash -c "set +e; source '${PROVISIONER}'; SINGLE_SLOT_LOCK='${tmplock}'; BOOTSTRAP_DRY_RUN=1; acquire_single_slot; echo rc=\$?"; [ "$status" -eq 0 ]
  wait; rm -f "${tmplock}"
}

@test "ensure_audit_sink: creates root:root dir 0750 + log 0640 regular (stubbed metadata + install)" {
  tmpdir="$(mktemp -d)"
  # Stub install (macOS non-root can't chown root), chown, chmod; _path/_config
  # metadata stubs return the expected trusted values so verify passes.
  run bash -c "set +e; source '${PROVISIONER}'; AUDIT_DIR='${tmpdir}/a'; AUDIT_LOG='${tmpdir}/a/lifecycle.log'; _config_metadata(){ printf 'root:root 640 regular'; }; _path_metadata(){ printf 'root:root 750 directory'; }; install(){ mkdir -p \"\${!#}\"; }; chown(){ :; }; chmod(){ :; }; ensure_audit_sink; echo rc=\$?"
  [ "$status" -eq 0 ]
  rm -rf "$tmpdir"
}

@test "main --dry-run: docker+timeout printed; NEVER token; rc 0 (stubs)" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; echo 'ghs_SUPERSECRET_xyz' | bash -c '
    source \"${PROVISIONER}\"
    current_uid(){ echo 0; }
    _config_metadata(){ printf \"root:root 600 regular\"; }
    _path_metadata(){ printf \"root:root 755 directory\"; }
    docker(){ return 0; }
    PROVISIONER_CONFIG=\"${tmpcfg}\" main --registration-token-stdin --dry-run --runner-name ci-build-DRYTEST
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -q 'rc=0'; echo "$output" | grep -qi 'timeout'
  ! echo "$output" | grep -q 'SUPERSECRET'
}

@test "main: rejects non-root" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; bash -c '
    source \"${PROVISIONER}\"; current_uid(){ echo 1000; }
    PROVISIONER_CONFIG=\"${tmpcfg}\" main --registration-token-stdin --dry-run --runner-name ci-build-X
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -qv 'rc=0'
}
