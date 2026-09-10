# arc-runner-golang

Custom [ARC (actions-runner-controller)](https://github.com/actions/actions-runner-controller)
runner image with the Go toolchain baked in — **the** Go CI environment for our
self-hosted runner scale sets. Everything `make build` / `make lint` /
`make test` / `make buf-generate` need is pre-installed; nothing downloads
per-run.

Image: `ghcr.io/atoz-project/arc-runner-golang`

## Tags

The image is versioned independently of Go: one immutable SemVer tag per
release (`:v2.0.0`, …), from the `VERSION` file at the repo root. Bumping
`VERSION` is part of the change it ships with — the build **fails loudly** if
the tag already exists, so an immutable tag can never move. Matching git tags
(`vX.Y.Z`) map every image back to its source commit.

Bump rules: **major** = consumer-visible contract break (ENV/contract changes,
tool removal); **minor** = tool added or version-bumped, new baked Go line;
**patch** = base-image refresh, doc-only fixes.

There are deliberately **no floating tags** (`:latest`): the scale set pins a
`:vX.Y.Z` and bumps deliberately, so "what is running" is never
time-dependent, and ECI ImageCache (which matches pods by exact `name:tag`)
can never serve a stale snapshot.

The image carries no Go-version identity on purpose: Go version selection is
the workflow's job (below), not the tag's. See
[docs/adr/0003](docs/adr/0003-version-selection-delegated-to-setup-go.md).

## Using it in a workflow

The contract is stock GitHub — nothing org-specific:

```yaml
jobs:
  test:
    runs-on: arc-runner-set-golang
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-go@v7
        with:
          go-version: "1.25"   # explicit minor spec; baked lines resolve with zero download
          cache: true          # module/build cache via the Actions cache backend (works on ARC)
    # or: go-version-file: go.mod
      - run: go test ./...
```

`go-version` is the single source of truth for the Go version, exactly as on
GitHub-hosted runners (so this doubles as the overflow/DR path). The org's
aligned lines (`1.25`, `1.26`) are **baked into the image's tool-cache** as a
download-avoidance cache: matching specs resolve locally with no download;
anything else setup-go downloads at job time — slower, never an error.
`GOTOOLCHAIN=auto` is set image-wide for the same reason: a `go.mod`
`toolchain` directive newer than the selected Go downloads that toolchain
(sumdb-verified) instead of failing; set `GOTOOLCHAIN=local` per job if you
want strictness. CGO is on by default image-wide (`CGO_ENABLED=1`, gcc +
libc6-dev installed); per-command overrides (`CGO_ENABLED=0 go build`) still
win.

> The scale set must exist with **exactly** the name `arc-runner-set-golang`
> and be configured to use this image (see below). `runs-on` is just a label
> match — it does not pick the image by itself.

## What's inside

| Component | Version | Notes |
|---|---|---|
| GitHub Actions Runner | `2.337.0` (pinned base image) | [releases](https://github.com/actions/runner/releases) |
| Go | `1.25.14` + `1.26.8` linux/amd64, both baked into the tool-cache | sha256-verified downloads from go.dev; a **cache, not a boundary** |
| golangci-lint | `2.13.2` | **compiled from source with the image's Go** (`go install`, `/v2/` module path) — see note below; org lint standard is v2 schema ([ADR-0004](docs/adr/0004-golangci-lint-v2-org-standard.md)) |
| sqlc | `1.31.1` | store layer codegen; prebuilt binary (sha256, TOFU) so both Go lines run identical sqlc — v1.31.1 needs go ≥ 1.26 to compile |
| protoc-gen-go | `v1.36.10` | `go install`ed at image build; matches org repos |
| protoc-gen-connect-go | `v1.19.1` | `go install`ed at image build; matches org repos |
| gh | `2.100.0` | repo automation scripts; checksum-verified |
| goreleaser | `2.18.1` | org release convention (5 repos); sha256-verified binary |
| Tools | `git`, `make`, `gcc`, `libc6-dev`, `musl-tools`, `zstd`, `curl`, `ca-certificates`, `jq` | via apt; gcc+libc6-dev = CGO (mattn/go-sqlite3); zstd for cache compression |

`GOPRIVATE=github.com/atoz-project/*` is set image-wide; authentication for
private module fetches comes from workflow secrets at job time.

> **Why golangci-lint is goinstall'd, not a release binary:** release binaries
> lag the current Go and hard-refuse newer module targets ("the Go language
> version (goX) used to build golangci-lint is lower than the targeted Go
> version"). Compiling with this image's Go matches what our CI does. The org
> lint standard is **v2 schema** (ADR-0004); migrate consumer configs with
> `golangci-lint migrate`.


### Go pre-installed in the tool-cache layout

Both baked Go lines live side by side in the GitHub hostedtoolcache layout:

```
/opt/hostedtoolcache/go/<version>/x64/          # the Go distribution (bin/, pkg/, ...)
/opt/hostedtoolcache/go/<version>/x64.complete  # empty completion marker
```

`actions/setup-go` (through `@actions/tool-cache`) only accepts a cached tool
when both the directory and the sibling `<arch>.complete` marker exist. With
this layout, `setup-go` with a matching `go-version` hits the cache and
**skips the download entirely** (`check-latest: false`, the default); any
other version downloads normally.

The newest baked line is on `PATH` directly, so jobs that skip `setup-go`
still get a working `go`.

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
via the `gha-runner-scale-set` chart 0.14.2.
The deployed values are the source of truth in
[deploy/arc-runner-set-golang.values.yaml](deploy/arc-runner-set-golang.values.yaml)
— apply with `helm upgrade ... --version 0.14.2 -f deploy/…` (chart minor must
match the controller; see the file header for the incident rules). The
rendered spec for reference:

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
          image: ghcr.io/atoz-project/arc-runner-golang:v2.0.0   # pinned release — bump deliberately
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
  tag's snapshot silently goes stale. Use the release tag (`:v2.0.0`).
- ECI auto-matches pods to an existing ImageCache by image name — no pod
  annotation needed.
- The image is public, so no `imagePullSecrets` are required.

```yaml
apiVersion: eci.alibabacloud.com/v1
kind: ImageCache
metadata:
  name: arc-runner-golang-1-0-0
spec:
  images:
    - ghcr.io/atoz-project/arc-runner-golang:v2.0.0
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
`main`, on any tag, and on manual dispatch. Layers are cached with
`type=gha,mode=max`.

## License

[MIT](LICENSE)
