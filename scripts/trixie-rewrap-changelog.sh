#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/trixie-env.sh
. "${SCRIPT_DIR}/trixie-env.sh"
BACKPORT_VERSION="${OCSERV_VERSION}"
SOURCE_VERSION="${OCSERV_DEBIAN_VERSION}"
MAINTAINER_NAME="${MAINTAINER_NAME:-Thehkus Admin}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-master@thehkus.com}"

SRCDIR="${TARGET_SOURCE_ROOT}/ocserv-${OCSERV_UPSTREAM_VERSION}"
[[ -d "${SRCDIR}" ]] || die "missing source tree: ${SRCDIR}"
cd "${SRCDIR}"

current_version="$(dpkg-parsechangelog -SVersion)"
if [[ "${current_version}" == "${BACKPORT_VERSION}" ]]; then
  die "changelog already rewrapped to ${BACKPORT_VERSION}; rerun trixie-fetch-ocserv before trixie-rewrap-ocserv"
fi
[[ "${current_version}" == "${SOURCE_VERSION}" ]] \
  || die "unexpected changelog version ${current_version}; expected ${SOURCE_VERSION}"

export DEBEMAIL="${MAINTAINER_EMAIL}"
export DEBFULLNAME="${MAINTAINER_NAME}"

dch --distribution "${TARGET_DISTRIBUTION}" --force-distribution \
    --force-bad-version \
    -v "${BACKPORT_VERSION}" \
    "Backport ocserv ${SOURCE_VERSION} for Debian trixie."

new_version="$(dpkg-parsechangelog -SVersion)"
new_distribution="$(dpkg-parsechangelog -SDistribution)"
[[ "${new_version}" == "${BACKPORT_VERSION}" ]] \
  || die "changelog version ${new_version} != ${BACKPORT_VERSION}"
[[ "${new_distribution}" == "${TARGET_DISTRIBUTION}" ]] \
  || die "changelog distribution ${new_distribution} != ${TARGET_DISTRIBUTION}"

log "changelog top version: ${new_version}"
log "changelog distribution: ${new_distribution}"
