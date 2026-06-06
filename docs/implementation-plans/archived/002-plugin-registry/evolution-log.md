# Evolution Log — Plan 002: Plugin Registry

Records design-review (DR) round history. Given to DR agents as context to prevent re-reporting fixed issues or contradicting deliberate decisions.

## Round 1

**Models:** Opus · Codex · Gemini. 2 Critical, 8 High, 8 Medium, 2 Low.

### Fixed (applied to plan)
- **#1 (Critical) autopilot confinement contradiction** → `autopilot` plugin now installs only `agents/autopilot.agent.md`; infra (`.devcontainer`, `.autopilot.json`, `schemas/autopilot.schema.json`, `scripts/autopilot`) is a non-plugin prerequisite provisioned by `Initialize-Autopilot.ps1` (Plan 001). `ci`→`autopilot` satisfied by agent file + runtime preflight. (REQ-21, RISK-11, step 4.7)
- **#2 (Critical) supply-chain integrity** → `registry.json` embeds per-file sha256; install verifies staged files before move. (RISK-13, steps 3.1/4.5)
- **#3 (High) bootstrap pinned ref** → one-liner pins immutable SHA/tag; `-Ref` param. (REQ-12, step 6.1)
- **#4 (High) CRLF normalization** → clone with `core.autocrlf=false core.eol=lf`; cross-platform hash test. (RISK-14, steps 4.1/4.4/7.1)
- **#5 (High) atomic move** → transactional: stage on target volume `.github/.skillz/tmp/`, backup, atomic renames, success marker. (RISK-10, step 4.3)
- **#6 (High) transitive rollback scope** → all-or-nothing across full dependency set; rollback removes newly-installed deps. (REQ-11, step 4.3)
- **#7 (High) shared dest ownership** → registry-wide dest-uniqueness rule + runtime ownership map; ref-counting declined as overengineering (uniqueness suffices). (RISK-12, step 3.3)
- **#8 (High) receipt/disk consistency on skip** → per-file outcome state; version advanced only if all updated, else `degraded`. (REQ-7, step 5.1)
- **#9 (High) files[] schema** → concrete `plugin.json` example added; `files[]` = `{src,dest}` objects. (Decisions, step 1.2)
- **#10 (High) step 2.1 too large** → split into 2.1a (simple plugins) + 2.1b (skill/agent plugins).
- **#11 (Medium) path guard** → full-path `GetFullPath` confinement covering `..`/absolute/UNC/drive-relative/ADS. (REQ-14, steps 1.1/3.3/4.5)
- **#12 (Medium) source/ref coherence** → single SHA per operation for registry+payload; `ref` required in receipt schema. (REQ-5, steps 1.2/4.1/4.4)
- **#13 (Medium) drift semantics** → split into "modified" (disk vs receipt) and "outdated" (receipt vs registry). (REQ-9, step 5.3)
- **#14 (Medium) resolver determinism** → dedupe, lexical tie-breaks, no-op criteria, diamond tests. (step 4.2)
- **#15 (Medium) single-version model** → documented explicitly in Decisions.
- **#16 (Medium) autopilot partial state** → `status:partial`, `Test-Registry` warn-only file-existence. (RISK-11, step 2.1b)
- **#17 (Medium) drift authority** → `plugins/` is source of truth; `Sync-Dogfood.ps1` remediation. (REQ-22, step 3.4)
- **#18 (Medium) non-testable criteria** → REQ-2/REQ-5/REQ-7 rewritten as binary hash/outcome checks.
- **#20 (Low) Find-Plugin scheduling** → annotated parallelizable.

### Declined (deliberate)
- **#7 reference-counting** — declined; dest-uniqueness rule makes shared files impossible, so ref-counting is unnecessary complexity.
- **#19 (Low) raw-file fetch instead of clone** — declined; full shallow-clone is a settled decision keeping remote/local paths identical. Mitigated by `finally` cleanup.

### Deferred → Known Plan Issues
- None.
