# ocserv-backport

Single-purpose local build and validation repository for an ocserv Debian backport.

This repository locks the Debian sid source package `ocserv` version `1.5.0-1`,
fetches that source from the official Debian pool path `main/o/ocserv`, rewrites
the changelog for Debian trixie, and builds the amd64 backport package version
`1.5.0-1~bpo13+0local1` by default. Set `OCSERV_VERSION` to override the local
version.

The source identity is pinned. The build procedure is repeatable. This repository
does not claim bit-for-bit reproducible builds because trixie build dependencies
and container images are not timestamp- or digest-pinned here.

## Source Lock

`source-lock/ocserv/1.5.0-1.yaml` is the source identity authority. It records
the expected `.dsc` and source artifact names, sizes, SHA-256 hashes, and Debian
pool path.

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

Manual Ubuntu Noble build workflow runs on a GitHub-hosted `ubuntu-24.04`
runner. It frees runner disk space, provisions the Noble builder with
`scripts/noble-auto-build.sh --provision`, runs the full Noble binary build,
`lintian`, and Docker smoke validation, then uploads the generated source,
binary, and local repository artifacts.
This workflow does not publish packages, deploy hosts, or read repository secrets.

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

## Repository Layout

| Path | Purpose |
|---|---|
| `source-lock/` | Pinned Debian source identity and generated TSV projection |
| `scripts/` | Source fetch, package build, lint, smoke, local build, and source CI scripts |
| `test/` | Bats tests for parser, lock projection, fetch, smoke, build entrypoints, and source CI behavior |
| `.github/workflows/ci.yml` | GitHub-hosted static checks, unit tests, and stubbed entrypoint tests |
| `.github/workflows/source-ci.yml` | Manual and scheduled source-package CI in `debian:trixie` |
| `.github/workflows/ubuntu-noble-build.yml` | Manual Ubuntu Noble build workflow on GitHub-hosted `ubuntu-24.04` |
| `Makefile` | Local entry points |

This repository intentionally excludes package publishing, repository hosting,
environment deployment, production promotion, rollback automation, and build-host
provisioning automation.
