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
