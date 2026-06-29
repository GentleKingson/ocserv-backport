# 在 Ubuntu 24.04 Noble 上构建 ocserv backport

本文档说明如何在 Ubuntu 24.04 Noble 构建机上构建 `ocserv 1.5.0`
本地 backport 包。优先使用自动构建；只有需要完全手动准备环境时，再看手动构建部分。

## 自动构建前置条件

使用自动构建前，准备好：

- 一台 Ubuntu 24.04 Noble 构建机。
- 当前用户有 root 或 sudo 权限。
- 构建机能访问 Debian mirror、Ubuntu mirror、Docker 官方 APT 源和 GitHub。
- 构建机是 native `amd64` 或 `arm64`；`arm64` 构建应在原生 arm64
  Ubuntu 24.04 主机或 runner 上执行。

如果使用 `--provision`，不需要预先安装 `sbuild`、`schroot`、`lintian`
或 Docker；脚本会准备这些工具。如果使用无参数模式，这些工具和对应
Noble sbuild chroot 需要已经可用。

## 自动构建

如果还没有仓库，先克隆并进入仓库目录：

```bash
git clone https://github.com/GentleKingson/ocserv-backport.git
cd ocserv-backport
```

如果环境已经准备好，运行默认检查并构建：

```bash
scripts/noble-auto-build.sh
```

这个模式不会安装依赖、配置 Docker CE 或创建 sbuild chroot；它只检查现有环境。
检查通过后，脚本会继续运行完整 Noble 构建。

如果这是新的 Ubuntu 24.04 Noble 构建机，或默认检查提示需要准备环境，运行：

```bash
scripts/noble-auto-build.sh --provision
```

`--provision` 会安装构建依赖、检查 Debian source signature verification
keyring、配置 Docker CE，并在确认后创建 `noble-${TARGET_ARCH}` sbuild chroot。

无人值守环境可以使用：

```bash
scripts/noble-auto-build.sh --provision --yes
```

`--yes` 仅自动确认“缺少 sbuild chroot 时创建 chroot”这一项；它不会绕过
已存在目录、损坏 chroot、非 native 架构 guard 或其他安全检查。

如果普通用户首次加入 `sbuild` 组，脚本会提示在新 shell 中继续；按提示进入
新 shell 后重新运行自动构建即可。

未设置 `TARGET_ARCH` 时，Noble 脚本会自动检测 native `amd64`/`arm64`。
也可以显式设置 `TARGET_ARCH` 覆盖目标架构。显式目标架构与 native 架构不一致时，
脚本会 warning 后继续，但不会配置 cross-build、QEMU 或 binfmt；调用方必须已经
准备好匹配目标架构的 native-capable chroot 或 runner。

## 手动构建前置条件

选择不使用自动 `--provision` 时，需要自行准备：

- 一台 Ubuntu 24.04 Noble 构建机。
- 当前用户有 root 或 sudo 权限。
- 构建机能访问 Debian mirror、Ubuntu mirror、Docker 官方 APT 源和 GitHub。
- 构建机可以使用 `sbuild`、`schroot`、`lintian` 和 Docker CE。
- 目标架构对应的 Noble sbuild chroot 已创建并可用。
- Debian source signature verification keyring 可读。

## 手动准备构建机

更新 apt 索引：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 update
```

安装构建工具：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends \
  git ca-certificates curl gnupg \
  build-essential fakeroot devscripts dpkg-dev debhelper dh-nodejs \
  debian-archive-keyring debian-keyring debian-maintainers \
  sbuild schroot debootstrap lintian \
  python3 python3-yaml bats shellcheck
```

安装 Docker CE：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

cat <<EOF | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 update
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

创建默认 `amd64` sbuild chroot：

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

创建 `arm64` sbuild chroot 时使用 Ubuntu ports mirror：

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

普通用户需要加入 `sbuild` 组：

```bash
sudo sbuild-adduser "$USER"
newgrp sbuild
```

## 版本变量

Noble 脚本把 Debian 源包版本和 Ubuntu backport 版本分开：

```text
NODE_UNDICI_DEBIAN_VERSION=7.3.0+dfsg1+~cs24.12.11-1
NODE_UNDICI_NOBLE_VERSION=7.3.0+dfsg1+~cs24.12.11-1

OCSERV_DEBIAN_VERSION=1.5.0-1
OCSERV_NOBLE_VERSION=1.5.0-1~ubuntu24.04.1

TARGET_SUITE=noble
TARGET_ARCH=amd64  # 可选显式覆盖；未设置时由 Noble 脚本自动检测
```

`*_DEBIAN_VERSION` 只用于 `source-lock/` 和 Debian pool 下载。
`*_NOBLE_VERSION` 只用于 `debian/changelog` 和最终 Noble 构建产物。
不要把 `~ubuntu24.04.*` 写入 `source-lock` 路径。

如果构建机使用非标准 Debian keyring 路径，可以用冒号分隔列表覆盖默认候选项：

```bash
DSCVERIFY_KEYRING_PATHS=/path/to/debian-keyring.gpg:/path/to/extra.gpg make noble-build
```

## 手动构建命令

完整构建：

```bash
make noble-build
```

指定架构构建：

```bash
TARGET_ARCH=arm64 make noble-build
```

`TARGET_ARCH=arm64` 只会调整路径、repo、产物匹配和 sbuild 的 `--arch` 参数。
调用方必须已经准备好可用的 arm64 Noble sbuild/schroot 环境；脚本不会配置
cross-build、QEMU 或 binfmt。

需要分阶段运行时，按下面顺序执行：

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

## 产物目录

Noble 产物按架构隔离：

```text
build/ubuntu/noble/${TARGET_ARCH}/source/node-undici/
build/ubuntu/noble/${TARGET_ARCH}/source/ocserv/
build/ubuntu/noble/${TARGET_ARCH}/binary/node-undici/
build/ubuntu/noble/${TARGET_ARCH}/binary/ocserv/
build/ubuntu/noble/${TARGET_ARCH}/repo/
```

最终 `ocserv` 包位于：

```text
build/ubuntu/noble/${TARGET_ARCH}/binary/ocserv/
```

`noble-repo` 会在本机生成构建 `ocserv` 所需的临时本地 repo：

```text
build/ubuntu/noble/${TARGET_ARCH}/repo/
```

## GitHub Actions

手动 workflow `.github/workflows/ubuntu-noble-build.yml` 使用架构矩阵：

```text
amd64 -> ubuntu-24.04
arm64 -> ubuntu-24.04-arm
```

两个 job 都运行完整 Noble binary build、lintian 和 Docker smoke validation。
成功时 artifact 名称分别是 `ubuntu-noble-build-amd64` 和
`ubuntu-noble-build-arm64`。失败日志 artifact 也按架构区分。
