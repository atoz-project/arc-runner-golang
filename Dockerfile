# Custom ARC (actions-runner-controller) runner image with the Go toolchain baked in.
#
# Base: official GitHub Actions runner image, pinned to the latest stable release.
# Check for updates: https://github.com/actions/runner/releases
FROM ghcr.io/actions/actions-runner:2.337.0

ARG GO_VERSION=1.26.2
# SHA256 of https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz (from https://go.dev/dl/?mode=json).
ARG GO_SHA256=990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282
# golangci-lint: pinned to what our CI uses (v1.x while .golangci.yml is v1-schema).
ARG GOLANGCI_LINT_VERSION=1.64.8
ARG SQLC_VERSION=1.31.1
ARG BUF_VERSION=1.72.0
ARG GH_VERSION=2.100.0

USER root

# Toolchain and CI utilities. Keep this list minimal on purpose.
# zstd is required by the falcondev Actions cache server (compression backend).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gcc \
        git \
        jq \
        make \
        zstd \
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

# Cache persistence contract (see README): all Go caches point into
# /home/runner/.cache so a persistent volume mounted there captures the
# module cache, build cache, and GOPATH across runner pods.
ENV GOPATH=/home/runner/.cache/go \
    GOMODCACHE=/home/runner/.cache/go-mod \
    GOCACHE=/home/runner/.cache/go-build

# Go-based CLIs via `go install` with throwaway build caches in /tmp, so no
# root-owned files ever land in /home/runner/.cache (that tree belongs to the
# runner user and, in ARC, to the cache PV).
#
# golangci-lint MUST be goinstall'd, not fetched via the official install
# script: the prebuilt v1.64.8 binaries are compiled with go1.24 and
# hard-refuse go1.26 module targets ("the Go language version (go1.24) used
# to build golangci-lint is lower than the targeted Go version"). Compiling
# it with this image's Go 1.26.2 matches what our CI does today.
RUN export GOBIN=/usr/local/bin GOPATH=/tmp/gopath GOMODCACHE=/tmp/gomodcache GOCACHE=/tmp/gocache \
    && go install "github.com/golangci/golangci-lint/cmd/golangci-lint@v${GOLANGCI_LINT_VERSION}" \
    && go install "github.com/sqlc-dev/sqlc/cmd/sqlc@v${SQLC_VERSION}" \
    && rm -rf /tmp/gopath /tmp/gomodcache /tmp/gocache

# buf (proto codegen) and the GitHub CLI (repo automation scripts).
# gh is verified against the checksums published on the release.
RUN curl -fsSL -o /usr/local/bin/buf "https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/buf-Linux-x86_64" \
    && chmod +x /usr/local/bin/buf \
    && curl -fsSL -o "/tmp/gh_${GH_VERSION}_linux_amd64.tar.gz" "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
        | grep "linux_amd64.tar.gz" | (cd /tmp && sha256sum -c -) \
    && tar -xzf "/tmp/gh_${GH_VERSION}_linux_amd64.tar.gz" -C /tmp \
    && mv "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
    && rm -rf "/tmp/gh_${GH_VERSION}_linux_amd64" "/tmp/gh_${GH_VERSION}_linux_amd64.tar.gz"

# Home for the cache contract below; must be writable by the runner user even
# when no PV is mounted (a PV mount simply shadows this directory).
RUN mkdir -p /home/runner/.cache && chown -R runner:runner /home/runner/.cache

USER runner

# Smoke checks at build time: fail the build if anything doesn't run.
RUN go version \
    && golangci-lint --version \
    && sqlc version \
    && buf --version \
    && gh --version \
    && zstd --version
