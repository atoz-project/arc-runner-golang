# Custom ARC (actions-runner-controller) runner image with the Go toolchain baked in.
#
# Base: official GitHub Actions runner image, pinned to the latest stable release.
# Check for updates: https://github.com/actions/runner/releases
FROM ghcr.io/actions/actions-runner:2.337.0

ARG GO_VERSION=1.26.2
# SHA256 of https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz (from https://go.dev/dl/?mode=json).
ARG GO_SHA256=990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282

USER root

# Toolchain and CI utilities. Keep this list minimal on purpose.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gcc \
        git \
        jq \
        make \
    && rm -rf /var/lib/apt/lists/*

# NO DinD BY DESIGN: this image intentionally ships without a Docker daemon,
# docker CLI, or any container runtime. Our CI is pure Go (build / vet / test /
# lint), which needs no docker socket. Leaving Docker out keeps the runner pod
# unprivileged (no privileged: true, no dind sidecar, smaller attack surface,
# faster scheduling). Build jobs that genuinely need Docker must keep running
# on GitHub-hosted runners instead.

# Pre-install Go into the GitHub "hostedtoolcache" layout:
#   ${RUNNER_TOOL_CACHE}/go/<version>/<arch>/            <- extracted distribution
#   ${RUNNER_TOOL_CACHE}/go/<version>/<arch>.complete    <- empty completion marker
# actions/setup-go (via @actions/tool-cache) only accepts a cached tool when BOTH
# the directory and the sibling "<arch>.complete" marker file exist. With this
# layout in place, setup-go (check-latest: false, the default) finds 1.26.2
# locally and skips the download entirely.
# Ref: https://github.com/actions/toolkit/blob/main/packages/tool-cache/src/tool-cache.ts
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
ENV GO_TOOLCACHE_DIR=${RUNNER_TOOL_CACHE}/go/${GO_VERSION}/x64

RUN curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
    && mkdir -p "${GO_TOOLCACHE_DIR}" \
    && tar -xzf /tmp/go.tgz -C "${GO_TOOLCACHE_DIR}" --strip-components=1 \
    && touch "${GO_TOOLCACHE_DIR}.complete" \
    && rm /tmp/go.tgz \
    && chown -R runner:runner "${RUNNER_TOOL_CACHE}"

# Go on PATH regardless of whether a workflow uses actions/setup-go.
ENV PATH="${GO_TOOLCACHE_DIR}/bin:${PATH}"

USER runner

# Smoke check at build time: fail the build if Go does not run from this image.
RUN go version
