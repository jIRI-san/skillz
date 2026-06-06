---
description: Plugin registry architecture for skalary — plugin manifests, generated registry, install/update/remove flows, integrity and confinement guarantees
globs:
  - plugins/**
  - registry.json
  - scripts/skalary/**
  - schemas/plugin.schema.json
  - schemas/registry.schema.json
  - schemas/receipt.schema.json
  - .github/.skalary/**
---

# Plugin Registry

The plugin registry is a source-first packaging system: `plugins/` is authoritative, `registry.json` is generated metadata, and `.github/` is a dogfood install target synchronized from plugin sources.

## Bundle Model and Layout

| Layer | Source of truth | Purpose | Files |
|---|---|---|---|
| Plugin source | `plugins/<name>/` | Authoring bundle with manifest + payload | `plugins/*/plugin.json`, payload files |
| Registry index | `registry.json` | Generated install catalog with file hashes and bootstrap metadata | `scripts/skalary/Build-Registry.ps1` output |
| Runtime state | `.github/.skalary/receipts/<name>.json` | Per-plugin installation tracking, merge-safe | install/update/remove verbs |
| Dogfood target | `.github/**` | Installed copies used by local tooling | `Sync-Dogfood.ps1` |

## Schema Contracts

| Schema | Contract |
|---|---|
| `schemas/plugin.schema.json` | Declares plugin identity, semver, dependencies, `files[]` as `{src,dest}`, optional `status`, reserved `evals` block. |
| `schemas/registry.schema.json` | Generated catalog embeds per-file `sha256` and bootstrap metadata (`ref`, script URL, one-liner). |
| `schemas/receipt.schema.json` | Per-plugin receipt stores resolved source `ref` SHA, version, and per-file `{dest,sha256,outcome}` with optional `degraded` and reserved `evalStatus`. |

Design choice: per-plugin receipts replace a shared lock file to avoid cross-branch merge conflicts.

## Copilot Skill Metadata Boundary

To prevent drift with evolving Copilot skill specs, plugin packaging keeps ownership boundaries explicit:

| Artifact | Allowed metadata |
|---|---|
| `SKILL.md` (inside plugin payload) | Standard Copilot skill frontmatter and skill body only. |
| `plugin.json` | Packaging and install metadata (`version`, dependencies, `files[]`, status, eval reservation). |
| `registry.json` | Generated install index derived from `plugin.json` + file hashes. |

`plugin.json` must not introduce alternate skill-schema fields into `SKILL.md`; compatibility is preserved by keeping skill spec data standard and packaging data external.

## Dependency and Install Model

Install/update behavior is implemented in `scripts/skalary/Install-Plugin.ps1` and `scripts/skalary/Update-Plugin.ps1` using shared helpers in `_Common.ps1`.

| Area | Decision |
|---|---|
| Dependency resolution | Deterministic topological order, dedupe by plugin name, lexical tie-breaks, cycle detection before copy. |
| Source coherence | One resolved SHA per operation; remote clone and local `-Source` both install from a single commit snapshot. |
| Transactional apply | Stage files under `.github/.skalary/tmp/`, verify staged hashes, back up targets, atomic move, then write receipt. |
| Rollback | Any failure restores backups, removes staged files, writes no new receipt. |
| `evals/` handling | Files under `evals/` are always excluded from installation. |

## Integrity and Security Model

| Threat | Guard |
|---|---|
| Path traversal / escape from `.github/` | Full-path resolution guard rejects `..`, absolute, UNC, drive-relative, and ADS destinations. |
| Payload tampering | Staged payload hash must match `registry.json` before any move. |
| Cross-plugin overwrite/remove collisions | Registry-wide destination uniqueness validation + runtime ownership map from receipts. |
| Destructive overwrite/remove of user edits | Update/remove verify receipt hash and mark modified files as skipped unless `-Force`. |
| Arbitrary code execution in bootstrap flow | `bootstrap.ps1` downloads scripts + `registry.json` only; it does not execute plugin payload. |

## Autopilot Plugin vs Infra Split

`autopilot` plugin payload is intentionally confined to `.github/agents/autopilot.agent.md` only.

Autopilot infrastructure (`scripts/autopilot/**`, `.devcontainer/autopilot/**`, `.autopilot.json`, `schemas/autopilot.schema.json`) is a separate prerequisite provisioned by `scripts/skalary/Initialize-Autopilot.ps1` and not installed through the plugin file-copy path. This preserves `.github/` confinement while allowing `ci` to depend on `autopilot` agent payload.

## Dogfood Authority and Sync

`plugins/` is authoritative. `.github/` is treated as installed output and can drift.

`scripts/skalary/Sync-Dogfood.ps1` converges `.github/` back to `plugins/` sources, is idempotent, and supports `-WhatIf` for CI drift detection. Running sync to convergence produces the expected state for CI drift-check pass criteria (`.github/` byte-equivalent to plugin sources). Destination collision checks in sync mirror registry safety rules.

## Evals Contract

Plan 005 implements the eval harness as **report-only** and keeps registry/receipt seams reserved:

| Surface | Reserved contract |
|---|---|
| Plugin manifest | Optional `evals` object with `path`, `status`, `lastRun`. |
| Registry | Per-plugin `evals.status` summary. |
| Receipt | Reserved `evalStatus` field. |
| Validation | `Test-Registry.ps1` emits warn-only informational eval checks. |

The harness writes `.eval-report.json` (and optional `.eval-artifacts/*`) only. It does **not** populate `plugin.json` `evals.status` / `lastRun`, `registry.json` `evals.status`, or receipt `evalStatus`.

Known issue (DR2-#15): structural evals now exist for all plugins, but `registry.json` may still report `evals.status: "none"` because the seam remains reserved. Treat that field as non-authoritative until registry writeback is explicitly implemented.

See [plugin-evals.design.md](./plugin-evals.design.md) for harness behavior, backend isolation, and judge contracts.
