#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"
source "$(dirname "$0")/_manifest.sh"

# Spec §3.8 rollback read rule. Usage: aptly-rollback.sh <channel> [snapshot]
channel="$1"; snapshot="${2:-}"
require_channel "${channel}"
case "${channel}" in
  testing)    dist=trixie-testing ;;
  production) dist=trixie-production ;;
esac

if [[ -z "${snapshot}" ]]; then
  snapshot="$(jq -r .snapshot "$(manifest_path "${channel}" previous-good)" 2>/dev/null || true)"
fi
[[ -n "${snapshot}" ]] || die "no rollback snapshot (pass as \$2 or set previous-good manifest)"

acquire_repo_publish_lock
aptly publish switch "${dist}" "${snapshot}"
log "rolled back ${channel} -> ${snapshot}"
# Emit the version for the caller (CI) to pass to ansible rollback.
jq -r .version "$(manifest_path "${channel}" previous-good)"
