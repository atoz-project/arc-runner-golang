# arc-runner-golang

The shared CI runner image context: how org Go repositories get a fast,
reproducible Actions runner on our ARC/ECI cluster.

## Language

**Version line**:
One Go minor version (`1.25`, `1.26`), served by one floating image tag and
one scale set. The image never carries two Go minors.
_Avoid_: multi-version image, GO_VERSIONS

**Scale set**:
An ARC `AutoscalingRunnerSet`. Its name is the `runs-on` label, so the label
*is* the image choice; there is no per-job image selection.
_Avoid_: runner pool, fleet

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
