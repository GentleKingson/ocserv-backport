#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §3.4. rclone reads RCLONE_CONFIG_<REMOTE>_* at runtime, not R2_*.
channel="$1"; require_channel "${channel}"

: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY required}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID required}"
: "${R2_BUCKET:=apt-thehkus}"

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

acquire_repo_publish_lock
src="/var/aptly/public/${channel}/"
log "rclone sync ${src} -> r2:${R2_BUCKET}/${channel}/"
rclone sync "${src}" "r2:${R2_BUCKET}/${channel}/" --checksum --transfers 4
