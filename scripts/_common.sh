#!/usr/bin/env bash
# Shared helpers for repo scripts. Source with: source "$(dirname "$0")/_common.sh"
set -euo pipefail

# Logging --------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# flock wrapper --------------------------------------------------------------
# Usage: acquire_repo_publish_lock  -> sets fd 9, held until script exits
acquire_repo_publish_lock() {
  local lockdir="${APTLY_ROOT_DIR:-/var/aptly}/.locks"
  mkdir -p "${lockdir}" 2>/dev/null || true
  exec 9>"${lockdir}/repo-publish.lock"
  flock -n 9 || die "repo-publish-lock held by another process; aborting"
  log "acquired repo-publish-lock (${lockdir}/repo-publish.lock)"
}

# Channel validation ---------------------------------------------------------
valid_channel() { [[ "$1" == "testing" || "$1" == "production" ]]; }
require_channel() { valid_channel "$1" || die "channel must be testing|production, got: $1"; }

# ---- bootstrap helpers (spec §3.2) -----------------------------------------
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
is_set()     { [[ -n "${!1:-}" ]]; }
require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "required variable missing: ${name}"
}

# require_cmds <cmd:pkg> <cmd:pkg> ...  — die (reporting ALL missing) if any absent.
# Each arg is "command:debian-package". Reports every missing command in one
# message so the operator installs all gaps in a single pass (no fix-rerun loop).
# Usage: require_cmds dscverify:devscripts dpkg-source:dpkg-dev
require_cmds() {
  local missing=() pkgs=() c p
  for spec in "$@"; do
    c="${spec%%:*}"; p="${spec#*:}"
    command -v "$c" >/dev/null 2>&1 || { missing+=("$c"); pkgs+=("$p"); }
  done
  if (( ${#missing[@]} )); then
    die "missing commands: ${missing[*]}
  packages: ${pkgs[*]}
  fix: run 'make bootstrap-build-host' on the builder, or: sudo apt-get install -y ${pkgs[*]}"
  fi
}

# read -s a missing secret; never logs, never set -x
read_secret_if_missing() {
  local name="$1" prompt="$2"
  if [[ -z "${!name:-}" ]]; then
    # shellcheck disable=SC2229,SC2163  # dynamic name is intentional here
    read -r -s -p "${prompt}: " "${name}" >&2
    printf '\n' >&2
    # shellcheck disable=SC2163  # dynamic name is intentional here
    export "${name}"
  fi
}

# load_bootstrap_env_defaults <file>
# Fill defaults for vars NOT already set; never override caller-provided env.
# key validated ^BOOTSTRAP_[A-Z0-9_]+$; value via %%=/=#= so '=' in value is safe.
# .bootstrap.env supports only KEY=value / KEY="value"; no shell expansion.
load_bootstrap_env_defaults() {
  local file="$1" line key val
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    [[ "${key}" =~ ^BOOTSTRAP_[A-Z0-9_]+$ ]] || continue
    [[ -n "${!key:-}" ]] || export "${key}=${val}"
  done < "${file}"
}

# check_secret_file_mode <file>  (GNU stat -c; target is Linux/trixie only)
check_secret_file_mode() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local mode owner
  mode="$(stat -c '%a' "${file}")"
  owner="$(stat -c '%U' "${file}")"
  [[ "${mode}" == "600" ]] || die "${file} must be chmod 600 (got ${mode})"
  [[ "${owner}" == "$(id -un)" ]] || die "${file} must be owned by $(id -un) (got ${owner})"
}

# run_cmd <argv...>  — simple commands ONLY (spec implementation rule 3).
# Use run_safe_* wrappers for redirects/pipes/heredocs/secrets.
run_cmd() {
  if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
