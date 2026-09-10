---
status: accepted
---

# Cache volume over self-hosted Actions cache server

Go CI speed comes from persistent caches, not from a self-hosted Actions cache
server. We relocate all Go caches under `/home/runner/.cache` and mount one
shared volume there on the runner scale set. We deliberately do **not** adopt
a self-hosted Actions cache server (falcondev-oss/github-actions-cache-server).

## Considered Options

- **falcondev forked runner base** — works out of the box
  (`CUSTOM_ACTIONS_RESULTS_URL`), but extends the CI supply chain to one more
  vendor for every job we run.
- **Binary patch in our own image** — one `sed` renaming the UTF-16
  `ACTIONS_RESULTS_URL` string inside `Runner.Worker.dll`. No new vendor, but
  the patch silently no-ops if the runner binary changes, and runner
  self-update silently reverts it; both failure modes look like "cache just
  stopped".
- **Shared persistent volume (chosen)** — verified fact driving the decision:
  the stock runner overwrites `ACTIONS_RESULTS_URL` at runtime, so env-only
  configuration does nothing. Meanwhile Go's module/build caches are plain
  directories, concurrency-safe, content-addressed, and re-verified against
  each repo's `go.sum` — a volume serves them with zero protocol work.
  SaaS runner vendors (Namespace et al.) use the same cache-volume pattern.

## Consequences

- The volume is shared, writable CI state: every workflow on the scale set is
  inside its trust boundary. Accepted; Go's checksum model limits blast radius.
- `setup-go`'s `cache: true` (which round-trips through GitHub's hosted cache
  service) becomes redundant once the volume is warm — set `cache: false`.
- golangci-lint's cache lands on the same volume for free.
- Image pull cost is a separate layer, handled by ECI ImageCache against
  immutable date tags (see README), not by this decision.
- If a future need is language-agnostic `actions/cache` usage (non-Go tools),
  re-evaluate the cache server; nothing here blocks it.
