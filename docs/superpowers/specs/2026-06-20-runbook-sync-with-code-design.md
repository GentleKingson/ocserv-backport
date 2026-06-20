# Spec: runbook 文档与代码同步（2026-06-20）

## 背景

`make dry-run` 在本会话通过 6 个 PR 全绿。其中 PR #4（`fetch-source.sh`
的 `publish_orig_tarball`）改变了 fetch 阶段的持久产物语义：upstream
`.orig.tar.xz` + `.asc` 现在发布到 `build/source/`，不再只留在临时
staging。这使 runbook 出现 1 处与代码矛盾、2 处影响读者理解的遗漏。

本会话其余 PR（#2 rewrap `--force-bad-version`、#3 src-pkg `-d`、
#5 lint `--fail-on error`、#6 smoke `\${Version}`）属于实现细节（flag 名），
不改变 runbook 描述的阶段边界 / 产物 / 故障自检路径，故不入本次范围。
PR #1（509 cache fallback）已在 runbook §4.1 / §4.3 记录，无需改。

## 目标

让 `docs/trixie-builder-dryrun-runbook.md` 关于 fetch / src-pkg 阶段的
**持久产物、阶段间依赖、source tree 的替换语义以及 upstream orig tarball(+asc)
的后续发布语义**与 PR #4 后的代码行为一致，
形成完整的读者认知闭环：
**fetch 发布哪些产物 → src-pkg 为什么依赖这些产物 → staging 成功后 source
tree 如何带回滚地替换、upstream orig tarball(+asc) 如何随后发布**。

## 范围

- 改：仅 `docs/trixie-builder-dryrun-runbook.md`，共 3 处。
- 不改：`README.md`、`docs/BUILD_HOST_BOOTSTRAP.md`、任何脚本代码。
- 不补：纯 flag 名等实现细节（`--force-bad-version` / `-d` /
  `--fail-on error` / `\${Version}`）——它们随实现变化快，属代码注释与
  git 历史，不属于 runbook 描述的阶段边界。

## 改动点（目标状态）

### ① 修 CONTRADICTION — §4.2 第 8 步流水线表格，第 1 行（fetch）

当前（与代码矛盾）：
```
| 1 | fetch | build/source/ocserv-1.5.0/ | 不启用 sid apt 源（只 dget 源码）；
只发布 source tree，raw .dsc/tarballs 留在临时 staging |
```

PR #4 后，`build/source/` 会发布：
- `ocserv-1.5.0/` source tree；
- upstream `ocserv_1.5.0.orig.tar.xz`；
- 对应 `ocserv_1.5.0.orig.tar.xz.asc`。

`.dsc` 与 `.debian.tar.xz` 不发布到 `build/source/`，不作为 fetch 的持久输出；
backport 的 src-pkg 阶段会重新生成对应版本的源包文件。
（注：509 fallback 的 `build/source-cache/` 是操作者预置的只读 seed，会持久
保留这些输入；本边界只约束「不发布到 `build/source/` 作为 fetch 输出」，不
否定 seed 的持久存在。）

修改「预期产物」与「不触碰」两列以准确反映：fetch 持久发布 source tree +
upstream orig tarball(+asc)；sid 原版 `.dsc` / `.debian.tar.xz` 不作为 fetch
输出发布到 `build/source/`（backport 会重新生成它们）。

### ② 补 OMISSION（影响读者） — §4.2 表格，第 3 行（src-pkg）

明确 `dpkg-source -b`（quilt 3.0）会从 `build/source/` 找 upstream orig
tarball；缺失时报 `no upstream tarball`。这样读者可直接把 src-pkg 失败
关联回 fetch 产物完整性（自检 `build/source/` 是否有
`ocserv_1.5.0.orig.tar.xz`）。

不改 src-pkg 的核心产物描述（`.dsc` + `.debian.tar.xz` 仍准确）。也不
新增 `.changes` —— src-pkg 行原本未列它，补充它属超出"修影响读者理解"
范围的实现细节扩充，本次不做。

### ③ 补 OMISSION（影响读者） — §4.3 结尾 staging 注释

当前只说「只有完整 source tree 通过验证后，才会替换
`build/source/ocserv-1.5.0/`」。改为：fetch 每次都在新的临时 staging 目录中
完成下载和解包；只有完整 source tree 通过验证后，才会以**带回滚的替换方式**
更新 `build/source/ocserv-1.5.0/`，随后从同一 staging 目录发布 upstream
`ocserv_1.5.0.orig.tar.xz` 及其 `.asc` 到 `build/source/`。

关键：source tree 的替换（swap-with-rollback）与 orig tarball(+asc) 的发布是
**两次独立操作，非单一原子事务** —— 前者用 backup+restore 保证 source tree
替换可回滚，后者随后顺序 `mv`。文档不得暗示三者是 all-or-nothing。

sid 原版 `.dsc` 与 `.debian.tar.xz` 不发布为 fetch 输出，backport 会在
src-pkg 阶段重新生成它们。

## 验证方式

1. 改后通读 §4.2 表格 8 行 + §4.3 失败定位 + §4.4 清单，确认无新增矛盾。
2. 对照 `scripts/fetch-source.sh` 的 `publish_orig_tarball()` 与 `main()`
   两处调用，确认 §4.2 第 1 行、§4.3 staging 注释与代码逐句对应。
3. 对照 `scripts/build-source-package.sh`，确认 §4.2 第 3 行对
   `dpkg-source -b` 找 orig tarball 的描述与 `cd build/source/ocserv-1.5.0`
   后的相对路径（`../ocserv_1.5.0.orig.tar.*`）一致。

纯文档改动，无脚本逻辑变更，不涉及 builder 实测。
