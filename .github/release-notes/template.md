## Packages

| Distribution | Architectures | ocserv package |
| --- | --- | --- |
| Debian 13 (trixie) | amd64, arm64 | `${OCSERV_DEBIAN13}` |
| Ubuntu 24.04 (noble) | amd64, arm64 | `${OCSERV_NOBLE}` |
| Ubuntu 26.04 (resolute) | amd64, arm64 | `${OCSERV_RESOLUTE}` |

The Ubuntu 24.04 (noble) package is built with the llhttp copy bundled in
ocserv, so it needs no separate libllhttp package. Debian 13 (trixie) and
Ubuntu 26.04 (resolute) link against the system `libllhttp`.

## Install

Install this release with the one-line installer (selects the package for your
distribution and architecture, verifies `SHA256SUMS`, installs it, and enables
`ocserv.service` without starting it):

```bash
curl -fsSL https://raw.githubusercontent.com/GentleKingson/ocserv-backport/main/install.sh | sudo bash -s -- --release ${TAG}
```

Or download the `.deb` for your distribution and architecture together with
`SHA256SUMS`, then verify and install it manually:

```bash
sha256sum -c --ignore-missing SHA256SUMS
sudo apt install ./ocserv_<version>_<arch>.deb
```
