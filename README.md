# ocserv-backport

Single-purpose local build and validation repository for ocserv backports.

The default `make build` path locks the Debian sid source package `ocserv`
version `1.5.0-1`, fetches that source from the official Debian pool path
`main/o/ocserv`, rewrites the changelog for Debian trixie, and builds the amd64
backport package version `1.5.0-1~bpo13+0local1` by default. Set
`OCSERV_VERSION` to override the local trixie version.

The optional `make noble-build` path builds an Ubuntu 24.04 Noble local backport
pipeline. It first backports Debian `node-undici` to produce `libllhttp9.2` and
`libllhttp-dev`, creates a local file APT repository from only those libllhttp
packages, and then builds `ocserv 1.5.0` in a Noble sbuild chroot using that
local repository.

The source identity is pinned. The build procedure is repeatable. This repository
does not claim bit-for-bit reproducible builds because trixie build dependencies
and container images are not timestamp- or digest-pinned here.

## Source Lock

`source-lock/ocserv/1.5.0-1.yaml` and
`source-lock/node-undici/7.3.0+dfsg1+~cs24.12.11-1.yaml` are the source identity
authorities. They record the expected `.dsc` and source artifact names, sizes,
SHA-256 hashes, and Debian pool paths.

`source-lock/ocserv/1.5.0-1.lock.tsv` is a generated projection for Shell scripts.
It is not the authority. Run `make verify-lock` to regenerate the projection in a
temporary directory and compare it with the committed TSV.

## Pipeline

```text
verify-lock
  -> fetch from Debian pool
  -> rewrap changelog
  -> build source package
  -> build binary with sbuild
  -> lintian
  -> smoke-basic
```

The full local validation entry point is:

```bash
make build
```

`make build` is intended to run on a Debian trixie amd64 builder with a working
trixie sbuild schroot. It builds and validates local artifacts only. It does not
publish packages, deploy hosts, promote channels, or roll back external state.

`make dry-run` remains as a compatibility alias for `make build`.

The Noble local validation entry point is:

```bash
make noble-build
```

It runs:

```text
noble-verify-locks
  -> noble-fetch-node-undici
  -> noble-rewrap-node-undici
  -> noble-src-pkg-node-undici
  -> noble-binary-node-undici
  -> noble-repo
  -> noble-fetch-ocserv
  -> noble-rewrap-ocserv
  -> noble-src-pkg-ocserv
  -> noble-binary-ocserv
  -> noble-lint
  -> noble-smoke-basic
```

The Noble path is separate from the trixie path. `make build` does not invoke the
Noble flow.

## CI

Pull request CI uses a GitHub-hosted Ubuntu runner for static checks, lock
verification, unit tests, and stubbed build-entrypoint orchestration tests. It
does not build Debian binary packages, create sbuild chroots, run Docker smoke
tests, publish artifacts, deploy hosts, or read repository secrets.

Manual and scheduled source CI runs in a `debian:trixie` container. It executes
the real source package path:

```text
verify-lock -> fetch -> rewrap -> src-pkg
```

Source CI uploads source package artifacts only. It does not run `binary`,
`lint`, or `smoke-basic`, and it does not upload `.deb` files.

## Local Targets

```bash
make build
make dry-run
make ci-script-test
make source-ci
make verify-lock
make fetch
make rewrap
make src-pkg
make binary
make lint
make smoke-basic
make test
make noble-build
make noble-verify-locks
make noble-fetch-node-undici
make noble-rewrap-node-undici
make noble-src-pkg-node-undici
make noble-binary-node-undici
make noble-repo
make noble-fetch-ocserv
make noble-rewrap-ocserv
make noble-src-pkg-ocserv
make noble-binary-ocserv
make noble-lint
make noble-smoke-basic
```

## Builder Requirements

For the full `make build` path on a trixie amd64 builder:

- Python 3 with PyYAML
- curl
- debian-keyring and devscripts
- dpkg-dev
- sbuild
- schroot
- trixie amd64 sbuild chroot
- lintian
- Docker
- bats
- shellcheck

For the full `make noble-build` path, use an Ubuntu 24.04 Noble builder with a
matching Noble sbuild schroot for `TARGET_ARCH`. `TARGET_ARCH` defaults to
`amd64`; `TARGET_ARCH=arm64` expects an already working arm64 build environment
and does not enable automatic cross-builds.

## Repository Layout

| Path | Purpose |
|---|---|
| `source-lock/` | Pinned Debian source identity and generated TSV projection |
| `scripts/` | Source fetch, package build, lint, smoke, local build, and source CI scripts |
| `test/` | Bats tests for parser, lock projection, fetch, smoke, build entrypoints, and source CI behavior |
| `.github/workflows/ci.yml` | GitHub-hosted static checks, unit tests, and stubbed entrypoint tests |
| `.github/workflows/source-ci.yml` | Manual and scheduled source-package CI in `debian:trixie` |
| `Makefile` | Local entry points |

This repository intentionally excludes package publishing, external repository
hosting, production VPS deployment, production promotion, rollback automation,
and build-host provisioning automation. The Noble repo under
`build/noble/${TARGET_ARCH}/repo/` is local build plumbing for clean chroots, not
a production APT repository.

For the detailed Noble workflow, see
`docs/build-ocserv-backport-on-ubuntu24.04.md`.
