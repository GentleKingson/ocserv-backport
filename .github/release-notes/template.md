## Packages

| Distribution | Architectures | ocserv package |
| --- | --- | --- |
| Debian 13 (trixie) | amd64, arm64 | `${OCSERV_DEBIAN13}` |
| Ubuntu 24.04 (noble) | amd64, arm64 | `${OCSERV_NOBLE}` |

The Ubuntu Noble package is built with the llhttp copy bundled in ocserv, so
it needs no separate libllhttp package.

## Install

Download the `.deb` for your distribution and architecture together with
`SHA256SUMS`, then verify and install it:

```bash
sha256sum -c --ignore-missing SHA256SUMS
sudo apt install ./ocserv_<version>_<arch>.deb
```
