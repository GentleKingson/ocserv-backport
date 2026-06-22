#!/usr/bin/env bash
# Shared helpers for local backport build scripts.
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}
