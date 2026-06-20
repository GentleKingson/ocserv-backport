# Runbook 编号统一 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `docs/trixie-builder-dryrun-runbook.md` 的子节编号（X.Y）与所属「第 N 步」对齐，并修复所有失效/错位交叉引用。

**Architecture:** 纯文档修复。按物理分区（引言+第2步 / 第3步 / 第4步 / 附录B）切分为 4 个独立可提交的任务，每个任务只动自己分区内的标题与引用文本。最后一个任务做定向验证（标题 grep + 引用逐条核对 + git diff 复核），**不做过宽全文 grep**。

**Tech Stack:** Markdown 文档；Edit 工具按精确字符串替换；grep 仅用于锚定到标题行（`^### `）的定向检查。

**Spec:** `docs/superpowers/specs/2026-06-20-runbook-renumber-design.md`（权威基准，§3.2 是引用修复的逐条清单）

**关键纪律（来自 spec 审阅）：**
- 流水线内部编号（make dry-run 表「步骤 1~8」、失败定位表「步骤 1/4/6/7」、版本号 `1.5.0-1`）**保持不动**——它们是另一套体系，不是文档章节编号
- 验证只做两类：(A) `grep '^### '` 标题检查；(B) 以 spec §3.2 为基准的逐条引用核对。**禁止**「全文不存在 3.1/4.1」式过宽 grep（版本号/命令会误报）
- 每处 Edit 必须用足够上下文确保 `old_string` 唯一，**不要**用 replace_all 对裸数字（会误伤流水线表）

---

## File Structure

只修改一个文件：`docs/trixie-builder-dryrun-runbook.md`

修改点分布（按物理分区）：

| 分区 | 行号范围 | 改动内容 |
|------|---------|---------|
| 引言约定区 | L31 | 1 处引用（指向第 3 步 4.3） |
| 第 2 步区 | L135–307 | 5 个标题重编号（3.x→2.x）+ 3 处引用 |
| 第 3 步区 | L311–561 | 7 个标题重编号（4.x→3.x）+ 8 处引用 |
| 第 4 步区 | L565–750 | 5 个标题重编号（5.x→4.x）+ 6 处失败表引用 |
| 附录 A | L754–787 | 无改动（仅含「第 N 步」整步引用，无子节号） |
| 附录 B | L789–799 | 7 格「出现位置」列 |
| 附录 C | L803–861 | 无改动（引用已正确） |

行号是 spec 写作时的快照，**实施时不要依赖行号**——用 Edit 的精确字符串匹配。每处 Edit 都在下方给出唯一 `old_string`。

---

## Task 1: 引言约定区 + 第 2 步区

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md`（引言 L31 + 第 2 步 L144–296）

**本任务改动清单（共 9 处 Edit）：**
- 1 处引言引用（L31）
- 5 个标题：3.0→2.0、3.1→2.1、3.2→2.2、3.3→2.3、3.4→2.4
- 3 处正文引用：L183 `见 3.2`→`见 2.2`、L284 `第 1 步 2.1`→`第 1 步 1.1`、L285 `3.1 的 chmod`→`2.1 的 chmod`

- [ ] **Step 1: 修复引言区 L31 的引用**

old_string:
```
（第 3 步 4.3）两种场景都用同一个原理：退出当前 builder 会话再重开一个，让新会话重新读取
```
new_string:
```
（第 3 步 3.3）两种场景都用同一个原理：退出当前 builder 会话再重开一个，让新会话重新读取
```

- [ ] **Step 2: 重编号 5 个第 2 步标题**

逐条 Edit（每条 old_string 即原标题行，唯一）：

| old | new |
|-----|-----|
| `### 3.0 重要区分：两个不同的 dry-run（本步开头必读）` | `### 2.0 重要区分：两个不同的 dry-run（本步开头必读）` |
| `### 3.1 创建 .bootstrap.env（builder）` | `### 2.1 创建 .bootstrap.env（builder）` |
| `### 3.2 选择 GPG 模式（builder，决策，不执行）` | `### 2.2 选择 GPG 模式（builder，决策，不执行）` |
| `### 3.3 bootstrap dry-run 预演（builder）` | `### 2.3 bootstrap dry-run 预演（builder）` |
| `### 3.4 本步退出条件总览` | `### 2.4 本步退出条件总览` |

