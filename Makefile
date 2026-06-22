SHELL := /bin/bash
.DEFAULT_GOAL := help
OCSERV_VERSION := 1.5.0-1~bpo13+1

.PHONY: help
help: ## Show supported targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*##/:/' | column -t -s:

.PHONY: test
test: ## Run Bats test suite
	bats test/

.PHONY: verify-lock
verify-lock: ## Verify source-lock YAML files match generated TSV projections
	scripts/verify-source-lock.sh

.PHONY: fetch rewrap src-pkg
fetch: verify-lock ## Fetch locked ocserv source from Debian pool
	scripts/fetch-source.sh

rewrap: ## Rewrite changelog to the trixie backport version
	scripts/rewrap-changelog.sh

src-pkg: ## Build the backport source package
	scripts/build-source-package.sh

.PHONY: binary lint
binary: ## Build amd64 binary package with sbuild in trixie
	scripts/build-binary.sh

lint: ## Run lintian on the generated .changes
	scripts/lint-package.sh

.PHONY: smoke-basic
smoke-basic: ## Install and inspect the local .deb in a trixie container
	scripts/smoke-test.sh

.PHONY: dry-run
dry-run: ## Run the full local backport validation pipeline
	scripts/dry-run.sh
