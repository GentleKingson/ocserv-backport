# Build the ocserv backport on Ubuntu 24.04 Noble

This guide explains how to build local backport packages for `ocserv 1.5.0`
on an Ubuntu 24.04 Noble build host. Prefer the automatic build path. Use the
manual build sections only when the environment must be prepared manually.

## Automatic build prerequisites

Before using the automatic build, prepare:

- An Ubuntu 24.04 Noble build host.
- A current user with root or sudo privileges.
- Network access to the Debian mirror, Ubuntu mirror, Docker official APT
  repository, Docker registry, and GitHub.
- A native `amd64` or `arm64` build host. `arm64` builds should run on a native
  arm64 Ubuntu 24.04 host or runner.

When using `--provision`, `sbuild`, `schroot`, `lintian`, and Docker do not
need to be installed ahead of time; the script prepares them. When running
without arguments, these tools, the Debian source signature verification
keyring, and the matching Noble sbuild chroot must already be available.

## Automatic build

If the repository is not present yet, clone it and enter the repository:

```bash
git clone https://github.com/GentleKingson/ocserv-backport.git
cd ocserv-backport
```

If the environment is already prepared, run the default checks and build:

```bash
scripts/noble-auto-build.sh
```

This mode does not install dependencies, configure Docker CE, or create an
sbuild chroot. It only checks the existing environment. After the checks pass,
the script continues with the full Ubuntu Noble build.

If this is a new Ubuntu 24.04 Noble build host, or if the default checks report
that provisioning is needed, run:

```bash
scripts/noble-auto-build.sh --provision
```

`--provision` installs build dependencies, checks the Debian source signature
verification keyring, configures Docker CE, and creates the
`noble-${TARGET_ARCH}` sbuild chroot after confirmation.

For unattended environments, use:

```bash
scripts/noble-auto-build.sh --provision --yes
```

`--yes` only auto-confirms chroot creation when the sbuild chroot is missing.
It does not bypass checks for existing directories, broken chroots, Docker CE,
or other safety checks.

If a normal user has just been added to the `sbuild` group, the script prompts
you to continue in a new shell. Enter the new shell as instructed, then rerun
the automatic build.

When `TARGET_ARCH` is unset, the Noble scripts auto-detect native `amd64` or
`arm64`. You can also set `TARGET_ARCH` explicitly to override the target
architecture. If the explicit target architecture differs from the native
architecture, the script prints a warning and continues, but it does not
configure cross-build, QEMU, or binfmt. The caller must already provide a
matching native-capable chroot or runner for the target architecture.

## Manual build prerequisites

When not using automatic `--provision`, prepare:

- An Ubuntu 24.04 Noble build host.
- A current user with root or sudo privileges.
- Network access to the Debian mirror, Ubuntu mirror, Docker official APT
  repository, Docker registry, and GitHub.
- Working `sbuild`, `schroot`, `lintian`, and Docker CE installations.
- A created and usable Noble sbuild chroot for the target architecture.
- A readable Debian source signature verification keyring.
- A normal build user with `sbuild` group membership. Running
  `make noble-build` directly also requires access to the Docker daemon.

## Manually prepare the build host

The following steps apply only when not using
`scripts/noble-auto-build.sh --provision`. If the automatic script has already
prepared the build host, do not repeat the chroot creation or user group setup
from this section.

Update the apt index:

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 update
```

Install build tools:

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends \
  git ca-certificates curl gnupg \
  build-essential fakeroot devscripts dpkg-dev debhelper dh-nodejs \
  debian-archive-keyring debian-keyring debian-maintainers \
  sbuild schroot debootstrap lintian \
  python3 python3-yaml bats shellcheck
```

Install Docker CE:

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 remove -y \
  docker.io docker-doc docker-compose docker-compose-v2 podman-docker \
  containerd runc || true
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

cat <<EOF | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
Architectures: $(dpkg --print-architecture)
EOF

sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 update
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

If the current system only has the root user, create a normal build user first:

```bash
adduser builder
usermod -aG sudo builder
su - builder
```

A normal user must be added to the `sbuild` group:

```bash
sudo sbuild-adduser "$USER"
newgrp sbuild
```

The default manual build runs `docker` directly. If the normal user must run
`docker info` or `docker run` directly, add the current user to the `docker`
group and log in again:

```bash
sudo usermod -aG docker "$USER"
```

Create the default `amd64` sbuild chroot:

```bash
sudo sbuild-createchroot \
  --arch=amd64 \
  --chroot-suffix= \
  --components=main,universe \
  --include=eatmydata,ccache,gnupg,ca-certificates \
  noble \
  /srv/chroot/noble-amd64 \
  http://archive.ubuntu.com/ubuntu
```

