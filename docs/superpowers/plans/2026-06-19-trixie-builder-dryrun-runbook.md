# trixie 构建机 dry-run runbook 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已确认的 spec (`docs/superpowers/specs/2026-06-19-trixie-builder-dryrun-runbook-design.md`) 转写为正式交接 runbook `docs/trixie-builder-dryrun-runbook.md`, 供新工程师从裸机一路做到 `make dry-run` 通过。

**Architecture:** 文档转写项目 (非代码)。Task 1 一次性产出完整正式 runbook (内部按章拆子步骤, 但合并为一次提交, 不提交半成品); Task 2-4 依次做静态校验与语气清理; Task 5 可选真机实测; Task 6 最终审阅。

**Tech Stack:** Markdown, shell 命令核对, git。

**Spec 来源:** `docs/superpowers/specs/2026-06-19-trixie-builder-dryrun-runbook-design.md` (已确认 v1, 含审阅修正)

---

## 约束 (所有 task 必须遵守)

```text
- 不新设计流程, 只转写已确认 spec 的内容
- 不改变第 4 章分段 bootstrap 主路径 (install_packages → 重新登录 → prepare_directories onward)
- 不把 docker group 配置塞进第 4 章 (Docker 验收以 "smoke-basic 已通过" 反推)
- 不展开 staging / production / runner / secrets (这些超出本文档终点: make dry-run)
- 不保留 brainstorming / spec / writing-plans / 待 writing-plans 等流程性语言
- 不保留 commit 号作为读者操作依据 (如 commit 839df74)
- 不提交半成品正式 runbook (Task 1 一次性产出完整文档后才提交)
- 正式 runbook 路径: docs/trixie-builder-dryrun-runbook.md (与 docs/BUILD_HOST_BOOTSTRAP.md 同级)
- 每章保留: 验收点 (✅)、执行用户标注、占位符替换提示
- 正式文档去掉: 元数据行 (状态/日期/类型/父 spec)、§N 内部引用、superpowers 路径
```

## 文件结构

```text
创建:
  docs/trixie-builder-dryrun-runbook.md   # 正式交接 runbook (唯一交付物)

读取 (转写源, 不修改):
  docs/superpowers/specs/2026-06-19-trixie-builder-dryrun-runbook-design.md

参考 (交叉引用 / 事实核对):
  docs/BUILD_HOST_BOOTSTRAP.md            # 已有的快速参考文档, runbook 与之互补
  scripts/bootstrap-build-host.sh         # 核对命令、阶段名、preflight 行为
  scripts/dry-run.sh                      # 核对 8 步流水线
  .bootstrap.env.example                  # 核对配置项
  .env.example                            # 核对 DEBIAN_SNAPSHOT_TIMESTAMP
```

---

## Task 1: 转写完整正式 runbook

**Files:**
- Create: `docs/trixie-builder-dryrun-runbook.md`

本 task 内部按章拆 8 个子步骤, 但**合并为一次提交**。完成全部 8 个子步骤、通过 1.8 自查后, 才执行 1.9 提交。中间不提交半成品。

### 转写总原则 (适用于所有子步骤)

```text
保留 (从 spec 原样或微调):
  - 线性操作手册结构 (第 1-5 章 + 附录)
  - 所有命令块 (bash/text)
  - 验收点 ✅ 和验收命令
  - 执行用户标注 (root / builder)
  - "为什么" 引用块 (>)
  - 提示框 (ASCII ╔═╗ 边框)
  - 表格 (第 5 章 8 步流水线、附录速查)
  - 占位符替换提示 (凡占位符处明确标注必须替换)

去掉/改写 (spec 专属 → 正式文档):
  - 元数据行 (状态/日期/类型/父 spec) → 改为简短引言段
  - "父 spec §X" / "bootstrap spec §X" 内部引用 → 改为对读者有意义的话, 或指向 docs/ 下正式文档名
  - "commit 839df74" 等提交号 → 删除, 只保留行为描述
  - "已确认 v1 (待 writing-plans)" → 删除
  - "docs/superpowers/specs/..." 路径 → 改为 docs/ 下对应正式文档名 (若有) 或删除

第 1 章引言改写示例:
  spec 原文:
    - 状态: 已确认 v1 (待 writing-plans)
    - 日期: 2026-06-19
    - 类型: 交接/培训文档 (线性操作手册, 方案 A)
    - 父 spec: ...
  正式文档改为:
    一段引言说明本文档目的、读者、终点; 不暴露流程元数据。
```

