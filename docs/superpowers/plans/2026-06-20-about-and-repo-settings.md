# GitHub About & Repo Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure the `GentleKingson/ocserv-backport` repo's About box (description + 7 topics) and settings toggles (disable Wiki + Projects, keep Issues enabled, Discussions disabled, Homepage null).

**Architecture:** All changes are repo-metadata edits via the `gh` CLI (`gh repo edit` + `gh api`). No files are created or modified. Three sequential apply steps, bracketed by a pre-flight check and a final verification. The "commit" semantics differ from a normal plan: there is nothing to `git add` — each task's success is confirmed by re-querying the API.

**Tech Stack:** `gh` CLI (authenticated), GitHub Repos REST API.

**Spec:** `docs/superpowers/specs/2026-06-20-about-and-repo-settings-design.md` (authoritative — all values below are copied from spec §2)

**Note on TDD:** Not applicable. This plan configures external repo metadata; the analog of a test is the final `gh api` verification query (Task 4) that asserts every target value.

**Key constraints (from spec review):**
- `--add-topic` is **incremental** — Task 1 pre-flight confirms baseline topics are empty before adding, so the result is exactly the locked 7 (not "old + 7").
- `--enable-projects=false` does **not** fail when linked boards exist (it hides them from the repo tab; they persist at owner level). Do NOT block on owner-project listing output.
- Verification MUST include `has_discussions: false` (the constraint was previously under-verified).

---

## File Structure

No files created or modified. All operations target GitHub repo metadata via API.

| Target | What changes |
|--------|--------------|
| `repos/GentleKingson/ocserv-backport` description | null → locked sentence |
| `repos/GentleKingson/ocserv-backport` topics | `[]` → 7 locked topics |
| `repos/GentleKingson/ocserv-backport` has_wiki | true → false |
| `repos/GentleKingson/ocserv-backport` has_projects | true → false |
| (unchanged) has_issues, has_discussions, homepage | verified, not modified |

---

## Task 1: Pre-flight — confirm baseline state

**Files:** none (read-only API queries)

- [ ] **Step 1: Confirm baseline topics are empty**

This is the critical pre-flight: `--add-topic` is incremental, so if topics already exist the result would be "old + 7" instead of the locked 7.

Run: `gh api repos/GentleKingson/ocserv-backport --jq '.topics'`

Expected:
```
[]
```

- If `[]` → proceed to Task 2 (the `--add-topic` commands will yield exactly the locked 7).
- If a non-empty array → STOP. Surface the existing topics to the operator. Options: (a) remove the unwanted ones via `gh repo edit --remove-topic <name>` first, then proceed; (b) keep them and accept "existing + 7" (deviates from the locked design — get explicit operator approval). Do not blindly proceed.

- [ ] **Step 2: (Informational, non-blocking) Inspect owner-level Projects**

Run: `gh project list --owner GentleKingson --format json 2>/dev/null || echo "(could not list owner-level Projects, or none are accessible)"`

This is informational only. Caveats (do not block on this output):
- It lists owner-level Projects; it does NOT prove whether any are linked to this repo.
- Disabling repo Projects does NOT delete linked Projects — they just stop appearing in this repo's Projects tab and remain at the owner level.
- So: whatever this prints, proceed to Task 3 (unless Step 1 above told you to stop).

- [ ] **Step 3: No commit step**

No files changed, no commit. Proceed to Task 2.

---

## Task 2: Set description + topics

**Files:** none (API writes)

- [ ] **Step 1: Apply description and 7 topics in one command**

Run:
```bash
gh repo edit GentleKingson/ocserv-backport \
  --description "Reproducible Debian trixie backport pipeline for ocserv 1.5.0 with shared local/CI build stages." \
  --add-topic debian --add-topic trixie --add-topic ocserv \
  --add-topic openconnect --add-topic backport --add-topic sbuild --add-topic aptly
```

Expected: `✓ Edited repository GentleKingson/ocserv-backport` (or equivalent success output, exit 0).

- [ ] **Step 2: Confirm description + topics landed correctly**

Run: `gh api repos/GentleKingson/ocserv-backport --jq '{description: .description, topics: .topics}'`

Expected:
```json
{
  "description": "Reproducible Debian trixie backport pipeline for ocserv 1.5.0 with shared local/CI build stages.",
  "topics": ["debian", "trixie", "ocserv", "openconnect", "backport", "sbuild", "aptly"]
}
```

