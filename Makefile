SHELL := /bin/bash
.DEFAULT_GOAL := help
OCSERV_VERSION ?= 1.5.0-1~bpo13+0local1
export OCSERV_VERSION
NODE_UNDICI_DEBIAN_VERSION ?= 7.3.0+dfsg1+~cs24.12.11-1
NODE_UNDICI_NOBLE_VERSION ?= 7.3.0+dfsg1+~cs24.12.11-1~ubuntu24.04.1
OCSERV_DEBIAN_VERSION ?= 1.5.0-1
OCSERV_NOBLE_VERSION ?= 1.5.0-1~ubuntu24.04.1
TARGET_DISTRIBUTION ?= noble
TARGET_ARCH ?= amd64
export NODE_UNDICI_DEBIAN_VERSION NODE_UNDICI_NOBLE_VERSION
export OCSERV_DEBIAN_VERSION OCSERV_NOBLE_VERSION
export TARGET_DISTRIBUTION TARGET_ARCH

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

.PHONY: noble-build
noble-build: ## Run the Ubuntu 24.04 Noble two-stage local backport pipeline
	scripts/noble-build.sh

.PHONY: noble-verify-locks
noble-verify-locks: ## Verify ocserv and node-undici source locks
	scripts/verify-source-lock.sh

.PHONY: noble-fetch-node-undici noble-fetch-ocserv
noble-fetch-node-undici: ## Fetch locked Debian node-undici source for Noble
	scripts/noble-fetch-source.sh node-undici

noble-fetch-ocserv: ## Fetch locked Debian ocserv source for Noble
	scripts/noble-fetch-source.sh ocserv

.PHONY: noble-rewrap-node-undici noble-rewrap-ocserv
noble-rewrap-node-undici: ## Rewrite node-undici changelog to the Noble backport version
	scripts/noble-rewrap-changelog.sh node-undici

noble-rewrap-ocserv: ## Rewrite ocserv changelog to the Noble backport version
	scripts/noble-rewrap-changelog.sh ocserv

.PHONY: noble-src-pkg-node-undici noble-src-pkg-ocserv
noble-src-pkg-node-undici: ## Build node-undici Noble source package
	scripts/noble-build-source-package.sh node-undici

noble-src-pkg-ocserv: ## Build ocserv Noble source package
	scripts/noble-build-source-package.sh ocserv

.PHONY: noble-binary-node-undici noble-binary-ocserv
noble-binary-node-undici: ## Build node-undici Noble binary packages with sbuild
	scripts/noble-build-binary-node-undici.sh

noble-binary-ocserv: ## Build ocserv Noble binary package with local libllhttp repo
	scripts/noble-build-binary-ocserv.sh

.PHONY: noble-repo
noble-repo: ## Generate local libllhttp APT repo for the Noble ocserv build
	scripts/noble-build-repo.sh

.PHONY: noble-lint
noble-lint: ## Run lintian on the generated Noble ocserv .changes
	scripts/noble-lint-package.sh

.PHONY: noble-smoke-basic
noble-smoke-basic: ## Install and inspect Noble ocserv with local libllhttp repo
	scripts/noble-smoke-test.sh