- [ ] **Step 3: 修复第 2 步区 3 处正文引用**

Edit 1 — L183（.bootstrap.env 字段注释里的引用）：
old_string:
```
BOOTSTRAP_GPG_KEYID=                    # 见 3.2，按模式决定是否填
```
new_string:
```
BOOTSTRAP_GPG_KEYID=                    # 见 2.2，按模式决定是否填
```

Edit 2 — L284（失败排查表里指向第 1 步磁盘确认的失效引用）：
old_string:
```
- preflight die "less than 15GB free": 磁盘不足（回到第 1 步 2.1 扩容或换盘）
```
new_string:
```
- preflight die "less than 15GB free": 磁盘不足（回到第 1 步 1.1 扩容或换盘）
```

Edit 3 — L285（同表里指向 chmod 步骤的引用）：
old_string:
```
- load_config die "must be chmod 600": 3.1 的 chmod 漏了
```
new_string:
```
- load_config die "must be chmod 600": 2.1 的 chmod 漏了
```

- [ ] **Step 4: 分区定向验证**

Run: `grep -n '^### [23]\.' docs/trixie-builder-dryrun-runbook.md`

Expected（第 2 步区现在应是 2.x，不再有 3.x 标题）：
```
144:### 2.0 重要区分：两个不同的 dry-run（本步开头必读）
165:### 2.1 创建 .bootstrap.env（builder）
195:### 2.2 选择 GPG 模式（builder，决策，不执行）
244:### 2.3 bootstrap dry-run 预演（builder）
296:### 2.4 本步退出条件总览
```
（行号可能略移，关键是只剩 2.x，无 3.x；3.x 现在应只出现在第 3 步区，由 Task 2 处理前不会有 3.x 标题，Task 2 之后第 3 步区会有 3.0–3.6）

Run: `grep -n '见 3\.2\|第 1 步 2\.1\|3\.1 的 chmod\|第 3 步 4\.3）两种' docs/trixie-builder-dryrun-runbook.md`

Expected: 无输出（全部已改）。注意 `第 3 步 4.3` 在 Task 2 还会出现于第 3 步/失败表区，这里只验引言区那一处（`）两种`后缀确保唯一）。

- [ ] **Step 5: Commit**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs(runbook): renumber step 2 sub-sections 3.x → 2.x + fix intro/inline refs

- 引言 L31: 第 3 步 4.3 → 第 3 步 3.3
- 第 2 步标题: 3.0/3.1/3.2/3.3/3.4 → 2.0/2.1/2.2/2.3/2.4
- 正文引用: 见 3.2→2.2, 第 1 步 2.1→1.1, 3.1 的 chmod→2.1 的 chmod"
```

---

## Task 2: 第 3 步区

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md`（L311–561）

**本任务改动清单（共 15 处 Edit）：**
- 7 个标题：4.0→3.0、4.1→3.1、4.2→3.2、4.3→3.3、4.4→3.4、4.5→3.5、4.6→3.6
- 8 处正文引用：L346、L366（含 3 个号）、L371、L405、L407、L413、L416、L456

- [ ] **Step 1: 重编号 7 个第 3 步标题**

逐条 Edit：

| old | new |
|-----|-----|
| `### 4.0 阶段执行规则（全步适用）` | `### 3.0 阶段执行规则（全步适用）` |
| `### 4.1 运行方式选择` | `### 3.1 运行方式选择` |
| `### 4.2 第一段：install_packages（装包 + 加入 sbuild 组）` | `### 3.2 第一段：install_packages（装包 + 加入 sbuild 组）` |
| `### 4.3 阶段间动作：重新登录让 sbuild group 生效（硬性，必做）` | `### 3.3 阶段间动作：重新登录让 sbuild group 生效（硬性，必做）` |
| `### 4.4 第二段：从 prepare_directories 继续（builder）` | `### 3.4 第二段：从 prepare_directories 继续（builder）` |
| `### 4.5 drift 检查（可选，builder，幂等重跑）` | `### 3.5 drift 检查（可选，builder，幂等重跑）` |
| `### 4.6 本步退出条件总览` | `### 3.6 本步退出条件总览` |

- [ ] **Step 2: 修复第 3 步区 8 处正文引用**