(The exact topic ordering in the array may vary — what matters is the set equals those 7, no more, no less.)

- [ ] **Step 3: No commit step**

Repo metadata change, not a file. Proceed to Task 3.

---

## Task 3: Disable Wiki + Projects

**Files:** none (API writes)

- [ ] **Step 1: Disable Wiki and Projects**

Run:
```bash
gh repo edit GentleKingson/ocserv-backport --enable-wiki=false --enable-projects=false
```

Expected: `✓ Edited repository GentleKingson/ocserv-backport`, exit 0.

Note: this command does NOT fail if linked Project boards exist — it hides them from this repo's Projects tab (they persist at owner level). If it does error for some other reason, surface the error; do not guess.

- [ ] **Step 2: No commit step**

Repo metadata change. Proceed to Task 4 (final verification).

---

## Task 4: Final verification — assert all target values

**Files:** none (read-only API query)

This is the "test" for the whole plan: a single query asserting every target value from spec §2, including `has_discussions: false`.

- [ ] **Step 1: Run the full verification query**

Run:
```bash
gh api repos/GentleKingson/ocserv-backport --jq '{
  description: .description,
  topics: .topics,
  homepage: .homepage,
  has_issues: .has_issues,
  has_discussions: .has_discussions,
  has_wiki: .has_wiki,
  has_projects: .has_projects
}'
```

Expected output (must match exactly):
```json
{
  "description": "Reproducible Debian trixie backport pipeline for ocserv 1.5.0 with shared local/CI build stages.",
  "topics": ["debian", "trixie", "ocserv", "openconnect", "backport", "sbuild", "aptly"],
  "homepage": null,
  "has_issues": true,
  "has_discussions": false,
  "has_wiki": false,
  "has_projects": false
}
```

- [ ] **Step 2: Assert each field**

Check every field against the expected:
- `description` == the locked sentence (char-for-char)
- `topics` == exactly those 7 (set equality; order may differ)
- `homepage` == null
- `has_issues` == true
- `has_discussions` == false (the constraint that was previously under-verified)
- `has_wiki` == false
- `has_projects` == false

If any field is wrong, re-apply the relevant `gh repo edit` flag from Task 2/3 and re-run this query.

- [ ] **Step 3: No commit step**

All changes are repo metadata; nothing to `git add`. The plan is complete when Step 1's output matches the expected JSON in full.

---

## Self-Review

**1. Spec coverage:**
- spec §2.1 description → Task 2 Step 1 (`--description` flag with locked sentence) ✅
- spec §2.2 topics (7) → Task 2 Step 1 (7 `--add-topic` flags) ✅
- spec §2.3 Wiki disable → Task 3 Step 1 (`--enable-wiki=false`) ✅
- spec §2.3 Projects disable → Task 3 Step 1 (`--enable-projects=false`) ✅
- spec §2.3 Issues keep enabled → Task 4 asserts `has_issues: true` (no flag needed; default) ✅
- spec §2.3 Discussions keep disabled → Task 4 asserts `has_discussions: false` (no flag needed; default) ✅
- spec §2.3 Homepage null → Task 4 asserts `homepage: null` (no flag needed; default) ✅
- spec §3.3 verification JSON → Task 4 Step 1 (identical query, includes has_discussions) ✅
- spec §4.1 baseline-topics pre-flight → Task 1 Step 1 ✅
- spec §4.2 owner-project informational check → Task 1 Step 2 ✅
- spec §5 rollback semantics — reflected in Task 3 Step 1 note + Task 1 Step 2 caveats (non-blocking, hides not deletes) ✅

**2. Placeholder scan:** No TBD/TODO. Every step has exact commands and expected output. ✅

**3. Consistency check:**
- Description string is identical in Task 2 Step 1, Task 2 Step 2 expected, and Task 4 Step 1 expected. ✅
- The 7 topics are identical across Task 2 Step 1 and both verification expected outputs. ✅
- "has_discussions: false" appears in Task 4 expected (addresses review fix #2). ✅
- Task 1 Step 1's STOP-on-non-empty logic is consistent with the spec §4.1 incremental-topics caveat. ✅
- Task 3 Step 1's "does not fail on linked boards" note is consistent with spec §4.2/§5. ✅
