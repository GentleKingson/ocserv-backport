# ocserv-backport

Reproducible build, validation, and CI publishing pipeline that backports
ocserv (the OpenConnect VPN server) from Debian sid source to Debian trixie as
`1.5.0-1~bpo13+1`. The local entry point is `make dry-run`; CI owns testing
publish, production promotion, and rollback. Local and CI share the same core
build-validation stages.

## Pipeline

```text
fetch → rewrap → src-pkg → binary (sbuild) → lint → smoke-basic → temporary aptly snapshot → snapshot-name check
```

Each stage has a corresponding Make target. CI reuses the same core build-validation stages before publishing the testing channel.

Source identity is locked by `source-lock/<name>/<version>.yaml` (the Git-tracked authority) and its CI-verified `.lock.tsv` projection; `fetch` honors `FETCH_SOURCE=pool` (default; `deb.debian.org` pool) or `FETCH_SOURCE=cache` (verified local `build/source-cache/`). See the runbook's source-acquisition section for the prefetch/import workflow used to populate the cache from `snapshot.debian.org`.

## Quick start

```bash
make dry-run   # validates the core CI build path locally; touches no real state
```

`make dry-run` validates the pipeline with a temporary aptly root and does not touch R2, staging, production, or the real aptly database.

## Publishing & rollback (CI-driven)

- `.github/workflows/ci-testing.yml` — build, lint, smoke, publish testing channel
- `.github/workflows/promote-production.yml` — promote a validated snapshot (protected `production` environment)
- `.github/workflows/rollback-production.yml` — rollback production to a previous-good snapshot

## Build host setup

From a bare Debian trixie amd64 machine to `make dry-run` passing, follow the
linear handoff in [`docs/trixie-builder-dryrun-runbook.md`](docs/trixie-builder-dryrun-runbook.md).
Bootstrap script quick-reference: [`docs/BUILD_HOST_BOOTSTRAP.md`](docs/BUILD_HOST_BOOTSTRAP.md).

## Repo layout

| Path | Purpose |
|---|---|
| `scripts/` | Build, bootstrap, packaging, and validation scripts |
| `Makefile` | Local build targets; run `make help` |
| `ansible/` | Repository installation, upgrade, verification, and rollback automation |
| `.github/workflows/` | Testing publish, production promotion, and rollback workflows |
| `docs/` | Build-host runbook and operational references |