Update the chroot:

```bash
sudo sbuild-update -udcar noble-amd64
```

Create the `arm64` sbuild chroot with the Ubuntu ports mirror:

```bash
sudo sbuild-createchroot \
  --arch=arm64 \
  --chroot-suffix= \
  --components=main,universe \
  --include=eatmydata,ccache,gnupg,ca-certificates \
  noble \
  /srv/chroot/noble-arm64 \
  http://ports.ubuntu.com/ubuntu-ports
```

Update the chroot:

```bash
sudo sbuild-update -udcar noble-arm64
```

## Version variables

The Noble scripts keep Debian source package versions separate from Ubuntu
backport versions. Default versions come from the `Makefile` and Noble build
scripts:

```text
NODE_UNDICI_DEBIAN_VERSION=7.3.0+dfsg1+~cs24.12.11-1
NODE_UNDICI_NOBLE_VERSION=7.3.0+dfsg1+~cs24.12.11-1

OCSERV_DEBIAN_VERSION=1.5.0-1
OCSERV_NOBLE_VERSION=1.5.0-1~ubuntu24.04.1

TARGET_SUITE=noble
TARGET_ARCH=amd64  # Optional explicit override; auto-detected by the Noble script when unset
```

`*_DEBIAN_VERSION` is used only for `source-lock/` and Debian pool downloads.
`*_NOBLE_VERSION` is used only for `debian/changelog` and the final Noble build
artifacts. Do not put `~ubuntu24.04.*` in `source-lock` paths.

If the build host uses non-standard Debian keyring paths, override the default
candidates with a colon-separated list:

```bash
DSCVERIFY_KEYRING_PATHS=/path/to/debian-keyring.gpg:/path/to/extra.gpg make noble-build
```

## Manual build commands

Run the full build:

```bash
make noble-build
```

Build a specific architecture:

```bash
TARGET_ARCH=arm64 make noble-build
```

`TARGET_ARCH=arm64` only adjusts paths, repository layout, artifact matching,
and the `--arch` argument passed to sbuild. The caller must already provide a
matching native-capable Noble sbuild/schroot environment or runner for the
target architecture. The scripts do not configure cross-build, QEMU, or binfmt.

To run the build in stages, execute the following targets in order:

```bash
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

## Artifact directories

Noble artifacts are isolated by architecture:

```text
build/ubuntu/noble/${TARGET_ARCH}/source/node-undici/
build/ubuntu/noble/${TARGET_ARCH}/source/ocserv/
build/ubuntu/noble/${TARGET_ARCH}/binary/node-undici/
build/ubuntu/noble/${TARGET_ARCH}/binary/ocserv/
build/ubuntu/noble/${TARGET_ARCH}/repo/
build/ubuntu/noble/${TARGET_ARCH}/keyrings/debian/
```

The final `ocserv` package is located in:

```text
build/ubuntu/noble/${TARGET_ARCH}/binary/ocserv/
```

Source package artifacts are located in:

```text
build/ubuntu/noble/${TARGET_ARCH}/source/node-undici/
build/ubuntu/noble/${TARGET_ARCH}/source/ocserv/
```

`noble-repo` creates the temporary local repository required to build `ocserv`:

```text
build/ubuntu/noble/${TARGET_ARCH}/repo/
```

When the automatic build refreshes the Debian source signature verification
keyring, it stores the temporary keyring in:

```text
build/ubuntu/noble/${TARGET_ARCH}/keyrings/debian/
```

## GitHub Actions

Pull request CI runs only static checks, lock verification, unit tests, and
stub orchestration tests.

Pull request CI does not create an sbuild chroot, run the Docker smoke test, or
build or upload binary `.deb` files. Changes limited to `docs/**` usually do
not trigger this PR CI; trigger the workflow manually when needed.

The manual workflow `.github/workflows/ubuntu-noble-build.yml` uses this
architecture matrix:

```text
amd64 -> ubuntu-24.04
arm64 -> ubuntu-24.04-arm
```

The workflow uses `scripts/noble-auto-build.sh --provision` on GitHub-hosted
runners to prepare the Noble sbuild environment, run the full Noble binary
build, lintian, and Docker smoke validation, and upload build artifacts.

On success, the artifact names are `ubuntu-noble-build-amd64` and
`ubuntu-noble-build-arm64`. The log artifact names are
`ubuntu-noble-build-logs-amd64` and `ubuntu-noble-build-logs-arm64`; the
workflow also attempts to upload them on failure.