- [ ] **1.1 建文档骨架 (标题 + 引言 + 第 1 章)**

创建 `docs/trixie-builder-dryrun-runbook.md`, 写入:

```markdown
# trixie 构建机准备到 dry-run 通过 — 操作手册

本手册带新工程师从一台 Debian 13 trixie amd64 裸机构建主机开始, 一步步完成
builder 用户配置、bootstrap、sbuild chroot、GPG/aptly 本地状态和 dry-run 验证,
最终跑通 `make dry-run`。

**读者:** 接手 ocserv backport 项目的新工程师, 熟悉 Linux 但不熟悉本项目。
**终点:** `make dry-run` 退出码 0, 全程不触碰 R2 / Cloudflare / GitHub runner /
staging / production 或正式 aptly DB。
**写作约定:**
- 命令在 trixie amd64 上执行; 执行用户在每章开头标注 (root 或 builder)。
- 需要权限的命令显式标 `sudo`。
- "为什么" 用引用块 (`>`) 简短说明。
- 验收点用 ✅ 标记, 是进入下一章的前置条件。
- 凡占位符 (如 `YYYYMMDDTHHMMSSZ`、`ssh-ed25519 AAAA...`、`<host>`) 必须替换为
  真实值, 不得原样复制执行。文档会在出现处明确提示。

**成功定义:** 能在本机完成源码获取、changelog rewrap、source package、sbuild binary
build、lint/smoke-basic、本地临时 aptly repo/snapshot 验证; dry-run 用临时 aptly root
验证 repo/snapshot 逻辑, 不 publish, 不触碰正式 aptly DB。

**本文档不含:** production promote/rollback、Ansible staging/production upgrade、
GitHub runner 注册与 secrets 配置。这些是 dry-run 之后的阶段, 见
`docs/BUILD_HOST_BOOTSTRAP.md` 及 CI workflow 文档。
```

把 spec 第 1 节的 1.2 成功定义、1.3 不含边界的内容融入上述引言 (1.1 文档目标、1.2、1.3
合并为引言段; 1.4 读者约定融入"写作约定"列表)。

- [ ] **1.2 转写第 2 章: 裸机准备**

转写 spec 第 2 节 (2.1-2.5), 标题改为:

```markdown
## 第 1 步: 裸机准备 (以 root 执行)
```

(正式文档用"第 N 步"而非"第 N 节", 更贴合操作手册语气。后续章节同理重新编号为
第 2-4 步。)

内容逐子节转写 (2.1-2.5):
- 2.1 确认机器基础形态 → 保留磁盘三层阈值表、验收
- 2.2 安装 sudo + 创建 builder 用户 → **保留 sudo 前移逻辑** (审阅修正 1), 保留时序前提引用块
- 2.3 配置 SSH → 保留 ADMIN_PUBKEY 变量主路径 + ssh-copy-id 可选
- 2.4 切 builder + 克隆仓库 → 保留"不再重复安装"说明
- 2.5 本章退出条件 → 原样保留勾选清单

去掉 spec 章首"本章产出: 正好满足 bootstrap preflight..."里的 `(scripts/bootstrap-build-host.sh stage_preflight:...)`
行号引用, 改为 "本章产出正好满足 bootstrap 的 preflight 前置条件 (OS/架构/用户/sudo/磁盘)"。

- [ ] **1.3 转写第 3 章: bootstrap 配置与 dry-run 预演**

转写 spec 第 3 节 (3.0-3.4), 标题改为:

```markdown
## 第 2 步: bootstrap 配置、GPG 模式选择与预演 (以 builder 执行)
```

