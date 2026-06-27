# 在 Ubuntu 24.04 上构建 ocserv 1.5.0 backport

本文档说明如何在 Ubuntu 24.04 Noble 干净构建环境中，用两级流程构建
`ocserv 1.5.0` 本地 backport 包。

现有 Debian 13/trixie 流程保持不变：

```bash
make build
```

Ubuntu 24.04 Noble 使用专用入口：

```bash
make noble-build
```

## 前置条件

准备一台 Ubuntu 24.04 Noble 构建机。

需要 root 或 sudo 权限。

需要能访问 Debian mirror 和 GitHub。

完整本地构建会使用 sbuild、schroot、lintian 和 Docker。

## 自动准备并构建

Noble 构建机可以先使用自动包装脚本检查环境：

```bash
scripts/noble-auto-build.sh
```

这个默认模式只检查并打印修复命令，不会安装软件包、写入 Docker APT 配置、启动
daemon、修改用户组或创建 chroot。环境已经准备好时，它会继续运行
`make noble-build`。`make noble-auto-build` 等价于这个默认检查模式。

需要脚本代为准备主机时，使用：

```bash
scripts/noble-auto-build.sh --provision
```

`--provision` 会安装构建依赖，检查 Debian `dscverify` keyring，配置 Docker CE，
并移除会和 Docker CE 冲突的 Ubuntu `docker.io` / `containerd` 相关包。Docker
必须来自 Docker 官方 APT 源；脚本会写入 `download.docker.com` 的 Noble APT
source 并安装 `docker-ce`、`docker-ce-cli`、`containerd.io`、
`docker-buildx-plugin` 和 `docker-compose-plugin`。宿主 apt 操作会使用
`apt-get -q=1 -o=Dpkg::Use-Pty=0` 静默执行；成功时隐藏 apt 过程输出，失败时显示
原始 apt 错误。Noble binary 阶段的 `sbuild` 成功输出也会静默，隐藏 chroot 内部
apt/build 细节；失败时会显示原始 `sbuild` 输出。如果 Docker 已安装但 daemon 不可达，
provision 模式会尝试有限修复：

```bash
sudo systemctl enable --now docker
```

普通用户还需要有效的 `sbuild` 组成员身份。默认模式会打印：

```bash
sudo sbuild-adduser "$USER"
newgrp sbuild
scripts/noble-auto-build.sh --provision
```

provision 模式可以执行 `sbuild-adduser`，但刚加入的组不会自动出现在旧 shell
里；脚本不会在旧 shell 中继续构建。按提示执行 `newgrp sbuild` 后，在新 shell
重新运行 `scripts/noble-auto-build.sh --provision`。

如果缺少 sbuild chroot，默认模式只打印创建命令。provision 模式会先提示
`Type yes to create this chroot now:`，只有输入完整的 `yes` 后才会执行
`sbuild-createchroot` 创建 `noble-${TARGET_ARCH}` chroot。自动创建命令会启用
`main,universe` 组件，因为 `ccache` 在 Ubuntu Noble 的 `universe` 组件中：

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

如果目标目录已经存在但 `schroot` / `sbuild` 没有注册对应 chroot，脚本不会继续
覆盖创建，也不会自动删除目录。确认这是失败的 chroot 创建残留后，再手工删除并
重新运行 provision。

Noble binary 阶段会显式传入：

```text
--chroot=noble-${TARGET_ARCH}
```

因此 `schroot -l` / `sbuild --list-chroots` 至少需要能看到 `noble-amd64` 或
`chroot:noble-amd64` 这类可直接用于构建 session 的条目。只有
`source:noble-amd64` 不会被视为可用构建 chroot。自动包装脚本还会实际运行空
session 验证：

```bash
schroot -c noble-amd64 -u root -- true
```

只有注册名存在且 session 能创建成功时，才会继续运行 `make noble-build`。

`TARGET_ARCH` 默认是 `amd64`。使用 `TARGET_ARCH=arm64` 时，自动包装脚本只会选择
ports mirror，并创建或检查 `noble-arm64` sbuild chroot；它不会配置
qemu/binfmt，也不会把 amd64 主机变成自动 cross-build 环境。

