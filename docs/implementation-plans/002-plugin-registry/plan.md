# 002: Plugin Registry + PowerShell Management

<!-- execution-mode: container-autopilot -->
<!-- scope: plan -->

> Converts this repo into a plugin registry compatible with the Copilot CLI / Agent Skills ecosystem, and adds PowerShell tooling so VS Code users can install/update/remove plugins (bundles of skills + prompts + agents) directly into a consuming repo's `.github/`. Runs **after Plan 001** under container autopilot (whole-plan scope). Includes **eval reservation seams** only — the eval harness itself is a future Plan 003.

## Decisions

- **Plugin = bundle.** A plugin is a named bundle that may install multiple related files across `.github/skills`, `.github/prompts`, `.github/agents`, and `.github/agents/scripts`. See **Plugin Inventory** below.
- **Globally unique plugin names.** Identity = the plugin name. The bundle model removes the `cr`/`dr` prompt-vs-agent collision (each is one plugin owning both files).
- **Destination uniqueness (DR1-#7).** No two plugins may declare the same `.github/` destination path. `Test-Registry` enforces registry-wide dest uniqueness; install/update build an ownership map from receipts and abort on collision. No shared-file reference-counting (kept out by the uniqueness rule).
- **This repo IS the registry.** Canonical plugin sources live under `plugins/<name>/` — **`plugins/` is the single source of truth**; `.github/` dogfood copies are *derived* and must match. skillz dogfoods by installing the plugins it uses into its own `.github/` (committed). CI drift-checks `.github/` against `plugins/`; remediation is `Sync-Dogfood.ps1` (also run by CI to prove it converges).
- **Canonical layout (mirror-structure).** `plugins/<name>/plugin.json` + files laid out mirroring their `.github/` destination, e.g. `plugins/cr/agents/cr.agent.md`, `plugins/cr/prompts/cr.prompt.md`, `plugins/cr/agents/scripts/get-diff-branch.ps1`. Install copies each file to `.github/<same-relative-path>`.
- **`plugin.json` fields:** `name` (unique), `version` (semver), `description`, `author` (inherit repo owner), `license` (inherit repo LICENSE), `tags[]`, `dependencies[]` (plugin names), `files[]` (array of `{ "src": "<path under plugins/<name>/>", "dest": "<path under .github/>" }`; for mirror-structured plugins `dest` equals `src`, for `autopilot` `dest` is explicit), optional `status` (`stable`|`partial`), and reserved `evals` block (see Eval Reservation). Concrete example below.
- **Install target:** consuming repo's `.github/` (committed with that repo). Scripts refuse to write outside `.github/` — confinement is enforced by resolving `[IO.Path]::GetFullPath(Join-Path repoRoot dest)` and requiring the result to be under the resolved `.github/` path (case-insensitive on Windows, trailing-separator checked). Rejects `..`, absolute, rooted, UNC (`\\`), drive-relative (`C:foo`), and alternate-data-stream (`:`) dests (DR1-#11).
- **`autopilot` is `.github/`-only (DR1-#1).** The `autopilot` *plugin* installs only `.github/agents/autopilot.agent.md` (obeys the confinement invariant like every other plugin). The autopilot *infrastructure* (`.devcontainer/autopilot/**`, `.autopilot.json`, `schemas/autopilot.schema.json`, `scripts/autopilot/**`) is a **non-plugin prerequisite** delivered by Plan 001 and provisioned by a separate `Initialize-Autopilot.ps1` (or documented preflight in the `ci` skill) — never through the confined install path. Therefore `ci` depends on `cr` + `autopilot` at the *plugin* level (agent file), and the `ci` skill performs an autopilot-infra *preflight check* at runtime.
- **Install source + ref coherence (DR1-#12).** Remote GitHub (`github.com/<owner>/skillz`) via shallow git clone to temp + copy + cleanup; `-Source <localPath>` override for a local checkout. Every operation resolves **one commit SHA** and uses it for BOTH `registry.json` and payload fetch; that SHA is recorded in the receipt. Clone disables line-ending rewrite: `git clone -c core.autocrlf=false -c core.eol=lf --depth 1 --branch <ref>` (DR1-#4) so payload bytes (and sha256) are identical cross-platform.
- **Supply-chain integrity (DR1-#2).** `Build-Registry.ps1` embeds each plugin file's sha256 into `registry.json`. `Install-Plugin` verifies every staged file's hash against the `registry.json` manifest **before** moving anything into `.github/`; mismatch aborts. (The receipt hash is for later local-edit detection, a separate concern.)
- **Tracking = per-plugin receipts.** `.github/.skillz/receipts/<name>.json` per installed plugin: name, version, source, **ref (commit SHA, required)**, per-file records `{ dest, sha256, outcome: installed|updated|skipped-modified }`, install timestamp, optional `degraded` flag, reserved `evalStatus`. **No central lockfile** — separate files per plugin avoid cross-branch merge collisions. `Get-Plugin` reconstructs the installed view by reading receipts.
- **Index:** `registry.json` at repo root is the generated source of truth (built from `plugins/*/plugin.json` + file hashes by `Build-Registry.ps1`); README catalog table is generated from `registry.json`. CI fails on drift in either direction.
- **Scripts (PowerShell 7+, one per verb)** in `scripts/skillz/`: `bootstrap.ps1`, `Install-Plugin.ps1`, `Update-Plugin.ps1`, `Remove-Plugin.ps1`, `Get-Plugin.ps1` (list), `Find-Plugin.ps1` (search), `Test-Registry.ps1` (validate), `Build-Registry.ps1` (index), `Sync-Dogfood.ps1` (sync `.github/` from `plugins/`), `Initialize-Autopilot.ps1` (provision autopilot infra), `_Common.ps1` (shared helpers). Every script `#requires -Version 7.0`.
- **Bootstrap (pinned, DR1-#3).** README install one-liner pins an **immutable commit SHA or release tag**, generated by `Build-Registry.ps1`: `irm https://raw.githubusercontent.com/<owner>/skillz/<SHA-or-tag>/scripts/skillz/bootstrap.ps1 | iex`. `bootstrap.ps1` takes a `-Ref` parameter (default = pinned tag), fetches the verb scripts + `registry.json` into the consuming repo's `scripts/skillz/`, creates `.github/.skillz/`, executes **no** plugin payload, then prints next-step guidance.
- **Install is transactional / all-or-nothing (DR1-#5, #6, #10).** Resolve the full dependency set into one ordered install plan; stage **all** files for **all** plugins in the transaction into a temp dir **on the target volume** (`.github/.skillz/tmp/`); verify hashes against `registry.json`; back up any existing targets; apply per-file atomic renames in deterministic order; write a success marker; write receipts. On any failure: restore backups, remove staged files, write no receipts (newly-resolved deps tracked in transaction state are rolled back too).
- **Dependencies (DR1-#14, #15).** Single-version model: the registry publishes one (latest) version per plugin; `Update-Plugin` always moves to latest; **no** multi-version resolution or version ranges. Resolver dedupes by name, uses stable lexical tie-breaks for siblings, detects cycles via visited-set, and is a **no-op** when a dep is already installed at the desired version + matching hashes. Diamond graphs install each plugin exactly once.
- **Drift semantics (DR1-#13).** Two distinct concepts: **modified** = disk hash ≠ receipt hash (works offline in any consuming repo); **outdated** = receipt version < registry version (handled by `Update-Plugin`). `Get-Plugin` reports both independently.
- **Update consistency (DR1-#8).** `Update-Plugin` verifies existing file hashes; user-modified files are skipped (unless `-Force`) and recorded as `skipped-modified` with their **actual** on-disk hash. The plugin version is advanced only if **all** managed files updated; otherwise the receipt is marked `degraded` and requires explicit reconciliation (`-Force` or manual).
- **Security:** install/copy confined to `.github/` (full-path resolution guard above); registry-side hash verification before move; verify recorded sha256 before update/remove (warn + skip on user-modified files unless `-Force`); `Remove-Plugin` deletes only receipt-listed files whose hash matches and refuses if another installed plugin would be orphaned; never `iex`/dot-source downloaded plugin content; bootstrap pins to an immutable ref and the user reviews the one-liner.
- **PowerShell rules:** no leading `&`; invoke `.ps1` directly; stage only touched files (no `git add -A`); cross-platform `pwsh`.
- **Eval reservation (framework-agnostic):** reserve seams only — no runner, no scoring, no format commitment. See Eval Reservation section.
- **Formatting:** `.editorconfig` + `PSScriptAnalyzerSettings.psd1` reused/extended from Plan 001; lint clean at every phase boundary.

### `plugin.json` example (`cr`)

```jsonc
{
  "name": "cr",
  "version": "1.0.0",
  "description": "Code review — orchestrator + three specialist subagents + git diff helpers.",
  "author": "<repo-owner>",
  "license": "<inherited-from-LICENSE>",
  "tags": ["review", "agent", "prompt"],
  "dependencies": [],
  "status": "stable",
  "files": [
    { "src": "prompts/cr.prompt.md",        "dest": "prompts/cr.prompt.md" },
    { "src": "agents/cr.agent.md",          "dest": "agents/cr.agent.md" },
    { "src": "agents/cr-opus.agent.md",     "dest": "agents/cr-opus.agent.md" },
    { "src": "agents/cr-codex.agent.md",    "dest": "agents/cr-codex.agent.md" },
    { "src": "agents/cr-gemini.agent.md",   "dest": "agents/cr-gemini.agent.md" },
    { "src": "agents/scripts/get-diff-branch.ps1",        "dest": "agents/scripts/get-diff-branch.ps1" }
    /* … remaining get-diff-*.ps1 … */
  ],
  "evals": { "path": "evals/", "status": "none", "lastRun": null }
}
```

`dest` is relative to the consuming repo's `.github/`. For mirror-structured plugins `dest == src`; the `autopilot` plugin sets a single explicit `dest` of `agents/autopilot.agent.md`. `registry.json` additionally stores each file's `sha256` (added by `Build-Registry.ps1`).

## Plugin Inventory

| Plugin | Bundled files (under `plugins/<name>/`) | Depends on | Type(s) |
|--------|------------------------------------------|------------|---------|
| `cr` | `prompts/cr.prompt.md`, `agents/cr.agent.md`, `agents/cr-opus.agent.md`, `agents/cr-codex.agent.md`, `agents/cr-gemini.agent.md`, `agents/scripts/get-diff-*.ps1` (6) | — | prompt + agents + scripts |
| `dr` | `prompts/dr.prompt.md`, `agents/dr.agent.md`, `agents/dr-opus.agent.md`, `agents/dr-codex.agent.md`, `agents/dr-gemini.agent.md` | — | prompt + agents |
| `cip` | `skills/cip/SKILL.md`, `skills/cip/assets/**` | `dr` | skill |
| `ci` | `skills/ci/SKILL.md` | `cr`, `autopilot` | skill |
| `cdn` | `prompts/cdn.prompt.md` | — | prompt |
| `udn` | `prompts/udn.prompt.md` | — | prompt |
| `autopilot` | **plugin payload (installed):** `agents/autopilot.agent.md` only. **Infra prerequisite (NOT installed via confined path, provisioned by `Initialize-Autopilot.ps1` from Plan 001):** `scripts/autopilot/**`, `.devcontainer/autopilot/**`, `.autopilot.json`, `schemas/autopilot.schema.json` | — | agent (+ infra prerequisite) |

> **DR1-#1:** The `autopilot` plugin installs only its `.github/`-confined agent file. Its infrastructure is a separate prerequisite (Plan 001) provisioned outside the confined install path. `ci`'s plugin dependency on `autopilot` is satisfied by the agent file; the `ci` skill preflight-checks that the infra is present before an autonomous run.

## Eval Reservation (seams only — Plan 003 fills these)

- `plugin.json` carries an optional `evals` block: `{ "path": "evals/", "status": "none|passing|failing", "lastRun": null }`. Absent → treated as `none`.
- Reserved author-side folder `plugins/<name>/evals/` (documented, **not populated**). `Install-Plugin` **excludes** `evals/` from copied files (evals are author-side, not installed into consuming repos).
- `registry.json` carries the per-plugin `evals` summary (status only).
- Receipt schema reserves `evalStatus` (unused now).
- `Test-Registry.ps1` includes a warn-only informational check "evals folder present?" — no failure, just surfaces coverage.
- Design note `plugin-registry.design.md` gets an "Evals (future)" section recording this fixed contract so Plan 003 inherits a stable interface.

## Requirements

| ID | Requirement | Acceptance Criteria | Phases/Steps |
|----|-------------|---------------------|--------------|
| REQ-1 | Canonical `plugins/<name>/` layout + `plugin.json` schema | Given the inventory, every plugin has a valid `plugin.json` and mirror-structured files; `schemas/plugin.schema.json` validates them | 1.1, 1.2, 2.1, 2.2 |
| REQ-2 | Migrate existing `.github/` customizations into `plugins/` sources | Each current skill/prompt/agent/script exists byte-identically under `plugins/` (sha256 of source == sha256 of original `.github/` file); `Test-Registry` passes | 2.1a, 2.1b, 2.2 |
| REQ-3 | `Build-Registry.ps1` generates `registry.json` + README catalog | Running it produces `registry.json` from `plugins/*/plugin.json` and regenerates the README catalog table; re-running is idempotent | 3.1, 3.2 |
| REQ-4 | `Install-Plugin.ps1` installs a plugin (+deps) into `.github/` | Installing `ci` also installs `cr` + `autopilot` (agent file); every file lands at its declared `.github/` dest; staged hashes match `registry.json` before move; receipt written with ref+per-file outcomes; `evals/` excluded | 4.1, 4.2, 4.3 |
| REQ-5 | Remote + local source support, ref-coherent | `Install-Plugin -Name cr` clones from GitHub at one resolved SHA; `-Source <path>` installs from a local checkout; against the same commit snapshot both produce byte-identical files and receipts modulo the `source` field (verified by hash) | 4.1, 4.4 |
| REQ-6 | Per-plugin receipts (merge-safe tracking) | After install, `.github/.skillz/receipts/<name>.json` exists with ref + per-file `{dest,sha256,outcome}`; two plugins installed on two branches produce disjoint receipt files (no merge collision) | 4.3 |
| REQ-7 | `Update-Plugin.ps1` upgrades an installed plugin | Update moves to the registry's latest version; user-modified files recorded `skipped-modified` with actual hash unless `-Force`; version advanced only if all files updated else receipt `degraded`; receipt `ref` refreshed | 5.1 |
| REQ-8 | `Remove-Plugin.ps1` uninstalls cleanly | Remove deletes only receipt-listed files whose sha256 matches; warns+keeps modified files unless `-Force`; refuses if another installed plugin depends on it (unless `-Force`); prunes emptied dirs; never deletes unlisted files | 5.2 |
| REQ-9 | `Get-Plugin.ps1` lists catalog + installed state | Lists all registry plugins with version + installed/not-installed + **modified** flag (disk vs receipt hash) + **outdated** flag (receipt vs registry version); `-Installed` filters to receipts | 5.3 |
| REQ-10 | `Find-Plugin.ps1` searches catalog | Searches name/description/tags case-insensitively; returns matches with metadata | 5.4 |
| REQ-11 | Dependency resolution (transitive, cycle-safe) | Installing a plugin pulls deps in correct order; missing dep → clear error; cyclic dep graph → detected + aborted | 4.2 |
| REQ-12 | `bootstrap.ps1` one-liner setup, pinned | The documented one-liner pins an immutable SHA/tag (not `main`); `bootstrap.ps1 -Ref` defaults to that tag; in a fresh repo it fetches verb scripts + `registry.json` into `scripts/skillz/`, creates `.github/.skillz/`, executes no plugin payload, prints next-step guidance | 6.1 |
| REQ-13 | `Test-Registry.ps1` validation rules | Enforces: name+description present, valid semver, deps resolve (no missing/cyclic), **registry-wide dest uniqueness**, registry↔disk no drift, **embedded file sha256 match**, no path-traversal/absolute/UNC/drive-relative/ADS dests, README↔registry match; warn-only evals-present check; `status:partial` plugins exempt from file-existence failure | 3.3, 7.1 |
| REQ-14 | Security: confined, integrity-verified, no code-exec | A `..`/absolute/UNC/drive-relative/ADS dest is rejected via full-path resolution; staged payload verified against `registry.json` hashes before any move; modified file not silently overwritten/deleted; no downloaded content executed; cross-plugin dest collision rejected | 4.5, 5.1, 5.2, 3.3 |
| REQ-15 | skillz dogfoods its own plugins into `.github/` | `.github/` installed copies match `plugins/` sources; CI drift-check passes; VS Code customizations still load | 2.3, 7.2 |
| REQ-16 | Eval reservation seams in place | `plugin.json`/`registry.json`/receipt schemas carry reserved eval fields; `evals/` excluded from install; validate has warn-only eval check; design note documents the contract | 1.2, 4.3, 3.3, 8.1 |
| REQ-17 | Pester tests for all verbs | Tests cover install(+deps)/update/remove/list/search/validate/build against a temp fixture repo; security guards tested; all pass | 7.1 |
| REQ-18 | CI workflow validates registry on PR | GitHub Action runs PSScriptAnalyzer + Pester + `Test-Registry` + dogfood drift-check; fails on any error | 7.2 |
| REQ-19 | Design note + README rewrite | New `plugin-registry.design.md` documents the system; README has Installation (pinned bootstrap) + catalog + usage; `.design-notes.md` index updated | 8.1, 8.2 |
| REQ-20 | Zero lint warnings | `Invoke-ScriptAnalyzer` zero warnings across `scripts/skillz/**` at every phase boundary | 1.3, 4.6, 5.5, 7.1 |
| REQ-21 | `autopilot` plugin obeys confinement; infra provisioned separately | The `autopilot` plugin installs only `agents/autopilot.agent.md`; `Initialize-Autopilot.ps1` provisions infra outside the confined path; installing `ci` succeeds without violating the `.github/` guard | 2.1b, 4.7, 8.1 |
| REQ-22 | Dogfood sync + authority | `plugins/` is authoritative; `Sync-Dogfood.ps1` regenerates `.github/` from `plugins/` and is idempotent; running it makes the CI drift-check pass | 3.4, 7.2 |

## Risks

| ID | Risk | Likelihood | Impact | Mitigation | Steps |
|----|------|------------|--------|------------|-------|
| RISK-1 | Moving `.github/` files to `plugins/` breaks live VS Code customizations mid-migration | Medium | High | Keep `.github/` copies (dogfood); migrate by copy-then-verify, not move; drift-check ties them together | 2.1, 2.3, 7.2 |
| RISK-2 | Agent Skills / Copilot CLI registry spec evolves; our `plugin.json` diverges | Medium | Medium | Keep SKILL.md frontmatter standard (name+description); confine custom metadata to `plugin.json`; document mapping in design note | 1.2, 8.1 |
| RISK-3 | Path-traversal via crafted `files[]` dest writes outside `.github/` | Low | High | Reject `..`/absolute/rooted dests; resolve+verify final path is under `.github/`; unit-test the guard | 4.5, 7.1 |
| RISK-4 | `irm … | iex` bootstrap is an arbitrary-code-execution vector | Medium | High | Pin one-liner to a ref; document reviewing it; bootstrap only fetches reviewable scripts, executes none of the plugin payload; never auto-elevate | 6.1, 8.2 |
| RISK-5 | Receipt hash drift causes destructive update/remove of user edits | Medium | High | Verify sha256 before overwrite/delete; warn+skip modified files unless `-Force`; never delete unlisted files | 4.3, 5.1, 5.2 |
| RISK-6 | Cyclic or missing dependencies cause infinite loop / partial install | Medium | Medium | Topological resolve with visited-set cycle detection; pre-validate full graph before copying any file; transactional rollback on failure | 4.2, 7.1 |
| RISK-7 | `registry.json` ↔ README ↔ `plugins/` drift accumulates | Medium | Medium | Single generator (`Build-Registry.ps1`); CI drift-check fails PRs; generation idempotent | 3.1, 3.2, 7.2 |
| RISK-8 | Cross-branch merge conflicts in tracking state (the original pain point) | Low | Medium | Per-plugin receipt files (one file per plugin) instead of a central lockfile | 4.3, 6.x |
| RISK-9 | Eval seams added now constrain a future harness | Low | Low | Reserve only generic fields/folders; commit to no format; design-note records the contract as provisional | 1.2, 8.1 |
| RISK-10 | Partial install leaves repo in inconsistent state on mid-copy failure | Low | Medium | Transactional: stage on target volume, verify hashes, back up targets, atomic renames, success marker; on error roll back and write no receipt | 4.3, 4.5 |
| RISK-11 | Plan 001 incomplete / autopilot infra absent when 002 executes | Medium | Medium | `autopilot` plugin payload is just the agent file (`status:stable`); infra is a documented prerequisite; `Test-Registry` treats `status:partial` as warn-only; `ci` skill preflights infra at runtime | 2.1b, 4.7, REQ-21 |
| RISK-12 | Two plugins map to the same `.github/` dest → silent overwrite / destructive remove | Medium | High | Registry-wide dest-uniqueness check in `Test-Registry`; runtime ownership map from receipts; abort on collision; no shared-file deletion | 3.3, 4.3 |
| RISK-13 | Compromised ref / MITM yields malicious payload blessed into receipt | Medium | High | `registry.json` embeds trusted per-file sha256; install verifies staged files against it before move; single-SHA coherence; pinned bootstrap ref | 3.1, 4.5, 6.1 |
| RISK-14 | CRLF normalization on Windows clone corrupts hashes → false drift | Medium | High | Clone with `core.autocrlf=false core.eol=lf`; treat payload byte-exact; cross-platform hash-equality test | 4.4, 7.1 |

## Phase 1: Scaffold + Schemas

<!-- worktree: (recorded by /ci when worktree is created) -->

- [x] 1.1 Create `plugins/` root + `scripts/skillz/` root; add `scripts/skillz/_Common.ps1` (`#requires -Version 7.0`; helpers: repo-root resolve, `.github/`-confinement path guard, sha256 helper, semver parse/compare, JSON read/write with stable key order) (REQ-1, REQ-14, RISK-3) `M`
- [ ] 1.2 Add `schemas/plugin.schema.json` (name/version/description/author/license/tags/dependencies/`files[]` as `{src,dest}` objects/optional `status`/reserved `evals`), `schemas/registry.schema.json` (incl. per-file `sha256`), and `schemas/receipt.schema.json` (required `ref` SHA, per-file `{dest,sha256,outcome}`, optional `degraded`, reserved `evalStatus`) (REQ-1, REQ-16, RISK-2, RISK-9) `M`
- [ ] 1.3 Extend `.editorconfig` + `PSScriptAnalyzerSettings.psd1` to cover `scripts/skillz/**`; verify `Invoke-ScriptAnalyzer` clean (REQ-20) `S`

## Phase 2: Migrate Customizations into `plugins/`

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 2.1a Author the simple single/few-file plugins (`cr`, `dr`, `cdn`, `udn`): `plugin.json` (with explicit `files[]` `{src,dest}`) + mirror-structured files copied (not moved) from current `.github/`; verify each source sha256 == original (REQ-1, REQ-2, RISK-1) [after: 1.2] `L`
- [ ] 2.1b Author the skill/agent plugins (`cip`, `ci`, `autopilot`): `cip`+`ci` SKILL.md (+`cip` assets) with dependency edges (`cip→dr`, `ci→cr,autopilot`); `autopilot` `plugin.json` declares ONLY `agents/autopilot.agent.md` as installed payload with `status:partial` until Plan 001 ships (REQ-1, REQ-2, REQ-21, RISK-1, RISK-11) [after: 2.1a] `M`
- [ ] 2.2 Validate every `plugin.json` against `schemas/plugin.schema.json`; confirm dependency edges resolve and registry-wide dest uniqueness holds (REQ-1, REQ-2, RISK-12) [after: 2.1b] `M`
- [ ] 2.3 Confirm `.github/` still holds working copies identical to `plugins/` sources (dogfood baseline); record the dogfood set (`cr`,`dr`,`cip`,`ci`,`cdn`,`udn`,`autopilot`) (REQ-15, REQ-22, RISK-1) [after: 2.1b] `S`

## Phase 3: Registry Index Generation

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 3.1 `scripts/skillz/Build-Registry.ps1`: scan `plugins/*/plugin.json` → generate `registry.json` (incl. **per-file sha256**, reserved `evals` summary, `status`); generate the pinned bootstrap one-liner ref; stable ordering; idempotent (REQ-3, REQ-16, RISK-7, RISK-13) [after: 2.2] `M`
- [ ] 3.2 Extend `Build-Registry.ps1` to (re)generate the README catalog table between markers from `registry.json`; idempotent (REQ-3, RISK-7) [after: 3.1] `M`
- [ ] 3.3 `scripts/skillz/Test-Registry.ps1`: enforce name+description, semver, dependency resolution (missing+cyclic), **registry-wide dest uniqueness**, registry↔disk drift, **embedded sha256 match**, full-path-resolution dest guard (reject `..`/absolute/UNC/drive-relative/ADS), README↔registry match; `status:partial` exempt from file-existence failure; warn-only evals-present check (REQ-13, REQ-14, REQ-16, RISK-3, RISK-6, RISK-7, RISK-12) [after: 3.2] `L`
- [ ] 3.4 `scripts/skillz/Sync-Dogfood.ps1`: regenerate `.github/` dogfood copies from authoritative `plugins/` sources; idempotent; convergence makes the drift-check pass (REQ-22, RISK-1) [after: 3.1] `M`

## Phase 4: Install + Dependency Resolution

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 4.1 `scripts/skillz/Install-Plugin.ps1` (source acquisition only): resolve a single commit SHA; remote shallow-clone-to-temp (`-c core.autocrlf=false -c core.eol=lf --depth 1`) default, `-Source <path>` override; locate plugin in `registry.json`; `finally` temp cleanup (REQ-4, REQ-5, RISK-4, RISK-14) [after: 3.3] `M`
- [ ] 4.2 Dependency resolver in `_Common.ps1`: dedupe by name, topological order with stable lexical tie-breaks, visited-set cycle detection; no-op when already-installed at desired version+hash; pre-validate full graph before any copy; missing/cyclic → abort (REQ-11, RISK-6) [after: 4.1] `M`
- [ ] 4.3 Transactional copy engine: build ownership map from receipts (reject cross-plugin dest collision); stage ALL files for the full dependency set into `.github/.skillz/tmp/` (target volume); verify each staged hash against `registry.json`; back up existing targets; atomic per-file renames in deterministic order; success marker; write receipts (ref + per-file `{dest,sha256,outcome}`, reserved `evalStatus`); **exclude `evals/`** (REQ-4, REQ-6, REQ-14, REQ-16, RISK-5, RISK-8, RISK-10, RISK-12, RISK-13) [after: 4.2] `L`
- [ ] 4.4 Wire remote fetch coherence: clone at the resolved SHA, copy needed plugin dirs, cleanup temp in `finally`; record SHA in receipt; assert remote-vs-local byte equivalence at same commit (REQ-5, RISK-14) [after: 4.1] `M`
- [ ] 4.5 Security hardening + rollback: full-path-resolution dest guard (`..`/absolute/UNC/drive-relative/ADS); verify staged payload against `registry.json` hashes before move; never dot-source/`iex` plugin content; on any failure restore backups, remove staged files, write no receipt (REQ-14, RISK-3, RISK-10, RISK-13) [after: 4.3] `M`
- [ ] 4.6 Install-phase lint pass: `Invoke-ScriptAnalyzer` zero warnings (REQ-20) [after: 4.5] `S`
- [ ] 4.7 `scripts/skillz/Initialize-Autopilot.ps1`: provision autopilot infra (from Plan 001) OUTSIDE the confined install path; `ci` skill preflight invokes/checks it; idempotent; clear error if Plan 001 infra absent (REQ-21, RISK-11) [after: 4.5] `M`

## Phase 5: Update / Remove / List / Search

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 5.1 `scripts/skillz/Update-Plugin.ps1`: resolve single SHA; compare receipt version vs registry; verify existing file hashes (record `skipped-modified` with actual hash unless `-Force`); replace updated files; advance version only if all files updated else mark receipt `degraded`; refresh receipt `ref` (REQ-7, REQ-14, RISK-5) [after: 4.6] `M`
- [ ] 5.2 `scripts/skillz/Remove-Plugin.ps1`: delete only receipt-listed files whose sha256 matches (warn+keep modified unless `-Force`); refuse if a dependent installed plugin needs it (unless `-Force`); prune empty dirs; delete receipt; never touch unlisted files (REQ-8, REQ-14, RISK-5) [after: 4.6] `M`
- [ ] 5.3 `scripts/skillz/Get-Plugin.ps1`: list registry plugins with version + installed state (from receipts) + **modified** flag (disk vs receipt hash) + **outdated** flag (receipt vs registry version); `-Installed` filter (REQ-9, REQ-6) [after: 4.6] `M`
- [ ] 5.4 `scripts/skillz/Find-Plugin.ps1`: case-insensitive search over name/description/tags in `registry.json`; return matches with metadata (REQ-10) [after: 3.2] `S` <!-- parallelizable with Phase 4: only reads registry.json -->
- [ ] 5.5 Verbs lint pass: `Invoke-ScriptAnalyzer` zero warnings across update/remove/list/search (REQ-20) [after: 5.1, 5.2, 5.3, 5.4] `S`

## Phase 6: Bootstrap

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 6.1 `scripts/skillz/bootstrap.ps1`: `#requires -Version 7.0`; `-Ref` param (default = pinned tag from `Build-Registry`); fetch verb scripts + `registry.json` from the pinned ref into consuming repo's `scripts/skillz/`; create `.github/.skillz/`; print next-step guidance; execute no plugin payload (REQ-12, RISK-4, RISK-8, RISK-13) [after: 4.6] `M`

## Phase 7: Tests + CI

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 7.1 Pester suite (`tests/skillz/`) against a temp fixture repo: install(+transitive deps, diamond graph exactly-once, all-or-nothing rollback), update (modified-file skip, degraded marking), remove (dependent-block + hash guard), list/search, build idempotency, `Test-Registry` rule coverage, dest-collision rejection, path-traversal rejection (`..`/absolute/UNC/drive-relative/ADS), registry-hash mismatch abort, cross-platform hash-equality; lint clean (REQ-17, REQ-13, REQ-14, REQ-20, RISK-3, RISK-6, RISK-10, RISK-12, RISK-13, RISK-14) [after: 5.5, 6.1] `L`
- [ ] 7.2 `.github/workflows/registry-ci.yml`: PSScriptAnalyzer + Pester + `Test-Registry` + dogfood drift-check (`.github/` == `plugins/` via `Sync-Dogfood -WhatIf`) + README↔registry check; matrix ubuntu+windows (REQ-18, REQ-15, REQ-22, RISK-1, RISK-7, RISK-14) [after: 7.1] `M`

## Phase 8: Docs

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 8.1 Create `docs/design-notes/architecture/plugin-registry.design.md`: bundle model, layout, `plugin.json`/`registry.json`/receipt schemas, dependency resolution, transactional install + integrity model, autopilot plugin-vs-infra split, dogfood authority + `Sync-Dogfood`, security model, **Evals (future) contract**; add row to `.design-notes.md` index (REQ-19, REQ-16, REQ-21, REQ-22, RISK-2, RISK-9) [after: 7.2] `M`
- [ ] 8.2 Rewrite `README.md`: Installation (bootstrap one-liner + review guidance), generated plugin catalog, usage examples (install/update/remove/list/search), security note on `irm | iex` (REQ-19, RISK-4) [after: 8.1] `M`

## Notes

- Depends on **Plan 001** (the `autopilot` plugin bundles its infra; `ci`→`autopilot`). Until 001 ships, the `autopilot` plugin's infra files are placeholders/partial.
- Eval harness (runner, scoring, fixtures, CI gating) is deferred to a future **Plan 003**; this plan only reserves the seams.
