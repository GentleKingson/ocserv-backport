SHELL := /bin/bash
.DEFAULT_GOAL := help
# Package version defaults live in scripts/_versions.sh; override them from
# the environment or the make command line.
export OCSERV_VERSION OCSERV_DEBIAN_VERSION OCSERV_NOBLE_VERSION
TARGET_DISTRIBUTION ?= noble
export TARGET_DISTRIBUTION TARGET_ARCH

.PHONY: help
help: ## Show supported targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*##/:/' | column -t -s:

.PHONY: test
test: ## Run Bats test suite
	bats test/

.PHONY: ci-script-test
ci-script-test: ## Run stubbed Trixie build-entrypoint orchestration tests
	bats test/test_trixie_build_entrypoint.bats test/test_trixie_source_ci.bats

.PHONY: trixie-verify-locks
trixie-verify-locks: ## Verify source-lock YAML files match generated TSV projections
	scripts/verify-source-lock.sh

.PHONY: trixie-fetch-ocserv trixie-rewrap-ocserv trixie-src-pkg-ocserv
trixie-fetch-ocserv: ## Fetch locked ocserv source from Debian pool
	scripts/trixie-fetch-source.sh

trixie-rewrap-ocserv: ## Rewrite ocserv changelog to the Trixie backport version
	scripts/trixie-rewrap-changelog.sh

trixie-src-pkg-ocserv: ## Build the ocserv Trixie source package
	scripts/trixie-build-source-package.sh

.PHONY: trixie-binary-ocserv trixie-lint
trixie-binary-ocserv: ## Build target-architecture ocserv binary package with sbuild in trixie
	scripts/trixie-build-binary-ocserv.sh

trixie-lint: ## Run lintian on the generated Trixie ocserv .changes
	scripts/trixie-lint-package.sh

.PHONY: trixie-smoke-basic
trixie-smoke-basic: ## Install and inspect the local Trixie ocserv .deb in a trixie container
	scripts/trixie-smoke-test.sh

.PHONY: trixie-build
trixie-build: ## Run the full Debian Trixie local backport validation pipeline
	scripts/trixie-build.sh

.PHONY: trixie-auto-build
trixie-auto-build: ## Run the Debian Trixie host auto-build pipeline
	scripts/trixie-auto-build.sh

.PHONY: trixie-source-ci
trixie-source-ci: ## Run the real Debian Trixie source-package CI pipeline
	scripts/trixie-source-package-ci.sh

.PHONY: noble-build
noble-build: ## Run the Ubuntu 24.04 Noble local backport pipeline
	scripts/noble-build.sh

.PHONY: noble-source-ci
noble-source-ci: ## Run the real Ubuntu Noble source-package CI pipeline
	scripts/noble-source-package-ci.sh

.PHONY: noble-auto-build
noble-auto-build: ## Run the Ubuntu 24.04 Noble host auto-build pipeline
	scripts/noble-auto-build.sh

.PHONY: noble-verify-locks
noble-verify-locks: ## Verify ocserv source locks
	scripts/verify-source-lock.sh

.PHONY: noble-fetch-ocserv
noble-fetch-ocserv: ## Fetch locked Debian ocserv source for Noble
	scripts/noble-fetch-source.sh ocserv

.PHONY: noble-rewrap-ocserv
noble-rewrap-ocserv: ## Rewrite ocserv changelog to the Noble backport version
	scripts/noble-rewrap-changelog.sh ocserv

.PHONY: noble-src-pkg-ocserv
noble-src-pkg-ocserv: ## Build ocserv Noble source package
	scripts/noble-build-source-package.sh ocserv

.PHONY: noble-binary-ocserv
noble-binary-ocserv: ## Build ocserv Noble binary package (bundled llhttp) with sbuild
	scripts/noble-build-binary-ocserv.sh

.PHONY: noble-lint
noble-lint: ## Run lintian on the generated Noble ocserv .changes
	scripts/noble-lint-package.sh

.PHONY: noble-smoke-basic
noble-smoke-basic: ## Install and inspect the local Noble ocserv .deb in a noble container
	scripts/noble-smoke-test.sh

.PHONY: install-test install-e2e
install-test: ## Run install.sh unit tests
	bats test/test_install.bats

INSTALL_E2E_IMAGE ?= debian:trixie
install-e2e: ## Run install.sh in a systemd container (INSTALL_E2E_IMAGE=debian:trixie|ubuntu:24.04)
	scripts/install-e2e-test.sh $(INSTALL_E2E_IMAGE)
