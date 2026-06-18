# ocserv-backport — local==CI entrypoint. Spec §4.5.
SHELL := /bin/bash
.DEFAULT_GOAL := help
OCSERV_VERSION := 1.5.0-1~bpo13+1

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*##/:/' | column -t -s:

.PHONY: snapshot-name
snapshot-name: ## Print the snapshot name for current context
	@scripts/snapshot-name.sh

.PHONY: fetch rewrap src-pkg
fetch: ## dget ocserv source from snapshot.debian.org
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

.PHONY: dry-run
dry-run: ## end-to-end local dry-run (no real aptly/R2/staging/prod)
	scripts/dry-run.sh