下面的手动安装章节仍保留，用于审计、复现包装脚本行为和排障。

## 安装工具

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

`debian-keyring` 是必需的。fetch 阶段会用 `dscverify` 验证 Debian `.dsc`
签名；如果没有任何可读 Debian keyring，脚本会提前失败，而不会降级成跳过签名
验证。`debhelper` 和 `dh-nodejs` 也是 Noble 源码包阶段的宿主依赖：
`dpkg-buildpackage -S` 会执行 `debian/rules clean`，`node-undici` 的 clean 阶段
需要 `dh` 和 `pkgjs-pjson`。

## 安装 Docker CE

`noble-smoke-basic` 会使用 Docker 运行 Ubuntu 24.04 容器。Noble 构建机推荐按
Docker 官方 Ubuntu 安装方法安装 Docker CE，不要把 Ubuntu `docker.io` 和 Docker
CE 的 `containerd.io` 混装。

如果已经错误安装过 Ubuntu Docker 相关包，先移除可能冲突的包：

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 remove -y "$pkg"
done
```

添加 Docker 官方 APT 源：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 update
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
```

安装 Docker CE：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

验证 Docker：

```bash
sudo systemctl status docker
sudo docker run hello-world
```

## 为什么需要 node-undici

Ubuntu 24.04 Noble 官方 `ocserv` 仍来自旧版本，构建依赖使用
`libhttp-parser-dev`。Debian sid 的 `ocserv 1.5.0-1` 已改用
`libllhttp-dev`。

在 Debian trixie 中，`libllhttp-dev` 和运行时库 `libllhttp9.2` 来自
`node-undici` 源包。因此 Noble 流程先 backport `node-undici`，再用产出的
`libllhttp-dev` 构建 `ocserv`。

```text
Debian node-undici source
  -> libllhttp9.2 + libllhttp-dev
  -> local file APT repo
  -> Debian ocserv source
  -> Ubuntu 24.04 Noble ocserv .deb
```

## 版本变量

Noble 脚本把 Debian 源包版本和 Ubuntu backport 版本分开：

```text
NODE_UNDICI_DEBIAN_VERSION=7.3.0+dfsg1+~cs24.12.11-1
NODE_UNDICI_NOBLE_VERSION=7.3.0+dfsg1+~cs24.12.11-1

OCSERV_DEBIAN_VERSION=1.5.0-1
OCSERV_NOBLE_VERSION=1.5.0-1~ubuntu24.04.1

TARGET_DISTRIBUTION=noble
TARGET_ARCH=amd64
```

`*_DEBIAN_VERSION` 只用于 `source-lock/` 和 Debian pool 下载。
`*_NOBLE_VERSION` 只用于 `debian/changelog` 和最终 Noble 构建产物。
默认情况下，`NODE_UNDICI_NOBLE_VERSION` 等于 `NODE_UNDICI_DEBIAN_VERSION`。

不要把 `~ubuntu24.04.*` 写入 `source-lock` 路径。

`node-undici` 的 Noble 默认版本固定为 Debian 原版本
`7.3.0+dfsg1+~cs24.12.11-1`。本仓库在 rewrap 阶段会把顶层 changelog
distribution 改为 `noble`，并修改 `debian/rules`，让 binary build 的
`dh_auto_configure` 前生成 `types/package.json` 并向
`llparse-builder/tsconfig.json` 注入 `paths` 映射。生成 `types/package.json`
只是 dh-nodejs 链接 `node_modules/undici-types` 的前置条件；真正消除
`TS2307` 的是 tsconfig `paths` 注入：tsc 默认会把 `@types/node` 符号链接解析到
真实路径 `/usr/share/nodejs/...`，再从真实路径上溯找 `undici-types`，而 Noble
的系统旧版 `node-undici` 没有把 `undici-types` 装到那里，所以构建树里的
`node_modules/undici-types` 链接对 tsc 不可见。`paths` 按 tsconfig 文件位置
解析、不走真实路径上溯，因此能把 `import("undici-types")` 重定向到源码树内的
`types/` 目录。rewrap 脚本会自动迁移旧版本（build-hook 和 configure-only）的
hook。这是同版本、不同源码内容的本地重打包策略，只适用于本仓库的私有 Noble
构建流水线，不适合发布到会和 Debian 官方源混用的通用仓库。

