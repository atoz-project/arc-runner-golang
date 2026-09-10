# arc-runner-golang

Custom [ARC (actions-runner-controller)](https://github.com/actions/actions-runner-controller)
runner image with the Go toolchain baked in. Built on top of the official
`ghcr.io/actions/actions-runner` image.

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


## What's inside

| Component | Version / source | Notes |
|---|---|---|
| GitHub Actions Runner | `2.337.0` (pinned base image) | [releases](https://github.com/actions/runner/releases) |
| Go | `1.26.2` linux/amd64 | sha256-verified download from go.dev |
| Tools | `git`, `make`, `gcc`, `curl`, `ca-certificates`, `jq` | via apt |

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

Go is also on `PATH` directly (`/opt/hostedtoolcache/go/1.26.2/x64/bin`), so
jobs that skip `setup-go` still get `go` for free.

## The live scale set

Deployed as `arc-runner-set-golang` in namespace `arc-runners` (k8s-sg-dev)
via the `gha-runner-scale-set` chart 0.13.0. The effective spec:

```yaml
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: arc-runner-set-golang
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
          image: ghcr.io/atoz-project/arc-runner-golang:latest
          command: ["/home/runner/run.sh"]
```

For a reviewable, pinned rollout, use the date tag (e.g.
`ghcr.io/atoz-project/arc-runner-golang:202609101`, format `YYYYMMDD` + build
run number) instead of `latest`.

## Self-hosted Actions cache server

If you run a self-hosted implementation of the GitHub Actions cache service
(such as [falcondev-oss/github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server)),
point the runners at it via environment variables on the runner container:

```yaml
          env:
            - name: ACTIONS_CACHE_URL
              value: "https://gha-cache.example.com/"
            - name: ACTIONS_RESULTS_URL
              value: "https://gha-cache.example.com/"
```

Replace the URL with wherever your cache server lives. Both variables are
required; the runner passes them to actions so `actions/cache`, buildx
`type=gha`, etc. use your server instead of the hosted service.

## No DinD by design

This image deliberately has **no Docker daemon, no docker CLI, and no dind
sidecar**. The CI it serves is pure Go (`go build` / `go vet` / `go test` /
lint), which never needs a docker socket. Leaving Docker out keeps the runner
pod unprivileged — no `privileged: true`, smaller attack surface, faster
scheduling. Workflows that genuinely need Docker (image builds, compose-based
integration tests) should keep running on GitHub-hosted runners.

## Building

The image is built and pushed by
[.github/workflows/build.yml](.github/workflows/build.yml) on every push to
`main`, on any tag, and on manual dispatch. Layers are cached with
`type=gha,mode=max`.

## License

[MIT](LICENSE)
