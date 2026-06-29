# ocserv-backport

Multi-version ocserv backport build and validation pipelines for Debian 13 and
Ubuntu 24.04.

The repository pins Debian source identity for locked input versions, rebuilds
local source and binary packages, runs package checks, and exercises basic
install smoke tests. It is for local validation and release preparation.

## Build Entrypoints

| Target | Purpose |
|---|---|
| `make build` | Full Debian 13 local backport pipeline |
| `scripts/debian-auto-build.sh` | Check a Debian 13 builder and run the Debian build when ready |
| `scripts/debian-auto-build.sh --provision` | Prepare the Debian builder after confirmation, then run the Debian build |
| `make source-ci` | Source-package-only path used by scheduled/manual source CI |
| `scripts/noble-auto-build.sh` | Check an Ubuntu 24.04 builder and run the Ubuntu build when ready |
| `scripts/noble-auto-build.sh --provision` | Prepare the Ubuntu builder after confirmation, then run the Ubuntu build |
| `make noble-build` | Lower-level Ubuntu 24.04 backport pipeline |
| `make test` | Run the Bats test suite |

Use the detailed guides for builder setup, version overrides, and target-specific
workflow notes.

## Source Locks

The `source-lock/` YAML files are the source identity authorities for locked
Debian inputs. They record the expected `.dsc` and source artifacts, sizes,
SHA-256 hashes, and Debian pool paths.

The committed `.lock.tsv` files are shell-friendly projections generated from
the YAML files. Run `make verify-lock` to regenerate and compare them.

## CI

Pull request CI runs static checks, source-lock verification, Bats tests, and
stubbed build-entrypoint orchestration tests. It does not build Debian binary
packages, create sbuild chroots, run Docker smoke tests, publish artifacts,
deploy hosts, or read repository secrets.

Manual and scheduled source CI run the real source-package path in a
`debian:trixie` container and upload source package artifacts only.

The Manual Debian 13 build workflow is
`.github/workflows/debian-trixie-build.yml`. It builds amd64 and arm64 in a
matrix: amd64 runs on `ubuntu-24.04`, and arm64 runs on the native
`ubuntu-24.04-arm` runner. It runs the Debian binary build, lintian, and Docker
smoke validation, then uploads generated artifacts.
It does not publish packages, deploy hosts, or read repository secrets.

The Manual Ubuntu 24.04 build workflow is
`.github/workflows/ubuntu-noble-build.yml`. It builds amd64 and arm64 in a
matrix: amd64 runs on `ubuntu-24.04`, and arm64 runs on the native
`ubuntu-24.04-arm` runner. It runs the Ubuntu binary build, lintian, and Docker
smoke validation, then uploads generated artifacts.
It does not publish packages, deploy hosts, or read repository secrets.

## Detailed Guides

- [Build on Debian 13](docs/build-ocserv-backport-on-debian13.md)
- [Build on Ubuntu 24.04](docs/build-ocserv-backport-on-ubuntu24.04.md)

## Boundaries

This repository intentionally excludes package publishing, external repository
hosting, production VPS deployment, production promotion, and rollback
automation. Any generated local package repository is build plumbing for clean
chroots, not a production APT repository.