## 源码签名验证 keyring

fetch 脚本默认检查这些候选 keyring：

```text
/usr/share/keyrings/debian-keyring.gpg
/usr/share/keyrings/debian-maintainers.gpg
/usr/share/keyrings/debian-nonupload.gpg
/usr/share/keyrings/debian-tag2upload.pgp
```

脚本只会把实际可读的 keyring 传给 `dscverify`。Ubuntu 24.04 Noble 上可能没有
`debian-tag2upload.pgp`，这种缺失不会单独阻塞构建。

至少需要一个 Debian keyring 可读。常规修复方式是：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends debian-keyring
```

如果构建机使用非标准 keyring 路径，可以用冒号分隔列表覆盖默认候选项：

```bash
DSCVERIFY_KEYRING_PATHS=/path/to/debian-keyring.gpg:/path/to/extra.gpg make noble-build
```

## 产物目录

Noble 产物按架构隔离：

```text
build/noble/${TARGET_ARCH}/source/node-undici/
build/noble/${TARGET_ARCH}/source/ocserv/
build/noble/${TARGET_ARCH}/binary/node-undici/
build/noble/${TARGET_ARCH}/binary/ocserv/
build/noble/${TARGET_ARCH}/repo/
```

`TARGET_ARCH` 默认是 `amd64`。如果要构建 `arm64`：

```bash
TARGET_ARCH=arm64 make noble-build
```

这只会调整路径、repo、产物匹配和 sbuild 的 `--arch` 参数。调用方必须已经准备
好可用的 arm64 Noble sbuild/schroot 环境；本仓库不实现 amd64 主机上的自动
cross-build。

## Noble 流水线

完整入口：

```bash
make noble-build
```

执行顺序：

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

`noble-repo` 必须位于 `noble-binary-node-undici` 之后、
`noble-binary-ocserv` 之前，因为 ocserv 的 Noble clean chroot 需要通过这个本地
repo 安装 `libllhttp-dev`。

## 本地 libllhttp repo

`noble-repo` 只从：

```text
build/noble/${TARGET_ARCH}/binary/node-undici/
```

筛选这两类包：

```text
libllhttp9.2_*.deb
libllhttp-dev_*.deb
```

并生成：

```text
build/noble/${TARGET_ARCH}/repo/Packages
build/noble/${TARGET_ARCH}/repo/Packages.gz
```

它不会默认收集 `node-undici_*.deb` 或 `node-llhttp_*.deb`。

该 repo 只服务本机 clean chroot 构建。它不是生产发布 repo，也不会被发布到外部
APT 仓库。

## sbuild repo 注入

`noble-binary-ocserv` 构建期间会临时启动只绑定 `127.0.0.1` 的 HTTP server，
服务目录是：

```text
build/noble/${TARGET_ARCH}/repo/
```

然后通过 sbuild extra repository 注入：

```text
deb [trusted=yes] http://127.0.0.1:<port>/ ./
```

这样可以避免裸 `file:/host/path` 在 schroot 内不可见的问题。HTTP server 只在
`noble-binary-ocserv` 阶段存在，脚本会在成功、失败或中断时清理该进程。
Noble binary 阶段仍会显示外层阶段和产物日志；静默的只是成功路径中的 `sbuild`
内部输出。若 `sbuild` 失败，脚本会完整打印原始 stdout/stderr。两个 Noble binary
阶段都会显式使用 `--chroot=noble-${TARGET_ARCH}`，避免 sbuild 按默认规则误选
其他同发行版/架构 chroot。失败时脚本还会查找 `--build-dir` 中最新的
`*.build` / `*.buildlog` / `*.log`，打印日志路径和尾部内容，避免只看到
`E: Build failure (dpkg-buildpackage died)`。

## 生产边界

本仓库不自动部署生产 VPS，不配置外部发布仓库，也不管理生产升级策略。

如果生产机使用你自己的私有 APT repo，可以直接：

```bash
sudo apt install ocserv
```

APT 会解析 `ocserv` 对 `libllhttp9.2` 的运行时依赖。

如果手工传包到生产机，至少需要同时携带：

```text
libllhttp9.2_*.deb
ocserv_1.5.0-1~ubuntu24.04.1_*.deb
```

生产机不需要 `libllhttp-dev`、编译器、`devscripts`、`sbuild` 或其他构建工具。

部署前应备份已有配置：

```bash
sudo cp -a /etc/ocserv/ocserv.conf /etc/ocserv/ocserv.conf.before-1.5.0
```

安装后至少验证：

```bash
ocserv --version
sudo ocserv -c /etc/ocserv/ocserv.conf -t
sudo systemctl restart ocserv
sudo systemctl status ocserv
```

## Troubleshooting

### `E: Couldn't find these debs: ccache`