Edit 1 — L346（运行方式 A 的阶段间动作提示）：
old_string:
```
   [阶段间动作：重新登录 / newgrp sbuild，见 4.3]
```
new_string:
```
   [阶段间动作：重新登录 / newgrp sbuild，见 3.3]
```

Edit 2 — L366（展开说明里的三段串联）：
old_string:
```
本步按 A 展开（4.2 第一段 → 4.3 阶段间动作 → 4.4 第二段）。
```
new_string:
```
本步按 A 展开（3.2 第一段 → 3.3 阶段间动作 → 3.4 第二段）。
```

Edit 3 — L371（install_packages 注释里的规则引用）：
old_string:
```
# 显式 preflight 前置（preflight 不自动带，见 4.0）
```
new_string:
```
# 显式 preflight 前置（preflight 不自动带，见 3.0）
```

Edit 4 — L405（install_packages 末尾 WARN 提示）：
old_string:
```
> 都必须执行 4.3 的验收，不能跳过。
```
new_string:
```
> 都必须执行 3.3 的验收，不能跳过。
```

Edit 5 — L407（退出码 0 后的过渡提示）：
old_string:
```
退出码 0 后，不要继续直接跑 chroot —— 先做 4.3。
```
new_string:
```
退出码 0 后，不要继续直接跑 chroot —— 先做 3.3。
```

Edit 6 — L413（阶段间动作节开头的前置警告）：
old_string:
```
没有完成本节验收，不要进入 setup_sbuild_chroot（4.4）。
```
new_string:
```
没有完成本节验收，不要进入 setup_sbuild_chroot（3.4）。
```

Edit 7 — L416（阶段间动作背景说明）：
old_string:
```
背景：4.2 把 builder 加入了 sbuild group，但 Linux group 成员身份在当前登录会话中
```
new_string:
```
背景：3.2 把 builder 加入了 sbuild group，但 Linux group 成员身份在当前登录会话中
```

Edit 8 — L456（阶段间动作验收提示）：
old_string:
```
✅ 验收（必须输出 OK 才能进 4.4）：
```
new_string:
```
✅ 验收（必须输出 OK 才能进 3.4）：
```

- [ ] **Step 3: 分区定向验证**

Run: `grep -n '^### [34]\.' docs/trixie-builder-dryrun-runbook.md`

Expected:
- 第 3 步区标题为 3.0–3.6（共 7 个）
- **不再有** `### 4.x` 标题（4.x 全部已改为 3.x；第 4 步区的 5.x 由 Task 3 处理为 4.x，本步还没动）

第 3 步区应看到的 7 行：
```
### 3.0 阶段执行规则（全步适用）
### 3.1 运行方式选择
### 3.2 第一段：install_packages（装包 + 加入 sbuild 组）
### 3.3 阶段间动作：重新登录让 sbuild group 生效（硬性，必做）
### 3.4 第二段：从 prepare_directories 继续（builder）
### 3.5 drift 检查（可选，builder，幂等重跑）
### 3.6 本步退出条件总览
```

Run（核对 8 处引用已改）: `grep -n '见 4\.3\|→ 4\.3 阶段间动作\|见 4\.0\|4\.3 的验收\|先做 4\.3\|setup_sbuild_chroot（4\.4）\|4\.2 把 builder\|才能进 4\.4' docs/trixie-builder-dryrun-runbook.md`

Expected: 无输出。

- [ ] **Step 4: Commit**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs(runbook): renumber step 3 sub-sections 4.x → 3.x + fix inline refs

- 第 3 步标题: 4.0..4.6 → 3.0..3.6
- 正文引用 8 处: 见 4.3→3.3, 4.2→3.2/4.3→3.3/4.4→3.4 (串联),
  见 4.0→3.0, 4.3 的验收→3.3, 先做 4.3→3.3, setup_sbuild_chroot(4.4)→(3.4),
  4.2 把 builder→3.2, 才能进 4.4→3.4"
```

---

## Task 3: 第 4 步区（含失败定位表）

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md`（L565–750）

**本任务改动清单（共 11 处 Edit）：**
- 5 个标题：5.1→4.1、5.2→4.2、5.3→4.3、5.4→4.4、5.5→4.5
- 6 处失败定位表引用：L667（5.1→4.1）、L671/673/675/679（第 3 步 4.x→3.x）、L690（第 3 步 4.4→3.4）

