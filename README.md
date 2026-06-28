# ocserv-backport

Local build and validation pipelines for `ocserv 1.5.0` backports on Debian
trixie and Ubuntu 24.04 Noble.

The repository pins Debian source identity, rebuilds local source and binary
packages, runs package checks, and exercises basic install smoke tests. It is
for local validation only.

## Build Entrypoints

| Target | Purpose |
|---|---|
| `make build` | Full Debian trixie local backport pipeline for `ocserv 1.5.0-1` |
| `scripts/debian-auto-build.sh` | Check a Debian trixie builder and run the Debian build when ready |
| `scripts/debian-auto-build.sh --provision` | Prepare the Debian builder after confirmation, then run the Debian build |
| `make source-ci` | Source-package-only path used by scheduled/manual source CI |
| `scripts/noble-auto-build.sh` | Check an Ubuntu 24.04 Noble builder and run the Noble build when ready |
| `scripts/noble-auto-build.sh --provision` | Prepare the Noble builder after confirmation, then run the Noble build |
| `make noble-build` | Lower-level Ubuntu 24.04 Noble backport pipeline |
| `make test` | Run the Bats test suite |

The Debian path builds the default local version
`1.5.0-1~debian13.1`. Override it with `OCSERV_VERSION` when needed.

The Noble path builds `ocserv` through a two-stage local flow: first rebuild the
locked Debian `node-undici` source to provide local `libllhttp` packages, then
build `ocserv` against that local file APT repository.

## Source Locks

The `source-lock/` YAML files are the source identity authorities. They record
the expected `.dsc` and source artifacts, sizes, SHA-256 hashes, and Debian pool
paths for:

- `source-lock/ocserv/1.5.0-1.yaml`
- `source-lock/node-undici/7.3.0+dfsg1+~cs24.12.11-1.yaml`

The committed `.lock.tsv` files are shell-friendly projections generated from
the YAML files. Run `make verify-lock` to regenerate and compare them.

## CI

Pull request CI runs static checks, source-lock verification, Bats tests, and
stubbed build-entrypoint orchestration tests. It does not build Debian binary
packages, create sbuild chroots, run Docker smoke tests, publish artifacts,
deploy hosts, or read repository secrets.

Manual and scheduled source CI run the real source-package path in a
`debian:trixie` container and upload source package artifacts only.

The Manual Debian Trixie build workflow is
`.github/workflows/debian-trixie-build.yml`. It provisions a GitHub-hosted
`ubuntu-24.04` runner for a Debian trixie target build, runs the Debian binary
build, lintian, and Docker smoke validation, then uploads generated artifacts.
It does not publish packages, deploy hosts, or read repository secrets.

The Manual Ubuntu Noble build workflow is
`.github/workflows/ubuntu-noble-build.yml`. It provisions a GitHub-hosted
`ubuntu-24.04` runner, runs the Noble binary build, lintian, and Docker smoke
validation, then uploads generated artifacts. It does not publish packages, deploy hosts, or read repository secrets.

## Detailed Guides

- [Build on Debian 13](docs/build-ocserv-backport-on-debian13.md)
- [Build on Ubuntu 24.04](docs/build-ocserv-backport-on-ubuntu24.04.md)

## Repository Layout

| Path | Purpose |
|---|---|
| `source-lock/` | Pinned Debian source identity and generated TSV projections |
| `scripts/` | Source fetch, package build, lint, smoke, local build, and source CI scripts |
| `test/` | Bats tests for lock handling, build entrypoints, CI behavior, and smoke checks |
| `.github/workflows/ci.yml` | Pull request static checks and stubbed orchestration tests |
| `.github/workflows/source-ci.yml` | Manual and scheduled source-package CI in `debian:trixie` |
| `.github/workflows/debian-trixie-build.yml` | Manual Debian Trixie binary build workflow |
| `.github/workflows/ubuntu-noble-build.yml` | Manual Ubuntu Noble binary build workflow |
| `docs/` | Detailed Debian and Ubuntu builder guides |
| `Makefile` | Local entry points |

## Boundaries

This repository intentionally excludes package publishing, external repository
hosting, production VPS deployment, production promotion, and rollback
automation. The Noble repository under
`build/ubuntu/noble/${TARGET_ARCH}/repo/` is local build plumbing for clean
chroots, not a production APT repository.
