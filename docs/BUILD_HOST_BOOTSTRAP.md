# Build Host Bootstrap

> 完整的从裸机到 dry-run 的线性操作手册见 `docs/trixie-builder-dryrun-runbook.md`。
> 本文档是 bootstrap 脚本的快速参考。

The builder is initialized by `scripts/bootstrap-build-host.sh` (run ON the
trixie amd64 builder, as `BOOTSTRAP_BUILDER_USER` with passwordless sudo).

## First-time setup
1. `cp .bootstrap.env.example .bootstrap.env && chmod 600 .bootstrap.env`
2. Edit `.bootstrap.env` (GPG keyid, R2 account id, urls as needed).
3. Choose a GPG mode:
   - New signing key:    `scripts/bootstrap-build-host.sh --generate-gpg-key`
   - Import existing:    `scripts/bootstrap-build-host.sh --import-gpg-key /path/to/private.asc`
                         (set `BOOTSTRAP_GPG_KEYID` in `.bootstrap.env`)
   - Reuse in keyring:   `scripts/bootstrap-build-host.sh --reuse-gpg-key <FINGERPRINT>`
4. Dry-run first:        `scripts/bootstrap-build-host.sh --dry-run --generate-gpg-key`
5. Run for real:         `scripts/bootstrap-build-host.sh --generate-gpg-key`

The script prints the manual GitHub steps (runner registration + secrets) at the end.

## Drift check (re-run safely)
`scripts/bootstrap-build-host.sh --only-stage install_packages` etc. Safe-repeat
stages are idempotent; GPG/runner are fail/info on existing state (never auto-replaced).

## Spec
See `docs/superpowers/specs/2026-06-19-bootstrap-build-host-design.md` (v2).