**⚠️ 高风险提示：** 失败定位表里有「步骤 1/4/6/7」（指 make dry-run 流水线步骤，不是文档章节），**保持不动**。只改 `第 3 步 4.x` 形式的引用。

- [ ] **Step 1: 重编号 5 个第 4 步标题**

逐条 Edit：

| old | new |
|-----|-----|
| `### 5.1 确认 dry-run 环境参数` | `### 4.1 确认 dry-run 环境参数` |
| `### 5.2 运行 make dry-run：8 步流水线与产物验收` | `### 4.2 运行 make dry-run：8 步流水线与产物验收` |
| `### 5.3 失败定位：按步骤编号回查` | `### 4.3 失败定位：按步骤编号回查` |
| `### 5.4 最终终态验收清单：机器状态 + dry-run 产物状态` | `### 4.4 最终终态验收清单：机器状态 + dry-run 产物状态` |
| `### 5.5 dry-run 之后是什么` | `### 4.5 dry-run 之后是什么` |

注意：标题 `4.2 运行 make dry-run：8 步流水线` 里的「8 步」是流水线步骤数，**保留**。

- [ ] **Step 2: 修复失败定位表 6 处引用**

失败定位表位于 4.3（原 5.3）节内。**只改 `第 3 步 4.x` 和 `5.1` 形式的引用，不动「步骤 1/4/6/7」。**

Edit 1 — L667（步骤 1 fetch 失败的回查指向）：
old_string:
```
  回到：5.1（确认 .env 时间戳）；或排查网络/代理
```
new_string:
```
  回到：4.1（确认 .env 时间戳）；或排查网络/代理
```

Edit 2 — L671（步骤 4 binary 失败，原因 A）：
old_string:
```
    → 回到：第 3 步 4.3（重新登录 / newgrp sbuild）
```
new_string:
```
    → 回到：第 3 步 3.3（重新登录 / newgrp sbuild）
```

Edit 3 — L673（步骤 4 binary 失败，原因 B）：
old_string:
```
    → 回到：第 3 步 4.4 第二段（setup_sbuild_chroot）
```
new_string:
```
    → 回到：第 3 步 3.4 第二段（setup_sbuild_chroot）
```

Edit 4 — L675（步骤 4 binary 失败，原因 C）：
old_string:
```
    → 回到：第 3 步 4.5（--only-stage setup_sbuild_chroot 看 verify_chroot_sources 报错）
```
new_string:
```
    → 回到：第 3 步 3.5（--only-stage setup_sbuild_chroot 看 verify_chroot_sources 报错）
```

Edit 5 — L679（步骤 6 smoke-basic 失败，原因 A）：
old_string:
```
    → 回到：第 3 步 4.2（install_packages 装了 docker.io）；sudo systemctl start docker
```
new_string:
```
    → 回到：第 3 步 3.2（install_packages 装了 docker.io）；sudo systemctl start docker
```

Edit 6 — L690（步骤 7 aptly temp 失败）：
old_string:
```
  回到：第 3 步 4.4 第二段（setup_aptly 阶段）；或看 dry-run 日志的具体 aptly 报错
```
new_string:
```
  回到：第 3 步 3.4 第二段（setup_aptly 阶段）；或看 dry-run 日志的具体 aptly 报错
```

- [ ] **Step 3: 分区定向验证**

Run: `grep -n '^### [45]\.' docs/trixie-builder-dryrun-runbook.md`

Expected:
- 第 4 步区标题为 4.1–4.5（共 5 个）
- **不再有** `### 5.x` 标题

应看到的 5 行：
```
### 4.1 确认 dry-run 环境参数
### 4.2 运行 make dry-run：8 步流水线与产物验收
### 4.3 失败定位：按步骤编号回查
### 4.4 最终终态验收清单：机器状态 + dry-run 产物状态
### 4.5 dry-run 之后是什么
```

Run（核对失败表 6 处引用已改）: `grep -n '回到：5\.1\|第 3 步 4\.3（重新登录\|第 3 步 4\.4 第二段（setup_sbuild_chroot）\|第 3 步 4\.5（\|第 3 步 4\.2（install_packages\|第 3 步 4\.4 第二段（setup_aptly' docs/trixie-builder-dryrun-runbook.md`