内容转写:
- 3.0 两个 dry-run 的区分 → **完整保留** (这是关键防混淆点), 去掉"本章只涉及第 1 个"末句的"本章"
- 3.1 创建 .bootstrap.env → 保留幂等写法 `[[ -f .bootstrap.env ]] || cp ...` (审阅修正 4)
- 3.2 选择 GPG 模式 → 保留决策树、"特别注意: generate 模式不会询问 passphrase" 段、dedicated builder 安全边界
- 3.3 bootstrap dry-run 预演 → 保留三种 GPG 模式分支命令 (审阅修正点)
- 3.4 本章退出条件 → 模式化退出条件 (generate/import/reuse 三分支, 不硬绑 generate)

去掉 `(scripts/_common.sh check_secret_file_mode)` 行号引用, 改为 "bootstrap 的 load_config
阶段会校验 .bootstrap.env 的权限 (mode 600 + owner=当前用户)"。

- [ ] **1.4 转写第 4 章: 分段 bootstrap 真实运行**

转写 spec 第 4 节 (4.0-4.6), 标题改为:

```markdown
## 第 3 步: bootstrap 真实运行 (以 builder 执行)
```

**这是全文最关键的章节, 必须完整保留:**
- 核心时序框 (install_packages → 重新登录 → prepare_directories onward)
- 4.0 阶段执行规则提示框 (load_config 自动前置、preflight 不自动前置)
- 4.1 分段跑为主路径 (A), 一次全跑降级为 (B); **A 的策略摘要必须含显式 preflight** (审阅修正 2)
- 4.2 第一段 → 保留"命令 1/命令 2"分开的预期输出 (审阅修正 3)
- 4.3 阶段间动作: 重新登录让 sbuild group 生效 (硬性必做) → 完整保留背景说明和两种方式
- 4.4 第二段 → 保留"命令 1/命令 2"分开的预期输出 (审阅修正 3)、WARN 不等于失败提示框
- 4.5 drift 检查 (可选) → 标"不是 make dry-run 硬性前置"
- 4.6 本章退出条件

去掉 `(commit 839df74: sudo sbuild-adduser builder)` 提交号引用 (4.1 的"为什么"引用块),
改为 "install_packages 阶段会把 builder 加入 sbuild 组 (sudo sbuild-adduser)"。
去掉 `(scripts/bootstrap-build-host.sh main())` 行号引用 (4.0 提示框内), 改为 "源自
bootstrap 脚本的阶段执行逻辑"。
幂等语义引用块的 `(承接 bootstrap spec §1.2)` → 改为 "见 bootstrap 脚本的阶段定义"。

- [ ] **1.5 转写第 5 章: make dry-run 端到端验收**

转写 spec 第 5 节 (5.1-5.5), 标题改为:

```markdown
## 第 4 步: make dry-run 端到端验收 (以 builder 执行)
```

内容转写:
- 5.1 确认 dry-run 环境参数 → 保留 DEBIAN_SNAPSHOT_TIMESTAMP 为唯一必填、格式示例说明、dry-run 专用行为 (mktemp 临时 root)
- 5.2 运行 make dry-run → 保留 8 步流水线表格 (步骤/target/产物/不触碰)、DRY-RUN PASSED 验收
- 5.3 失败定位 → 保留精选高频失败点 (步骤 1/4/6/7)、Docker socket 权限排查、其他步骤一句话覆盖
- 5.4 最终终态验收清单 → 保留 A 机器状态 + B dry-run 产物状态两组清单
- 5.5 dry-run 之后是什么 → 改引用为正式文档名

5.5 的引用改写:
```text
spec 原文:
  父 spec docs/superpowers/specs/2026-06-18-ocserv-backport-design.md §4 / §6.6
  bootstrap spec docs/superpowers/specs/2026-06-19-bootstrap-build-host-design.md §2.11
正式文档改为:
  见 docs/BUILD_HOST_BOOTSTRAP.md (GitHub 手动清单: runner/secrets/environment)
  及 .github/workflows/ 下的 CI workflow 文档 (ci-testing / promote-production / rollback-production)。
```

- [ ] **1.6 转写附录: 主路径速查 + 占位符清单**

转写 spec 末尾两个附录:

附录 A: 文档结构与命令主路径速查
- 保留章节总览表 (主题/执行用户/关键产出), 标题列"第 N 步"重新编号
- 保留第 4 步完整主路径命令块 (含显式 preflight、三种 GPG 模式平行)

