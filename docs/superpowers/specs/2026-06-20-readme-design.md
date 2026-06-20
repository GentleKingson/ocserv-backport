# README Design

**Date:** 2026-06-20
**Target:** Create `README.md` (new file, project root)
**Type:** New documentation file (single file, ~60 lines)

---

## 1. Goal

Write a concise, English-language README that lets a first-time reader understand
what ocserv-backport is, how to validate it locally, how CI publishes, and where to
find deeper docs — in roughly one minute of skimming. The README is an **entry
point and navigation layer**, not a substitute for the existing 862-line runbook.

**Non-goals:**
- Do NOT duplicate runbook content (builder setup, sbuild group, GPG modes).
- Do NOT enumerate all `make` targets (the Makefile already has `make help`).
- Do NOT cover secrets configuration, runner registration, or production ops in
  depth — these belong to later-phase docs.

---

## 2. Scope Decisions (locked from brainstorming)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language | **English** | Matches scripts/Makefile/CI/workflow style; suitable for external/future-open readers |
| Depth | **Minimal entry-point** | Runbook already owns "bare metal → dry-run"; README points to it, doesn't repeat |
| "One screen" | **~1-minute skim, ~60 lines** | Not a physical viewport constraint; aim for fast comprehension |
| Pipeline viz | **Arrow diagram in ```text fence** | Highest information density per line; fence prevents Markdown reflow |
| Repo layout table | **5-row table** | Navigation layer: scripts/Makefile/ansible/workflows/docs. Not clutter for this multi-component repo |
| Quick start command | **`make dry-run` only** | `make help` mention lives in the Repo layout table's Makefile row |
| dry-run boundary note | **Explicit** | Distinguish full CI publish pipeline from local validation path |
| Section order | what/why → Pipeline → Quick start → Publishing & rollback → Build host setup → Repo layout | Project does-what first, local validation, CI publishing, then defer machine setup to runbook |

---

## 3. README Structure & Content

The README has exactly six sections in this order. Approximate line budget: ~60
lines of prose + 1 code block + 1 table.

### 3.1 Title + what/why (~4 lines)

**Content requirements:**
- H1: `# ocserv-backport`
- 2-3 sentence definition. Use this accurate framing (NOT "stops at signed .deb"):
  - It is a reproducible build, validation, and CI publishing pipeline that
    backports ocserv (OpenConnect VPN server) from Debian sid source to Debian
    trixie as `1.5.0-1~bpo13+1`.
  - Local entry point is `make dry-run`; CI owns testing publish, production
    promotion, and rollback.
- Mention the local==CI principle in one phrase (CI invokes the same build
  stages used locally).

**Draft text:**

```markdown
# ocserv-backport

Reproducible build, validation, and CI publishing pipeline that backports
ocserv (the OpenConnect VPN server) from Debian sid source to Debian trixie as
`1.5.0-1~bpo13+1`. The local entry point is `make dry-run`; CI owns testing
publish, production promotion, and rollback. Local and CI run the same build
stages — what passes locally passes in CI.
```

### 3.2 Pipeline (~6 lines)

**Content requirements:**
- Arrow diagram inside a ```text fence (prevents reflow).
- 8 stages in dry-run.sh order: fetch → rewrap → src-pkg → binary (sbuild) →
  lint → smoke-basic → aptly snapshot → R2 sync.
- One boundary sentence below: each stage has a Make target; CI invokes the
  same stages used locally.

**Draft text:**

```markdown
## Pipeline

```text
fetch → rewrap → src-pkg → binary (sbuild) → lint → smoke-basic → aptly snapshot → R2 sync
```

Each stage has a corresponding Make target; CI invokes the same build stages used locally.
```

### 3.3 Quick start (~5 lines)

**Content requirements:**
- Single command: `make dry-run` in a bash code block.
- Explicit boundary note (distinguishes full CI publish from local validation):
  make dry-run validates the pipeline with a temporary aptly root and does not
  touch R2, staging, production, or the real aptly database.
- One-line pointer to `make help` for all targets.

**Draft text:**

```markdown
## Quick start

```bash
make dry-run   # reproduces CI locally, touches NO real state
```

`make dry-run` validates the pipeline with a temporary aptly root and does not touch R2, staging, production, or the real aptly database. See `make help` for all targets.
```

### 3.4 Publishing & rollback (~8 lines)

**Content requirements:**
- 3 bullets, one per workflow, naming the file + one-phrase role.
- Do NOT duplicate trigger conditions, inputs, or secrets (those live in the
  workflow files and runbook appendices).

**Draft text:**

```markdown
## Publishing & rollback (CI-driven)

- `.github/workflows/ci-testing.yml` — build, lint, smoke, publish testing channel
- `.github/workflows/promote-production.yml` — promote a validated snapshot (protected `production` environment)
- `.github/workflows/rollback-production.yml` — rollback production to a previous-good snapshot
```

### 3.5 Build host setup (~5 lines)

**Content requirements:**
- One sentence: from bare Debian trixie to `make dry-run` passing.
- Primary link: `docs/trixie-builder-dryrun-runbook.md` (linear handoff).
- Secondary link: `docs/BUILD_HOST_BOOTSTRAP.md` (bootstrap script quick-ref).

**Draft text:**

```markdown
## Build host setup

From a bare Debian trixie amd64 machine to `make dry-run` passing, follow the
linear handoff in [`docs/trixie-builder-dryrun-runbook.md`](docs/trixie-builder-dryrun-runbook.md).
Bootstrap script quick-reference: [`docs/BUILD_HOST_BOOTSTRAP.md`](docs/BUILD_HOST_BOOTSTRAP.md).
```

### 3.6 Repo layout (~9 lines)

**Content requirements:**
- 5-row markdown table, columns: Path | Purpose.
- Exact wording from review (locked):

| Path | Purpose |
|------|---------|
| `scripts/` | Build, bootstrap, packaging, and validation scripts |
| `Makefile` | Local build targets; run `make help` |
| `ansible/` | Repository installation, upgrade, verification, and rollback automation |
| `.github/workflows/` | Testing publish, production promotion, and rollback workflows |
| `docs/` | Build-host runbook and operational references |

---

## 4. Verification

### 4.1 Done criteria

1. File `README.md` exists at project root.
2. Markdown renders cleanly (no broken links, no malformed table, code fences
   balanced).
3. All three doc links resolve to existing files:
   - `docs/trixie-builder-dryrun-runbook.md`
   - `docs/BUILD_HOST_BOOTSTRAP.md`
   - (workflow file references in §3.4 are prose, not links — they name paths)
4. Total length ~60 lines of prose + 1 code block + 1 table (skimmable in ~1 min).
5. No content duplicated from the runbook (no GPG mode details, no sbuild group
   steps, no builder-user creation).

### 4.2 Self-check commands

- `wc -l README.md` → roughly 60-80 lines total.
- Verify links: the two `docs/` links point to files that `ls` confirms exist.
- Eyeball the rendered table alignment (5 rows, 2 columns, header separator).

---

## 5. Implementation Notes

- Single new file, no other files modified.
- No code or script changes.
- Use the exact draft text in §3.1–§3.6 (reviewed during brainstorming); the
  implementer may adjust only whitespace/line-wrapping for readability.
- Commit as a single commit: `docs: add concise project README`.