Expected: 无输出。

Run（确认流水线步骤编号仍在，未误伤）: `grep -n '步骤 1 fetch\|步骤 4 binary\|步骤 6 smoke-basic\|步骤 7 aptly' docs/trixie-builder-dryrun-runbook.md`

Expected: 4 行全在（这些是流水线步骤，保留）。

- [ ] **Step 4: Commit**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs(runbook): renumber step 4 sub-sections 5.x → 4.x + fix failure-table refs

- 第 4 步标题: 5.1..5.5 → 4.1..4.5
- 失败定位表 6 处: 回到 5.1→4.1, 第 3 步 4.3/4.4/4.5/4.2 → 3.3/3.4/3.5/3.2
- 流水线步骤编号 (步骤 1/4/6/7) 保持不动——属于另一套体系"
```

---

## Task 4: 附录 B 占位符清单表

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md`（L793–798，共 6 格；L799 不变）

**本任务改动清单（6 处 Edit，每格一行）：**

附录 B 是最容易漏改处（一列七格，L799 已正确不动）。逐格 Edit，每行 old_string 取整行确保唯一。

- [ ] **Step 1: 逐格修改 6 行**

Edit 1 — L793（YYYYMMDDTHHMMSSZ 行）：
old_string:
```
| `YYYYMMDDTHHMMSSZ` | 第 4 步 5.1 `.env` 的 `DEBIAN_SNAPSHOT_TIMESTAMP` | snapshot.debian.org 锁定 ocserv 1.5.0-1 源码的时间戳，以 snapshot.debian.org 实际记录为准 |
```
new_string:
```
| `YYYYMMDDTHHMMSSZ` | 第 4 步 4.1 `.env` 的 `DEBIAN_SNAPSHOT_TIMESTAMP` | snapshot.debian.org 锁定 ocserv 1.5.0-1 源码的时间戳，以 snapshot.debian.org 实际记录为准 |
```

Edit 2 — L794（ADMIN_PUBKEY 行）：
old_string:
```
| `ssh-ed25519 AAAA... replace-with-your-real-public-key` | 第 1 步 2.3 `ADMIN_PUBKEY` | 管理员真实 SSH 公钥 |
```
new_string:
```
| `ssh-ed25519 AAAA... replace-with-your-real-public-key` | 第 1 步 1.2 `ADMIN_PUBKEY` | 管理员真实 SSH 公钥 |
```

Edit 3 — L795（`<host>` 行，含两处引用）：
old_string:
```
| `<host>` | 第 1 步 2.3 / 第 3 步 4.3 等 | 构建机的主机名或 IP |
```
new_string:
```
| `<host>` | 第 1 步 1.2 / 第 3 步 3.3 等 | 构建机的主机名或 IP |
```

Edit 4 — L796（`<仓库 URL>` 行）—— 注意按 spec 审阅反馈，措辞改得更明确：
old_string:
```
| `<仓库 URL>` | 第 1 步 2.4 git clone | ocserv-backport 仓库地址 |
```
new_string:
```
| `<仓库 URL>` | 第 1 步 1.2 的 `--repo-url`（git clone） | ocserv-backport 仓库地址 |
```

Edit 5 — L797（`<FULL_FINGERPRINT>` 行，含两处引用）：
old_string:
```
| `<FULL_FINGERPRINT>` | 第 2 步 3.3 / 第 3 步 4.4 reuse-gpg-key | GPG key 的完整 fingerprint（非短 keyid） |
```
new_string:
```
| `<FULL_FINGERPRINT>` | 第 2 步 2.3 / 第 3 步 3.4 reuse-gpg-key | GPG key 的完整 fingerprint（非短 keyid） |
```

Edit 6 — L798（`/path/to/private.asc` 行，含两处引用）：
old_string:
```
| `/path/to/private.asc` | 第 2 步 3.3 / 第 3 步 4.4 import-gpg-key | 待导入的 GPG 私钥文件路径 |
```
new_string:
```
| `/path/to/private.asc` | 第 2 步 2.3 / 第 3 步 3.4 import-gpg-key | 待导入的 GPG 私钥文件路径 |
```