如果 `scripts/noble-auto-build.sh --provision` 创建 chroot 时出现：

```text
E: Couldn't find these debs: ccache
E: Error running debootstrap
```

说明 chroot 创建命令没有启用 Ubuntu Noble 的 `universe` 组件。当前脚本会通过
`sbuild-createchroot --components=main,universe` 处理这个问题。

如果失败前已经留下目录，例如：

```text
/srv/chroot/noble-amd64
```

先确认这个目录确实是失败的本次创建残留，再手工清理：

```bash
sudo rm -rf /srv/chroot/noble-amd64
scripts/noble-auto-build.sh --provision
```

不要让脚本自动删除 `/srv/chroot` 下的目录；该路径可能包含用户已有的 chroot。

### `E: Error creating chroot session: skipping node-undici`

如果 `make noble-build` 在 `noble-binary-node-undici` 阶段出现：

```text
E: Error creating chroot session: skipping node-undici
```

通常说明 Noble sbuild chroot 名称、注册状态或实际目录不符合本仓库约定。
Noble binary 阶段会显式使用 `--chroot=noble-${TARGET_ARCH}`，例如
`--chroot=noble-amd64`。当前 `scripts/noble-auto-build.sh` 会在构建前实际运行
空 session 验证，因此可以提前发现 stale schroot 注册。

检查当前注册的 chroot：

```bash
schroot -l
sbuild --list-chroots
schroot -c noble-amd64 -u root -- true
```

确认输出中存在：

```text
noble-amd64
```

或：

```text
chroot:noble-amd64
```

如果只看到 `source:noble-amd64`，它不是可直接用于 binary build 的 session。
重新运行 `scripts/noble-auto-build.sh --provision` 创建/检查目标 chroot，或按本文
创建命令手工准备 `noble-${TARGET_ARCH}`。

如果 `schroot -l` 能看到 `chroot:noble-amd64`，但 session 验证失败并提示：

```text
Directory /srv/chroot/noble-amd64 does not exist
```

说明 `/etc/schroot` 中仍有 stale 注册，但实际 chroot 目录已经不存在。先定位注册
配置和目录状态：

```bash
sudo grep -R "^\[noble-amd64\]" -n /etc/schroot/chroot.d /etc/schroot/schroot.conf || true
sudo ls -ld /srv/chroot/noble-amd64 || true
schroot -i -c noble-amd64
```

如果配置位于 `/etc/schroot/chroot.d/...`，并确认它是坏的 stale 注册，可以删除
该配置文件并重建 chroot：

```bash
cfg="$(sudo grep -Rl '^\[noble-amd64\]' /etc/schroot/chroot.d 2>/dev/null | head -n1)"
if [ -n "$cfg" ]; then
  sudo rm -f "$cfg"
fi

sudo rm -rf /srv/chroot/noble-amd64
scripts/noble-auto-build.sh --provision
```

如果配置位于 `/etc/schroot/schroot.conf`，不要删除整个文件；只手工编辑并移除
`[noble-amd64]` 这一段，然后重新运行 provision。

### `Cannot find module 'undici-types'`

