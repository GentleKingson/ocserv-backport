# ocserv-backport — local==CI entrypoint. Spec §4.5.
SHELL := /bin/bash
.DEFAULT_GOAL := help
OCSERV_VERSION := 1.5.0-1~bpo13+1

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*##/:/' | column -t -s:

.PHONY: test
test: ## run bats test suite
	bats test/

.PHONY: snapshot-name
snapshot-name: ## Print the snapshot name for current context
	@scripts/snapshot-name.sh

.PHONY: fetch rewrap src-pkg
fetch: ## fetch ocserv source per FETCH_SOURCE (pool|cache), locked by source-lock/
	scripts/fetch-source.sh
rewrap: ## rewrite changelog to backport version
	scripts/rewrap-changelog.sh
src-pkg: ## regenerate backport .dsc
	scripts/build-source-package.sh

.PHONY: binary lint
binary: ## sbuild binary deb in trixie schroot
	scripts/build-binary.sh
lint: ## lintian on .changes (errors fatal)
	scripts/lint-package.sh

.PHONY: smoke smoke-basic smoke-service
smoke: smoke-basic           ## alias: smoke-basic
smoke-basic:                 ## container smoke (no systemd)
	scripts/smoke-test.sh basic
smoke-service:               ## host smoke (needs systemd VM)
	scripts/smoke-test.sh service

.PHONY: pub-testing pub-prod require-SNAP
require-SNAP:
	@test -n "$(SNAP)" || { echo "SNAP is required"; exit 1; }

pub-testing: ## publish testing channel (auto snapshot name)
	scripts/aptly-publish.sh testing $$(scripts/snapshot-name.sh) $(OCSERV_VERSION)

pub-prod: require-SNAP ## publish production channel (SNAP=... required)
	scripts/aptly-publish.sh production $(SNAP) $(OCSERV_VERSION)

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
rollback-testing-auto: ## rollback testing using previous-good manifest (CI auto)
	scripts/aptly-rollback.sh testing
rollback-prod-auto: ## rollback production using previous-good manifest
	scripts/aptly-rollback.sh production

.PHONY: dry-run
dry-run: ## end-to-end local dry-run (no real aptly/R2/staging/prod)
	scripts/dry-run.sh

.PHONY: bootstrap-build-host
bootstrap-build-host: ## Bootstrap the trixie build host (run ON the builder)
	scripts/bootstrap-build-host.sh $(ARGS)

.PHONY: runner-image runner-provision
RUNNER_TARBALL_URL ?=
RUNNER_TARBALL_SHA256 ?=
TRIXIE_DIGEST ?=
REGISTRY ?= ghcr.io/gentlekingson

runner-image: ## Build + push ephemeral ci-build runner image; print manifest digest
	@test -n "$(RUNNER_TARBALL_URL)" -a -n "$(RUNNER_TARBALL_SHA256)" || { echo "set RUNNER_TARBALL_URL + RUNNER_TARBALL_SHA256"; exit 1; }
	@echo "$(RUNNER_TARBALL_SHA256)" | grep -qE '^[0-9a-f]{64}$$' || { echo "RUNNER_TARBALL_SHA256 must be 64 lowercase hex"; exit 1; }
	@test -n "$(TRIXIE_DIGEST)" || { echo "set TRIXIE_DIGEST=docker.io/library/debian@sha256:<64hex>"; exit 1; }
	@echo "$(TRIXIE_DIGEST)" | grep -q '@sha256:[0-9a-f]\{64\}$$' || { echo "TRIXIE_DIGEST must be a digest"; exit 1; }
	DOCKER_BUILDKIT=1 docker buildx build -f docker/runner/Dockerfile \
	  --build-arg TRIXIE_DIGEST="$(TRIXIE_DIGEST)" \
	  --build-arg RUNNER_TARBALL_URL="$(RUNNER_TARBALL_URL)" \
	  --build-arg RUNNER_TARBALL_SHA256="$(RUNNER_TARBALL_SHA256)" \
	  -t $(REGISTRY)/ocserv-ci-runner:phase1 --push docker/runner/
	@echo "=== manifest digest -> RUNNER_IMAGE: ==="
	@docker buildx imagetools inspect $(REGISTRY)/ocserv-ci-runner:phase1 --format '{{.Manifest.Digest}}' | sed 's|^|$(REGISTRY)/ocserv-ci-runner@|'

runner-provision: ## Dry-run the provisioner (token from stdin; never executes docker run)
	@echo "Dry-run: scripts/runner-provisioner.sh --dry-run < /dev/null"