**L799 不动**（`/path/to/id_ed25519.pub` 行已正确指向 `第 1 步 1.2`）。

- [ ] **Step 2: 分区定向验证**

Run: `grep -n '^|.*第 [1-4] 步' docs/trixie-builder-dryrun-runbook.md | grep -E '2\.[0-9]|3\.[0-9]|4\.[0-9]|5\.[0-9]'`

Expected（附录 B 七格「出现位置」列应全部为新编号）：
```
| `YYYYMMDDTHHMMSSZ` | 第 4 步 4.1 ...（不含 5.x）
| ... ADMIN_PUBKEY ... 第 1 步 1.2（不含 2.3）
| `<host>` | 第 1 步 1.2 / 第 3 步 3.3（不含 2.3/4.3）
| `<仓库 URL>` | 第 1 步 1.2 的 --repo-url（不含 2.4）
| `<FULL_FINGERPRINT>` | 第 2 步 2.3 / 第 3 步 3.4（不含 3.3/4.4）
| `/path/to/private.asc` | 第 2 步 2.3 / 第 3 步 3.4（不含 3.3/4.4）
| `/path/to/id_ed25519.pub` | 第 1 步 1.2（原本就正确）
```

Run（确认无旧引用残留）: `grep -n '第 1 步 2\.[34]\|第 2 步 3\.3\|第 3 步 4\.[34]\|第 4 步 5\.1' docs/trixie-builder-dryrun-runbook.md`

Expected: 无输出。

- [ ] **Step 3: Commit**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs(runbook): fix appendix B placeholder table cross-references

7 格「出现位置」列改为新编号:
- 第 4 步 5.1 → 4.1
- 第 1 步 2.3 → 1.2 (ADMIN_PUBKEY, <host>)
- 第 1 步 2.4 → 1.2 的 --repo-url（措辞更明确，避免误以为含独立 git clone 命令）
- 第 2 步 3.3 → 2.3 (FULL_FINGERPRINT, private.asc)
- 第 3 步 4.3/4.4 → 3.3/3.4

L799 (id_ed25519.pub) 原本已正确，不动。"
```

---

## Task 5: 全局定向验证 + diff 复核

**Files:**
- Read-only: `docs/trixie-builder-dryrun-runbook.md`

本任务不改文件，只做 spec §4.1 的两类定向检查 + git diff 内容语义复核。

- [ ] **Step 1: 标题检查 —— 全文标题按步号分组单调**

Run: `grep -n '^### ' docs/trixie-builder-dryrun-runbook.md`

Expected（共 22 个子节标题，按所属步号分组，组内单调递增）：

第 1 步区（1.x，未改）：
```
### 1.1 运行脚本前的只读确认
### 1.2 运行 bootstrap-bare-metal.sh
### 1.3 本步退出条件总览
```

第 2 步区（2.x）：
```
### 2.0 重要区分：两个不同的 dry-run（本步开头必读）
### 2.1 创建 .bootstrap.env（builder）
### 2.2 选择 GPG 模式（builder，决策，不执行）
### 2.3 bootstrap dry-run 预演（builder）
### 2.4 本步退出条件总览
```

第 3 步区（3.x）：
```
### 3.0 阶段执行规则（全步适用）
### 3.1 运行方式选择
### 3.2 第一段：install_packages（装包 + 加入 sbuild 组）
### 3.3 阶段间动作：重新登录让 sbuild group 生效（硬性，必做）
### 3.4 第二段：从 prepare_directories 继续（builder）
### 3.5 drift 检查（可选，builder，幂等重跑）
### 3.6 本步退出条件总览
```

第 4 步区（4.x）：
```
### 4.1 确认 dry-run 环境参数
### 4.2 运行 make dry-run：8 步流水线与产物验收
### 4.3 失败定位：按步骤编号回查
### 4.4 最终终态验收清单：机器状态 + dry-run 产物状态
### 4.5 dry-run 之后是什么
```

附录区（C.x，未改）：
```
### C.1 安装 sudo + 创建 builder 用户 + 配置 passwordless sudo
### C.2 配置 builder 的 SSH authorized_keys
### C.3 切 builder + 克隆仓库
```

判定：第 N 步区下只出现 N.x；不出现任何 `### 3.x`（在第 2 步区）或 `### 4.x`（在第 3 步区）或 `### 5.x`（在第 4 步区）的错位。

