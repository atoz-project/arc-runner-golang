---
status: accepted
---

# GOTOOLCHAIN=auto as the image-wide default

The runner image sets `GOTOOLCHAIN=auto` (not `local`): a repo whose
`go.mod`/`toolchain` directive is newer than the image's Go downloads that
toolchain at job time instead of failing. This deliberately weakens the
image's otherwise strict version-pinning posture.

## Considered Options

- **`GOTOOLCHAIN=local` (initial choice)** — fail loudly when a repo runs
  ahead of the image, producing a clear "bump the image line" signal. In
  practice the signal lands as a hard CI blockage on the *consumer* side
  until infra rebuilds and rolls out, which couples every repo's pipeline to
  image maintenance latency.
- **`GOTOOLCHAIN=auto` (chosen, human decision 2026-09-10)** — self-healing
  download. Toolchain fetches are module-based and sumdb-verified, so
  integrity is preserved; the costs are per-run download time and silent
  drift (a repo can quietly run a newer toolchain than its scale set's line).

## Consequences

- Silent line-crossing is possible (a repo on the 1.25 line may run a 1.26
  toolchain). Accepted: the `toolchain` directive in go.mod is itself an
  explicit act by the repo.
- Repos that want the strict behavior set `GOTOOLCHAIN=local` per job — the
  image default no longer provides it.
- infra loses the fail-loud trigger for "bump the line"; line bumps stay on
  the deliberate matrix-edit cadence instead.
