SHELL := /bin/bash
.DEFAULT_GOAL := help
OCSERV_VERSION ?= 1.5.0-1~bpo13+0local1
export OCSERV_VERSION

.PHONY: help
help: ## Show supported targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*##/:/' | column -t -s:

.PHONY: test
test: ## Run Bats test suite
	bats test/

.PHONY: ci-script-test
ci-script-test: ## Run stubbed build-entrypoint orchestration tests
	bats test/test_build_entrypoint.bats test/test_source_ci.bats

.PHONY: verify-lock
verify-lock: ## Verify source-lock YAML files match generated TSV projections
	scripts/verify-source-lock.sh

.PHONY: fetch rewrap src-pkg
fetch: ## Fetch locked ocserv source from Debian pool
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

.PHONY: build
build: ## Run the full local backport validation pipeline
	scripts/build.sh

.PHONY: source-ci
source-ci: ## Run the real source-package CI pipeline
	scripts/source-package-ci.sh

.PHONY: dry-run
dry-run: ## Compatibility alias for the full local build pipeline
	scripts/dry-run.sh
