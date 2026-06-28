# 在 Debian 13 上构建 ocserv backport

本文档说明如何在 Debian 13 trixie 干净构建环境中，把 Debian sid 的
`ocserv 1.5.0-1` 源码重建成本地 backport 包。

仓库默认生成的本地版本号是：

```text
1.5.0-1~debian13.1
```

需要修改版本号时，使用 `OCSERV_VERSION` 环境变量覆盖。

## 前置条件

准备一台 Debian 13 trixie amd64 构建机。

需要 root 或 sudo 权限。

需要能访问 Debian mirror 和 GitHub。

完整本地构建会使用 sbuild、schroot、lintian 和 Docker。

## 安装工具

更新 apt 索引：

```bash
sudo apt update
```

安装构建工具：

```bash
sudo apt install -y --no-install-recommends \
  git ca-certificates curl gnupg \
  build-essential fakeroot devscripts dpkg-dev \
  debian-archive-keyring debian-keyring debian-maintainers \
  sbuild schroot debootstrap lintian libdistro-info-perl docker.io \
  python3 python3-yaml bats shellcheck
```

## 只有 root 用户时创建构建用户

如果当前系统只有 root 用户，先创建一个普通构建用户。

默认示例用户名是 `builder`，可以替换成你自己的用户名：

```bash
adduser builder
```

允许该用户使用 sudo：

```bash
usermod -aG sudo builder
```

切换到构建用户：

```bash
su - builder
```

后续命令都在这个普通构建用户下执行。

## 配置构建用户组

把当前用户加入 `sbuild` 组：

```bash
sudo sbuild-adduser "$USER"
```

把当前用户加入 `docker` 组：

```bash
sudo usermod -aG docker "$USER"
```

完整执行 `make build` 前，重新登录，让 `sbuild` 和 `docker` 组权限生效。

如果现在只想继续创建 sbuild chroot，可以临时进入 `sbuild` 组：

```bash
newgrp sbuild
```

## 创建 trixie sbuild chroot

创建 amd64 chroot：

```bash
sudo sbuild-createchroot \
  --arch=amd64 \
  --include=eatmydata,ccache,gnupg,ca-certificates \
  trixie \
  /srv/chroot/trixie-amd64-sbuild \
  http://deb.debian.org/debian
```

更新 chroot：

```bash
sudo sbuild-update -udcar trixie-amd64-sbuild
```

## 获取仓库

克隆仓库：

```bash
git clone https://github.com/GentleKingson/ocserv-backport.git
```

进入目录：

```bash
cd ocserv-backport
```

## 构建本地 backport

推荐先让自动包装脚本检查环境：

```bash
scripts/debian-auto-build.sh
```

环境已经准备好时，脚本会继续运行 `make build`。`make debian-auto-build`
等价于这个默认检查模式。

需要脚本代为准备构建机时，使用：

```bash
scripts/debian-auto-build.sh --provision
```

`--provision` 会安装构建依赖、检查 Debian source signature verification
keyring、检查 Docker，并在确认后创建 `trixie-amd64-sbuild` sbuild chroot。
普通用户首次加入 `sbuild` 组后，需要在新 shell 中继续：

```bash
newgrp sbuild
scripts/debian-auto-build.sh --provision
```

运行完整本地构建入口：

```bash
make build
```

该命令会按顺序执行：

```text
verify-lock -> fetch -> rewrap -> src-pkg -> binary -> lint -> smoke-basic
```

它会生成本地构建产物，不会发布包，不会部署主机，也不会修改外部仓库。

## 指定本地版本号

默认版本号是：

```text
1.5.0-1~debian13.1
```

使用环境变量覆盖版本号：

```bash
OCSERV_VERSION=1.5.0-1~debian13.2 make build
```

## 查看产物

查看 source package 产物：

```bash
ls -lh build/source/
```

查看二进制 `.deb` 产物：

```bash
ls -lh build/binary/
```

## 只构建 source package

只运行 source package 链路：

```bash
make source-ci
```

该命令只执行：

```text
verify-lock -> fetch -> rewrap -> src-pkg
```

它不会运行 sbuild 二进制构建，不会运行 lintian，也不会运行 Docker smoke test。

## 运行脚本测试

运行一键入口的 stub 编排测试：

```bash
make ci-script-test
```

运行完整 Bats 测试：

```bash
make test
```

## 兼容入口

`make dry-run` 是兼容别名，会转发到完整本地构建入口：

```bash
make dry-run
```

新脚本和新文档应优先使用：

```bash
make build
```

## GitHub Actions 边界

Pull request CI 只运行静态检查、锁文件验证、单测和 stub 编排测试。

Pull request CI 不创建 sbuild chroot，不运行 Docker smoke test，也不构建或上传
二进制 `.deb` 文件。

手动 Debian Trixie build workflow 在 GitHub-hosted `ubuntu-24.04` runner
上准备 trixie sbuild 环境，运行完整 Debian 二进制构建、lintian 和 Docker
smoke validation，并上传构建产物。

手动或定时 source CI 在 `debian:trixie` 容器中只构建 source package artifact。

source CI 不运行 `binary`、`lint` 或 `smoke-basic`。
