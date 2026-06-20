# Runbook ↔ Code Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync `docs/trixie-builder-dryrun-runbook.md` with PR #4's changed fetch/source-package behavior (upstream orig tarball + .asc now published to `build/source/`), fixing 1 contradiction and 2 reader-impacting omissions.

**Architecture:** Single markdown document, 3 surgical edits. No code, no TDD, no builder test. Each edit is an exact-string replace with the precise before/after text below — the executor must copy the strings verbatim because they include CJK punctuation (，。：（）) that must not be altered.

**Tech Stack:** Markdown only. Source of truth for the edits: `scripts/fetch-source.sh` (`publish_orig_tarball` + `main`), `scripts/build-source-package.sh` (`dpkg-buildpackage -S -d`).

**Reference spec:** `docs/superpowers/specs/2026-06-20-runbook-sync-with-code-design.md`

---

## File Structure

- Modify ONLY: `docs/trixie-builder-dryrun-runbook.md` (3 distinct locations)
- Do NOT touch: `README.md`, `docs/BUILD_HOST_BOOTSTRAP.md`, any `scripts/*`, any `test/*`

Three edits, one commit. Edit order does not matter (non-overlapping locations) but Task 3 depends conceptually on Task 1's framing, so do them in order.

---

### Task 1: Fix §4.2 fetch row contradiction (publish orig tarball + .asc)

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md` (line ~657, the `| 1 | fetch | ...` table row)

This fixes the actively-misleading claim "只发布 source tree，raw .dsc/tarballs 留在临时 staging". After PR #4, the upstream `.orig.tar.xz` and `.asc` ARE published to `build/source/` (the quilt source rebuild needs them).

- [ ] **Step 1: Apply the exact string replacement**

Find this exact line (it is the `| 1 | fetch | ...` row in the §4.2 table):

```
| 1 | fetch | `build/source/ocserv-1.5.0/` | 不启用 sid apt 源（只 dget 源码）；只发布 source tree，raw .dsc/tarballs 留在临时 staging |
```

Replace with (CJK punctuation preserved verbatim):

```
| 1 | fetch | `build/source/ocserv-1.5.0/` + upstream `ocserv_1.5.0.orig.tar.xz` 及 `.asc` | 不启用 sid apt 源（只 dget 源码）；持久发布 source tree 与 upstream orig tarball(+asc) 到 `build/source/`（src-pkg 的 quilt 重打包需要 orig tarball）。sid 原版 `.dsc` / `.debian.tar.xz` 不发布为 fetch 输出（backport 会重新生成它们） |
```

- [ ] **Step 2: Verify the edit landed in exactly one place**

Run: `grep -c '只发布 source tree，raw .dsc/tarballs 留在临时 staging' docs/trixie-builder-dryrun-runbook.md`
Expected: `0` (the old misleading phrase is gone)

Run: `grep -c 'src-pkg 的 quilt 重打包需要 orig tarball' docs/trixie-builder-dryrun-runbook.md`
Expected: `1` (the new row exists in exactly one place)

---

### Task 2: Fix §4.2 src-pkg row omission (orig tarball dependency)

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md` (line ~659, the `| 3 | src-pkg | ...` table row)

This lets a reader who hits `dpkg-source: ... no upstream tarball` self-diagnose by checking whether fetch published the orig tarball.

- [ ] **Step 1: Apply the exact string replacement**

Find this exact line (the `| 3 | src-pkg | ...` row):

```
| 3 | src-pkg | `build/source/ocserv_1.5.0-1~bpo13+1.dsc` + `.debian.tar.xz` | 不构建 binary |
```

Replace with (CJK punctuation preserved verbatim):

```
| 3 | src-pkg | `build/source/ocserv_1.5.0-1~bpo13+1.dsc` + `.debian.tar.xz` | 不构建 binary；`dpkg-source -b` 从 `build/source/` 找 upstream orig tarball（见第 1 步），缺失时报 `no upstream tarball`，可据此回查 fetch 产物完整性 |
```

- [ ] **Step 2: Verify**

