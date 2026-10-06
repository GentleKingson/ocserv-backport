# ocserv-backport

Multi-version ocserv backport build and validation pipelines for Debian 13 and
Ubuntu 24.04.

The repository pins Debian source identity, rebuilds local source and binary
packages, and validates them for local release preparation.

## Install

On Debian 13 (trixie) or Ubuntu 24.04 (noble), amd64 or arm64:

```bash
curl -fsSL https://raw.githubusercontent.com/GentleKingson/ocserv-backport/main/install.sh | sudo bash
```

The installer picks the package for your system from the latest release,
verifies it against `SHA256SUMS`, installs it and enables `ocserv.service`
without starting it. Edit `/etc/ocserv/ocserv.conf`, then start the server:

```bash
sudo systemctl start ocserv
```

To install a specific release, pass its tag:
`curl -fsSL <url> | sudo bash -s -- --release 1.5.0-2`.

## Build Guides

- [Build on Debian 13](docs/build-ocserv-backport-on-debian13.md)
- [Build on Ubuntu 24.04](docs/build-ocserv-backport-on-ubuntu24.04.md)

## Releases

- [Publish a release](docs/release.md)
