# Phase 1 ci-build runner image. Non-root (10001:10001); read-only rootfs at runtime.
# libicu76: Actions Runner (.NET) ICU dep on trixie (config.sh fails without it).
# curl: runbook integration test. iproute2: IPv6-absence runtime check.
# util-linux: findmnt in entrypoint. No runtime pip (python3-yaml baked).
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1, §2.3.

# Base image has NO default tag — the Makefile MUST pass
# TRIXIE_DIGEST=docker.io/library/debian@sha256:<64hex>.
ARG TRIXIE_DIGEST
FROM "${TRIXIE_DIGEST}" AS base

RUN groupadd --system --gid 10001 runner \
 && useradd  --system --uid 10001 --gid 10001 --no-create-home --home-dir /runner runner

# lock-projection deps as Debian packages — NO pip, NO PyPI at runtime.
# python3-yaml provides PyYAML (read-source-lock.py imports yaml).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      make \
      python3 \
      python3-yaml \
      util-linux \
      libicu76 \
      curl \
      iproute2 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# actions-runner payload pinned by SHA-256 checksum via ADD --checksum=.
# RUNNER_TARBALL_URL + RUNNER_TARBALL_SHA256 are required build ARGs (no default —
# forces explicit pinning per build; see Makefile runner-image target).
ARG RUNNER_TARBALL_URL
ARG RUNNER_TARBALL_SHA256
ADD --checksum=sha256:${RUNNER_TARBALL_SHA256} "${RUNNER_TARBALL_URL}" /opt/actions-runner.tar.gz
RUN mkdir -p /opt/actions-runner-src \
 && tar -xzf /opt/actions-runner.tar.gz -C /opt/actions-runner-src \
 && rm -f /opt/actions-runner.tar.gz

COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod 0555 /opt/entrypoint.sh /opt/actions-runner-src

USER 10001:10001
ENTRYPOINT ["/opt/entrypoint.sh"]
