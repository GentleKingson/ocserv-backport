# Build the ocserv backport on Ubuntu 26.04 Resolute

This guide explains how to build local backport packages for `ocserv 1.6.0`
on an Ubuntu 26.04 Resolute build host. Prefer the automatic build path.

## Automatic build

Clone the repository and run the automatic build wrapper:

```bash
git clone https://github.com/GentleKingson/ocserv-backport.git
cd ocserv-backport
scripts/resolute-auto-build.sh --provision
```

For unattended environments (such as CI runners), pass `--yes` to auto-confirm
creating a missing `resolute-${TARGET_ARCH}` sbuild chroot:

```bash
scripts/resolute-auto-build.sh --provision --yes
```

If the build host is already prepared (build tools, Docker CE, Debian
`dscverify` keyrings, `sbuild` group membership, and `resolute-${TARGET_ARCH}`
sbuild chroot), run without `--provision`:

```bash
scripts/resolute-auto-build.sh
```

## Version variables

All version defaults live in `scripts/_versions.sh`:

```text
OCSERV_DEBIAN_VERSION=1.6.0-3
OCSERV_PACKAGING_VERSION=1.6.0-3
BACKPORT_REVISION=1
OCSERV_RESOLUTE_VERSION=1.6.0-3~ubuntu26.04.1

TARGET_SUITE=resolute
TARGET_ARCH=amd64  # Optional explicit override; auto-detected when unset
```

Unlike Ubuntu 24.04 Noble, Ubuntu 26.04 Resolute ships both `libllhttp-dev` (in
`universe`) and `systemd` 259 (supporting `u!` in `sysusers.d`). The Resolute
build therefore links against the system `libllhttp` library and keeps
`debian/ocserv.sysusers` unchanged.

## Manual build commands

Run the full local build:

```bash
make resolute-build
```

Run only the source package path:

```bash
make resolute-source-ci
```

Stage-by-stage targets:

```bash
make resolute-verify-locks
make resolute-fetch-ocserv
make resolute-rewrap-ocserv
make resolute-src-pkg-ocserv
make resolute-binary-ocserv
make resolute-lint
make resolute-smoke-basic
```

## Artifact directories

Resolute artifacts are isolated by architecture:

```text
build/ubuntu/resolute/${TARGET_ARCH}/source/
build/ubuntu/resolute/${TARGET_ARCH}/binary/
build/ubuntu/resolute/${TARGET_ARCH}/keyrings/debian/
```

## GitHub Actions

The `ci.yml` workflow verifies `make resolute-source-ci` inside an
`ubuntu:26.04` container on a weekly schedule and on manual dispatch
(`target=source-package` or `target=all`).

The manual and release-called workflow `.github/workflows/ubuntu-resolute-build.yml`
uses this architecture matrix:

```text
amd64 -> ubuntu-26.04
arm64 -> ubuntu-26.04-arm
```

The fixed check names for the two jobs are `ubuntu-resolute-build-amd64` and
`ubuntu-resolute-build-arm64`. On success, the artifact names are
`ubuntu-resolute-build-amd64` and `ubuntu-resolute-build-arm64`; the log
artifact names are `ubuntu-resolute-build-logs-amd64` and
`ubuntu-resolute-build-logs-arm64` (uploaded on both success and failure).
