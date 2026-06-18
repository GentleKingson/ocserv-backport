#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"
source "$(dirname "$0")/_manifest.sh"

# Spec §3.8 rollback read rule. Usage:
#   aptly-rollback.sh <channel> [snapshot]
# If snapshot omitted, reads <channel>-previous-good.json.
# Prints (last line) the deb version of the rolled-back-to snapshot, for
#   ansible -e ocserv_target_version=...  (resolves from aptly, not the manifest,
#   so it stays correct even if the manifest is stale).
channel="$1"; snapshot="${2:-}"
require_channel "${channel}"
case "${channel}" in
  testing)    dist=trixie-testing ;;
  production) dist=trixie-production ;;
esac

# Resolve target snapshot: explicit arg, else previous-good from manifest.
if [[ -z "${snapshot}" ]]; then
  prev_good="$(manifest_read_previous_good "${channel}")"
  snapshot="$(printf '%s' "${prev_good}" | jq -r '.snapshot // empty')"
fi
[[ -n "${snapshot}" ]] \
  || die "no rollback snapshot (pass as \$2 or set previous-good manifest for ${channel})"

acquire_repo_publish_lock
aptly publish switch "${dist}" "${snapshot}"
log "rolled back ${channel} -> ${snapshot}"

# Emit the deb version of the snapshot we switched TO (resolving from aptly, not the
# previous-good manifest — robust even on first-ever rollback / if manifest is stale).
version="$(aptly snapshot show -json "${snapshot}" 2>/dev/null \
  | jq -r '.Packages[]? | select(.Name=="ocserv") | .Version' | head -n1 || true)"
if [[ -z "${version}" ]]; then
  log "WARNING: could not resolve ocserv version from snapshot ${snapshot}"
fi
printf '%s\n' "${version}"
