# GitHub About & Repo Settings Design

**Date:** 2026-06-20
**Target:** GitHub repository `GentleKingson/ocserv-backport` About box and settings
**Type:** Repository metadata configuration (no code/docs files changed)

---

## 1. Goal

Configure the repository's About box (description + topics) and settings toggles
(Wiki, Projects, Issues, Discussions, Homepage) so the public-facing repo entry
point is accurate, discoverable, and free of unused features that fragment
documentation or add navigation noise.

**Current state (verified via `gh api repos/GentleKingson/ocserv-backport`):**
- `description`: null (empty)
- `topics`: [] (empty)
- `homepage`: null
- `has_issues`: true, `has_wiki`: true, `has_projects`: true (all defaults)
- `visibility`: public

**Non-goals:**
- Do NOT change visibility, default branch, merge strategy, or branch protection.
- Do NOT add Homepage URL (no project site; apt repo endpoint is infra, not a homepage).
- Do NOT configure GitHub Actions permissions, secrets, or environments (separate concern).

---

## 2. Design (all three parts locked from brainstorming)

### 2.1 About description

```
Reproducible Debian trixie backport pipeline for ocserv 1.5.0 with shared local/CI build stages.
```

- **Length:** 98 characters — renders fully in the About box and in search results.
- **Language:** English (matches README first paragraph).
- **Wording rationale:** "shared local/CI build stages" matches README's
  "share the same core build-validation stages" and avoids the over-strong
  `local==CI` (which could read as "passes locally → guaranteed passes in CI").

### 2.2 Topics (7)

```
debian, trixie, ocserv, openconnect, backport, sbuild, aptly
```

| Topic | Purpose |
|-------|---------|
| `debian` | Target distro — highest-traffic discoverable tag |
| `trixie` | Specific target release; distinguishes from generic Debian repos |
| `ocserv` | The software being backported |
| `openconnect` | Covers ecosystem searchers who don't know the name `ocserv` |
| `backport` | The project's defining activity |
| `sbuild` | Signature build tool (chroot builds) |
| `aptly` | Signature publish tool (repo/snapshot management) |

**Deliberately excluded:**
- `vpn` — too broad; would misclassify as a generic VPN deployment/config repo
- `docker`, `ansible`, `github-actions` — implementation details, not signatures; attract wrong searchers
- `gpg`, `rclone`, `cloudflare-r2` — secondary pipeline pieces

### 2.3 Settings toggles

| Setting | Current | Target | Rationale |
|---------|---------|--------|-----------|
| Wiki | enabled | **disable** | Repo already has versioned `docs/` (runbook, bootstrap ref, specs, plans); Wiki would create a second doc entry point without git-tracked review. Temporary notes belong in issues/PRs/commits/in-repo docs. |
| Projects | enabled | **disable** | No usage; empty Projects tab is navigation noise. Re-enable later if cross-issue kanban is needed. Verify no active linked boards before disabling. |
| Issues | enabled | **keep enabled** | Appropriate for build failures, backport drift, runbook revisions, CI problems. |
| Discussions | disabled | **keep disabled** | Docs + issues + PRs suffice at current team size; no need for an unstructured discussion surface. |
| Homepage URL | null | **leave null** | APT repo endpoint is publish infrastructure, not a project homepage; README already serves as project entry. |

---

## 3. Implementation

All changes are applied via the `gh` CLI (repo settings API). No file edits.

### 3.1 Set description + topics

```bash
gh repo edit GentleKingson/ocserv-backport \
  --description "Reproducible Debian trixie backport pipeline for ocserv 1.5.0 with shared local/CI build stages." \
  --add-topic debian --add-topic trixie --add-topic ocserv \
  --add-topic openconnect --add-topic backport --add-topic sbuild --add-topic aptly
```

### 3.2 Disable Wiki and Projects

```bash
gh repo edit GentleKingson/ocserv-backport --enable-wiki=false --enable-projects=false
```

(Issues stays enabled, Discussions stays disabled, Homepage stays null — no flags needed.)

### 3.3 Verification

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

**Expected output:**
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

---

## 4. Pre-flight checks (informational, non-blocking)

These confirm current state before applying changes. They do NOT block the
`gh repo edit` commands — disabling repository Wiki/Projects does not fail when
content or linked boards exist (see §5 for what actually happens to that content).

### 4.1 Confirm baseline topics are still empty

`--add-topic` is incremental — it adds to existing topics rather than replacing
them. The design target is exactly 7 topics; if the repo already has topics at
implementation time, the result would be "old + new 7" instead of the locked 7.

```bash
gh api repos/GentleKingson/ocserv-backport --jq '.topics'
```

- `[]` → proceed with the `--add-topic` commands from §3.1
- non-empty array → surface the existing topics to the operator; decide whether
  to keep, remove (via `--remove-topic`), or use a precise-replace approach
  before continuing

### 4.2 Inspect owner-level Projects (optional, informational only)

```bash
gh project list --owner GentleKingson --format json 2>/dev/null || echo "(no classic projects API access / none exist)"
```

Caveats (do not treat as blocking):
- This lists the owner's Projects; it does **not** prove whether any of them are
  linked to `GentleKingson/ocserv-backport`. Owner-project listing and
  repository linking/unlinking are distinct operations in `gh`.
- Disabling repository Projects does **not** delete linked Projects — they simply
  stop appearing in this repository's Projects tab and remain accessible at the
  owner level.
- Therefore: do not block `--enable-projects=false` merely because Projects exist.

---

## 5. Rollback

All changes are reversible via the same `gh repo edit` flags:
- Restore Wiki/Projects: `--enable-wiki=true --enable-projects=true`
- Clear description: `--description ""`
- Remove topics: `--remove-topic <name>` per topic

**Data-retention behavior on disable (important):**
- Disabling Wiki **hides** existing wiki content rather than erasing it;
  re-enabling Wiki restores the previous pages.
- Disabling repository Projects **hides** linked Projects from this repository's
  Projects tab; it does **not** delete the owner-level Projects themselves. They
  remain accessible and re-linkable at the owner level.

So none of the disable operations in this spec destroy data; they only change
visibility.