- [ ] **Step 2: 引用检查 —— 以 spec §3.2 逐条清单为基准**

逐条核对 spec `docs/superpowers/specs/2026-06-20-runbook-renumber-design.md` §3.2 表 B（正文引用 18 条）和表 C（附录 B 七格）的每一条都已落实。重点高风险区：

(a) 失败定位区（第 4 步 4.3，原 5.3）：
Run: `grep -n '回到：第 3 步' docs/trixie-builder-dryrun-runbook.md`
Expected: 5 行，全部为 `第 3 步 3.2/3.3/3.4/3.5`（无 4.x）。

(b) 附录 B 七格「出现位置」列：人工读 L793–799 七行，每格的步号与子节号都已更新（已在 Task 4 Step 2 验过，这里再复核一次）。

(c) 「第 3 步 3.3 / 3.4 / 3.5」这几个高风险引用点（被引最多）：
Run: `grep -n '第 3 步 3\.' docs/trixie-builder-dryrun-runbook.md`
Expected: 多行，全是 3.x（3.2/3.3/3.4/3.5），无遗漏。

- [ ] **Step 3: 流水线步骤编号未误伤**

Run: `grep -n '步骤 [1-8]' docs/trixie-builder-dryrun-runbook.md`

Expected：流水线表的「步骤 1~8」、失败定位表的「步骤 1/4/6/7」、引言「顺序跑 8 步」全部仍在。这些是流水线步骤，本次不动。

- [ ] **Step 4: git diff 内容语义复核**

Run: `git diff main -- docs/trixie-builder-dryrun-runbook.md` （或 `git log -p -4 docs/trixie-builder-dryrun-runbook.md` 看四个 task 的累计 diff）

判定标准（必须全部满足）：
- 改动**只涉及**：子节标题里的数字、正文/引用块/表格里指向章节的编号
- **不出现**：命令增删、段落增删、占位符语义变化、流水线步骤编号改动、版本号（`1.5.0-1` 等）改动
- 行数变化在 ±5 行内（标题行只改数字字符，理论上 ±0；附录 B 的 L796 因措辞细化可能略长）

如发现任何非编号/引用类改动，回滚该 hunk 重做。

- [ ] **Step 5: 最终 commit（仅当 Step 1–4 全过且无需补改时）**

如果 Task 1–4 的提交已覆盖所有改动且验证全过，本步**无需新提交**，标记完成即可。

若 Step 1–4 发现遗漏需补改，则：
```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs(runbook): fix remaining cross-reference(s) caught in final verification"
```

---

## Self-Review（plan 作者自检）

**1. Spec 覆盖：**
- spec §3.1 子节重编号映射 → Task 1/2/3 的标题重编号覆盖（5+7+5=17 个）✅
- spec §3.2 表 B 正文引用 18 条 → Task 1（引言 1 + 第2步区 3 = 4 条）+ Task 2（8 条）+ Task 3（6 条）= 18 条 ✅
- spec §3.2 表 C 附录 B 七格 → Task 4（6 格改 + 1 格不动）✅
- spec §3.3 不动项（流水线 1~8、版本号）→ Task 3 Step 3 + Task 5 Step 3 显式验证 ✅
- spec §4.1 两类验证 → Task 5 Step 1（标题）+ Step 2（引用）✅

**2. Placeholder 扫描：** 无 TBD/TODO；每个 Edit 都给出精确 old_string/new_string ✅

**3. 类型一致性：** 所有引用的新编号在 spec §3.1 映射表里都有定义；附录 C 引用（L803/805/806）已在 spec 标注「不动」，未列入任何 task ✅

**4. 风险点：**
- 失败定位表里「步骤 4」「步骤 6」等流水线编号与「第 3 步 4.3」章节引用同区共存——Task 3 已显式提醒只改后者，并在 Step 3 验证流水线编号未误伤 ✅
- 附录 B L795/L797/L798 一行含两个引用——Task 4 给出整行 old_string，避免 replace_all 误伤 ✅
- 流水线表「步骤 4 binary」的「4」是孤立的（表单元格分隔），不会与「4.3」字符串冲突 ✅