附录 B: 占位符清单
- 完整保留占位符表 (6 个占位符: DEBIAN_SNAPSHOT_TIMESTAMP / SSH 公钥 / host / 仓库 URL / FULL_FINGERPRINT / private.asc 路径)

- [ ] **1.7 加入文档间导航 (可选, 轻量)**

在正式 runbook 顶部引言后, 加一行交叉引用 (与 BUILD_HOST_BOOTSTRAP.md 互补):

```markdown
> 相关文档: `docs/BUILD_HOST_BOOTSTRAP.md` 是 bootstrap 脚本的快速参考;
> 本手册是"从裸机到 dry-run"的完整线性流程。两者覆盖范围不同。
```

- [ ] **1.8 自查全文连续性**

通读完整 `docs/trixie-builder-dryrun-runbook.md`, 逐项确认:

```text
□ 章节编号连续: 第 1 步 (裸机) → 第 2 步 (bootstrap 配置) → 第 3 步 (bootstrap 真实运行) → 第 4 步 (dry-run)
□ 执行用户流转正确: 第 1 步 root → 第 1 步末切 builder → 第 2-4 步 builder
□ 第 3 步 (原第 4 章) 分段跑主路径完整: preflight → install_packages → 重新登录 → preflight → from-stage prepare_directories
□ 第 3 步的 sbuild group 重新登录在第 3 步内 (不依赖跨章状态)
□ 第 4 步 (原第 5 章) dry-run 依赖的前置 (chroot/GPG/aptly) 在第 3 步已建立
□ 所有占位符在正文出现处都有"必须替换"提示
□ 无残留 spec 流程语言 (grep 验证, 见 1.8 命令)
□ 无残留 commit 号 (grep 验证)
□ 无残留 superpowers 路径 (grep 验证)
```

执行 grep 自查命令:

```bash
# 应全部无输出 (无残留)
grep -n "spec\|brainstorming\|writing-plans\|待 writing-plans\|已确认 v1" docs/trixie-builder-dryrun-runbook.md
grep -n "commit [0-9a-f]\{7\}" docs/trixie-builder-dryrun-runbook.md
grep -n "docs/superpowers/" docs/trixie-builder-dryrun-runbook.md
grep -n "§[0-9]" docs/trixie-builder-dryrun-runbook.md
```

如有输出, 回到对应子步骤修正后重跑 grep, 直到全部无输出。

