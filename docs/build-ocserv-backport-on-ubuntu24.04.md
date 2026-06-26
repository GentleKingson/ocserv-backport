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
NODE_UNDICI_NOBLE_VERSION=7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1

OCSERV_DEBIAN_VERSION=1.5.0-1
OCSERV_NOBLE_VERSION=1.5.0-1~ubuntu24.04.1

TARGET_DISTRIBUTION=noble
TARGET_ARCH=amd64
```

`*_DEBIAN_VERSION` 只用于 `source-lock/` 和 Debian pool 下载。
`*_NOBLE_VERSION` 只用于 `debian/changelog` 和最终 Noble 构建产物。

不要把 `~ubuntu24.04.1` 写入 `source-lock` 路径。

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