Run: `grep -c 'no upstream tarball' docs/trixie-builder-dryrun-runbook.md`
Expected: `1` (only the src-pkg row; the §4.3 failure table does NOT mention this — that's fine, we deliberately scoped §4.3 changes to staging-note only)

Run: `grep -c 'dpkg-source -b. 从 \`build/source/\` 找 upstream orig tarball' docs/trixie-builder-dryrun-runbook.md`
Expected: `1`

---

### Task 3: Fix §4.3 staging-note omission (non-atomic publish)

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md` (lines ~726-728, the closing note under §4.3)

This corrects "只有完整 source tree 通过验证后，才会替换 build/source/ocserv-1.5.0/" to also cover the subsequent orig-tarball publish, and to NOT imply atomicity (swap-with-rollback on the tree is a separate operation from the sequential tarball mv).

- [ ] **Step 1: Apply the exact string replacement**

Find this exact text (the closing `>` blockquote note at the end of §4.3, two lines):

```
> 通用排查：任一步失败后，产物目录 `build/source/` 和 `build/binary/` 会保留到失败点，
> 可直接检查半成品。fetch 每次都在新的临时 staging 目录中完成下载和解包；只有完整
> source tree 通过验证后，才会替换 build/source/ocserv-1.5.0/。若需彻底重置本地构建状态，
> 重跑前可手动执行 rm -rf build/。
```

Replace with (CJK punctuation preserved verbatim; note the orig-tarball publish is described as a FOLLOW-UP, not simultaneous):

```
> 通用排查：任一步失败后，产物目录 `build/source/` 和 `build/binary/` 会保留到失败点，
> 可直接检查半成品。fetch 每次都在新的临时 staging 目录中完成下载和解包；完整
> source tree 通过验证后，以带回滚的替换方式更新 `build/source/ocserv-1.5.0/`，随后从同一
> staging 目录发布 upstream `ocserv_1.5.0.orig.tar.xz` 及 `.asc` 到 `build/source/`（两步独立，
> 非单一原子事务）。sid 原版 `.dsc` 与 `.debian.tar.xz` 不发布为 fetch 输出，backport 在
> src-pkg 阶段重新生成它们。若需彻底重置本地构建状态，重跑前可手动执行 rm -rf build/。
```

- [ ] **Step 2: Verify**

Run: `grep -c '才会替换 build/source/ocserv-1.5.0/' docs/trixie-builder-dryrun-runbook.md`
Expected: `0` (the old wording is gone)

Run: `grep -c '两步独立，非单一原子事务' docs/trixie-builder-dryrun-runbook.md`
Expected: `1` (non-atomic wording present)

Run: `grep -c '原子替换' docs/trixie-builder-dryrun-runbook.md`
Expected: `0` (no stale "atomic replacement" phrasing anywhere — the runbook never had it, this is a paranoia check that we didn't introduce it)

---

### Task 4: Whole-document consistency review + commit

**Files:**
- Read-only review of `docs/trixie-builder-dryrun-runbook.md`

- [ ] **Step 1: Read the edited regions in context**

Read lines ~655-665 (§4.2 table) and ~724-730 (§4.3 closing note). Confirm:
- §4.2 fetch row now lists `ocserv_1.5.0.orig.tar.xz` + `.asc` as published products.
- §4.2 src-pkg row cross-references the orig tarball + the `no upstream tarball` failure.
- §4.3 note says tree swap is rollback-able, then orig tarball published after — two steps, not atomic.
- No mention of `.changes` added to src-pkg row (out of scope).
- Rows 2/4/5/6/7/8 unchanged.

- [ ] **Step 2: Confirm no other contradiction was introduced**

Run: `grep -n '只发布 source tree\|raw .dsc/tarballs 留在临时 staging\|才会替换 build/source' docs/trixie-builder-dryrun-runbook.md`
Expected: no output (all three stale phrases removed)

- [ ] **Step 3: Commit all three edits together**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs: sync runbook fetch/src-pkg products with PR #4

After PR #4, fetch publishes the upstream .orig.tar.xz + .asc to
build/source/ (the quilt source rebuild needs them), not just the
source tree. Update §4.2 fetch row (products), §4.2 src-pkg row
(orig-tarball dependency + no-upstream-tarball failure path), and
§4.3 staging note (tree swap-with-rollback, then sequential orig-
tarball publish — two independent ops, not atomic).

sid .dsc/.debian.tar.xz remain unpublished as fetch outputs (backport
regenerates them); the 509 fallback's build/source-cache/ seed is a
separate persistent read-only input, unaffected."
```

- [ ] **Step 4: Verify clean tree + commit present**

Run: `git status`
Expected: `nothing to commit, working tree clean`

Run: `git log --oneline -1`
Expected: the commit from Step 3 at HEAD.

---

## Self-Review

**1. Spec coverage:** 
- Spec 改动点 ① (fetch row) → Task 1. ✓
- Spec 改动点 ② (src-pkg row) → Task 2. ✓
- Spec 改动点 ③ (staging note, non-atomic) → Task 3. ✓
- Spec exclusion "no flag names" → no task touches flag names. ✓
- Spec exclusion "README/BUILD_HOST_BOOTSTRAP unchanged" → no task touches them. ✓
- Spec 验证方式 (read §4.2/§4.3/§4.4 + cross-check scripts) → Task 4 Step 1-2 covers the read-through; the script cross-check is encoded in the before/after text itself (the after-text was derived from fetch-source.sh publish_orig_tarball + build-source-package.sh). ✓

**2. Placeholder scan:** Every edit step has exact find/replace strings. No TBD, no "similar to", no "add appropriate wording". Verification steps have exact grep commands with expected outputs. ✓

**3. Consistency check:** 
- The orig-tarball product name is consistently `ocserv_1.5.0.orig.tar.xz` across Task 1 (fetch row), Task 2 (src-pkg cross-ref), Task 3 (staging note). ✓
- The `.asc` is mentioned in Task 1 and Task 3 (not Task 2 — correct, since src-pkg's `dpkg-source -b` needs the tarball, not the signature; Task 2 is about the tarball dependency only). ✓
- "sid 原版 `.dsc` 与 `.debian.tar.xz` 不发布为 fetch 输出" wording matches the spec's review-corrected boundary (not "stays in temp staging"). ✓
- Non-atomic phrasing ("两步独立，非单一原子事务") matches spec 改动点 ③. ✓

No issues found.