- [ ] **1.9 提交完整 runbook**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs: trixie builder dry-run runbook (bare metal to make dry-run)"
```

提交信息正文 (可选):
```text
Linear handoff runbook for new engineers: bare trixie amd64 builder → make dry-run.
Segmented bootstrap (install_packages → relogin for sbuild group → from-stage
prepare_directories) as the first-boot path. Ends at dry-run; does not cover
testing publish / staging verify / production promote.
```

---

## Task 2: 校验命令路径与阶段顺序

**Files:**
- Read: `docs/trixie-builder-dryrun-runbook.md` (刚创建)
- Read: `scripts/bootstrap-build-host.sh` (核对阶段名/参数)
- Read: `scripts/dry-run.sh` (核对 8 步)
- Read: `Makefile` (核对 target 名)

目的: 确认正式 runbook 里每条命令在当前代码里真实存在、阶段名拼写正确、参数合法。

- [ ] **2.1 核对 bootstrap 阶段名与参数**

逐项核对 runbook 里的命令与 `scripts/bootstrap-build-host.sh` 一致:

```text
□ --only-stage preflight          → STAGES 数组含 preflight
□ --only-stage install_packages   → STAGES 数组含 install_packages
□ --only-stage check_runner       → STAGES 数组含 check_runner
□ --only-stage check_backups      → STAGES 数组含 check_backups
□ --only-stage setup_sbuild_chroot → STAGES 数组含 setup_sbuild_chroot
□ --from-stage prepare_directories → STAGES 数组含 prepare_directories, 且排在 install_packages 之后
□ --generate-gpg-key / --import-gpg-key <path> / --reuse-gpg-key <KEYID> → 参数解析含这三个
□ --dry-run                       → 参数解析含
```

核对命令:

```bash
# 列出脚本定义的合法阶段
grep -A2 '^STAGES=' scripts/bootstrap-build-host.sh
# 列出脚本支持的参数
grep -E '^\s+--(from-stage|only-stage|generate-gpg|import-gpg|reuse-gpg|dry-run)' scripts/bootstrap-build-host.sh
```

如 runbook 里的阶段名/参数与脚本不一致, 修正 runbook。

- [ ] **2.2 核对阶段执行规则 (load_config 自动前置 / preflight 不自动前置)**

确认 runbook 4.0 提示框 (正式文档对应位置) 的描述与脚本 main() 一致:

```bash
# 确认 load_config 强制前置的逻辑
sed -n '/^main()/,/^}/p' scripts/bootstrap-build-host.sh | grep -A3 'load_config'
```

确认点:
- `ONLY_STAGE != "load_config"` 时, main() 会先 `run_stage load_config` (自动前置)
- preflight 不在自动前置逻辑里 (只在 run 数组里按 FROM/ONLY/默认过滤)

如描述与代码不符, 修正 runbook。

- [ ] **2.3 核对 make dry-run 的 8 步**

对照 `scripts/dry-run.sh` 确认 runbook 第 4 步 (原第 5 章) 的 8 步表格:

```bash
grep -n 'log "==\|make \|aptly\|snapshot-name' scripts/dry-run.sh
```

确认点:
- 步骤顺序: fetch → rewrap → src-pkg → binary → lint → smoke-basic → aptly temp → snapshot-name
- aptly 步骤用 `APTLY_ROOT_DIR="$(mktemp -d)"` + `trap 'rm -rf' EXIT`
- snapshot 名形态正则 `^ocserv-1\.5\.0-1~bpo13\+1-build-(gh[0-9]+|local-[0-9]{8}T[0-9]{6})$`
- 成功信息 "DRY-RUN PASSED — no real aptly/R2/staging/prod touched."

如表格与脚本不符, 修正 runbook。

- [ ] **2.4 核对 Makefile target 名**

```bash
grep -E '^[a-z].*:' Makefile | grep -E 'fetch|rewrap|src-pkg|binary|lint|smoke|dry-run|bootstrap'
```

确认 runbook 引用的 target (`make dry-run`) 在 Makefile 存在。

- [ ] **2.5 提交校验修正**

如有修正:

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs: verify runbook command flow against current scripts"
```

如无修正 (全部一致), 跳过提交, 在执行日志注明 "Task 2: 无修正, 命令路径全部核对一致"。

---

## Task 3: 校验占位符、安全边界与"不触碰"声明

**Files:**
- Read: `docs/trixie-builder-dryrun-runbook.md`

目的: 确保所有占位符都有替换提示, 安全边界 (无 passphrase / 不触碰范围) 一致无矛盾。

- [ ] **3.1 校验占位符完整性**

确认 runbook 正文出现的每个占位符, 在附录占位符清单里都有对应条目, 且正文处有"必须替换"提示。

正文占位符 (应全部找到):

```bash
grep -n "YYYYMMDDTHHMMSSZ\|ssh-ed25519 AAAA\|<host>\|<仓库 URL>\|<FULL_FINGERPRINT>\|/path/to/private.asc" docs/trixie-builder-dryrun-runbook.md
```

逐个确认:
- `YYYYMMDDTHHMMSSZ`: 第 4 步 5.1 出现, 有验收命令 grep -qv, 附录有条目
- `ssh-ed25519 AAAA...`: 第 1 步 2.3 出现, 有"替换为你的真实公钥"注释, 附录有条件
- `<host>`: 多处出现, 附录有条目
- `<仓库 URL>`: 第 1 步 2.4 出现, 附录有条目
- `<FULL_FINGERPRINT>`: 第 2 步 3.3 / 第 3 步 4.4 出现, 附录有条目
- `/path/to/private.asc`: 第 2 步 3.3 / 第 3 步 4.4 出现, 附录有条目

如正文出现附录未收录的占位符, 补进附录; 如附录有条目但正文无替换提示, 补提示。

- [ ] **3.2 校验 GPG passphrase 描述一致性**

确认全文关于 passphrase 的描述前后一致 (这是审阅重点):

```bash
grep -n "passphrase\|无保护 key\|%no-protection\|BOOTSTRAP_GPG_PASSPHRASE" docs/trixie-builder-dryrun-runbook.md
```

