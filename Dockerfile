# Custom ARC (actions-runner-controller) runner image for Go CI: CGO toolchain,
# pinned CLI tools, and the org's Go lines pre-baked as a download-avoidance
# cache. Version SELECTION is delegated to actions/setup-go in each workflow
# (see README "Using this image").
#
# Base: official GitHub Actions runner image, pinned to the latest stable release.
# Check for updates: https://github.com/actions/runner/releases
FROM ghcr.io/actions/actions-runner:2.337.0

# GO_VERSIONS: space-separated patch versions baked into the hostedtoolcache.
# The baked lines are a CACHE, not a boundary — setup-go still resolves and
# downloads any version a workflow asks for; a baked line just makes that
# resolution a zero-download local hit. The LAST version in the list is the
# PATH default (keep the ENV PATH below in sync). SHA256s from
# https://go.dev/dl/?mode=json&include=all — one GO_SHA256_<x_y_z> per entry.
ARG GO_VERSIONS="1.25.14 1.26.8"
ARG GO_SHA256_1_25_14=a21ae5633a269bcd7e90cf767e48225633795e99d831742cbf3397064fee7712
ARG GO_SHA256_1_26_8=d0f743b33e8d8945e6b1f432edd15785c70507121d6e2a723b21285eddf8b57b
# golangci-lint: pinned to what our CI uses (v1.x while .golangci.yml is v1-schema).
ARG GOLANGCI_LINT_VERSION=1.64.8
ARG SQLC_VERSION=1.31.1
# sqlc publishes no checksums; this value was computed from the release tarball
# (trust-on-first-use). A re-uploaded/tampered artifact fails the build loudly.
ARG SQLC_SHA256=497ae4fcdfa64c5b0c311ffe4c2bd991e43991e82e5367792ed78bc2dca27354
ARG BUF_VERSION=1.72.0
ARG GH_VERSION=2.100.0
# protoc plugins are `go install`ed below; versions match what the org repos pin.
ARG PROTOC_GEN_GO_VERSION=v1.36.10
ARG PROTOC_GEN_CONNECT_GO_VERSION=v1.19.1
# From https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/sha256.txt
ARG BUF_SHA256=8720830e26a733da55bb89bcd3cb44849c0965fc0c44fb5d691cccdc64dca5af
# goreleaser: 5 org repos share the goreleaser-action "~> v2" release convention
# (issue #2). From the release's checksums.txt.
ARG GORELEASER_VERSION=2.18.1
ARG GORELEASER_SHA256=0c6122af0ad8fd65638889bf7d3757148b2f80eeff9f079682f0655df66ec8e8

USER root

# Toolchain and CI utilities. Keep this list minimal on purpose.
# gcc + libc6-dev: the CGO toolchain (mattn/go-sqlite3). Both are required —
# gcc without libc6-dev can't compile, and WITHOUT gcc Go silently defaults
# CGO_ENABLED=0, which compiles cgo packages as stubs (the 2026-09-10 cellar
# incident). zstd: cache compression. musl-tools: static linking targets.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libc6-dev \
        gcc \
        git \
        jq \
        make \
        musl-tools \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# NO DinD BY DESIGN: this image intentionally ships without a Docker daemon or
# any container runtime. (The base image does include the docker CLI binary,
# which the Actions runner needs for container actions; with no daemon and no
# socket it is inert.) Our CI is pure Go (build / vet / test / lint), which
# needs no docker socket. Leaving the daemon out keeps the runner pod
# unprivileged (no privileged: true, no dind sidecar, smaller attack surface,
# faster scheduling). Build jobs that genuinely need Docker must keep running
# on GitHub-hosted runners instead.

# Pre-install each GO_VERSIONS entry into the GitHub "hostedtoolcache" layout:
#   ${RUNNER_TOOL_CACHE}/go/<version>/<arch>/            <- extracted distribution
#   ${RUNNER_TOOL_CACHE}/go/<version>/<arch>.complete    <- empty completion marker
# actions/setup-go (via @actions/tool-cache) only accepts a cached tool when BOTH
# the directory and the sibling "<arch>.complete" marker file exist. With this
# layout in place, setup-go (check-latest: false, the default) finds the baked
# line locally and skips the download entirely; any other version falls through
# to a normal download, so nothing breaks when the image lags a release.
# Ref: https://github.com/actions/toolkit/blob/main/packages/tool-cache/src/tool-cache.ts
# bash needed for ${!var} indirect expansion and ${v//./_} substitution.
SHELL ["/bin/bash", "-c"]
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache

RUN set -e; for v in ${GO_VERSIONS}; do \
        var="GO_SHA256_${v//./_}"; sum="${!var}"; \
        [ -n "${sum}" ] || { echo "missing GO_SHA256 for go${v}"; exit 1; }; \
        curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${v}.linux-amd64.tar.gz"; \
        echo "${sum}  /tmp/go.tgz" | sha256sum -c -; \
        dir="${RUNNER_TOOL_CACHE}/go/${v}/x64"; \
        mkdir -p "${dir}"; \
        tar -xzf /tmp/go.tgz -C "${dir}" --strip-components=1; \
        touch "${dir}.complete"; \
    done; \
    rm -f /tmp/go.tgz; \
    chown -R runner:runner "${RUNNER_TOOL_CACHE}"

# Newest baked line on PATH (keep in sync with the last GO_VERSIONS entry) so
# plain `go` works for workflows that don't use actions/setup-go.
ENV PATH="${RUNNER_TOOL_CACHE}/go/1.26.8/x64/bin:${PATH}"

