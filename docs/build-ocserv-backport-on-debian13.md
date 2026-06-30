# 在 Debian 13 trixie 上构建 ocserv backport

本文档说明如何在 Debian 13 trixie 构建机上构建 `ocserv 1.5.0`
本地 backport 包。优先使用自动构建；只有需要完全手动准备环境时，再看手动构建部分。

仓库默认生成的本地版本号是 `1.5.0-1~debian13.1`。需要修改版本号时，
使用 `OCSERV_VERSION` 环境变量覆盖。

## 自动构建前置条件

使用自动构建前，准备好：

- 一台 Debian 13 trixie 构建机。
- 当前用户有 root 或 sudo 权限。
- 构建机能访问 Debian mirror、Docker 官方 APT 源、Docker registry 和 GitHub。
- 构建机是 native `amd64` 或 `arm64`；`arm64` 构建应在原生 arm64
  Debian 13 主机或 runner 上执行。

如果使用 `--provision`，不需要预先安装 `sbuild`、`schroot`、`lintian`
或 Docker；脚本会准备这些工具。如果使用无参数模式，这些工具、Debian source
signature verification keyring 和对应 trixie sbuild chroot 需要已经可用。

## 自动构建

如果还没有仓库，先克隆并进入仓库目录：

```bash
git clone https://github.com/GentleKingson/ocserv-backport.git
cd ocserv-backport
```

如果环境已经准备好，运行默认检查并构建：

```bash
scripts/trixie-auto-build.sh
```

这个模式不会安装依赖、配置 Docker CE 或创建 sbuild chroot；它只检查现有环境。
检查通过后，脚本会继续运行完整 Debian trixie 构建。

如果这是新的 Debian 13 trixie 构建机，或默认检查提示需要准备环境，运行：

```bash
scripts/trixie-auto-build.sh --provision
```

`--provision` 会安装构建依赖、检查 Debian source signature verification
keyring、配置 Docker CE，并在确认后创建 `trixie-${TARGET_ARCH}-sbuild`
sbuild chroot。

无人值守环境可以使用：

```bash
scripts/trixie-auto-build.sh --provision --yes
```

`--yes` 仅自动确认“缺少 sbuild chroot 时创建 chroot”这一项；它不会绕过
已存在目录、损坏 chroot、非 native 架构 guard 或其他安全检查。

如果普通用户首次加入 `sbuild` 组，脚本会提示在新 shell 中继续；按提示进入
新 shell 后重新运行自动构建即可。

未设置 `TARGET_ARCH` 时，Debian 脚本会自动检测 native `amd64`/`arm64`。
也可以显式设置 `TARGET_ARCH` 覆盖目标架构，支持别名 `x86_64 -> amd64` 和
`aarch64 -> arm64`。默认只支持 native 架构；如果显式目标架构与 native 架构
不一致，脚本会提前失败。

只有已经手动准备好 unsupported 非 native 构建环境时，才可以设置：

```bash
ALLOW_NON_NATIVE_TARGET_ARCH=1 TARGET_ARCH=arm64 make trixie-build
```

`ALLOW_NON_NATIVE_TARGET_ARCH=1` 只绕过 native 架构 guard。它不会配置
cross-build、QEMU、binfmt 或 foreign-arch chroot；该路径不由本项目支持。

## 手动构建前置条件

选择不使用自动 `--provision` 时，需要自行准备：

- 一台 Debian 13 trixie 构建机。
- 当前用户有 root 或 sudo 权限。
- 构建机能访问 Debian mirror、Docker 官方 APT 源、Docker registry 和 GitHub。
- 构建机可以使用 `sbuild`、`schroot`、`lintian` 和 Docker CE。
- 目标架构对应的 `trixie-${TARGET_ARCH}-sbuild` sbuild chroot 已创建并可用。
- Debian source signature verification keyring 可读。
- 普通构建用户已经具备 `sbuild` 组权限；直接运行 `make trixie-build` 时还需要可访问
  Docker daemon。

## 手动准备构建机

以下步骤只适用于不使用 `scripts/trixie-auto-build.sh --provision` 的场景。
如果已经让自动脚本准备构建机，不要重复执行本节中的 chroot 创建或用户组配置。

更新 apt 索引：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 update
```

安装构建工具：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends \
  git ca-certificates curl gnupg \
  build-essential fakeroot devscripts dpkg-dev debhelper \
  debian-archive-keyring debian-keyring debian-maintainers \
  sbuild schroot debootstrap lintian libdistro-info-perl \
  python3 python3-yaml bats shellcheck make
```

安装 Docker CE：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 remove -y \
  docker.io docker-doc docker-compose docker-compose-v2 podman-docker \
  containerd runc || true
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

cat <<EOF | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
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
  --chroot-suffix=-sbuild \
  --include=eatmydata,ccache,gnupg,ca-certificates \
  trixie \
  /srv/chroot/trixie-amd64-sbuild \
  http://deb.debian.org/debian
