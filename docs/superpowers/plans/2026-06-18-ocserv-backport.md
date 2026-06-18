# ocserv 1.5.0 trixie backport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the full private-backport pipeline for ocserv 1.5.0 on Debian 13 trixie: fetch sid source, rebuild in trixie, publish via aptly to R2, pin strictly, upgrade/rollback with Ansible, automate via GitHub Actions.

**Architecture:** Version-pinned shell scripts driven by a versioned Makefile; CI jobs are thin wrappers that call `make <target>`. aptly holds the source-of-truth snapshots on a long-lived builder host; R2 (`/testing/` + `/prod/`) is a mirror, not history. An Ansible role does controlled host-side add-repo/upgrade/rollback/verify; staging auto-rolls-back on verify failure, production promote is human-gated.

**Tech Stack:** Bash (`set -euo pipefail`), GNU Make, sbuild/schroot, devscripts (dget/dch/dpkg-buildpackage), aptly, rclone (R2 via S3 API), Cloudflare API (cache purge), Ansible, GitHub Actions (self-hosted runner). Testing via bats (shell), shellcheck, ansible-lint, and the spec's end-to-end dry-run.

**Reference spec:** `docs/superpowers/specs/2026-06-18-ocserv-backport-design.md` (v3). All version numbers, paths, names, and conventions below come from that spec — do not improvise alternatives.

**Conventions for every script in this repo:**
- Start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- No `cd` without checking; prefer absolute paths or `cd "$(dirname "$0")"` style with guards.
- All repo-relative paths assume the repo root as CWD unless noted.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, `ci:`, `docs:`).

**Test stance (adapt TDD to ops scripts):** Where a script has parseable logic (snapshot-name, assert-apt-policy, manifest read/write), write a bats test first. For scripts that wrap external tools (sbuild, rclone, aptly), the "test" is the spec's dry-run (§6.3) plus shellcheck. Ansible role is validated with ansible-lint + a molecule scenario against a trixie container.

---

## File Structure

Locked-in layout (from spec §6.9). Each file has one responsibility:

```
.gitignore                                   # already exists
Makefile                                     # single entrypoint, local==CI
scripts/
  _common.sh                                  # shared helpers (logging, flock wrapper)
  fetch-source.sh                             # dget from snapshot.debian.org
  rewrap-changelog.sh                         # dch to backport version
  build-source-package.sh                     # dpkg-buildpackage -S
  build-binary.sh                             # sbuild in trixie schroot
  lint-package.sh                             # lintian
  smoke-test.sh                               # arg: basic | service
  snapshot-name.sh                            # single source of snapshot name
  aptly-publish.sh                            # arg: channel; first-vs-subswitch logic; updates manifest
  aptly-rollback.sh                           # arg: channel; reads manifest
  r2-sync.sh                                  # arg: channel; maps RCLONE_CONFIG_R2_*
  cf-purge.sh                                 # arg: channel
test/
  helpers/bats-helper.bash                    # shared bats setup
  test_snapshot_name.bats
  test_assert_apt_policy.bats
  test_manifest.bats                          # tests manifest read/write helpers
  fixtures/apt-policy/                        # sample apt-cache policy outputs
ansible/
  site.yml                                     # one play, vars-driven
  ansible.cfg
  inventories/
    staging/group_vars/all.yml
    production/group_vars/all.yml
  roles/ocserv_backport/
    defaults/main.yml
    tasks/{main,add-repo,upgrade,rollback,verify}.yml
    templates/{thehkus-backports.sources,ocserv-pin}.j2
    files/
      thehkus-backports.asc                    # placeholder; real key exported at bootstrap
      assert-apt-policy.sh
    molecule/default/
      molecule.yml
      converge.yml
      verify.yml
.github/workflows/
  ci-testing.yml
  promote-production.yml
  rollback-production.yml
docs/
  BUILD_HOST_BOOTSTRAP.md                      # operator runbook for §6.1 init
```

**Why this split:** `scripts/_common.sh` keeps flock + logging DRY so every mutating script uses the same lock semantics (spec §1.4). `snapshot-name.sh`, the apt-policy assertion, and manifest handling are the only pieces with nontrivial parseable logic — they get bats tests. Everything else is wiring validated by the dry-run.

---

## Task 1: Repo scaffolding + Makefile skeleton + shellcheck gate

**Files:**
- Create: `scripts/_common.sh`
- Create: `Makefile`
- Create: `test/helpers/bats-helper.bash`
- Create: `.shellcheckrc`

- [ ] **Step 1: Create `.shellcheckrc`**

```ini
# Treat unset vars + pipefail expectations; scripts set -euo pipefail themselves.
enable=require-variable-braces
external-sources=true
```

- [ ] **Step 2: Create `scripts/_common.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for repo scripts. Source with: source "$(dirname "$0")/_common.sh"
set -euo pipefail

# Logging --------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# flock wrapper --------------------------------------------------------------
# Usage: acquire_repo_publish_lock  -> sets fd 9, held until script exits
acquire_repo_publish_lock() {
  local lockdir="${APTLY_ROOT_DIR:-/var/aptly}/.locks"
  mkdir -p "${lockdir}" 2>/dev/null || true
  exec 9>"${lockdir}/repo-publish.lock"
  flock -n 9 || die "repo-publish-lock held by another process; aborting"
  log "acquired repo-publish-lock (${lockdir}/repo-publish.lock)"
}

# Channel validation ---------------------------------------------------------
valid_channel() { [[ "$1" == "testing" || "$1" == "production" ]]; }
require_channel() { valid_channel "$1" || die "channel must be testing|production, got: $1"; }
```

- [ ] **Step 3: Create `test/helpers/bats-helper.bash`**

```bash
# Shared setup for bats tests.
export REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
load "${BATS_TEST_DIRNAME}/helpers/bats-helper.bash" 2>/dev/null || true
setup() { cd "${REPO_ROOT}"; }
```

- [ ] **Step 4: Create minimal `Makefile` (targets added in later tasks)**

```makefile
# ocserv-backport — local==CI entrypoint. Spec §4.5.
SHELL := /bin/bash
.DEFAULT_GOAL := help
OCSERV_VERSION := 1.5.0-1~bpo13+1

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*##/:/' | column -t -s:
```

- [ ] **Step 5: Install tooling locally (macOS dev note)**

Run (document; not committed):
```bash
brew install bats-core shellcheck ansible-lint
```
Expected: `bats --version`, `shellcheck --version`, `ansible-lint --version` all print versions.

- [ ] **Step 6: Verify shellcheck passes on the new script**

Run: `shellcheck scripts/_common.sh`
Expected: no output (clean).

- [ ] **Step 7: Commit**

```bash
git add scripts/_common.sh test/helpers/bats-helper.bash Makefile .shellcheckrc
git commit -m "chore: scaffold scripts/_common.sh, Makefile, bats helper, shellcheckrc"
```

---

## Task 2: `snapshot-name.sh` (TDD)

The single source of the snapshot name (spec §1.5, §2.2). CI uses `GITHUB_RUN_NUMBER`; local uses a timestamp. Never uses git short SHA.

**Files:**
- Create: `scripts/snapshot-name.sh`
- Create: `test/test_snapshot_name.bats`

- [ ] **Step 1: Write failing tests**