一致性要求:
- generate 模式: 生成无保护 key, 不读 passphrase, 不问密码 (第 2 步 3.2 和第 3 步 4.4 描述一致)
- import/reuse 模式: 若 key 带口令会交互式 read -s (第 2 步 3.2 描述)
- dedicated builder 安全边界: generate 无保护 key 只适合受控 dedicated builder (第 2 步 3.2)

如发现矛盾, 统一到正确描述。

- [ ] **3.3 校验"不触碰"声明一致性**

确认全文关于 dry-run / bootstrap 不触碰范围的声明一致:

```bash
grep -n "不触碰\|不触碰\|no real aptly\|不 publish\|不自动\|不注册" docs/trixie-builder-dryrun-runbook.md
```

关键一致点:
- bootstrap dry-run: 不修改状态, 只打印 (第 2 步 3.3)
- make dry-run: 不触碰 R2 / CF / GitHub runner / staging / production / 正式 /var/aptly DB (第 4 步引言、5.1、5.2 表格、5.4 B 组)
- bootstrap 真实运行: 不注册 runner、不写 secrets、不验证备份系统 (第 3 步 WARN 提示框)
- bootstrap 不改写已有 aptly config、不重建 chroot/repo (幂等语义)

如发现矛盾, 统一。

- [ ] **3.4 提交校验修正**

如有修正:

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs: tighten runbook placeholders and safety boundaries"
```

如无修正, 在执行日志注明 "Task 3: 无修正, 占位符与安全边界全部一致"。

---

## Task 4: 清理残留 spec 语气与内部引用

**Files:**
- Read: `docs/trixie-builder-dryrun-runbook.md`

目的: 虽然 Task 1 的 1.8 已做 grep 自查, 本 task 做更细的语气审读, 确保读起来像给新工程师的正式文档, 而非设计稿。

- [ ] **4.1 全文通读, 标记语气问题**

通读 `docs/trixie-builder-dryrun-runbook.md`, 寻找以下语气残留:

```text
需修正的语气:
  - "承接 spec §X" / "父 spec" / "bootstrap spec" → 已在 Task 1 处理, 此处复核
  - "(方案 A)" 这类设计决策标记 → 删除 (读者不需要知道选了哪个方案)
  - "审阅修正 N" → 删除 (读者不需要知道修订历史)
  - "commit XXXXXXX" → 删除 (读者不关心提交号)
  - 行号引用 "(scripts/xxx.sh:123)" → 改为函数/阶段名描述, 不带行号
  - "TDD" / "bats 测试" 等实现细节 → 删除 (读者只关心操作)
  - "(修改 N)" / "(评审必须修改)" → 删除
```

- [ ] **4.2 修正语气问题**

对 4.1 标记的每一处, 逐个修正:

- 设计决策标记 → 删除括号及内容
- 行号引用 → 改为 "bootstrap 脚本的 X 阶段" / "dry-run.sh 的第 N 步"
- 实现细节 → 删除整句或改为读者视角

例如:
```text
修正前: "因为 group 成员身份不会 retroactively 生效 (commit 839df74)"
修正后: "因为 group 成员身份不会在当前会话立即生效"

修正前: "preflight 的双阈值 (scripts/bootstrap-build-host.sh check_disk_threshold)"
修正后: "bootstrap preflight 的双阈值"

修正前: "幂等语义 (承接 bootstrap spec §1.2)"
修正后: "幂等语义 (见 bootstrap 脚本的阶段定义)"
```

- [ ] **4.3 复核 grep (与 Task 1.8 相同命令, 确保无回归)**

```bash
grep -n "spec\|brainstorming\|writing-plans\|待 writing-plans\|已确认 v1\|方案 A\|审阅修正\|(修改 [0-9])\|(评审" docs/trixie-builder-dryrun-runbook.md
grep -n "commit [0-9a-f]\{7\}" docs/trixie-builder-dryrun-runbook.md
grep -n "docs/superpowers/" docs/trixie-builder-dryrun-runbook.md
grep -n "§[0-9]" docs/trixie-builder-dryrun-runbook.md
grep -n ":1[0-9][0-9])" docs/trixie-builder-dryrun-runbook.md   # 行号引用如 :123)
```

应全部无输出。如有输出, 修正后重跑。

- [ ] **4.4 提交清理**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs: polish runbook wording for handoff use"
```