# Cache persistence contract (see README): all Go caches point into
# /home/runner/.cache so a persistent volume mounted there captures the
# module cache, build cache, and GOPATH across runner pods.
# golangci-lint's own cache (~/.cache/golangci-lint) rides along for free.
ENV GOPATH=/home/runner/.cache/go \
    GOMODCACHE=/home/runner/.cache/go-mod \
    GOCACHE=/home/runner/.cache/go-build
# Private org modules: skip the public proxy/sumdb; auth is injected by workflow secrets.
ENV GOPRIVATE=github.com/atoz-project/*
# GOTOOLCHAIN=auto (human decision, 2026-09-10): a repo whose go.mod/toolchain
# directive is newer than this image's Go downloads that toolchain at job time
# (sumdb-verified) instead of failing. Self-healing beats fail-loud here: the
# consumer-CI blockage cost outweighed the "bump the image" signal. Repos that
# want strictness can set GOTOOLCHAIN=local per job. See docs/adr/0002.
ENV GOTOOLCHAIN=auto
# CGO is a first-class contract of this image (gcc + libc6-dev above). Pin the
# default ON so a missing/broken C toolchain fails builds loudly instead of
# silently compiling cgo packages as stubs. Per-command overrides
# (CGO_ENABLED=0 go build for cross-compile) still win over the ENV.
ENV CGO_ENABLED=1

# Go-based CLIs via `go install` with throwaway build caches in /tmp, so no
# root-owned files ever land in /home/runner/.cache (that tree belongs to the
# runner user and, in ARC, to the cache PV).
#
# golangci-lint MUST be goinstall'd, not fetched via the official install
# script: the prebuilt v1.64.8 binaries are compiled with go1.24 and
# hard-refuse go1.26 module targets ("the Go language version (go1.24) used
# to build golangci-lint is lower than the targeted Go version"). Compiling
# it with this image's Go matches what our CI does today.
RUN export GOBIN=/usr/local/bin GOPATH=/tmp/gopath GOMODCACHE=/tmp/gomodcache GOCACHE=/tmp/gocache \
    && go install "github.com/golangci/golangci-lint/cmd/golangci-lint@v${GOLANGCI_LINT_VERSION}" \
    && go install "google.golang.org/protobuf/cmd/protoc-gen-go@${PROTOC_GEN_GO_VERSION}" \
    && go install "connectrpc.com/connect/cmd/protoc-gen-connect-go@${PROTOC_GEN_CONNECT_GO_VERSION}" \
    && rm -rf /tmp/gopath /tmp/gomodcache /tmp/gocache

# sqlc as a sha256-verified prebuilt binary, NOT `go install`: sqlc v1.31.1
# requires go >= 1.26.0 to compile, which the 1.25 image line does not have
# (and GOTOOLCHAIN=local forbids fetching one). The binary keeps both lines on
# the exact same sqlc.
RUN curl -fsSL "https://github.com/sqlc-dev/sqlc/releases/download/v${SQLC_VERSION}/sqlc_${SQLC_VERSION}_linux_amd64.tar.gz" -o /tmp/sqlc.tgz \
    && echo "${SQLC_SHA256}  /tmp/sqlc.tgz" | sha256sum -c - \
    && tar -xzf /tmp/sqlc.tgz -C /usr/local/bin sqlc \
    && rm /tmp/sqlc.tgz

# buf (proto codegen), the GitHub CLI (repo automation scripts), and
# goreleaser (org release convention). All sha256-verified against releases.
RUN curl -fsSL -o /usr/local/bin/buf "https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/buf-Linux-x86_64" \
    && echo "${BUF_SHA256}  /usr/local/bin/buf" | sha256sum -c - \
    && chmod +x /usr/local/bin/buf \
    && curl -fsSL -o "/tmp/gh_${GH_VERSION}_linux_amd64.tar.gz" "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
        | grep "linux_amd64.tar.gz" | (cd /tmp && sha256sum -c -) \
    && tar -xzf "/tmp/gh_${GH_VERSION}_linux_amd64.tar.gz" -C /tmp \
    && mv "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
    && rm -rf "/tmp/gh_${GH_VERSION}_linux_amd64" "/tmp/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    && curl -fsSL -o /tmp/gr.tgz "https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}/goreleaser_Linux_x86_64.tar.gz" \
    && echo "${GORELEASER_SHA256}  /tmp/gr.tgz" | sha256sum -c - \
    && tar -xzf /tmp/gr.tgz -C /usr/local/bin goreleaser \
    && rm /tmp/gr.tgz

# Home for the cache contract below; must be writable by the runner user even
# when no PV is mounted (a PV mount simply shadows this directory).
RUN mkdir -p /home/runner/.cache && chown -R runner:runner /home/runner/.cache

USER runner

# Smoke checks at build time: fail the build if anything doesn't run.
RUN go version \
    && golangci-lint --version \
    && sqlc version \
    && buf --version \
    && goreleaser --version \
    && protoc-gen-go --version \
    && protoc-gen-connect-go --version \
    && gh --version \
    && zstd --version

# CGO smoke check: actually compile a cgo program. This is the regression test
# for the missing-gcc incident — version banners alone did not catch it.
RUN printf 'package main\nimport "C"\nfunc main() {}\n' > /tmp/cgo_smoke.go \
    && go build -o /tmp/cgo_smoke /tmp/cgo_smoke.go \
    && rm -f /tmp/cgo_smoke /tmp/cgo_smoke.go
