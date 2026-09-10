# arc-runner-golang

Custom [ARC (actions-runner-controller)](https://github.com/actions/actions-runner-controller)
runner image with the Go toolchain baked in — **the** Go CI environment for our
self-hosted runner scale sets. Everything `make build` / `make lint` /
`make test` / `make buf-generate` need is pre-installed; nothing downloads
per-run.

Image: `ghcr.io/atoz-project/arc-runner-golang`

## Using it in a workflow

The live scale set `arc-runner-set-golang` (runner group `arc-public`) serves
this image. Select it per job — the label *is* the image choice:

```yaml
jobs:
  test:
    runs-on: arc-runner-set-golang   # Go toolchain preinstalled
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.26.2"        # hits the baked-in toolcache, no download
      - run: go test ./...
```

With the hostedtoolcache layout baked in, `setup-go` resolves instantly; plain
`go` also works with no setup step at all. The default `arc-runner-set` keeps
serving the official minimal runner image for repos that have not opted in.

> The scale set must exist with **exactly** that name and be configured to use
> this image (see below). `runs-on` is just a label match — it does not pick
> the image by itself.

## What's inside

| Component | Version | Notes |
|---|---|---|
| GitHub Actions Runner | `2.337.0` (pinned base image) | [releases](https://github.com/actions/runner/releases) |
| Go | `1.26.2` linux/amd64 | sha256-verified download from go.dev |
| golangci-lint | `1.64.8` | **compiled from source with Go 1.26.2** (`go install`) — see note below |
| sqlc | `1.31.1` | store layer codegen |
| buf | `1.72.0` | proto codegen (`make buf-generate`) |
| gh | `2.100.0` | repo automation scripts; checksum-verified |
| Tools | `git`, `make`, `gcc`, `curl`, `ca-certificates`, `jq`, `zstd` | via apt; zstd for cache-server compression |

> **Why golangci-lint is goinstall'd, not a release binary:** the prebuilt
> v1.64.8 binaries are compiled with go1.24 and hard-refuse go1.26 module
> targets ("the Go language version (go1.24) used to build golangci-lint is
> lower than the targeted Go version"). Compiling with this image's Go 1.26.2
> matches what our CI does. The v1.x pin stays while `.golangci.yml` is
> v1-schema; migrate config and binary together.

### Go pre-installed in the tool-cache layout

Go is extracted into the GitHub hostedtoolcache layout:

```
/opt/hostedtoolcache/go/1.26.2/x64/          # the Go distribution (bin/, pkg/, ...)
/opt/hostedtoolcache/go/1.26.2/x64.complete  # empty completion marker
```

`actions/setup-go` (through `@actions/tool-cache`) only accepts a cached tool
when both the directory and the sibling `<arch>.complete` marker exist. With
this layout, `setup-go` with `go-version: "1.26.2"` (or a `go.mod` declaring
`go 1.26.2`) hits the cache and **skips the download entirely**
(`check-latest: false`, the default).

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
churn. See the cache PV section below.

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
          image: ghcr.io/atoz-project/arc-runner-golang:latest   # pin the date tag for reviewable rollouts
          command: ["/home/runner/run.sh"]
          volumeMounts:
            - name: go-cache
              mountPath: /home/runner/.cache   # matches the ENV contract above
      volumes:
        - name: go-cache
          persistentVolumeClaim:
            claimName: arc-golang-cache        # pre-created, see below
```

For a reviewable, pinned rollout, use the date tag (e.g.
`ghcr.io/atoz-project/arc-runner-golang:202609101`, format `YYYYMMDD` + build
run number) instead of `latest`.

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

## Integration tests (postgres service container)

ARC's kubernetes container mode supports job service containers. Our DB tests
need postgres **with `pg_trgm`** (and pgvector), so use the pgvector image —
it ships the full contrib set:

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

## Self-hosted Actions cache server

To use a self-hosted implementation of the GitHub Actions cache service
(such as [falcondev-oss/github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server)),
point runners at it via environment variables on the runner container:

```yaml
          env:
            - name: ACTIONS_CACHE_URL
              value: "http://cache.example.internal/"
            - name: ACTIONS_RESULTS_URL
              value: "http://cache.example.internal/"
```

Replace the URL with wherever your cache server lives. `zstd` is preinstalled
for cache compression.

> **Pending decision — `ACTIONS_RESULTS_URL` gets overwritten by the stock
> runner.** The upstream `actions/runner` binary overwrites
> `ACTIONS_RESULTS_URL` at runtime with the GitHub-hosted value, so the env
> above is only half-effective with the stock base image. Options:
>
> 1. **Recommended: rebase this image** `FROM ghcr.io/falcondev-oss/actions-runner:2.337.0`
>    (their fork tracks upstream versions and honors
>    `CUSTOM_ACTIONS_RESULTS_URL` natively).
> 2. Binary-patch the stock runner in this Dockerfile.
>
> Not done yet — flagged here so the decision is recorded next to the config
> that depends on it.

## No DinD by design

This image deliberately has **no Docker daemon, no docker CLI, and no dind
sidecar**. The CI it serves is pure Go (`go build` / `go vet` / `go test` /
lint / codegen), which never needs a docker socket. Leaving Docker out keeps
the runner pod unprivileged — no `privileged: true`, smaller attack surface,
faster scheduling. Workflows that genuinely need Docker (image builds,
compose-based integration tests) should keep running on GitHub-hosted
runners.

## Building

The image is built and pushed by
[.github/workflows/build.yml](.github/workflows/build.yml) on every push to
`main`, on any tag, and on manual dispatch. Layers are cached with
`type=gha,mode=max`.

## License

[MIT](LICENSE)
