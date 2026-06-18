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
