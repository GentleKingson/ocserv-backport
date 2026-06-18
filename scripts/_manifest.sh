#!/usr/bin/env bash
# Source-only library. Spec §3.8. State lives under ${APTLY_STATE_DIR}.
set -euo pipefail

manifest_state_dir() { printf '%s' "${APTLY_STATE_DIR:-/var/aptly/state}"; }

manifest_path() { printf '%s/%s-%s.json' "$(manifest_state_dir)" "$1" "$2"; }  # channel, kind

manifest_read_current()        { cat "$(manifest_path "$1" current)" 2>/dev/null || echo '{}'; }
manifest_read_previous_good()  { cat "$(manifest_path "$1" previous-good)" 2>/dev/null || echo '{}'; }

# manifest_update <channel> <snapshot> <version>
manifest_update() {
  local channel="$1" snapshot="$2" version="$3"
  command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
  mkdir -p "$(manifest_state_dir)"
  local cur prev
  cur="$(manifest_read_current "${channel}")"
  prev="${cur}"
  printf '%s\n' "${prev}" > "$(manifest_path "${channel}" previous-good)"
  jq -n \
    --arg snapshot "${snapshot}" \
    --arg version "${version}" \
    --arg channel "${channel}" \
    --arg promoted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{snapshot:$snapshot, version:$version, channel:$channel, promoted_at:$promoted_at}' \
    > "$(manifest_path "${channel}" current)"
}
