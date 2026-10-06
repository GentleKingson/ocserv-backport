#!/usr/bin/env bash
# Single source of package version defaults. Sourced by trixie-env.sh and
# noble-env.sh; every value can be overridden from the environment.

# Debian source versions. Each needs source-lock/<source>/<version>.yaml.
OCSERV_DEBIAN_VERSION="${OCSERV_DEBIAN_VERSION:-1.5.0-1}"
NODE_UNDICI_DEBIAN_VERSION="${NODE_UNDICI_DEBIAN_VERSION:-7.3.0+dfsg1+~cs24.12.11-1}"

# Backport versions written to debian/changelog.
OCSERV_VERSION="${OCSERV_VERSION:-${OCSERV_DEBIAN_VERSION}~debian13.1}"
OCSERV_NOBLE_VERSION="${OCSERV_NOBLE_VERSION:-${OCSERV_DEBIAN_VERSION}~ubuntu24.04.1}"
NODE_UNDICI_NOBLE_VERSION="${NODE_UNDICI_NOBLE_VERSION:-${NODE_UNDICI_DEBIAN_VERSION}}"

# 1.5.0-1 -> 1.5.0 (the unpacked source tree is <source>-<upstream>).
OCSERV_UPSTREAM_VERSION="${OCSERV_DEBIAN_VERSION%-*}"

export OCSERV_DEBIAN_VERSION NODE_UNDICI_DEBIAN_VERSION
export OCSERV_VERSION OCSERV_NOBLE_VERSION NODE_UNDICI_NOBLE_VERSION
export OCSERV_UPSTREAM_VERSION
