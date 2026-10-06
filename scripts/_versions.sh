#!/usr/bin/env bash
# Single source of package version defaults. Sourced by trixie-env.sh and
# noble-env.sh; every value can be overridden from the environment.

# Debian source version. It needs source-lock/<source>/<version>.yaml.
OCSERV_DEBIAN_VERSION="${OCSERV_DEBIAN_VERSION:-1.5.0-1}"

# Backport revision: bump it to rebuild the same Debian source as a new
# release that apt sees as an upgrade.
BACKPORT_REVISION="${BACKPORT_REVISION:-1}"

# Backport versions written to debian/changelog.
OCSERV_VERSION="${OCSERV_VERSION:-${OCSERV_DEBIAN_VERSION}~debian13.${BACKPORT_REVISION}}"
OCSERV_NOBLE_VERSION="${OCSERV_NOBLE_VERSION:-${OCSERV_DEBIAN_VERSION}~ubuntu24.04.${BACKPORT_REVISION}}"

# 1.5.0-1 -> 1.5.0 (the unpacked source tree is <source>-<upstream>).
OCSERV_UPSTREAM_VERSION="${OCSERV_DEBIAN_VERSION%-*}"

export OCSERV_DEBIAN_VERSION BACKPORT_REVISION
export OCSERV_VERSION OCSERV_NOBLE_VERSION
export OCSERV_UPSTREAM_VERSION