如果 `make noble-build` 在 `noble-binary-node-undici` 阶段出现：

```text
error TS2307: Cannot find module 'undici-types' or its corresponding type declarations.
dh_auto_build: error: cd ./llparse-builder
E: Build failure (dpkg-buildpackage died)
```

说明正在构建的 `node-undici` Noble source package 没有包含本仓库的 Noble 专用
`debian/rules` build hook。Ubuntu Noble chroot 内的 `@types/node` 会导入
`undici-types`，但 Noble 系统旧版 `node-undici`（基于 undici 6.x）没有把
独立的 `undici-types` 装到 `/usr/share/nodejs/undici-types/`，而 Debian
trixie 的新版（基于 undici 7.x）装了。tsc 默认会把 `@types/node` 符号链接解析
到真实路径 `/usr/share/nodejs/@types/node/...` 再上溯，所以 Noble 缺这个系统
目录时，构建树里的 `node_modules/undici-types` 链接对 tsc 不可见，即使已正确
建立也会报 TS2307。当前 rewrap 阶段会修改 `debian/rules`，让 binary build 在
`dh_auto_configure` 前生成 `types/package.json`，并向
`llparse-builder/tsconfig.json` 注入 `paths: {"undici-types": ["../types"]}`，
让 tsc 按 tsconfig 文件位置解析、绕过真实路径上溯。rewrap 脚本会自动迁移旧版本
（build-hook 和 configure-only）的 hook，因此即使源码树里残留旧 hook 也会被
修正。

确认本地脚本和 source tree 是最新状态后，重新从 fetch/rewrap 阶段开始：

```bash
make noble-fetch-node-undici
make noble-rewrap-node-undici
make noble-src-pkg-node-undici
make noble-binary-node-undici
```

生成的 node-undici Noble 版本应为：

```text
7.3.0+dfsg1+~cs24.12.11-1
```

### `pkgjs-pjson: not found` 或 `dh: No such file or directory`

如果 `make noble-build` 在 `noble-src-pkg-node-undici` 或 `noble-src-pkg-ocserv`
阶段出现：

```text
/bin/sh: 1: pkgjs-pjson: not found
make: dh: No such file or directory
dpkg-buildpackage: error: debian/rules clean subprocess returned exit status
```

说明宿主构建机缺少 source package clean 阶段需要的工具。这不是 sbuild chroot
里的依赖问题；`dpkg-buildpackage -S` 在宿主机上生成 `.dsc`，会先运行
`debian/rules clean`。

安装宿主工具后重试：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 update
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends debhelper dh-nodejs
```

如果 apt 找不到 `dh-nodejs`，先确认 Noble 构建机启用了 Ubuntu `universe`
组件或检查 apt sources。

### `dscverify failed` 且 keyring unreadable

如果 `make noble-build` 在 `noble-fetch-node-undici` 或 `noble-fetch-ocserv`
阶段出现类似输出：

```text
Keyring /usr/share/keyrings/debian-keyring.gpg unreadable
Keyring /usr/share/keyrings/debian-maintainers.gpg unreadable
Keyring /usr/share/keyrings/debian-nonupload.gpg unreadable
Keyring /usr/share/keyrings/debian-tag2upload.pgp unreadable
ERROR: dscverify failed
```

说明构建机缺少可读 Debian keyring，或脚本版本仍把缺失 keyring 当成硬错误。

先安装 keyring：

```bash
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 update
sudo apt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends debian-keyring
```

然后重新运行：

```bash
make noble-build
```

当前脚本会忽略不可读的可选候选 keyring，但不会跳过 Debian source signature
verification。

### `containerd.io : Conflicts: containerd`

如果安装工具阶段出现：

```text
containerd.io : Conflicts: containerd
E: Error, pkgProblemResolver::Resolve generated breaks
```

说明系统正在混用 Docker CE 的 `containerd.io` 和 Ubuntu 仓库的 `containerd` /
`docker.io` 依赖。不要继续安装 `docker.io`。按本文“安装 Docker CE”章节移除冲突
包，并从 Docker 官方 APT 源安装 Docker Engine。
