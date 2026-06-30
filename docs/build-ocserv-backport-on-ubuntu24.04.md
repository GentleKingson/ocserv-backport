# 在 Ubuntu 24.04 Noble 上构建 ocserv backport

本文档说明如何在 Ubuntu 24.04 Noble 构建机上构建 `ocserv 1.5.0`
本地 backport 包。优先使用自动构建；只有需要完全手动准备环境时，再看手动构建部分。

## 自动构建前置条件

使用自动构建前，准备好：

- 一台 Ubuntu 24.04 Noble 构建机。
- 当前用户有 root 或 sudo 权限。
- 构建机能访问 Debian mirror、Ubuntu mirror、Docker 官方 APT 源、Docker registry
  和 GitHub。
- 构建机是 native `amd64` 或 `arm64`；`arm64` 构建应在原生 arm64
  Ubuntu 24.04 主机或 runner 上执行。

如果使用 `--provision`，不需要预先安装 `sbuild`、`schroot`、`lintian`
或 Docker；脚本会准备这些工具。如果使用无参数模式，这些工具、Debian source
signature verification keyring 和对应 Noble sbuild chroot 需要已经可用。

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
检查通过后，脚本会继续运行完整 Ubuntu Noble 构建。

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
已存在目录、损坏 chroot、Docker CE 检查或其他安全检查。

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
- 构建机能访问 Debian mirror、Ubuntu mirror、Docker 官方 APT 源、Docker registry
  和 GitHub。
- 构建机可以使用 `sbuild`、`schroot`、`lintian` 和 Docker CE。
- 目标架构对应的 Noble sbuild chroot 已创建并可用。
- Debian source signature verification keyring 可读。
- 普通构建用户已经具备 `sbuild` 组权限；直接运行 `make noble-build` 时还需要可访问
  Docker daemon。

## 手动准备构建机

以下步骤只适用于不使用 `scripts/noble-auto-build.sh --provision` 的场景。
如果已经让自动脚本准备构建机，不要重复执行本节中的 chroot 创建或用户组配置。

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

如果当前系统只有 root 用户，先创建一个普通构建用户：

```bash
adduser builder
usermod -aG sudo builder
su - builder
```

普通用户需要加入 `sbuild` 组：

```bash
sudo sbuild-adduser "$USER"
newgrp sbuild
```

默认手动构建会直接运行 `docker`。如果需要让普通用户直接运行 `docker info`
或 `docker run`，把当前用户加入 `docker` 组后重新登录：

```bash
sudo usermod -aG docker "$USER"
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

更新 chroot：

```bash
sudo sbuild-update -udcar noble-amd64
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

更新 chroot：

```bash
sudo sbuild-update -udcar noble-arm64
```

## 版本变量

Noble 脚本把 Debian 源包版本和 Ubuntu backport 版本分开。默认版本号来自
`Makefile` 和 Noble 构建脚本：

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
调用方必须已经准备好匹配目标架构的 native-capable Noble sbuild/schroot
环境或 runner；脚本不会配置 cross-build、QEMU 或 binfmt。

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
build/ubuntu/noble/${TARGET_ARCH}/keyrings/debian/
```

最终 `ocserv` 包位于：

```text
build/ubuntu/noble/${TARGET_ARCH}/binary/ocserv/
```

source package 产物位于：

```text
build/ubuntu/noble/${TARGET_ARCH}/source/node-undici/
build/ubuntu/noble/${TARGET_ARCH}/source/ocserv/
```

`noble-repo` 会在本机生成构建 `ocserv` 所需的临时本地 repo：

```text
build/ubuntu/noble/${TARGET_ARCH}/repo/
```

自动构建刷新 Debian source signature verification keyring 时，会把临时 keyring
放在：

```text
build/ubuntu/noble/${TARGET_ARCH}/keyrings/debian/
```

## GitHub Actions

Pull request CI 只运行静态检查、锁文件验证、单测和 stub 编排测试。

Pull request CI 不创建 sbuild chroot，不运行 Docker smoke test，也不构建或上传
二进制 `.deb` 文件。仅修改 `docs/**` 通常不会触发这个 PR CI；需要时可以手动
触发 workflow。

手动 workflow `.github/workflows/ubuntu-noble-build.yml` 使用架构矩阵：

```text
amd64 -> ubuntu-24.04
arm64 -> ubuntu-24.04-arm
```

workflow 会在 GitHub-hosted runner 上通过
`scripts/noble-auto-build.sh --provision` 准备 Noble sbuild 环境，运行完整
Noble binary build、lintian 和 Docker smoke validation，并上传构建产物。

成功时 artifact 名称分别是 `ubuntu-noble-build-amd64` 和
`ubuntu-noble-build-arm64`。日志 artifact 名称分别是
`ubuntu-noble-build-logs-amd64` 和 `ubuntu-noble-build-logs-arm64`，失败时也
会尝试上传。