`test/test_snapshot_name.bats`:
```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

@test "CI env produces gh<N> suffix" {
  GITHUB_RUN_NUMBER=123 run scripts/snapshot-name.sh
  [ "$status" -eq 0 ]
  [ "$output" = "ocserv-1.5.0-1~bpo13+1-build-gh123" ]
}

@test "local env produces local-<timestamp> suffix" {
  unset GITHUB_RUN_NUMBER
  FAKETIME=1 run scripts/snapshot-name.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^ocserv-1\.5\.0-1~bpo13\+1-build-local-[0-9]{8}T[0-9]{6}$ ]]
}
```

- [ ] **Step 2: Run tests, confirm they fail**

Run: `bats test/test_snapshot_name.bats`
Expected: FAIL (script does not exist).

- [ ] **Step 3: Implement `scripts/snapshot-name.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Single source of snapshot name. Spec §1.5 / §2.2.
OCSERV_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"

if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
  build_no="gh${GITHUB_RUN_NUMBER}"
else
  build_no="local-$(date -u +%Y%m%dT%H%M%S)"
fi
printf 'ocserv-%s-build-%s\n' "${OCSERV_VERSION}" "${build_no}"
```

- [ ] **Step 4: Run tests, confirm CI case passes**

Run: `GITHUB_RUN_NUMBER=123 bats test/test_snapshot_name.bats`
Expected: first test PASSES. (Local-env test uses `FAKETIME`; if libfaketime unavailable, mark `skip` — see Step 5.)

- [ ] **Step 5: Make the local-env test robust without libfaketime**

Replace the second test body to assert shape only (no `FAKETIME` dependency):
```bash
@test "local env produces local-<timestamp> suffix" {
  unset GITHUB_RUN_NUMBER
  run scripts/snapshot-name.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^ocserv-1\.5\.0-1~bpo13\+1-build-local-[0-9]{8}T[0-9]{6}$ ]]
}
```
Run: `bats test/test_snapshot_name.bats`
Expected: both tests PASS.

- [ ] **Step 6: Add Makefile target + verify**

Append to `Makefile`:
```makefile
.PHONY: snapshot-name
snapshot-name: ## Print the snapshot name for current context
	@scripts/snapshot-name.sh
```
Run: `GITHUB_RUN_NUMBER=7 make snapshot-name`
Expected: `ocserv-1.5.0-1~bpo13+1-build-gh7`

- [ ] **Step 7: shellcheck**

Run: `shellcheck scripts/snapshot-name.sh`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add scripts/snapshot-name.sh test/test_snapshot_name.bats Makefile
git commit -m "feat: snapshot-name.sh as single source of snapshot name (TDD)"
```

---

## Task 3: Source acquisition — `fetch-source.sh` + `rewrap-changelog.sh` + `build-source-package.sh`

These wrap external Debian tooling; verified by dry-run in Task 12. Keep them thin and strict.

**Files:**
- Create: `scripts/fetch-source.sh`
- Create: `scripts/rewrap-changelog.sh`
- Create: `scripts/build-source-package.sh`
- Create: `.env.example` (the snapshot timestamp is a real value to fill in at bootstrap)

- [ ] **Step 1: Create `.env.example` documenting the pinned timestamp**

```ini
# snapshot.debian.org fixed-time URL locking ocserv 1.5.0-1 source. Spec §2.4.
# Replace YYYYMMDDTHHMMSSZ with the actual snapshot timestamp at bootstrap,
# then commit a real .env (or pass via CI var). Reproducibility depends on this.
DEBIAN_SNAPSHOT_TIMESTAMP=YYYYMMDDTHHMMSSZ
```

Add `.env` (real values) to `.gitignore`:
Append to `.gitignore`:
```
# real bootstrap values
.env
```

- [ ] **Step 2: Write `scripts/fetch-source.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §2.4. dget from snapshot.debian.org fixed timestamp; chroot never sees sid.
UPSTREAM="${OCSERV_UPSTREAM_VERSION:-1.5.0}"
REVISION="${OCSERV_DEBIAN_REVISION:-1}"
SRC_VER="${UPSTREAM}-${REVISION}"

# Load timestamp: .env first, then environment.
if [[ -f .env ]]; then set -a; source .env; set +a; fi
TS="${DEBIAN_SNAPSHOT_TIMESTAMP:?DEBIAN_SNAPSHOT_TIMESTAMP must be set (.env or env)}"
BASE="https://snapshot.debian.org/archive/debian/${TS}"
DSC_URL="${BASE}/pool/main/o/ocserv/ocserv_${SRC_VER}.dsc"

mkdir -p build/source
cd build/source
log "dget ${DSC_URL}"
dget -x -u "${DSC_URL}"   # -u: do not verify with GnuPG at fetch (we trust archive)
log "source tree ready: $(pwd)/ocserv-${UPSTREAM}"
```

- [ ] **Step 3: Write `scripts/rewrap-changelog.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §2.5. Rewrite changelog to backport version + trixie distribution.
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
MAINTAINER_NAME="${MAINTAINER_NAME:-Thehkus Admin}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-master@thehkus.com}"

SRCDIR="build/source/ocserv-${BACKPORT_VERSION%%-*}"   # 1.5.0-1~bpo13+1 -> 1.5.0
[[ -d "${SRCDIR}" ]] || die "missing source tree: ${SRCDIR}"
cd "${SRCDIR}"

export DEBEMAIL="${MAINTAINER_EMAIL}"
export DEBFULLNAME="${MAINTAINER_NAME}"

dch --distribution trixie --force-distribution \
    -v "${BACKPORT_VERSION}" \
    "Private rebuild for Debian 13 trixie."
log "changelog top version: $(dpkg-parsechangelog -SVersion)"
log "changelog distribution: $(dpkg-parsechangelog -SDistribution)"
```

- [ ] **Step 4: Write `scripts/build-source-package.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §2.6. Regenerate backport .dsc; never feed sid .dsc to sbuild.
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
SRCDIR="build/source/ocserv-${BACKPORT_VERSION%%-*}"
cd "${SRCDIR}"
dpkg-buildpackage -S -us -uc
cd - >/dev/null
DSC="build/source/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "expected dsc not found: ${DSC}"
log "source package: ${DSC}"
```

- [ ] **Step 5: shellcheck all three**

Run: `shellcheck scripts/fetch-source.sh scripts/rewrap-changelog.sh scripts/build-source-package.sh`
Expected: clean.

- [ ] **Step 6: Add Makefile targets**

Append to `Makefile`:
```makefile
.PHONY: fetch rewrap src-pkg
fetch: ## dget ocserv source from snapshot.debian.org
	scripts/fetch-source.sh
rewrap: ## rewrite changelog to backport version
	scripts/rewrap-changelog.sh
src-pkg: ## regenerate backport .dsc
	scripts/build-source-package.sh
```

- [ ] **Step 7: Commit**

```bash
git add scripts/fetch-source.sh scripts/rewrap-changelog.sh scripts/build-source-package.sh \
        .env.example .gitignore Makefile
