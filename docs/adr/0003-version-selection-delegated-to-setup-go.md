# Version selection delegated to setup-go; baked lines are a cache, not a boundary

Earlier the same day we shipped one image per Go version line (`:1.25`, `:1.26`
tags, one scale set per line, `runs-on` label = version choice). We reversed
course: **one image** bakes all org-aligned Go patch versions into the
hostedtoolcache layout, and **version selection happens in each workflow** via
`actions/setup-go@v7` with an explicit `go-version` and `cache: true`.

Why the reversal: (a) ADR-0002's `GOTOOLCHAIN=auto` dissolved the "image version
is a hard boundary" property the dual-line design was paying for; (b) version
selection already lived in workflow files across the org's 10+ Go repos —
moving it to the `runs-on` label forked that convention; (c) a scale set per
line multiplies warm pods and release choreography for a distinction setup-go
already makes for free.

The baked versions are a **download-avoidance cache**: a `go-version` matching
a baked line resolves locally in zero download; anything else falls through to
a normal setup-go download, so the image lagging a Go release is never an
incident — rebuilding the image on new Go releases is routine maintenance, not
a gate.

Status: accepted (2026-09-10, human decision)

## Considered Options

- **gvm (Go Version Manager) inside one image** — rejected: `gvm use` mutates
  only the current shell, and CI steps are separate shells, so the selection
  would not persist across steps without manual `$GITHUB_PATH` plumbing; and
  there is no GitHub Action ecosystem for gvm (the org standard is setup-go,
  which manages versions itself).
- **Pure delegation (no Go in the image)** — rejected: every job would pay a
  ~70MB toolchain download from go.dev per run, making go.dev availability a
  per-job runtime dependency — the exact pain the tool-cache work was built
  to remove.

## Consequences

- One scale set (`arc-runner-set-golang`) serves all lines; the
  versioned-scale-set naming question dissolves.
- Floating line tags (`:1.25`, `:1.26`) and `:latest` are retired; the image
  ships immutable date tags only, and the scale set pins a date tag.
- Consumer contract: `runs-on: arc-runner-set-golang` + `setup-go@v7` with
  explicit `go-version` + `cache: true`. Works identically on GitHub-hosted
  runners, so it doubles as the overflow/DR path.
