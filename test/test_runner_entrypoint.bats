load helpers/bats-helper.bash
ENTRYPOINT="${REPO_ROOT}/docker/runner/entrypoint.sh"

# Path-aware stub so /tmp gets noexec while /runner /work don't.
pathaware() {
cat <<'STUB'
current_uid() { echo 10001; }
_findmnt_fstype() { echo tmpfs; }
_findmnt_options() {
  case "$1" in
    /runner|/work) printf '%s\n' 'rw,nosuid,nodev,mode=0700' ;;
    /tmp)          printf '%s\n' 'rw,nosuid,nodev,noexec,mode=1777' ;;
    /)             printf '%s\n' 'ro,relatime' ;;
  esac
}
STUB
}

@test "assert_running_as_10001: stubbable current_uid" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; assert_running_as_10001; echo ok"
  echo "$output" | grep -q ok
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 0; }; assert_running_as_10001; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "assert_rootfs_readonly + assert_tmpfs_workspace: pass with path-aware stub" {
  run bash -c "set +e; source '${ENTRYPOINT}'; $(pathaware); assert_rootfs_readonly; assert_tmpfs_workspace; echo ok"
  echo "$output" | grep -q ok
}

@test "assert_tmpfs_workspace: /tmp missing noexec FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; _findmnt_fstype(){ echo tmpfs; }; _findmnt_options(){ case \"\$1\" in /tmp) printf 'rw,nosuid,nodev,mode=1777';; *) printf 'rw,nosuid,nodev';; esac; }; assert_tmpfs_workspace; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "assert_tmpfs_workspace: /tmp missing nosuid FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; _findmnt_fstype(){ echo tmpfs; }; _findmnt_options(){ case \"\$1\" in /tmp) printf 'rw,nodev,noexec';; *) printf 'rw,nosuid,nodev';; esac; }; assert_tmpfs_workspace; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "assert_tmpfs_workspace: /tmp missing nodev FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; _findmnt_fstype(){ echo tmpfs; }; _findmnt_options(){ case \"\$1\" in /tmp) printf 'rw,nosuid,noexec';; *) printf 'rw,nosuid,nodev';; esac; }; assert_tmpfs_workspace; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "assert_tmpfs_workspace: /runner not tmpfs FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; _findmnt_fstype(){ echo overlay; }; _findmnt_options(){ echo rw; }; assert_tmpfs_workspace; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "assert_rootfs_readonly: rw rootfs FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_options(){ echo 'rw,relatime'; }; assert_rootfs_readonly; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "build_config_args: --ephemeral --unattended --disableupdate --work /work --labels ci-build" {
  run bash -c "set +e; source '${ENTRYPOINT}'; build_config_args U T ci-build-N ci-build | while IFS= read -r -d '' a; do printf '%s\n' \"\$a\"; done"
  echo "$output" | grep -qx -- '--ephemeral'
  echo "$output" | grep -qx -- '--unattended'
  echo "$output" | grep -qx -- '--disableupdate'
  echo "$output" | grep -qx -- '--work'
  echo "$output" | grep -qx -- '/work'
}