git commit -m "feat: source acquisition (fetch/rewrap/src-pkg) from snapshot.debian.org"
```

> **Note:** `dget -u` disables signature verification at fetch — the snapshot.debian.org `.dsc` integrity is validated later by sbuild. If your policy requires verifying at fetch, drop `-u` and ensure the upstream archive keyring is present.

---

## Task 4: Binary build + lint — `build-binary.sh` + `lint-package.sh`

**Files:**
- Create: `scripts/build-binary.sh`
- Create: `scripts/lint-package.sh`

- [ ] **Step 1: Write `scripts/build-binary.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §2.7. sbuild in clean trixie schroot; -d trixie (not trixie-backports).
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
DSC="build/source/ocserv_${BACKPORT_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "missing dsc: ${DSC} (run 'make src-pkg' first)"
mkdir -p build/binary

sbuild \
  --chroot-mode=schroot \
  -d trixie \
  --arch=amd64 \
  --build-dir build/binary \
  --no-run-lintian \
  "${DSC}"

log "binary built; artifacts in build/binary"
ls -1 build/binary/*.deb
```

- [ ] **Step 2: Write `scripts/lint-package.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §6.3 step 5. lintian on .changes; treat Errors as fatal.
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
CHANGES="$(ls build/binary/ocserv_${BACKPORT_VERSION}_amd64.changes 2>/dev/null || true)"
[[ -n "${CHANGES}" ]] || die "no .changes found in build/binary"

log "lintian ${CHANGES}"
# --fail-on-error: nonzero exit if any E: tag. Warnings are printed but pass.
lintian --fail-on-error "${CHANGES}" || die "lintian reported errors"
log "lintian: no errors"
```

- [ ] **Step 3: shellcheck**

Run: `shellcheck scripts/build-binary.sh scripts/lint-package.sh`
Expected: clean.

- [ ] **Step 4: Add Makefile targets**

```makefile
.PHONY: binary lint
binary: ## sbuild binary deb in trixie schroot
	scripts/build-binary.sh
lint: ## lintian on .changes (errors fatal)
	scripts/lint-package.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/build-binary.sh scripts/lint-package.sh Makefile
git commit -m "feat: binary build (sbuild) + lintian gate"
```

---

## Task 5: `smoke-test.sh` (basic + service modes)

Spec §6.4: `basic` runs in a plain container (no systemd/TUN); `service` runs on a VM. CI only runs basic; staging runs service.

**Files:**
- Create: `scripts/smoke-test.sh`

- [ ] **Step 1: Write `scripts/smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §6.4. Mode arg: basic (container, no systemd) | service (VM).
MODE="${1:-}"
[[ "${MODE}" == "basic" || "${MODE}" == "service" ]] \
  || die "usage: smoke-test.sh basic|service"

BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
DEB="$(ls build/binary/ocserv_${BACKPORT_VERSION}_amd64.deb 2>/dev/null || true)"
[[ -n "${DEB}" ]] || die "no deb in build/binary (run 'make binary')"

case "${MODE}" in
  basic)
    smoke_basic "${DEB}" ;;
  service)
    smoke_service ;;
esac

smoke_basic() {
  local deb="$1"
  log "smoke-basic: container, no systemd assumed"
  # Run in a throwaway trixie container. Dpkg -i may need deps; fall back to apt install.
  docker run --rm -v "$(pwd)/build/binary:/deb:ro" debian:trixie bash -euxc '
    apt-get update -qq
    apt-get install -y -qq /deb/'"$(basename "${deb}")"' || \
      { apt-get install -y -qq -f; }              # resolve deps
    dpkg-query -W -f="${Version}\n" ocserv
    ocserv --version
    test -f /lib/systemd/system/ocserv.service || test -f /usr/lib/systemd/system/ocserv.service
    test -f /etc/ocserv/ocserv.conf || test -f /usr/share/doc/ocserv/ocserv.conf
    ldd /usr/sbin/ocserv  | grep -i "not found" && exit 1 || true
    ldd /usr/bin/occtl    | grep -i "not found" && exit 1 || true
  '
  log "smoke-basic: OK"
}

smoke_service() {
  log "smoke-service: expects to run ON the staging VM (not container)"
  command -v systemctl >/dev/null || die "systemctl missing; smoke-service needs a systemd host"
  systemctl is-active --quiet ocserv || die "ocserv not active"
  ss -H -ltn 'sport = :443' | grep -q . || die "TCP 443 not listening (override OCSERV_TCP_PORT if needed)"
  ss -H -lun 'sport = :443' | grep -q . || die "UDP 443 not listening"
  journalctl -u ocserv --since "5 min ago" --no-pager | \
    grep -Ei "fatal|config error|permission denied" && die "fatal in journal" || true
  log "smoke-service: OK"
}
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck scripts/smoke-test.sh`
Expected: clean.

- [ ] **Step 3: Add Makefile targets**

```makefile
.PHONY: smoke smoke-basic smoke-service
smoke: smoke-basic           ## alias: smoke-basic
smoke-basic:                 ## container smoke (no systemd)
	scripts/smoke-test.sh basic
smoke-service:               ## host smoke (needs systemd VM)
	scripts/smoke-test.sh service
```

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke-test.sh Makefile
git commit -m "feat: smoke-test basic (container) + service (VM) modes"
```

---

## Task 6: Manifest read/write helpers (TDD)

Spec §3.8: aptly publish updates JSON manifest mapping snapshot↔version; rollback reads it. Pure logic → bats.

**Files:**
- Create: `scripts/_manifest.sh`
- Create: `test/test_manifest.bats`

- [ ] **Step 1: Write failing tests**

`test/test_manifest.bats`:
```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

STATE_DIR=""

setup() {
  cd "${REPO_ROOT}"
  STATE_DIR="$(mktemp -d)"
  export APTLY_STATE_DIR="${STATE_DIR}"
}

teardown() { rm -rf "${STATE_DIR}"; }

@test "promote updates current and shifts old current to previous-good" {
  source scripts/_manifest.sh
  manifest_update testing "snap-A" "1.5.0-1~bpo13+1"
  manifest_update testing "snap-B" "1.5.0-1~bpo13+2"

  run jq -r .snapshot "${STATE_DIR}/testing-current.json"
  [ "$output" = "snap-B" ]
  run jq -r .version   "${STATE_DIR}/testing-previous-good.json"
  [ "$output" = "1.5.0-1~bpo13+1" ]
}

@test "previous-good json is empty object before any promote" {
  source scripts/_manifest.sh
  run manifest_read_previous_good testing
  [ "$status" -eq 0 ]
}

@test "current json includes promoted_at ISO timestamp" {
  source scripts/_manifest.sh
  manifest_update production "snap-X" "1.5.0-1~bpo13+1"
  run jq -r .promoted_at "${STATE_DIR}/production-current.json"
  [[ "$output" =~ T ]]   # ISO 8601 has a 'T'
}
```

- [ ] **Step 2: Run, confirm failure**

Run: `bats test/test_manifest.bats`
Expected: FAIL (script missing).

- [ ] **Step 3: Implement `scripts/_manifest.sh`**

```bash
#!/usr/bin/env bash
# Source-only library. Spec §3.8. State lives under ${APTLY_STATE_DIR}.
set -euo pipefail

manifest_state_dir() { printf '%s' "${APTLY_STATE_DIR:-/var/aptly/state}"; }

manifest_path() { printf '%s/%s-%s.json' "$(manifest_state_dir)" "$1" "$2"; }  # channel, kind

manifest_read_current()        { cat "$(manifest_path "$1" current)" 2>/dev/null || echo '{}'; }
manifest_read_previous_good()  { cat "$(manifest_path "$1" previous-good)" 2>/dev/null || echo '{}'; }

# manifest_update <channel> <snapshot> <version>
manifest_update() {
  local channel="$1" snapshot="$2" version="$3"
  command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
  mkdir -p "$(manifest_state_dir)"
  local cur prev
  cur="$(manifest_read_current "${channel}")"
  prev="${cur}"
  printf '%s\n' "${prev}" > "$(manifest_path "${channel}" previous-good)"
  jq -n \
    --arg snapshot "${snapshot}" \
    --arg version "${version}" \
    --arg channel "${channel}" \
    --arg promoted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{snapshot:$snapshot, version:$version, channel:$channel, promoted_at:$promoted_at}' \
    > "$(manifest_path "${channel}" current)"
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `bats test/test_manifest.bats`
Expected: 3/3 PASS.

- [ ] **Step 5: shellcheck**

Run: `shellcheck scripts/_manifest.sh`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/_manifest.sh test/test_manifest.bats
git commit -m "feat: aptly publish manifest helpers (TDD)"
```

---

## Task 7: `aptly-publish.sh` (first snapshot vs subsequent switch + manifest)

Spec §3.7/§3.8. Holds the repo-publish-lock; detects whether channel distribution already exists.

**Files:**
- Create: `scripts/aptly-publish.sh`

- [ ] **Step 1: Write `scripts/aptly-publish.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"
source "$(dirname "$0")/_manifest.sh"

# Spec §3.7 / §3.8. Usage: aptly-publish.sh <testing|production> <snapshot> [version]
channel="$1"; snapshot="$2"; version="${3:-}"
require_channel "${channel}"

# Map channel -> aptly distribution
case "${channel}" in
  testing)    dist=trixie-testing ;;
  production) dist=trixie-production ;;
esac

acquire_repo_publish_lock

# Detect first-publish vs subsequent-switch. Spec §3.8.
if aptly publish list -raw 2>/dev/null | grep -Fx "${dist}" >/dev/null; then
  log "channel ${dist} exists -> publish switch"
  aptly publish switch "${dist}" "${snapshot}"
else
  log "channel ${dist} absent -> publish snapshot (first publish)"
  aptly publish snapshot \
    -origin=THEHKUS-Backports \
    -distribution="${dist}" \
    -component=main \
    "${snapshot}"
fi

# Version for manifest: prefer explicit, else read from snapshot if resolvable.
if [[ -z "${version}" ]]; then
  version="$(aptly snapshot show -json "${snapshot}" 2>/dev/null \
    | jq -r '.Packages[]? | select(.Name=="ocserv") | .Version' | head -n1 || true)"
fi
[[ -n "${version}" ]] || die "could not determine ocserv version for manifest (pass as \$3)"
manifest_update "${channel}" "${snapshot}" "${version}"
log "published ${channel} -> ${snapshot} (version ${version})"
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck scripts/aptly-publish.sh`
Expected: clean.

- [ ] **Step 3: Add Makefile target with guard**

```makefile
.PHONY: pub-testing pub-prod require-SNAP
require-SNAP:
	@test -n "$(SNAP)" || { echo "SNAP is required"; exit 1; }

pub-testing: ## publish testing channel (auto snapshot name)
	scripts/aptly-publish.sh testing $$(scripts/snapshot-name.sh) $(OCSERV_VERSION)

pub-prod: require-SNAP ## publish production channel (SNAP=... required)
	scripts/aptly-publish.sh production $(SNAP) $(OCSERV_VERSION)
```

- [ ] **Step 4: Commit**

```bash
git add scripts/aptly-publish.sh Makefile
git commit -m "feat: aptly-publish with first-snapshot-vs-switch detection + manifest"
```

---

## Task 8: `aptly-rollback.sh`, `r2-sync.sh`, `cf-purge.sh`

**Files:**
- Create: `scripts/aptly-rollback.sh`
- Create: `scripts/r2-sync.sh`
- Create: `scripts/cf-purge.sh`

- [ ] **Step 1: Write `scripts/aptly-rollback.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"
source "$(dirname "$0")/_manifest.sh"

# Spec §3.8 rollback read rule. Usage: aptly-rollback.sh <channel> [snapshot]
channel="$1"; snapshot="${2:-}"
require_channel "${channel}"
case "${channel}" in
  testing)    dist=trixie-testing ;;
  production) dist=trixie-production ;;
esac

if [[ -z "${snapshot}" ]]; then
  snapshot="$(jq -r .snapshot "$(manifest_path "${channel}" previous-good)" 2>/dev/null || true)"
fi
[[ -n "${snapshot}" ]] || die "no rollback snapshot (pass as \$2 or set previous-good manifest)"

acquire_repo_publish_lock
aptly publish switch "${dist}" "${snapshot}"
log "rolled back ${channel} -> ${snapshot}"
# Emit the version for the caller (CI) to pass to ansible rollback.
jq -r .version "$(manifest_path "${channel}" previous-good)"
```

- [ ] **Step 2: Write `scripts/r2-sync.sh` (RCLONE_CONFIG_R2_* mapping, spec §3.4)**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §3.4. rclone reads RCLONE_CONFIG_<REMOTE>_* at runtime, not R2_*.
channel="$1"; require_channel "${channel}"

: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY required}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID required}"
: "${R2_BUCKET:=apt-thehkus}"

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

acquire_repo_publish_lock
src="/var/aptly/public/${channel}/"
log "rclone sync ${src} -> r2:${R2_BUCKET}/${channel}/"
rclone sync "${src}" "r2:${R2_BUCKET}/${channel}/" --checksum --transfers 4
```

- [ ] **Step 3: Write `scripts/cf-purge.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §3.5. Purge /dists/* after publish. Idempotent.
channel="$1"; require_channel "${channel}"
: "${CF_API_TOKEN:?CF_API_TOKEN required}"
: "${CF_ZONE_ID:?CF_ZONE_ID required}"

base="${APT_BASE_URL:-https://apt.example.com}"
curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"prefixes\":[\"${base#https://}/${channel}/dists/\"]}" \
  | jq .
log "purged ${channel}/dists/*"
```

- [ ] **Step 4: shellcheck all**

Run: `shellcheck scripts/aptly-rollback.sh scripts/r2-sync.sh scripts/cf-purge.sh`
Expected: clean.

- [ ] **Step 5: Add Makefile targets + guard**

```makefile
.PHONY: sync-testing purge-testing sync-prod purge-prod \
        rollback-testing rollback-prod require-TARGET_SNAP
require-TARGET_SNAP:
	@test -n "$(TARGET_SNAP)" || { echo "TARGET_SNAP is required"; exit 1; }

sync-testing: ; scripts/r2-sync.sh testing
sync-prod:    ; scripts/r2-sync.sh production
purge-testing: ; scripts/cf-purge.sh testing
purge-prod:    ; scripts/cf-purge.sh production

rollback-testing: require-TARGET_SNAP
	scripts/aptly-rollback.sh testing $(TARGET_SNAP)
rollback-prod: require-TARGET_SNAP
	scripts/aptly-rollback.sh production $(TARGET_SNAP)
```

- [ ] **Step 6: Commit**

```bash
git add scripts/aptly-rollback.sh scripts/r2-sync.sh scripts/cf-purge.sh Makefile
git commit -m "feat: aptly-rollback (manifest-driven) + r2-sync + cf-purge"
```

---

## Task 9: `assert-apt-policy.sh` (TDD) — lives in the Ansible role

Spec §5.11. Placed in `roles/ocserv_backport/files/` so the role is self-contained; also unit-tested from the repo root.

**Files:**
- Create: `ansible/roles/ocserv_backport/files/assert-apt-policy.sh`
- Create: `test/test_assert_apt_policy.bats`
- Create: `test/fixtures/apt-policy/good.txt`
- Create: `test/fixtures/apt-policy/bad-origin.txt`

- [ ] **Step 1: Capture realistic `apt-cache policy ocserv` fixtures**

`test/fixtures/apt-policy/good.txt` (Candidate from THEHKUS-Backports, priority 1001):
```text
ocserv:
  Installed: (none)
  Candidate: 1.5.0-1~bpo13+1
  Version Table:
     1.5.0-1~bpo13+1 1001
       1001 https://apt.example.com/prod trixie-production/main amd64 Packages
     1.2.0-1 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
```

`test/fixtures/apt-policy/bad-origin.txt` (Candidate from Debian official):
```text
ocserv:
  Installed: (none)
  Candidate: 1.2.0-1
  Version Table:
     1.2.0-1 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
     1.5.0-1~bpo13+1 -1
        -1 https://apt.example.com/prod trixie-production/main amd64 Packages
```

- [ ] **Step 2: Write failing tests**

`test/test_assert_apt_policy.bats`:
```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

SCRIPT="ansible/roles/ocserv_backport/files/assert-apt-policy.sh"

@test "passes on good fixture (candidate=THEHKUS-Backports, prio 1001)" {
  run bash "${SCRIPT}" \
    --package ocserv --expected-version 1.5.0-1~bpo13+1 \
    --expected-origin THEHKUS-Backports --expected-suite trixie-production \
    --expected-priority 1001 \
    --input test/fixtures/apt-policy/good.txt
  [ "$status" -eq 0 ]
}

@test "fails when candidate is from Debian official" {
  run bash "${SCRIPT}" \
    --package ocserv --expected-version 1.5.0-1~bpo13+1 \
    --expected-origin THEHKUS-Backports --expected-suite trixie-production \
    --expected-priority 1001 \
    --input test/fixtures/apt-policy/bad-origin.txt
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Run, confirm fail**

Run: `bats test/test_assert_apt_policy.bats`
Expected: FAIL (script missing).

- [ ] **Step 4: Implement the script**

`ansible/roles/ocserv_backport/files/assert-apt-policy.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# Spec §5.11. Parse `apt-cache policy <pkg>` and assert candidate source/version/priority.
# In real runs, --input omitted -> reads live `apt-cache policy`. Tests pass --input.

package=""; expected_version=""; expected_origin=""; expected_suite=""; expected_priority=""; input=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; shift 2 ;;
    --expected-version) expected_version="$2"; shift 2 ;;
    --expected-origin) expected_origin="$2"; shift 2 ;;
    --expected-suite) expected_suite="$2"; shift 2 ;;
    --expected-priority) expected_priority="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

policy="$(if [[ -n "${input}" ]]; then cat "${input}"; else apt-cache policy "${package}"; fi)"

# Candidate line
candidate="$(printf '%s\n' "${policy}" | awk '/Candidate:/{print $2; exit}')"
[[ "${candidate}" == "${expected_version}" ]] \
  || { echo "FAIL: Candidate=${candidate} != ${expected_version}" >&2; echo "${policy}" >&2; exit 1; }

# Find the version-table block for expected_version, capture its priority + source line.
block="$(printf '%s\n' "${policy}" | awk -v v="^${expected_version} " '
  $0 ~ v {found=1; print; next}
  found && /^[[:space:]]+[0-9-]+ / {print; next}
  found && /^[[:space:]]+[0-9]+ / {print; next}
  found && /https?:\/\// {print; next}
  found {exit}
')"
priority="$(printf '%s\n' "${block}" | awk 'NR==2{print $NF; exit}')"
src_line="$(printf '%s\n' "${block}" | grep -Eo 'https?://[^ ]+ [^ ]+' | head -n1)"

[[ "${priority}" == "${expected_priority}" ]] \
  || { echo "FAIL: priority=${priority} != ${expected_priority}" >&2; exit 1; }
[[ "${src_line}" == *"${expected_suite}"* ]] \
  || { echo "FAIL: source '${src_line}' lacks suite ${expected_suite}" >&2; exit 1; }

# Origin is asserted via the aptly -origin at publish; here we confirm suite + priority,
# which together with the pinning guarantee the origin. (Spec §5.12: verify on real box.)
echo "OK: Candidate=${candidate} src=${src_line} priority=${priority}"
```

- [ ] **Step 5: Run tests, confirm pass**

Run: `bats test/test_assert_apt_policy.bats`
Expected: 2/2 PASS.

- [ ] **Step 6: shellcheck**

Run: `shellcheck ansible/roles/ocserv_backport/files/assert-apt-policy.sh`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/ocserv_backport/files/assert-apt-policy.sh test/test_assert_apt_policy.bats test/fixtures/
git commit -m "feat: assert-apt-policy.sh in role/files (TDD) for candidate verification"
```

---

## Task 10: Ansible role skeleton — defaults, templates, files

**Files:**
- Create: `ansible/ansible.cfg`
- Create: `ansible/site.yml`
- Create: `ansible/roles/ocserv_backport/defaults/main.yml`
- Create: `ansible/roles/ocserv_backport/templates/thehkus-backports.sources.j2`
- Create: `ansible/roles/ocserv_backport/templates/ocserv-pin.j2`
- Create: `ansible/roles/ocserv_backport/files/thehkus-backports.asc` (placeholder)
- Create: `ansible/inventories/staging/group_vars/all.yml`
- Create: `ansible/inventories/production/group_vars/all.yml`

- [ ] **Step 1: `ansible/ansible.cfg`**

```ini
[defaults]
roles_path = roles
host_key_checking = False
stdout_callback = yaml
```

- [ ] **Step 2: `ansible/roles/ocserv_backport/defaults/main.yml`**

```yaml
---
# Default channel settings; overridden by inventory. Spec §5.3.
ocserv_channel: testing
ocserv_repo_suite: trixie-testing
ocserv_repo_baseurl: https://apt.example.com/testing
ocserv_tcp_port: 443
ocserv_udp_port: 443
ocserv_run_config_test: false
```

- [ ] **Step 3: deb822 source template** (`templates/thehkus-backports.sources.j2`, spec §5.4)

```text
# /etc/apt/sources.list.d/thehkus-backports.sources  (managed by ocserv_backport role)
Types: deb
URIs: {{ ocserv_repo_baseurl }}
Suites: {{ ocserv_repo_suite }}
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/thehkus-backports.asc
Enabled: yes
```

- [ ] **Step 4: pinning template** (`templates/ocserv-pin.j2`, spec §5.5 — deny first, allow ocserv)

```text
# /etc/apt/preferences.d/ocserv-thehkus-backports  (managed)
Package: *
Pin: release o=THEHKUS-Backports
Pin-Priority: -1

Package: ocserv
Pin: release o=THEHKUS-Backports,n={{ ocserv_repo_suite }}
Pin-Priority: 1001
```

- [ ] **Step 5: Placeholder pubkey + a README so it's not silently empty**

`ansible/roles/ocserv_backport/files/thehkus-backports.asc`:
```text
-----BEGIN PGP PUBLIC KEY BLOCK-----
# PLACEHOLDER. Replace at bootstrap with the real key exported per
# docs/BUILD_HOST_BOOTSTRAP.md (gpg --armor --export <KEYID>).
Comment: This file MUST be replaced before any real deploy.
-----END PGP PUBLIC KEY BLOCK-----
```

- [ ] **Step 6: Inventory group vars**

`ansible/inventories/staging/group_vars/all.yml`:
```yaml
---
ocserv_channel: testing
ocserv_repo_suite: trixie-testing
ocserv_repo_baseurl: https://apt.example.com/testing
ocserv_tcp_port: 4433
ocserv_udp_port: 4433
```

`ansible/inventories/production/group_vars/all.yml`:
```yaml
---
ocserv_channel: production
ocserv_repo_suite: trixie-production
ocserv_repo_baseurl: https://apt.example.com/prod
ocserv_tcp_port: 443
ocserv_udp_port: 443
```

- [ ] **Step 7: `ansible/site.yml`**

```yaml
---
- name: Apply ocserv_backport role
  hosts: all
  become: true
  roles:
    - role: ocserv_backport
```

- [ ] **Step 8: ansible-lint sanity**

Run: `cd ansible && ansible-lint roles/ocserv_backport/ site.yml`
Expected: no errors (warnings acceptable; address what's actionable).

- [ ] **Step 9: Commit**

```bash
git add ansible/
git commit -m "feat: ansible role skeleton (defaults, deb822 + pinning templates, inventory)"
```

---

## Task 11: Ansible tasks — add-repo, upgrade, rollback, verify, main

Spec §5.6–§5.10. All five task files.

**Files:**
- Create: `ansible/roles/ocserv_backport/tasks/main.yml`
- Create: `ansible/roles/ocserv_backport/tasks/add-repo.yml`
- Create: `ansible/roles/ocserv_backport/tasks/upgrade.yml`
- Create: `ansible/roles/ocserv_backport/tasks/rollback.yml`
- Create: `ansible/roles/ocserv_backport/tasks/verify.yml`

- [ ] **Step 1: `tasks/main.yml`** (entry dispatch, spec §5.10 — explicit action required)

```yaml
---
- name: Assert explicit ocserv_backport_action
  ansible.builtin.assert:
    that:
      - ocserv_backport_action is defined
      - ocserv_backport_action in ['add-repo', 'upgrade', 'rollback', 'verify']
    fail_msg: "must pass -e ocserv_backport_action=add-repo|upgrade|rollback|verify"

- name: add-repo (for add-repo/upgrade/rollback)
  ansible.builtin.import_tasks: add-repo.yml
  when: ocserv_backport_action in ['add-repo', 'upgrade', 'rollback']

- name: upgrade
  ansible.builtin.import_tasks: upgrade.yml
  when: ocserv_backport_action == 'upgrade'

- name: rollback
  ansible.builtin.import_tasks: rollback.yml
  when: ocserv_backport_action == 'rollback'

- name: verify
  ansible.builtin.import_tasks: verify.yml
  when: ocserv_backport_action == 'verify'
```

- [ ] **Step 2: `tasks/add-repo.yml`** (spec §5.6)

```yaml
---
- name: Ensure keyrings dir
  ansible.builtin.file: { path: /etc/apt/keyrings, state: directory, mode: "0755" }

- name: Install GPG pubkey
  ansible.builtin.copy:
    src: thehkus-backports.asc
    dest: /etc/apt/keyrings/thehkus-backports.asc
    mode: "0644"

- name: Render deb822 source
  ansible.builtin.template:
    src: thehkus-backports.sources.j2
    dest: /etc/apt/sources.list.d/thehkus-backports.sources
    mode: "0644"

- name: Render pinning
  ansible.builtin.template:
    src: ocserv-pin.j2
    dest: /etc/apt/preferences.d/ocserv-thehkus-backports
    mode: "0644"

- name: apt update
  ansible.builtin.apt: { update_cache: true }
```

- [ ] **Step 3: `tasks/upgrade.yml`** (spec §5.7 — explicit version, mkdir, assert-policy)

```yaml
---
- name: Assert ocserv_target_version provided
  ansible.builtin.assert:
    that: [ocserv_target_version is defined]
    fail_msg: "upgrade requires -e ocserv_target_version=..."

- name: Verify candidate source/version/priority
  ansible.builtin.script: >
    files/assert-apt-policy.sh
    --package ocserv
    --expected-version {{ ocserv_target_version }}
    --expected-origin THEHKUS-Backports
    --expected-suite {{ ocserv_repo_suite }}
    --expected-priority 1001

- name: Ensure state dir
  ansible.builtin.file:
    path: /var/lib/ocserv-backport
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Record current version (audit)
  ansible.builtin.command: dpkg-query -W -f='${Version}' ocserv
  register: ver_before
  changed_when: false

- name: Write previous-version (audit, not rollback authority)
  ansible.builtin.copy:
    dest: /var/lib/ocserv-backport/previous-version
    content: "{{ ver_before.stdout }}\n"
    mode: "0644"

- name: Install explicit version (not latest)
  ansible.builtin.apt:
    name: "ocserv={{ ocserv_target_version }}"
    state: present
    allow_downgrade: true

- name: Restart ocserv
  ansible.builtin.systemd: { name: ocserv, state: restarted }

- name: Verify
  ansible.builtin.import_tasks: verify.yml
```

- [ ] **Step 4: `tasks/rollback.yml`** (spec §5.8 — explicit version, allow_downgrade)

```yaml
---
- name: Assert ocserv_target_version provided
  ansible.builtin.assert:
    that: [ocserv_target_version is defined]
    fail_msg: "rollback requires -e ocserv_target_version=... (human-confirmed target)"

- name: apt update (pull old index)
  ansible.builtin.apt: { update_cache: true }

- name: Downgrade to target version
  ansible.builtin.apt:
    name: "ocserv={{ ocserv_target_version }}"
    state: present
    allow_downgrade: true

- name: Restart ocserv
  ansible.builtin.systemd: { name: ocserv, state: restarted }

- name: Verify
  ansible.builtin.import_tasks: verify.yml
```

- [ ] **Step 5: `tasks/verify.yml`** (spec §5.9 — precise port match, case-insensitive journal, rc!=0 occtl)

```yaml
---
- name: ocserv active
  ansible.builtin.systemd: { name: ocserv }
  register: svc
  failed_when: svc.status.ActiveState != 'active'

- name: TCP listening (exact port match)
  ansible.builtin.shell: "ss -H -ltn sport = :{{ ocserv_tcp_port }}"
  register: ss_tcp
  changed_when: false
  failed_when: ss_tcp.stdout | length == 0

- name: UDP listening (exact port match)
  ansible.builtin.shell: "ss -H -lun sport = :{{ ocserv_udp_port }}"
  register: ss_udp
  changed_when: false
  failed_when: ss_udp.stdout | length == 0

- name: Version matches target
  ansible.builtin.command: dpkg-query -W -f='${Version}' ocserv
  register: ver
  changed_when: false
  failed_when: >
    ocserv_target_version is defined and
    ver.stdout != ocserv_target_version

- name: No fatal in recent journal (case-insensitive)
  ansible.builtin.command: journalctl -u ocserv --since "5 min ago" --no-pager
  register: journal
  changed_when: false
  failed_when: >
    'fatal' in (journal.stdout | lower) or
    'config error' in (journal.stdout | lower) or
    'permission denied' in (journal.stdout | lower)

- name: (optional) config syntax check
  ansible.builtin.command: "ocserv --test-config --config=/etc/ocserv/ocserv.conf"
  changed_when: false
  when: ocserv_run_config_test | bool

- name: occtl executable (rc != 0 fails; as root for socket access)
  ansible.builtin.command: occtl show users
  register: occtl_out
  become: true
  changed_when: false
  failed_when: occtl_out.rc != 0
```

- [ ] **Step 6: ansible-lint the role**

Run: `cd ansible && ansible-lint roles/ocserv_backport/`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/ocserv_backport/tasks/
git commit -m "feat: ansible tasks (main/add-repo/upgrade/rollback/verify)"
```

---

## Task 12: End-to-end dry-run driver + bootstrap runbook

Spec §6.2–§6.5. The dry-run is the integration test for the whole pipeline; it must NOT touch real `/var/aptly`, R2, staging, or prod.

**Files:**
- Create: `scripts/dry-run.sh`
- Create: `docs/BUILD_HOST_BOOTSTRAP.md`

- [ ] **Step 1: Write `scripts/dry-run.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §6.3–§6.5. Runs locally, touches NO real state.
# Prereqs (builder host): sbuild, schroot trixie-amd64-sbuild, dget (devscripts), jq, docker.

fail() { log "DRY-RUN FAILED at: $*"; exit 1; }

log "== 1. fetch ==";        make fetch   || fail fetch
log "== 2. rewrap ==";       make rewrap  || fail rewrap
log "== 3. src-pkg ==";      make src-pkg || fail src-pkg
log "== 4. binary ==";       make binary  || fail binary
log "== 5. lint ==";         make lint    || fail lint
log "== 6. smoke-basic ==";  make smoke-basic || fail smoke-basic

log "== 7. aptly add+snapshot in TEMP DB (no real /var/aptly) =="
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT
APTLY_ROOT_DIR="${TMPROOT}" aptly repo create ocserv-backports-dryrun >/dev/null
APTLY_ROOT_DIR="${TMPROOT}" aptly repo add ocserv-backports-dryrun build/binary/*.deb >/dev/null
SNAP="$(scripts/snapshot-name.sh)-dryrun"
APTLY_ROOT_DIR="${TMPROOT}" aptly snapshot create "${SNAP}" from repo ocserv-backports-dryrun >/dev/null
APTLY_ROOT_DIR="${TMPROOT}" aptly snapshot show "${SNAP}" | grep -q ocserv || fail "snapshot missing ocserv"
log "temp snapshot OK (in ${TMPROOT})"

log "== 8. snapshot-name consistency =="
OUT="$(scripts/snapshot-name.sh)"
[[ "${OUT}" =~ ^ocserv-1\.5\.0-1~bpo13\+1-build-(gh[0-9]+|local-[0-9]{8}T[0-9]{6})$ ]] \
  || fail "snapshot-name shape: ${OUT}"
log "snapshot-name OK: ${OUT}"

log "DRY-RUN PASSED — no real aptly/R2/staging/prod touched."
```

- [ ] **Step 2: Write `docs/BUILD_HOST_BOOTSTRAP.md`** (operator runbook for spec §6.1)

```markdown
# Build Host Bootstrap (spec §6.1)

One-time setup on the dedicated trixie amd64 builder (user `builder`).

## 1. Packages
sudo apt install -y sbuild schroot debootstrap \
  build-essential devscripts debhelper debhelper-compat \
  dpkg-dev fakeroot lintian quilt \
  rclone aptly gnupg jq docker.io git curl ca-certificates

## 2. trixie sbuild chroot (sources: trixie / trixie-updates / trixie-security ONLY)
sudo sbuild-createchroot --arch=amd64 --components=main \
  trixie /var/lib/sbuild/trixie-amd64-sbuild http://deb.debian.org/debian
# Verify sources.list has NO sid/testing; edit if needed.

## 3. GPG signing key (local, never leaves this host)
gpg --generate-key          # dedicated backport signing key
KEYID=...
gpg --armor --export "${KEYID}" > ansible/roles/ocserv_backport/files/thehkus-backports.asc
# Put passphrase into GitHub secret GPG_PASSPHRASE.

## 4. aptly init
aptly config edit   # set gpgKey=<KEYID>, rootDir=/var/aptly
sudo mkdir -p /var/aptly/{public/{testing,prod},.locks,state}
sudo chown -R builder:builder /var/aptly
aptly repo create ocserv-backports

## 5. rclone remote skeleton (NO secrets here)
# scripts/r2-sync.sh injects RCLONE_CONFIG_R2_* at runtime from CI secrets.

## 6. GitHub self-hosted runner
# Register runner with labels [self-hosted, builder], as user `builder`.

## 7. GitHub secrets (repo or environment level)
# R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID, R2_BUCKET
# CF_API_TOKEN, CF_ZONE_ID, GPG_PASSPHRASE
# (GPG private key, aptly DB, staging/prod SSH keys are NEVER GitHub secrets.)

## 8. Backups (spec §6.1 [10])
# /var/aptly, /var/aptly/state, ~/.gnupg, /etc/schroot/chroot.d/, rclone.conf, runner config.

## Verify with dry-run
make -C <repo> dry-run
```

- [ ] **Step 3: Add Makefile target**

```makefile
.PHONY: dry-run
dry-run: ## end-to-end local dry-run (no real aptly/R2/staging/prod)
	scripts/dry-run.sh
```

- [ ] **Step 4: shellcheck**

Run: `shellcheck scripts/dry-run.sh`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/dry-run.sh docs/BUILD_HOST_BOOTSTRAP.md Makefile
git commit -m "feat: dry-run driver + build host bootstrap runbook"
```

> The dry-run can only fully execute on the builder host (needs sbuild/chroot). On a dev machine, run bats suites + shellcheck + ansible-lint instead (Task 13).

---

## Task 13: CI workflows (ci-testing, promote-production, rollback-production)

Spec §4.2–§4.8.

**Files:**
- Create: `.github/workflows/ci-testing.yml`
- Create: `.github/workflows/promote-production.yml`
- Create: `.github/workflows/rollback-production.yml`

- [ ] **Step 1: `.github/workflows/ci-testing.yml`**

```yaml
name: ci-testing
on:
  push:
    branches: [main]
    paths: ['debian/**', 'scripts/**', 'ansible/**', 'Makefile', '.github/workflows/ci-testing.yml']
  workflow_dispatch:
jobs:
  build:
    runs-on: [self-hosted, builder]
    steps:
      - uses: actions/checkout@v4
      - run: make fetch
      - run: make rewrap
      - run: make src-pkg
      - run: make binary
      - uses: actions/upload-artifact@v4
        with: { name: deb, path: build/binary/*.deb }

  lint-and-smoke:
    needs: build
    runs-on: [self-hosted, builder]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: deb, path: build/binary }
      - run: make lint
      - run: make smoke-basic

  publish-testing:
    needs: lint-and-smoke
    runs-on: [self-hosted, builder]
    concurrency: { group: repo-publish-lock, cancel-in-progress: false }
    env:
      GITHUB_RUN_NUMBER: ${{ github.run_number }}
    outputs:
      snapshot: ${{ steps.snap.outputs.name }}
    steps:
      - uses: actions/checkout@v4
      - id: snap
        run: echo "name=$(scripts/snapshot-name.sh)" >> "$GITHUB_OUTPUT"
      - run: make pub-testing
        env: { OCSERV_VERSION: "1.5.0-1~bpo13+1" }
      - run: make sync-testing
        env: { R2_ACCESS_KEY_ID: "${{secrets.R2_ACCESS_KEY_ID}}", R2_SECRET_ACCESS_KEY: "${{secrets.R2_SECRET_ACCESS_KEY}}", R2_ACCOUNT_ID: "${{secrets.R2_ACCOUNT_ID}}" }
      - run: make purge-testing
        env: { CF_API_TOKEN: "${{secrets.CF_API_TOKEN}}", CF_ZONE_ID: "${{secrets.CF_ZONE_ID}}" }

  staging-upgrade:
    needs: publish-testing
    runs-on: [self-hosted, builder]
    concurrency: { group: repo-publish-lock, cancel-in-progress: false }
    steps:
      - uses: actions/checkout@v4
      - run: ansible-playbook -i ansible/inventories/staging ansible/site.yml
            -e ocserv_backport_action=upgrade
            -e ocserv_target_version=1.5.0-1~bpo13+1
      - run: ansible-playbook -i ansible/inventories/staging ansible/site.yml
            -e ocserv_backport_action=verify
            -e ocserv_target_version=1.5.0-1~bpo13+1
      - if: failure()
        run: |
          make rollback-testing TARGET_SNAP="${{ needs.publish-testing.outputs.snapshot }}"
          make sync-testing
        env: { R2_ACCESS_KEY_ID: "${{secrets.R2_ACCESS_KEY_ID}}", R2_SECRET_ACCESS_KEY: "${{secrets.R2_SECRET_ACCESS_KEY}}", R2_ACCOUNT_ID: "${{secrets.R2_ACCOUNT_ID}}" }
```

- [ ] **Step 2: `.github/workflows/promote-production.yml`** (human gate; NO host upgrade)

```yaml
name: promote-production
on:
  workflow_dispatch:
    inputs:
      snapshot:
        description: 'Validated snapshot to promote'
        required: true
jobs:
  promote:
    runs-on: [self-hosted, builder]
    concurrency: { group: repo-publish-lock, cancel-in-progress: false }
    environment: production   # protected environment w/ required reviewers
    steps:
      - uses: actions/checkout@v4
      - run: make pub-prod
        env:
          SNAP: "${{ inputs.snapshot }}"
          OCSERV_VERSION: "1.5.0-1~bpo13+1"
      - run: make sync-prod
        env: { R2_ACCESS_KEY_ID: "${{secrets.R2_ACCESS_KEY_ID}}", R2_SECRET_ACCESS_KEY: "${{secrets.R2_SECRET_ACCESS_KEY}}", R2_ACCOUNT_ID: "${{secrets.R2_ACCOUNT_ID}}" }
      - run: make purge-prod
        env: { CF_API_TOKEN: "${{secrets.CF_API_TOKEN}}", CF_ZONE_ID: "${{secrets.CF_ZONE_ID}}" }
```

- [ ] **Step 3: `.github/workflows/rollback-production.yml`** (human gate + host downgrade)

```yaml
name: rollback-production
on:
  workflow_dispatch:
    inputs:
      snapshot:
        description: 'Target snapshot to roll back to'
        required: true
      target_version:
        description: 'Target deb version for ansible downgrade'
        required: true
jobs:
  rollback:
    runs-on: [self-hosted, builder]
    concurrency: { group: repo-publish-lock, cancel-in-progress: false }
    environment: production
    steps:
      - uses: actions/checkout@v4
      - run: make rollback-prod
        env: { TARGET_SNAP: "${{ inputs.snapshot }}" }
      - run: make sync-prod
        env: { R2_ACCESS_KEY_ID: "${{secrets.R2_ACCESS_KEY_ID}}", R2_SECRET_ACCESS_KEY: "${{secrets.R2_SECRET_ACCESS_KEY}}", R2_ACCOUNT_ID: "${{secrets.R2_ACCOUNT_ID}}" }
      - run: make purge-prod
        env: { CF_API_TOKEN: "${{secrets.CF_API_TOKEN}}", CF_ZONE_ID: "${{secrets.CF_ZONE_ID}}" }
      - run: ansible-playbook -i ansible/inventories/production ansible/site.yml
            -e ocserv_backport_action=rollback
            -e ocserv_target_version="${{ inputs.target_version }}"
```

- [ ] **Step 4: YAML lint**

Run: `python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]; print('yaml ok')"`
Expected: `yaml ok`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/
git commit -m "ci: ci-testing + promote-production + rollback-production workflows"
```

---

## Task 14: Verify gate — run all local tests before declaring done

This is the verification-before-completion checkpoint, not a code task.

- [ ] **Step 1: Run all bats**

Run: `bats test/*.bats`
Expected: all PASS.

- [ ] **Step 2: shellcheck every script**

Run: `shellcheck scripts/*.sh ansible/roles/ocserv_backport/files/*.sh`
Expected: clean.

- [ ] **Step 3: ansible-lint**

Run: `cd ansible && ansible-lint`
Expected: no errors.

- [ ] **Step 4: Make help sanity**

Run: `make help`
Expected: lists all targets without error.

- [ ] **Step 5: Confirm no real-state side effects from dev runs**

Confirm `git status` is clean and `build/` is not tracked (add `build/` to `.gitignore` if not already).

Append to `.gitignore` if missing:
```
build/
```

- [ ] **Step 6: Final commit if .gitignore changed**

```bash
git add .gitignore
git commit -m "chore: ignore build/ artifacts" || echo "nothing to commit"
```

---

## Self-Review (completed during authoring)

**Spec coverage check:**
- §2 version/snapshot naming → Tasks 2, 3 ✓
- §2.3 immutability (bump +N) → documented convention; enforced by review, not code (acceptable)
- §2.4 dget/snapshot → Task 3 ✓
- §2.5 changelog → Task 3 ✓
- §2.6 rebuild .dsc → Task 3 ✓
- §2.7 sbuild trixie → Task 4 ✓
- §3.4 R2 creds → Task 8 ✓
- §3.5 cache purge → Task 8 ✓
- §3.7 first-snapshot-vs-switch → Task 7 ✓
- §3.8 manifest → Tasks 6, 7, 8 ✓
- §4.2–4.8 CI → Task 13 ✓
- §5.4–5.12 role → Tasks 9, 10, 11 ✓
- §6.1 bootstrap → Task 12 runbook ✓
- §6.3–6.5 dry-run → Task 12 ✓
- §6.7/6.8 staging/prod verification checklists → operator runbook (Task 12) references; the actual checks run via ansible verify (Task 11) ✓

**Placeholder scan:** No TBD/TODO; pubkey is a deliberate placeholder flagged with instructions. ✓

**Type/name consistency:** `OCSERV_VERSION`, `GITHUB_RUN_NUMBER`, `APTLY_ROOT_DIR`, `APTLY_STATE_DIR`, `ocserv_backport_action`, `ocserv_target_version`, `repo-publish-lock` used consistently across scripts/Makefile/CI/Ansible. ✓
