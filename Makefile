SHELL := /bin/bash
.DEFAULT_GOAL := help
# Package version defaults live in scripts/_versions.sh; override them from
# the environment or the make command line.
export OCSERV_VERSION OCSERV_DEBIAN_VERSION OCSERV_NOBLE_VERSION OCSERV_RESOLUTE_VERSION
TARGET_DISTRIBUTION ?= noble
export TARGET_DISTRIBUTION TARGET_ARCH

.PHONY: help
help: ## Show supported targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sed 's/:.*##/:/' | column -t -s:

.PHONY: test
test: ## Run Bats test suite
	bats test/

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

.PHONY: noble-build noble-source-ci noble-auto-build noble-verify-locks
.PHONY: noble-fetch-ocserv noble-rewrap-ocserv noble-src-pkg-ocserv
.PHONY: noble-binary-ocserv noble-lint noble-smoke-basic
noble-build: ## Run the Ubuntu 24.04 Noble local backport pipeline
	TARGET_SUITE=noble scripts/ubuntu-build.sh

noble-source-ci: ## Run the real Ubuntu Noble source-package CI pipeline
	TARGET_SUITE=noble scripts/ubuntu-source-package-ci.sh

noble-auto-build: ## Run the Ubuntu 24.04 Noble host auto-build pipeline
	scripts/noble-auto-build.sh

noble-verify-locks: ## Verify ocserv source locks
	scripts/verify-source-lock.sh

noble-fetch-ocserv: ## Fetch locked Debian ocserv source for Noble
	TARGET_SUITE=noble scripts/ubuntu-fetch-source.sh ocserv

noble-rewrap-ocserv: ## Rewrite ocserv changelog to the Noble backport version
	TARGET_SUITE=noble scripts/ubuntu-rewrap-changelog.sh ocserv

noble-src-pkg-ocserv: ## Build ocserv Noble source package
	TARGET_SUITE=noble scripts/ubuntu-build-source-package.sh ocserv

noble-binary-ocserv: ## Build ocserv Noble binary package (bundled llhttp) with sbuild
	TARGET_SUITE=noble scripts/ubuntu-build-binary-ocserv.sh

noble-lint: ## Run lintian on the generated Noble ocserv .changes
	TARGET_SUITE=noble scripts/ubuntu-lint-package.sh

noble-smoke-basic: ## Install and inspect the local Noble ocserv .deb in a noble container
	TARGET_SUITE=noble scripts/ubuntu-smoke-test.sh

.PHONY: resolute-build resolute-source-ci resolute-auto-build resolute-verify-locks
.PHONY: resolute-fetch-ocserv resolute-rewrap-ocserv resolute-src-pkg-ocserv
.PHONY: resolute-binary-ocserv resolute-lint resolute-smoke-basic
resolute-build: ## Run the Ubuntu 26.04 Resolute local backport pipeline
	TARGET_SUITE=resolute scripts/ubuntu-build.sh

resolute-source-ci: ## Run the real Ubuntu Resolute source-package CI pipeline
	TARGET_SUITE=resolute scripts/ubuntu-source-package-ci.sh

resolute-auto-build: ## Run the Ubuntu 26.04 Resolute host auto-build pipeline
	scripts/resolute-auto-build.sh

resolute-verify-locks: ## Verify ocserv source locks
	scripts/verify-source-lock.sh

resolute-fetch-ocserv: ## Fetch locked Debian ocserv source for Resolute
	TARGET_SUITE=resolute scripts/ubuntu-fetch-source.sh ocserv

resolute-rewrap-ocserv: ## Rewrite ocserv changelog to the Resolute backport version
	TARGET_SUITE=resolute scripts/ubuntu-rewrap-changelog.sh ocserv

resolute-src-pkg-ocserv: ## Build ocserv Resolute source package
	TARGET_SUITE=resolute scripts/ubuntu-build-source-package.sh ocserv

resolute-binary-ocserv: ## Build ocserv Resolute binary package with sbuild
	TARGET_SUITE=resolute scripts/ubuntu-build-binary-ocserv.sh

resolute-lint: ## Run lintian on the generated Resolute ocserv .changes
	TARGET_SUITE=resolute scripts/ubuntu-lint-package.sh

resolute-smoke-basic: ## Install and inspect the local Resolute ocserv .deb in a resolute container
	TARGET_SUITE=resolute scripts/ubuntu-smoke-test.sh

.PHONY: install-test install-e2e
install-test: ## Run install.sh unit tests
	bats test/test_install.bats

INSTALL_E2E_IMAGE ?= debian:trixie
install-e2e: ## Run install.sh in a systemd container (INSTALL_E2E_IMAGE=debian:trixie|ubuntu:24.04|ubuntu:26.04)
	scripts/install-e2e-test.sh $(INSTALL_E2E_IMAGE)