提交信息正文 (可选):
```text
Remove design-phase artifacts (spec/§ references, commit hashes, line-number
citations, revision markers) so the document reads as a finished operator
manual rather than a design draft.
```

---

## Task 5: 可选 — trixie builder 真机实测

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md` (记录偏差)

**前置条件:** 有一台可用的 trixie amd64 builder 真机 (或等价 VM), 可以从裸机状态开始。
**若无真机:** 跳过本 task, 在执行日志注明 "Task 5 skipped: 无 trixie 真机, 静态校验 (Task 2-4) 已完成"。

目的: 按 runbook 实地走一遍第 1-4 步, 记录任何与文档描述不符的偏差, 回填修正。

- [ ] **5.1 第 1 步实测: 裸机准备**

在一台裸 trixie amd64 机器上, 以 root 按 runbook 第 1 步执行:

```text
□ 2.1 机器形态确认: OS/arch/磁盘验收通过
□ 2.2 sudo 安装 + builder 用户 + sudoers: visudo -c 通过, sudo -n true 通过
□ 2.3 SSH 配置: builder 能 SSH 登录
□ 2.4 切 builder + clone: git status clean
□ 2.5 退出条件全勾
```

记录任何命令失败或输出与文档不符之处。

- [ ] **5.2 第 2 步实测: bootstrap 配置与预演**

以 builder 按 runbook 第 2 步执行:

```text
□ .bootstrap.env 创建 (幂等不覆盖)
□ GPG 模式决策
□ bootstrap --dry-run [GPG模式] 退出码 0
□ 退出条件全勾
```

记录偏差 (如 dry-run 报错信息与文档"常见失败排查"不符)。

- [ ] **5.3 第 3 步实测: bootstrap 真实运行 (分段)**

以 builder 按 runbook 第 3 步执行:

```text
□ preflight (显式) 通过
□ install_packages: 装包完成, builder 加入 sbuild 组, WARN 出现
□ 重新登录 / newgrp sbuild: id -nG 含 sbuild
□ preflight (显式, 重登后) 通过
□ from-stage prepare_directories [GPG模式]: 全阶段通过, 退出码 0
□ chroot 创建 + verify_chroot_sources OK
□ GPG key 生成 (generate 模式无 passphrase 提示)
□ aptly repo 创建
□ check_runner / check_backups WARN 出现但不阻塞
□ 退出条件全勾
```

**重点验证:**
- install_packages 后如果不重新登录直接跑 setup_sbuild_chroot, 是否真的失败 (验证分段跑的必要性)
- generate 模式是否真的不问 passphrase

记录所有偏差。

- [ ] **5.4 第 4 步实测: make dry-run**

以 builder 按 runbook 第 4 步执行:

```text
□ .env 填真实 DEBIAN_SNAPSHOT_TIMESTAMP (占位符已替换)
□ make dry-run 8 步全过, 退出码 0
□ "DRY-RUN PASSED" 出现
□ 5.4 终态清单 A 组 + B 组全勾
```

**重点验证:**
- snapshot.debian.org 时间戳是否有效 (fetch 步骤)
- smoke-basic 的 docker 容器是否正常 (docker socket 权限)
- 临时 aptly root 是否正确清理 (检查 mktemp 目录已删)

记录所有偏差。

- [ ] **5.5 回填文档偏差**

将 5.1-5.4 记录的偏差, 逐条对照 runbook 修正:

- 命令实际输出与文档"预期输出"不符 → 更新预期输出
- 失败排查路径与实际不符 → 更新失败定位
- 新发现的常见失败 → 补进失败定位

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs: validate runbook on trixie builder, fix observed deviations"
```

---

## Task 6: 最终审阅与提交整理

**Files:**
- Read: `docs/trixie-builder-dryrun-runbook.md`
- Read: `docs/BUILD_HOST_BOOTSTRAP.md` (确认互补关系)

- [ ] **6.1 最终通读**

完整通读 `docs/trixie-builder-dryrun-runbook.md` 一次, 以"新工程师第一次看"的视角检查:

