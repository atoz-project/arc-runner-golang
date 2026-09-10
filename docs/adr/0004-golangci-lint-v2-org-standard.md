# golangci-lint v2 as the org-wide lint standard

The image launched pinning golangci-lint **v1.64.8** because the repos already
onboarded (cellar, virt-squad) had v1-schema `.golangci.yml`, while netmap had
already migrated to v2 schema — an org-wide split the image could not serve
with one binary (v1 can't read v2 configs and vice versa). On 2026-09-11 the
operator ruled: **the org standardizes on v2** (v1 is EOL upstream), so the
image ships golangci-lint v2.13.2 and consumers migrate their configs.

Status: accepted (2026-09-11, operator decision)

## Consequences

- Image major bump (v1.0.0 → v2.0.0): a pinned-tool contract break for
  v1-schema consumers.
- Consumers migrate with golangci-lint's built-in `golangci-lint migrate`
  (rewrites `.golangci.yml` to v2 schema) and pin CI to the migrated config.
- The scale set flips to the v2.0.0 image only after consumer config
  migrations land, so no one's lint gate breaks mid-flight.
- netmap (already v2-schema) becomes the aligned reference; the image's
  preinstalled binary now serves them directly, replacing their per-run
  `go install golangci-lint@latest` (floating + 40-60s compile + report-only
  masking install failures).
