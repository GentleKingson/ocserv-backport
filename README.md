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

The Noble `node-undici` backport version defaults to
`7.3.0+dfsg1+~cs24.12.11-1`, matching the locked Debian source version. The
Noble pipeline still rewrites the top changelog distribution to `noble` and
injects local packaging changes, so this same-version rebuild is intended for
the private local Noble build flow rather than a public repository mixed with
Debian's official packages.

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

The Noble host wrapper entry point is:

```bash
scripts/noble-auto-build.sh
scripts/noble-auto-build.sh --provision
```

The wrapper default mode checks the Noble host foundation and prints repair
commands when something is missing. It does not install packages, write Docker
configuration, start daemons, add groups, or create chroots. With `--provision`,
it can install build dependencies, configure Docker CE from Docker's official
APT repository, repair the Docker daemon with a limited `systemctl enable --now`
attempt, add the current user to the `sbuild` group, and create the Noble sbuild
chroot after an interactive `yes` confirmation. Once the foundation is ready, it
runs `make noble-build`. Host APT operations run with
`apt-get -q=1 -o=Dpkg::Use-Pty=0`; successful APT output is hidden, and failures
print the original APT output. Noble binary `sbuild` stages also hide successful
internal chroot output and print the original `sbuild` output on failure. Those
binary stages explicitly use `--chroot=noble-${TARGET_ARCH}`. The wrapper
verifies that this registered schroot can create an empty session before it runs
`make noble-build`, not only that the name appears in `schroot -l`.

`make noble-build` is the lower-level Noble validation entry point for builders
that are already prepared:

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
make noble-auto-build
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
- debhelper and dh-nodejs for Noble source-package clean steps
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
and does not enable automatic cross-builds. The expected chroot name is
`noble-${TARGET_ARCH}`, for example `noble-amd64`.

The Noble builder needs the same Debian source verification tooling as the
trixie builder, including a readable Debian keyring for `dscverify`:

- Python 3 with PyYAML
- curl
- debian-keyring and devscripts
- dpkg-dev
- debhelper and dh-nodejs for Noble source-package clean steps
- sbuild
- schroot
- Noble sbuild chroot for `TARGET_ARCH`
- lintian
- Docker Engine for `noble-smoke-basic`
- bats
- shellcheck

For Noble builders, install Docker Engine from Docker's official APT repository
as described in `docs/build-ocserv-backport-on-ubuntu24.04.md`. Do not mix the
Ubuntu `docker.io` stack with Docker CE packages such as `containerd.io`.

If `make noble-build` fails with unreadable `/usr/share/keyrings/debian-*.gpg`
paths, install the keyring package:

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends debian-keyring
```

The fetch scripts ignore missing optional keyring candidates, such as
`debian-tag2upload.pgp` on Ubuntu 24.04, but at least one Debian keyring must be
readable. Set `DSCVERIFY_KEYRING_PATHS` to a colon-separated list only when a
builder uses non-standard keyring paths.

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
hosting, production VPS deployment, production promotion, and rollback
automation. `scripts/noble-auto-build.sh --provision` can prepare a local Noble
builder, but it does not manage production hosts. The Noble repo under
`build/noble/${TARGET_ARCH}/repo/` is local build plumbing for clean chroots, not
a production APT repository.

For the detailed Noble workflow, see
`docs/build-ocserv-backport-on-ubuntu24.04.md`.