```text
□ 从第 1 步到第 4 步, 能否不查其他文档就照做
□ 每个命令的执行用户是否清楚
□ 每章退出条件是否可客观判定 (有命令验收, 不靠主观)
□ 占位符是否都知道该填什么
□ 遇到失败是否知道去哪查
□ "不触碰"边界是否清楚 (不会误以为要配 R2/runner)
```

- [ ] **6.2 确认与 BUILD_HOST_BOOTSTRAP.md 的互补关系**

确认两份文档不冲突、不重复、覆盖范围清晰:

```text
docs/trixie-builder-dryrun-runbook.md:
  从裸机到 make dry-run 的完整线性流程 (交接培训用)

docs/BUILD_HOST_BOOTSTRAP.md:
  bootstrap 脚本的快速参考 (已就绪后的日常/drift 检查用)

确认:
  - runbook 的第 2-3 步覆盖了 BUILD_HOST_BOOTSTRAP 的首次设置, 但更详细
  - BUILD_HOST_BOOTSTRAP 的 drift check 在 runbook 第 3 步 4.5 (drift 检查可选) 有对应
  - 两文档不矛盾
```

如 BUILD_HOST_BOOTSTRAP.md 需要加一行指向新 runbook (避免读者不知道有完整手册), 加:

```bash
# 在 docs/BUILD_HOST_BOOTSTRAP.md 顶部加一行交叉引用
```

具体: 在 BUILD_HOST_BOOTSTRAP.md 第 1 行后加:

```markdown
> 完整的从裸机到 dry-run 的线性操作手册见 `docs/trixie-builder-dryrun-runbook.md`。
> 本文档是 bootstrap 脚本的快速参考。
```

- [ ] **6.3 检查 git 状态**

```bash
git status                          # 应 clean 或只有最终修改
git log --oneline -8                # 确认提交历史清晰
```

- [ ] **6.4 最终提交 (如有 BUILD_HOST_BOOTSTRAP.md 交叉引用修改)**

```bash
git add docs/BUILD_HOST_BOOTSTRAP.md
git commit -m "docs: cross-reference trixie builder runbook from bootstrap quick-ref"
```

- [ ] **6.5 完成确认**

确认交付物:

```text
□ docs/trixie-builder-dryrun-runbook.md 存在, 完整 (5 章 + 附录)
□ 已通过 Task 2 (命令路径核对)
□ 已通过 Task 3 (占位符/安全边界核对)
□ 已通过 Task 4 (语气清理, grep 无残留)
□ Task 5 (真机实测) 已做或已注明跳过原因
□ docs/BUILD_HOST_BOOTSTRAP.md 已交叉引用 (如 6.2 决定加)
□ git 工作区 clean
```

---

## 自审 (计划完成后执行)

**1. Spec 覆盖:**

对照 spec 的 5 章 + 附录, 确认每个部分在计划里都有对应转写 task:
- spec 第 1 节 (定位/边界) → Task 1.1 (引言段)
- spec 第 2 节 (裸机) → Task 1.2
- spec 第 3 节 (bootstrap 配置/dry-run 预演) → Task 1.3
- spec 第 4 节 (bootstrap 真实运行/分段) → Task 1.4
- spec 第 5 节 (make dry-run) → Task 1.5
- spec 附录 (速查/占位符) → Task 1.6
- spec 审阅修正 (sudo 前移/显式 preflight/命令拆分/幂等) → Task 1.2/1.3/1.4 各自子步骤明确要求保留
- 命令路径核对 → Task 2
- 占位符/安全边界核对 → Task 3
- 语气清理 → Task 4
- 真机实测 → Task 5
- 最终审阅 → Task 6

无 spec 部分遗漏。

**2. 占位符扫描:**

本计划无 TBD/TODO; 每个 task 的步骤都有具体内容和命令。

**3. 一致性:**

- 章节编号: 计划用"第 N 步" (Task 1 各子步骤转写时统一), spec 用"第 N 节" — Task 1.2-1.5 已明确要求重新编号
- 路径: `docs/trixie-builder-dryrun-runbook.md` 在所有 task 一致
- 提交信息: 每个 task 的 commit message 明确
