---
status: accepted
---

# Pod-local cache with NAS `.tar.zst` job-hook snapshots

Go CI caches (`GOPATH`, `GOMODCACHE`, `GOCACHE`, `golangci-lint`) stay on pod-local block storage at `/home/runner/.cache`. Alibaba Cloud Capacity NAS (`071vdgqttek72nsstpz`) mounts at `/mnt/nas-cache` instead, and Actions runner job hooks stream per-repo, per-job `.tar.zst` snapshots to and from `/mnt/nas-cache/v1`.

## Context

Mounting the shared Capacity NAS directly at `/home/runner/.cache` tested [ADR-0001](0001-cache-volume-over-self-hosted-cache-server.md) across concurrent ECI pods and disproved the assumption that Go caches are concurrency-safe and fast over shared NFSv3. Four failures appeared in live CI runs.

1. **Missing cross-pod file locks.** ACK Serverless ECI mounts in-tree NFSv3 with `nolock,local_lock=all`, confining `flock` locks to one pod kernel. Concurrent `go mod download` runs produced `stale file handle` on `.zip*.tmp`, partial `0555` module trees missing subdirectories (`golang.org/x/net@v0.57.0`), and `unlinkat ... permission denied`.
2. **Linker `mmap` bus errors.** `cmd/link` maps object files with `mmap`. Concurrent writes and trims on shared `GOCACHE` crashed builds with `fatal error: fault [signal SIGBUS: bus error]`.
3. **Cross-repo `$GOPATH/bin` shadowing.** `actions/setup-go` prepends `$GOPATH/bin` ahead of `/usr/local/bin`. One repo installing a custom `golangci-lint` v1 binary into shared `/home/runner/.cache/go/bin` shadowed the image's preinstalled `v2.13.2` binary for unrelated v2 repos.
4. **Metadata latency across zones.** Small-file operations (`stat`, `open`, `unlink`) against cross-AZ Capacity NAS (`1b` ECI to `1a` NAS) slowed `go vet` from 10s to 164s and `make tools` from 3s to 13m33s.

Meanwhile, pod-local testing at `2C/4Gi` Guaranteed QoS passed `x-platform` `go test -race` across 95+ packages with zero cgroup OOM kills (`oom_kill 0`) and left `16 GiB` free on the default `30 GiB` container root disk.

## Decision

Keep `/home/runner/.cache` unmounted on pod-local storage and mount Capacity NAS at `/mnt/nas-cache` solely for sequential `.tar.zst` streaming through GitHub Actions runner hooks (`ACTIONS_RUNNER_HOOK_JOB_STARTED` and `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`).

- Both hook scripts (`arc-cache-restore.sh` and `arc-cache-save.sh`) are written by the container startup `command` inside [deploy/arc-runner-set-golang.values.yaml](../../deploy/arc-runner-set-golang.values.yaml), avoiding an image rebuild and preserving the ECI `ImageCache` match on `:v2.0.0`.
- Snapshots isolate by repository and workflow job at `/mnt/nas-cache/v1/<repo_slug>/<job_slug>/snap-<epoch>-<host>-<pid>.tar.zst`. Restore falls back only within `<repo_slug>/*/` so `$GOPATH/bin` never leaks across repos.
- Save strips `go-mod/cache/download/*.tmp`, caps `go-build` plus `golangci-lint` at `7500 MiB` and downloaded `.zip` archives at `1500 MiB` by `st_mtime`, streams `tar | zstd -1 -T0` to a `.tmp` file, and promotes atomically with `mv`.
- Garbage collection keeps the 2 newest snapshots per job unconditionally and deletes older ones only after a 30-minute grace window (`1800s`), preventing NFSv3 `ESTALE` for concurrent readers.
- Both hooks are non-fatal (`::warning::` and exit `0` on failure) and never touch the consumer `setup-go` `cache: false` contract.

## Consequences

- File locks, `mmap`, and compiler I/O run against pod-local disk with zero NFS race or bus-error exposure.
- Each job transfers one sequential archive stream over VPC LAN instead of thousands of small-file RPCs.
- Consumer workflows keep `cache: false` on `setup-go` and drop redundant `actions/cache` steps targeting `~/.cache/{go,go-mod,go-build}`.
- Snapshot size caps (`9000 MiB` combined across pruned build and zip caches) preserve disk headroom on the default `30 GiB` ECI disk without paid `+20Gi` storage.
