# ocserv-backport

Single-purpose local build and validation repository for an ocserv Debian backport.

This repository locks the Debian sid source package `ocserv` version `1.5.0-1`,
fetches that source from the official Debian pool path `main/o/ocserv`, rewrites
the changelog for Debian trixie, and builds the amd64 backport package version
`1.5.0-1~bpo13+1`.

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
make dry-run
```

`make dry-run` is intended to run on a Debian trixie amd64 builder with a working
trixie sbuild schroot. It builds and validates local artifacts only. It does not
publish packages, deploy hosts, promote channels, or roll back external state.

## CI

GitHub Actions CI uses a GitHub-hosted Ubuntu runner for static checks and
unit tests only. It does not build Debian binary packages, run sbuild, run the
container smoke test, publish artifacts, deploy hosts, or read repository
secrets.

CI runs syntax checks, ShellCheck, Python compilation, YAML linting,
`make verify-lock`, and `make test`.

## Local Targets

```bash
make verify-lock
make fetch
make rewrap
make src-pkg
make binary
make lint
make smoke-basic
make dry-run
make test
```

## Builder Requirements

For the full `make dry-run` path on a trixie amd64 builder:

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
| `scripts/` | Source fetch, package build, lint, smoke, and dry-run scripts |
| `test/` | Bats tests for parser, lock projection, fetch, smoke, and dry-run behavior |
| `.github/workflows/ci.yml` | GitHub-hosted static checks and unit tests |
| `Makefile` | Local entry points |

This repository intentionally excludes package publishing, repository hosting,
environment deployment, production promotion, rollback automation, and build-host
provisioning automation.