```

更新 chroot：

```bash
sudo sbuild-update -udcar trixie-amd64-sbuild
```

创建 `arm64` sbuild chroot 时使用相同 Debian mirror：

```bash
sudo sbuild-createchroot \
  --arch=arm64 \
  --chroot-suffix=-sbuild \
  --include=eatmydata,ccache,gnupg,ca-certificates \
  trixie \
  /srv/chroot/trixie-arm64-sbuild \
  http://deb.debian.org/debian
```

更新 chroot：

```bash
sudo sbuild-update -udcar trixie-arm64-sbuild
```

## 版本变量

Debian 脚本把 Debian 源包版本和本地 backport 版本分开。默认本地版本号来自
`Makefile` 和 Debian 构建脚本：

```text
OCSERV_VERSION=1.5.0-1~debian13.1

TARGET_SUITE=trixie
TARGET_ARCH=amd64  # 可选显式覆盖；未设置时由 Debian 脚本自动检测
```

`OCSERV_VERSION` 用于 `debian/changelog` 和最终 Debian trixie 构建产物。
Debian 源包身份由 `source-lock/` 中锁定的 `ocserv 1.5.0-1` 定义；不要把
`~debian13.*` 本地 backport 版本写入 `source-lock` 路径。

使用环境变量覆盖本地版本号：

```bash
OCSERV_VERSION=1.5.0-1~debian13.2 make trixie-build
```

如果构建机使用非标准 Debian keyring 路径，可以用冒号分隔列表覆盖默认候选项：

```bash
DSCVERIFY_KEYRING_PATHS=/path/to/debian-keyring.gpg:/path/to/extra.gpg make trixie-build
```

## 手动构建命令

完整构建：

```bash
make trixie-build
```

指定架构构建：

```bash
TARGET_ARCH=arm64 make trixie-build
```

`TARGET_ARCH=arm64` 只会调整路径、产物匹配和 sbuild 的 `--arch` 参数。
调用方必须已经准备好可用的 native arm64 构建机和 arm64 sbuild/schroot
环境；脚本不会配置 cross-build、QEMU 或 binfmt。

需要分阶段运行时，按下面顺序执行：

```bash
make trixie-verify-locks
make trixie-fetch-ocserv
make trixie-rewrap-ocserv
make trixie-src-pkg-ocserv
make trixie-binary-ocserv
make trixie-lint
make trixie-smoke-basic
```

只运行 source package 链路：

```bash
make trixie-source-ci
```

`make trixie-source-ci` 只执行：

```text
trixie-verify-locks -> trixie-fetch-ocserv -> trixie-rewrap-ocserv -> trixie-src-pkg-ocserv
```

它不会运行 sbuild 二进制构建，不会运行 lintian，也不会运行 Docker smoke test。
完整 `.deb` 构建仍依赖 native sbuild 环境或手动 Debian Trixie build workflow。

## 产物目录

Debian trixie 产物按架构隔离：

```text
build/debian/trixie/${TARGET_ARCH}/source/
build/debian/trixie/${TARGET_ARCH}/binary/
build/debian/trixie/${TARGET_ARCH}/keyrings/debian/
```

最终 `ocserv` 包位于：

```text
build/debian/trixie/${TARGET_ARCH}/binary/
```

source package 产物位于：

```text
build/debian/trixie/${TARGET_ARCH}/source/
```

自动构建刷新 Debian source signature verification keyring 时，会把临时 keyring
放在：

```text
build/debian/trixie/${TARGET_ARCH}/keyrings/debian/
```

## GitHub Actions

Pull request CI 只运行静态检查、锁文件验证、单测和 stub 编排测试。

Pull request CI 不创建 sbuild chroot，不运行 Docker smoke test，也不构建或上传
二进制 `.deb` 文件。仅修改 `docs/**` 通常不会触发这个 PR CI；需要时可以手动
触发 workflow。

`ci.yml` workflow 会在每周定时任务中验证 source package 构建链路，也可以通过
手动触发时选择 `target=source-package` 或 `target=all` 运行。该路径在
`debian:trixie` 容器中执行：

```text
trixie-verify-locks -> trixie-fetch-ocserv -> trixie-rewrap-ocserv -> trixie-src-pkg-ocserv
```

source CI 不运行 `trixie-binary-ocserv`、`trixie-lint` 或
`trixie-smoke-basic`，也不上传 GitHub Actions artifacts。

手动 workflow `.github/workflows/debian-trixie-build.yml` 使用架构矩阵：

```text
amd64 -> ubuntu-24.04
arm64 -> ubuntu-24.04-arm
```

两个 job 的固定 check 名分别是 `debian-trixie-build-amd64` 和
`debian-trixie-build-arm64`。workflow 会在 GitHub-hosted runner 上通过
`scripts/trixie-auto-build.sh --provision` 准备 trixie sbuild 环境，运行完整
Debian 二进制构建、lintian 和 Docker smoke validation，并上传构建产物。

成功时 artifact 名称分别是 `debian-trixie-build-amd64` 和
`debian-trixie-build-arm64`。日志 artifact 名称分别是
`debian-trixie-build-logs-amd64` 和 `debian-trixie-build-logs-arm64`，失败时也
会尝试上传。
