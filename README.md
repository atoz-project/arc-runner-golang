# arc-runner-golang

Custom [ARC (actions-runner-controller)](https://github.com/actions/actions-runner-controller)
runner image with the Go toolchain baked in — **the** Go CI environment for our
self-hosted runner scale sets. Everything `make build` / `make lint` /
`make test` / `make buf-generate` need is pre-installed; nothing downloads
per-run.

Image: `ghcr.io/atoz-project/arc-runner-golang`

## Version lines and tags

One image per Go minor version line, built from a matrix. Tags:

| Tag | Moves? | Meaning |
|---|---|---|
| `:1.25`, `:1.26` | yes, per patch release | floating minor line — what scale sets should consume |
| `:<go>-<date><run>` (e.g. `:1.26.8-202609101`) | never | immutable build, for pinned rollouts and ECI ImageCache |

There is deliberately **no `:latest` tag**: consumers pin an explicit line (or
date tag) so "what is running" is never time-dependent.

Scale set ↔ line mapping: `arc-runner-set-golang` tracks the **1.25** line
(the org's declared `go` directive); `arc-runner-set-golang-1.26` tracks the
**1.26** line for repos opting into the newer toolchain. Bumping a patch
version is a one-row edit in [build.yml](.github/workflows/build.yml); adding
a line (e.g. 1.27) is one more matrix row plus one more scale set.

## Using it in a workflow

Select the scale set per job — the label *is* the image choice:

```yaml
jobs:
  test:
    runs-on: arc-runner-set-golang   # Go 1.25.x preinstalled
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.25"          # hits the baked-in toolcache, no download
      - run: go test ./...
```

Pin `go-version` to the line your scale set tracks. With the hostedtoolcache
layout baked in, `setup-go` resolves instantly; plain `go` also works with no
setup step at all. `GOTOOLCHAIN=auto` is set image-wide: if a repo's
`go.mod`/`toolchain` directive demands a Go newer than the image, the job
downloads that toolchain at run time (slower, but self-healing) instead of
failing — repos that want strict pinning can set `GOTOOLCHAIN=local` per job.
The default `arc-runner-set` keeps serving the official minimal runner image for repos that have not opted in.

> The scale set must exist with **exactly** that name and be configured to use
> this image (see below). `runs-on` is just a label match — it does not pick
> the image by itself.

## What's inside

| Component | Version | Notes |
|---|---|---|
| GitHub Actions Runner | `2.337.0` (pinned base image) | [releases](https://github.com/actions/runner/releases) |
| Go | `1.25.14` / `1.26.8` linux/amd64 (per line) | sha256-verified download from go.dev |
| golangci-lint | `1.64.8` | **compiled from source with the image's Go** (`go install`) — see note below |
| sqlc | `1.31.1` | store layer codegen; prebuilt binary (sha256, TOFU) so both Go lines run identical sqlc — v1.31.1 needs go ≥ 1.26 to compile |
| protoc-gen-go | `v1.36.10` | `go install`ed at image build; matches org repos |
| protoc-gen-connect-go | `v1.19.1` | `go install`ed at image build; matches org repos |
| gh | `2.100.0` | repo automation scripts; checksum-verified |
| goreleaser | `2.18.1` | org release convention (5 repos); sha256-verified binary |
| Tools | `git`, `make`, `gcc`, `libc6-dev`, `musl-tools`, `zstd`, `curl`, `ca-certificates`, `jq` | via apt; gcc+libc6-dev = CGO (mattn/go-sqlite3); zstd for cache compression |

`GOPRIVATE=github.com/atoz-project/*` is set image-wide; authentication for
private module fetches comes from workflow secrets at job time.

> **Why golangci-lint is goinstall'd, not a release binary:** the prebuilt
> v1.64.8 binaries are compiled with go1.24 and hard-refuse go1.26 module
> targets ("the Go language version (go1.24) used to build golangci-lint is
> lower than the targeted Go version"). Compiling with this image's Go
> matches what our CI does. The v1.x pin stays while `.golangci.yml` is
> v1-schema; migrate config and binary together.

### Go pre-installed in the tool-cache layout

Go is extracted into the GitHub hostedtoolcache layout:

```
/opt/hostedtoolcache/go/<version>/x64/          # the Go distribution (bin/, pkg/, ...)
/opt/hostedtoolcache/go/<version>/x64.complete  # empty completion marker
```

`actions/setup-go` (through `@actions/tool-cache`) only accepts a cached tool
when both the directory and the sibling `<arch>.complete` marker exist. With
this layout, `setup-go` with a matching `go-version` hits the cache and
**skips the download entirely** (`check-latest: false`, the default).

Go is also on `PATH` directly, so jobs that skip `setup-go` still get `go`.

### Cache persistence contract

The image sets:

```
GOPATH=/home/runner/.cache/go
GOMODCACHE=/home/runner/.cache/go-mod
GOCACHE=/home/runner/.cache/go-build
```

so **a persistent volume mounted at `/home/runner/.cache` captures
everything** — module cache, build cache, GOPATH — and survives runner pod
churn. golangci-lint's cache (`~/.cache/golangci-lint`) rides along for free.
See the cache PV section below. Once the PV is proven warm, set
`cache: false` on `setup-go` in your workflows — its save/restore round-trip
to the GitHub cache service becomes redundant.

## The live scale set

Deployed as `arc-runner-set-golang` in namespace `arc-runners` (k8s-sg-dev)
via the `gha-runner-scale-set` chart 0.13.0. The effective spec:

```yaml
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: arc-runner-set-golang      # <- must match runs-on:
  namespace: arc-runners
spec:
  githubConfigUrl: https://github.com/atoz-project
  githubConfigSecret: github-config-secret
  runnerGroup: arc-public
  minRunners: 1
  template:
    spec:
      containers:
        - name: runner
          image: ghcr.io/atoz-project/arc-runner-golang:1.25   # explicit line tag, or a date tag for pinned rollouts
          command: ["/home/runner/run.sh"]
          volumeMounts:
            - name: go-cache
              mountPath: /home/runner/.cache   # matches the ENV contract above
      volumes:
        - name: go-cache
          persistentVolumeClaim:
            claimName: arc-golang-cache        # pre-created, see below
```

Note the pod spec should also set `securityContext.fsGroup: 1001` (the runner
uid) so the mounted cache volume is writable.

### Cache PV

The new ARC API (`actions.github.com/v1alpha1`) has **no
`volumeClaimTemplates`** on the runner pod template — and per-pod claims
would defeat cache sharing anyway (every new runner pod would get a fresh,
cold volume). Instead, pre-create **one shared PVC** and reference it from the
scale set, as above:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: arc-golang-cache
  namespace: arc-runners
spec:
  accessModes: ["ReadWriteMany"]       # RWX so every runner pod mounts the same cache
  storageClassName: <your-rwx-storage-class>   # e.g. an NFS-backed class
  resources:
    requests:
      storage: 100Gi
```

If your cluster has no RWX provisioner, use `ReadWriteOnce` with
`maxRunners: 1`, or accept per-pod `emptyDir` caches (drop the volume
entirely — the ENV contract still keeps caches in one place within a pod's
lifetime).

The cache is shared, writable CI state: module contents are still verified
against each repo's `go.sum`, and the build cache is content-addressed, but
treat the volume as within the trust boundary of every workflow that runs on
the scale set.

## ECI ImageCache

Our cluster (k8s-sg-dev) is pure ECI: every runner pod pays a full image pull
on cold start. Alibaba's
[ImageCache](https://www.alibabacloud.com/help/en/elastic-container-instance/latest/imagecaches-overview)
(`imagecaches.eci.alibabacloud.com`) snapshots an image so ECI pods start
without pulling layers. Contract:

- **Immutable tags only.** ImageCache matches by exact `name:tag`; a floating
  tag's snapshot silently goes stale. Use the date tag (`:1.26.8-202609101`).
- ECI auto-matches pods to an existing ImageCache by image name — no pod
  annotation needed.
- The image is public, so no `imagePullSecrets` are required.

```yaml
apiVersion: eci.alibabacloud.com/v1
kind: ImageCache
metadata:
  name: arc-runner-golang-1-26-8
spec:
  images:
    - ghcr.io/atoz-project/arc-runner-golang:1.26.8-202609101
  imageCacheSize: 25
  retentionDays: 7
```

Not wired yet: creating/updating the CR per build needs cluster credentials
the build workflow does not have. Follow-up is either a build.yml step with a
cluster kubeconfig secret, or a small in-cluster cron that reconciles the
newest date tag. Scale sets must also reference a date tag for this to take
effect.

## Integration tests (postgres service container)

Job service containers require `containerMode: kubernetes` on the scale set,
which is **not enabled** on ours — as written this section only applies once
that mode is turned on. With it, DB tests that need postgres **with
`pg_trgm`** (and pgvector) should use the pgvector image — it ships the full
contrib set:

```yaml
jobs:
  integration:
    runs-on: arc-runner-set-golang
    services:
      postgres:
        image: pgvector/pgvector:pg16
        env:
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          POSTGRES_DB: testdb
        ports: ["5432:5432"]
        options: >-
          --health-cmd "pg_isready -U test"
          --health-interval 5s --health-timeout 5s --health-retries 20
    steps:
      - run: make test   # DATABASE_URL=postgres://test:test@localhost:5432/testdb
```

Extensions are not created automatically. Two options:

1. **Recommended (zero infra): tests create what they need.** Run
   `CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS vector;`
   in test setup (or in the migration bootstrap the tests already execute).
   Works with any stock postgres-family image.
2. Publish a tiny internal postgres image that layers an
   `/docker-entrypoint-initdb.d/00-extensions.sql` onto `pgvector/pgvector:pg16`.
   Only worth it if option 1 becomes unmaintainable.

## Self-hosted Actions cache server — not adopted

We do not run one (e.g. falcondev-oss/github-actions-cache-server). Verified
against upstream docs: the stock runner **overwrites `ACTIONS_RESULTS_URL` at
runtime**, so merely setting `ACTIONS_CACHE_URL`/`ACTIONS_RESULTS_URL` env on
the runner container does nothing — working setups require a binary patch to
`Runner.Worker.dll` or the vendor's forked runner base image. We decline both
(supply chain vs. fragile patch), because the Go caching problem is already
solved by the persistent volume above. `ACTIONS_CACHE_URL` is additionally the
legacy v1 endpoint and ignored by the v2 cache protocol. See
[docs/adr/0001](docs/adr/0001-cache-volume-over-self-hosted-cache-server.md).
`zstd` stays installed: it is the compression format cache backends prefer.

## No DinD by design

This image deliberately has **no Docker daemon and no dind sidecar**. (The
docker CLI binary is inherited from the base image — the Actions runner needs
it for container actions — but with no daemon and no socket it is inert.) The
CI it serves is pure Go (`go build` / `go vet` / `go test` / lint / codegen),
which never needs a docker socket. Leaving the daemon out keeps the runner
pod unprivileged — no `privileged: true`, smaller attack surface, faster
scheduling. Workflows that genuinely need Docker (image builds, compose-based
integration tests) should keep running on GitHub-hosted runners. Job-level
`container:`/`services:` would additionally require `containerMode:
kubernetes` on the scale set, which is not enabled.

## Building

The image is built and pushed by
[.github/workflows/build.yml](.github/workflows/build.yml) on every push to
`main`, on any tag, and on manual dispatch — one matrix leg per Go version
line. Layers are cached with `type=gha,mode=max`, scoped per line.

## License

[MIT](LICENSE)
