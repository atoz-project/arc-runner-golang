# arc-runner-golang

The shared CI runner image context: how org Go repositories get a fast,
reproducible Actions runner on our ARC/ECI cluster.

## Language

**Version line**:
One Go minor version (`1.25`, `1.26`) that org repos align on. A property of
the *workflow* (`go-version:` in setup-go), not of the image: one image serves
all lines. See ADR-0003.
_Avoid_: line image, per-line scale set

**Baked line**:
A Go patch version pre-installed into the image's tool-cache as a
download-avoidance cache. Baked lines are a cache, not a boundary: setup-go
downloads any non-baked version at job time without failing.
_Avoid_: pinned Go (pinning is the workflow's job, via go-version)

**Scale set**:
An ARC `AutoscalingRunnerSet`. Its name is the `runs-on` label. There is one
scale set for Go CI; the label selects the *image*, never a Go version.
_Avoid_: runner pool, fleet, per-line scale set

**Tool-cache contract**:
The hostedtoolcache layout (`/opt/hostedtoolcache/go/<version>/x64/` plus the
sibling `x64.complete` marker) that makes `actions/setup-go` resolve locally
and skip downloading.
_Avoid_: preinstalled Go (vague; the layout is the contract)

**Cache directory contract**:
All Go caches (`GOPATH`, `GOMODCACHE`, `GOCACHE`, and golangci-lint's cache)
live under `/home/runner/.cache`, so one volume mount persists every cache
across ephemeral runner pods.

**ImageCache**:
An Alibaba ECI cluster-side image snapshot (`imagecaches.eci.alibabacloud.com`)
that removes the image-pull cost from runner pod cold starts. Matches pods by
exact `name:tag`, so it only works with immutable tags.
_Avoid_: image preheat, snapshot cache
