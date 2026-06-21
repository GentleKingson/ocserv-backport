#!/usr/bin/env bash
set -euo pipefail
# Phase 1 ci-build entrypoint (UID 10001). Payload read-only layer → /runner tmpfs
# (no-preserve-ownership copy). Token from stdin, never logged, unset after config.
# Assertions use findmnt mount type+options (NOT write-probes).
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1.

RUNNER_PAYLOAD_SRC="/opt/actions-runner-src"
RUNNER_PAYLOAD_DST="/runner"
WORK_DIR="/work"

die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[entrypoint] %s\n' "$*" >&2; }

# Stubbable helpers (tests override these; real impl uses findmnt / id).
current_uid() { id -u; }
_findmnt_fstype() { findmnt -n -o FSTYPE "$1"; }
_findmnt_options() { findmnt -n -o OPTIONS "$1"; }

assert_running_as_10001() {
  [[ "$(current_uid)" -eq 10001 ]] || die "must run as UID 10001 (got $(current_uid))"
}
assert_mount_option() {
  local mp="$1" opt="$2" opts; opts="$(_findmnt_options "${mp}")"
  [[ ",${opts}," == *",${opt},"* ]] || die "${mp} missing mount option '${opt}' (opts: ${opts})"
}
assert_tmpfs_type() {
  local t; t="$(_findmnt_fstype "$1")"
  [[ "${t}" == "tmpfs" ]] || die "$1 is not tmpfs (got ${t})"
}
assert_rootfs_readonly() { assert_mount_option / ro; }
assert_tmpfs_workspace() {
  local mp
  for mp in "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}" /tmp; do assert_tmpfs_type "${mp}"; done
  for mp in "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}"; do
    assert_mount_option "${mp}" nosuid; assert_mount_option "${mp}" nodev
  done
  # /tmp: tmpfs + nosuid + nodev + noexec (all four).
  assert_mount_option /tmp nosuid
  assert_mount_option /tmp nodev
  assert_mount_option /tmp noexec
}
build_config_args() {
  printf '%s\0' --url "$1" --token "$2" --name "$3" --labels "$4" --work "${WORK_DIR}" --ephemeral --unattended --disableupdate
}
main() {
  assert_running_as_10001
  assert_rootfs_readonly
  assert_tmpfs_workspace
  log "copy payload ${RUNNER_PAYLOAD_SRC} -> ${RUNNER_PAYLOAD_DST} (no ownership preserve)"
  # --no-preserve=ownership: source is root-owned (read-only layer); UID 10001 cannot
  # chown. Files become owned by 10001 in the destination tmpfs.
  cp -R --no-preserve=ownership "${RUNNER_PAYLOAD_SRC}/." "${RUNNER_PAYLOAD_DST}/"
  local registration_token=""
  IFS= read -r registration_token || die "no registration token on stdin"
  [[ -n "${registration_token}" ]] || die "empty registration token on stdin"
  local url="${RUNNER_URL:?}" label="${RUNNER_LABEL:?}" name="${RUNNER_NAME:?}"
  local cfg_argv=()
  while IFS= read -r -d '' a; do cfg_argv+=("${a}"); done < <(build_config_args "${url}" "${registration_token}" "${name}" "${label}")
  log "config.sh (token suppressed)"
  ( cd "${RUNNER_PAYLOAD_DST}" && ./config.sh "${cfg_argv[@]}" ) || die "config.sh failed"
  registration_token=""
  log "run.sh (ephemeral: exits after one job)"
  ( cd "${RUNNER_PAYLOAD_DST}" && ./run.sh ) || die "run.sh exited non-zero"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
