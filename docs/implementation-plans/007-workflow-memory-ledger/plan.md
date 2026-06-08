# 007: Workflow-Memory Ledger & Learning Capture

<!-- execution-mode: container-autopilot -->
<!-- scope: phase -->
<!-- phase-budget-points: 6 -->
<!-- evidence: required -->
<!-- depends-on: 006 -->
<!-- cip-stage: dr-round-3 -->

> Builds the **repo-scoped self-improving feedback loop** on plan 006's enforcement spine. Every interview decision, `dr`/`cr` finding, and execution surprise is captured during a run and, **at harvest**, distilled into a durable **workflow-memory ledger** under `docs/review-ledger/` that `cip` (before drafting) and `ci`/autopilot (before a review round) read back — so each run in a repo gets more reliable. **Architecture (rounds 1–3):** mid-run, orchestrators write only to per-plan **ephemeral logs** (`evolution-log.md`/`cr-log.md`/`learnings.md`), each **initialized + committed every phase by name** (with an explicit empty-state line so harvest can tell "intentionally empty" from "forgotten"); the durable ledger is written only at **harvest** via pre-approvable scripts `Add-LedgerEntry.ps1` (append + dedup) and `Remove-LedgerEntry.ps1` (script-mediated prune). Harvest is **two-branch**: an **append phase that always runs + commits before** the autonomous-vs-escalate decision (the loop must populate even on clean autonomous completions and survive `exit 42`), and a **prune + `/udn` phase gated to the `@human` escalation branch** (destructive/judgment work needs a reviewer). The procedure is hosted in **`autopilot.agent.md`** (autopilot never loads `ci` assets) — **guarded by a `Test-Path` presence check** so downstream installs lacking the repo-infra scripts fall through to standard finalization — with a parallel **host/interactive `/ci` trigger** (006's container-only finalization would otherwise leave the off-container loop dead). **Cross-cutting principle (from 006):** every ledger mutation goes through a pre-approvable `.ps1`, invoked via **argument arrays** — never an LLM-improvised string edit or shell-interpolated command. Depends on 006; a hard phase-0 start-gate (container Pester test **and** an off-container non-Pester check) blocks 007 if 006 hasn't landed.

## Decisions

### Two-branch harvest, single durable-write path (rounds 1–3)

- **Mid-run = ephemeral only; durable ledger = harvest only.** "Five live feeders writing the ledger" was mechanically broken (no `execute` tool on `dr`/`cr`; autopilot vs Rule 5; standalone `cr` no plan id; double-writes). Mid-run, orchestrators append only to ephemeral logs; the ledger is written only at harvest.
- **Explicit two-branch finalization (round-3 #1).** 006's Finalization has two outcomes. The **append phase** (`Add-LedgerEntry`, deterministic, append-only) runs + **commits before** the branch, so the ledger populates on every completion and survives `exit 42`. Then:
  - **Autonomous branch:** `append-harvest → commit → push → archive-commit → push → gh pr create`. Archive + real PR are **autonomous-only**; the second push guarantees the PR head includes the archive commit.
  - **Escalation branch (`@human`):** `append-harvest → commit → push → Remove prune + /udn reconciliation → commit pruned ledger + design-note edits → push → gh pr create --draft → write marker → exit 42`. **Never archives.** The post-prune push guarantees escalation edits aren't left uncommitted before `exit 42`.
- **`/udn` under autopilot (round-2 #19)** is an inline reconciliation routing to draft-PR + exit 42, never a silent no-op.

### Harvest hosting: agent + host trigger, guarded, with a canonical source (rounds 2–3)

- **Procedure lives in `autopilot.agent.md`** (autopilot never loads `ci` assets). Under container-autopilot the agent runs the append phase at completion.
- **Downstream-install guard (round-3 #2).** `autopilot.agent.md` is plugin payload synced into downstream repos; the `scripts/skalary/*.ps1` + `docs/review-ledger/` are repo infra in **no** manifest. The harvest block is wrapped in `if (Test-Path scripts/skalary/Add-LedgerEntry.ps1)` (and the ledger root); when absent it **falls through to standard archive/push/PR**, so downstream finalizations never crash.
- **Host/interactive trigger (round-2 #4).** A parallel **`/ci`-invoked harvest at interactive plan completion** runs the same Add/Remove scripts (append always; prune + `/udn` with the user present), documented in `ci`'s `crosscheck-guide.md`.
- **Canonical source + mirror (round-3 #9).** Autopilot and `ci` can't share an asset, so the orchestration/branch prose is duplicated. `autopilot.agent.md` is the **canonical** harvest spec; `crosscheck-guide.md` carries a **mirror** marked as such, plus a parity note pointing at the canonical source. Only the `Add`/`Remove` scripts are the genuinely shared mechanism.
- **Fail-loud, distinguishing empty from forgotten (round-2 #5 + round-3 #7).** Each phase initializes + commits its ephemeral logs **by name** with a stable header and an explicit empty-state line (`No entries for this phase.`); harvest fails loud only on a **missing placeholder/section**, not on a legitimately empty run.

### Ledger store + taxonomy

- **Per-category files** under `docs/review-ledger/`: `security`, `performance`, `error-handling`, `consistency`, `plan-structure`, `testing`, `observability`, + `README.md`. Tombstoned/pruned entries move to **`docs/review-ledger/.archive/`** (round-2 #12), which readers never enumerate. **Never auto-loaded**; consulted on demand.
- **Entry format:** `- [YYYY-MM-DD] <one-line lesson> (plan-NNN, src:cip|dr|cr|code-review|ci|autopilot, sev:Critical|High|Med|Low) #tags`. `Critical` is first-class (round-1 #15).

### `Add-LedgerEntry.ps1` — pre-approvable, sanitized, concurrency-safe

- **Strict inputs:** `-Category`/`-Src`/`-Severity` (incl. `Critical`) `ValidateSet`; path built from the validated lowercase slug only + repo-root confined (reuse 006's helper).
- **Sanitization (round-2 #18 + round-3 #6):** `-Entry`/`-Tags` are untrusted; strip the **full Unicode line-break set** (U+000A–U+000D, U+0085 NEL, U+2028 LS, U+2029 PS, VT/FF) + control chars, collapse whitespace, cap length, **and neutralize the schema's structural delimiters** (`(` `)` `,` `#`, `src:`/`sev:`) so the script alone emits trusted metadata — a one-line `-Entry` can't forge `(plan-999, sev:Critical)` or split into two parseable lines. Fail loud on malformed input.
- **`normalized-lesson` (round-2 #14)** is defined deterministically: trim, invariant-lowercase, collapse internal whitespace, standardize punctuation, NFC Unicode, cap *after* normalization. Both dedup keys derive from it.
- **Two dedup keys (round-1 #8):** idempotence/skip key = `category + normalized-lesson + plan + src + severity + sorted-tags` (date excluded → same-stage retry skipped); recurrence key = `category + normalized-lesson + sorted-tags` (plan/src/date excluded). Recurrence is **annotate-only** as an **immutable append** (round-2 #8); prior-plan lines are **never mutated**, so re-running harvest is idempotent. The recurrence **count** (round-2 #9) = a pure scan over **active** entries (excludes `.archive/`) by recurrence key.
- **Concurrency (round-2 #13 + round-3 #13):** the read-dedup-write critical section runs under a **workspace-scoped** mutex + temp-file atomic replace (single-worktree async). Cross-worktree parallel runs collide at **git-merge**; `Add` is **idempotent on replay** with deterministic entry ordering, so re-running it post-merge re-canonicalizes the file (documented "re-run `Add` to resolve").
- **Invocation (round-2 #10):** the agent calls the script via **argument arrays / `Start-Process -ArgumentList`** — never a string-interpolated shell line.
- `#requires -Version 7.0`, PSScriptAnalyzer-clean, repo-root-relative via `$PSScriptRoot`/`-RepoRoot`.

### `Remove-LedgerEntry.ps1` — script-mediated prune (rounds 1–3)

- `Remove-LedgerEntry.ps1 -Category -Match <normalized-line>` with **full-line equality** `[string]::Equals($line, $Match, [StringComparison]::Ordinal)` (round-3 #10) — *not* substring `-SimpleMatch`; "SimpleMatch" describes only the regex-disabled property. Same `-Category` `ValidateSet` + repo-confined slug→path as `Add` (round-3 #11).
- Deletes under the same lock; **moves to `.archive/`** rather than hard-delete; emits a **visible diff**.
- **Retention guard:** never prune current-plan entries or entries whose active recurrence count is above threshold (the severity-escalation evidence).
- **Escalation-branch purpose (round-3 #3):** prune **tombstones prior-plan entries that `/udn` reconciliation flags obsolete/superseded**; current-plan + above-threshold entries stay guard-protected. (The append phase wrote only current-plan entries, which are therefore never the prune target.)

### Capture (ephemeral) + readers

- **`cr-log.md` per mode (round-1 #11):** interactive `ci` writes the `@cr` report + triage; autopilot writes `code-review`/`rubber-duck` findings (`src:code-review`). **Standalone `cr`** persists nothing (round-1 #12).
- **`learnings.md` triggers + hard cap (round-1 #17 + round-2 #20):** append only on (a) rework > 1 iteration, (b) plan-contradicting surprise, (c) reusable pattern; each carries **trigger-type + source step**; a **hard per-plan cap** with explicit overflow (fold into a summary entry).
- **`evolution-log.md` (round-2 #17):** capture writes go to a **delimited `## Capture` section with a parsed schema**, separate from the DR-round history.
- **Readers (round-1 #13 + round-2 #16):** `cip` before drafting uses the **full 7-category mapping rubric** (keyword/REQ-class → file) in `drafting-guide.md`, loading only relevant small files (optional `#tag` filter), **excluding `.archive/`**. `ci`/autopilot consult before a CR round.

### Dependency preflight as a hard start-gate (round-2 #2/#7 + round-3 #5)

- **`depends-on: 006`** enforced by a **phase-0 start-gate**, not an end-check, in **two forms**: a container Pester test (`Skalary.Dependency.Plan006Present`) **and** an off-container **non-Pester hard-failing script check** wired into both the `/ci` harvest entry and the autopilot runner's plan-start hook — because `npm run test:unit` *skips* when Pester is absent (host/interactive), exactly where `Add` still hard-depends on a 006 helper.
- Both assert 006 **behaviorally**: resolve the `file:` evaluator through the public path 007 uses (`Get-Command`/module export OR `(Get-Command Test-Plan).Parameters.ContainsKey('VerifyEvidence')`) + probe a known pass/fail — not a hard-coded filename (006 ships it as `PlanEvidence.psm1` *or* a `-VerifyEvidence` param set). Every 006-touching step carries `[after: 0.1]`.

### Misc

- **Evidence markers** use `file:`/`test:` on produced artifacts; `review:` only for absence claims (round-1 #14). Autopilot-side markers are **behavior-specific** (round-3 #4): they anchor on text the change introduces (`cr-log`, `learnings`, `ephemeral logs by name`, `ArgumentList`, `Test-Path scripts/skalary`), not words already present.
- **Ledger + scripts are repo infra**, in no `plugin.json`. **Manifest scope (round-2 #21):** only `cip`/`ci` assets + the `autopilot` agent are edited — **not** `dr`/`cr` agents. Adding wiring to existing assets changes content, not `files[]` membership, so the registry step is **verification** (round-3 #12).
- **Stateless review subagents never write.** **Roles:** all `@ai-agent`. **Execution-mode:** container-autopilot, phase scope.

## Requirements

| ID | Requirement | Acceptance Criteria (with typed evidence) | Phases/Steps |
|----|-------------|--------------------------------------------|--------------|
| REQ-1 | Ledger store + README (taxonomy, format, dedup keys, `normalized-lesson`, recurrence count, retention, `.archive/` location) | Seven category files + `README.md` documenting all of the above + "never auto-load, consult on demand"; `.archive/` reserved for tombstones. `file:docs/review-ledger/README.md#contains:recurrence` · `file:docs/review-ledger#dircount>=8` | 1.1 |
| REQ-2 | `Add-LedgerEntry.ps1` appends + dedups (defined keys + `normalized-lesson`) + immutable recurrence append (idempotent re-run) | Skips an idempotence-key duplicate; a later plan's same lesson is appended (not skipped) with a recurrence marker; prior lines never mutated; harvest re-run is idempotent. `test:Add-LedgerEntry.Dedup` · `test:Add-LedgerEntry.RecurrenceNotSkipped` · `test:Add-LedgerEntry.RecurrenceReRunIdempotent` | 1.2, 1.3, 6.4 |
| REQ-3 | `Add-LedgerEntry.ps1` sanitizes untrusted text (full Unicode line-break set + structural-metadata forgery) + ValidateSet enums incl. `Critical` + confined path | All Unicode line breaks (U+000A–U+000D/0085/2028/2029/VT/FF) + control stripped, structural delimiters (`( ) , #`, `src:`/`sev:`) neutralized, length capped, fail-loud; `-Category`/`-Src`/`-Severity` `ValidateSet`; path from validated slug + repo-confined. `test:Add-LedgerEntry.SanitizesUnicodeBreaks` · `test:Add-LedgerEntry.RejectsForgery` · `test:Add-LedgerEntry.RejectsBadCategory` | 1.2, 1.3 |
| REQ-4 | `Add-LedgerEntry.ps1` is concurrency-safe + merge-idempotent | Workspace-scoped mutex + temp-file replace; idempotent on replay; a real 3-way merge fixture of two divergent appends equals a single canonicalizing re-run. `test:Add-LedgerEntry.ConcurrentAppend` · `test:Add-LedgerEntry.ThreeWayMergeReplay` | 1.2, 1.3 |
| REQ-5 | `Remove-LedgerEntry.ps1` full-line-equality prune + confined `-Category` + retention guard + `.archive/` tombstone + diff | `-Match` is full-line `Ordinal` equality (not substring); `-Category` uses the same ValidateSet + confined resolution; deletes under lock; moves to `.archive/`; visible diff; never prunes current-plan or above-active-recurrence-threshold; targets prior-plan `/udn`-flagged entries; no over-deletion incl. substring-collision. `test:Remove-LedgerEntry.FullLineEquality` · `test:Remove-LedgerEntry.RejectsBadCategory` · `test:Remove-LedgerEntry.RetentionGuard` · `test:Remove-LedgerEntry.NoSubstringOverDelete` | 2.1, 2.2, 6.4 |
| REQ-6 | Single durable-write path; explicit two-branch finalization (append always; prune+`/udn` escalation-only); ordered with required pushes | Mid-run writes only ephemeral logs; `Add` runs+commits before the branch; autonomous = archive+real-PR with post-archive push; escalation = prune+`/udn`+post-prune push+draft-PR+marker+exit 42, never archives. `file:plugins/autopilot/agents/autopilot.agent.md#contains:harvest` · `review:dr` | 3.1, 3.2, 3.3, 5.1 |
| REQ-7 | `cr-log.md` per mode + `learnings.md` triggers/hard-cap with trigger-type+source-step | Interactive `ci`→`@cr`; autopilot→`code-review` (`src:code-review`); standalone `cr` persists nothing; `learnings.md` appends only on the 3 triggers, each tagged trigger-type+source step, bounded by a hard cap + overflow policy. `file:plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md#contains:cr-log` · `file:plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md#contains:trigger` | 3.1, 3.2 |
| REQ-8 | `cip`/`dr` capture to a delimited `## Capture` section of `evolution-log.md` | Capture uses a parsed schema in its own section, separate from DR-round history; wired into 006's `drafting-guide`/`dr-guide`. `file:plugins/create-implementation-plan/skills/cip/assets/dr-guide.md#contains:Capture` · `review:cr` | 3.3 |
| REQ-9 | Ephemeral logs initialized + committed per phase by name with empty-state placeholders; harvest fails-loud on missing section | Each phase stages+commits `cr-log.md`/`learnings.md`/`evolution-log.md` by name (Rule-3 compliant) with a stable header + `No entries for this phase.` when empty; harvest aborts loudly only on a missing placeholder/section. `file:plugins/autopilot/agents/autopilot.agent.md#contains:ephemeral logs by name` · `file:plugins/autopilot/agents/autopilot.agent.md#contains:No entries for this phase` | 3.1, 3.2, 3.3, 5.1 |
| REQ-10 | Readers consult the ledger on demand via the full 7-category rubric, excluding `.archive/` | `cip` maps plan REQs/risks → category files using a documented 7-category rubric before drafting; `ci`/autopilot consult before a CR round; neither enumerates `.archive/`. `file:plugins/create-implementation-plan/skills/cip/assets/drafting-guide.md#contains:ledger-consult` · `file:plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md#contains:ledger-consult` | 4.1, 4.2 |
| REQ-11 | Harvest in `autopilot.agent.md`, `Test-Path`-guarded, argument-array invocation, Rule-5 carve-out, `/udn` defined | Finalization runs the harvest only when repo infra is present (`Test-Path scripts/skalary/Add-LedgerEntry.ps1`), else falls through to standard finalization; invokes `Add`/`Remove` via argument arrays; Rule 5 authorizes both scripts; `/udn`→draft-PR+exit 42. `file:plugins/autopilot/agents/autopilot.agent.md#contains:Test-Path scripts/skalary` · `file:plugins/autopilot/agents/autopilot.agent.md#contains:ArgumentList` | 5.1 |
| REQ-12 | Host/interactive harvest trigger as a marked mirror with parity note | `/ci` at interactive plan completion runs the same shared Add/Remove harvest (append always; prune+`/udn` with user present); `crosscheck-guide.md` carries it as a **mirror** of the canonical `autopilot.agent.md` spec with a parity note. `file:plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md#contains:harvest` · `file:plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md#contains:mirror` | 5.2 |
| REQ-13 | Enforceable 006 preflight as a hard phase-0 start-gate, container Pester + off-container non-Pester | Container Pester test + an off-container non-Pester hard-fail check both resolve 006's evaluator via the public path (accepts `.psm1` OR `-VerifyEvidence`) + probe pass/fail; wired into the runner plan-start + `/ci` harvest entry; 006-touching steps gated `[after: 0.1]`. `test:Skalary.Dependency.Plan006Present` · `file:plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md#contains:preflight` | 0.1, 6.4 |
| REQ-14 | Repo-root-relative script invocation (source/synced/container) | Scripts resolve paths via `$PSScriptRoot`/`-RepoRoot`. `file:scripts/skalary/Add-LedgerEntry.ps1#contains:PSScriptRoot` · `review:cr` | 1.2 |
| REQ-15 | Design notes + index updated | `copilot-customizations` (two-branch harvest loop, ephemeral capture, readers), `plan-workflow` (taxonomy + key contract + Add/Remove scripts), `autopilot-execution` (harvest in agent, `Test-Path` guard, Rule-5 carve-out, branch ordering), `.design-notes.md` index. `file:docs/design-notes/.design-notes.md#contains:review-ledger` · `review:dr` | 6.1 |
| REQ-16 | Registry rebuilt + dogfood holds; ledger infra excluded; manifest scope verified | Confirm no `files[]` delta is needed (assets already registered by 006) and that `docs/review-ledger/**` + both scripts are in **no** manifest (not `dr`/`cr`); `Build-Registry.ps1` + `Sync-Dogfood.ps1 -WhatIf` show only intended changes; `Test-Registry.ps1` passes. `test:Skalary.Registry.NoDrift` · `review:cr` | 6.2, 6.3 |

## Risks

| ID | Risk | Likelihood | Impact | Mitigation | Steps |
|----|------|------------|--------|------------|-------|
| RISK-1 | Ledger noise/bloat pollutes drafting context | Medium | Medium | Per-category small files; one-line entries; on-demand consult (never auto-load); dedup; prune to `.archive/`; tag/sev filtering | 1.1, 4.1, 4.2 |
| RISK-2 | Capture writes balloon token/time cost | Low | Medium | Ephemeral-log appends only mid-run; defined triggers + hard cap; harvest once at finalization | 3.2 |
| RISK-3 | 007 starts before 006 lands its assets/contracts | Medium | High | `depends-on: 006` + hard phase-0 start-gate (container Pester + off-container non-Pester, behavioral); all 006-touching steps `[after: 0.1]` | 0.1 |
| RISK-4 | `Add-LedgerEntry.ps1` mis-routes category / corrupts file under concurrency | Low | Medium | Slug `ValidateSet`; repo-confined path; workspace-scoped mutex + temp-replace; merge-replay idempotence; Pester coverage | 1.2, 1.3 |
| RISK-5 | Untrusted text forges a ledger line (Unicode break or in-line metadata) | Medium | High | Strip full Unicode line-break set + neutralize structural delimiters + cap + fail-loud; forgery tests | 1.2, 1.3 |
| RISK-6 | Prune destroys recurrence evidence, over-deletes, or runs unsupervised | Medium | High | Full-line `Ordinal` match; retention guard (active recurrence count); prior-plan-only target; `.archive/` tombstone + diff; prune only on the reviewed `@human` branch | 2.1, 2.2, 5.1 |
| RISK-7 | Double-write or autonomous/escalation conflation (archive on escalated run) | Medium | High | Single durable path; append before branch; explicit two-branch finalization with archive autonomous-only + required pushes (REQ-6) | 3.1, 5.1 |
| RISK-8 | Category path traversal via interpolated path | Low | Medium | `ValidateSet` slug + path from slug only + reuse 006's confinement on both `Add` and `Remove`; traversal tests | 1.2, 2.1 |
| RISK-9 | Adding wiring without `plugin.json` breaks dogfood byte-equivalence | Medium | Medium | REQ-16 rebuild + `Sync-Dogfood -WhatIf` + `Test-Registry`; correct manifest scope; ledger infra excluded | 6.2, 6.3 |
| RISK-10 | Off-container loop dead / harvest in an asset autopilot never loads | Medium | High | Harvest procedure in `autopilot.agent.md`; parallel host/interactive `/ci` trigger; same shared scripts; canonical-source + mirror | 5.1, 5.2 |
| RISK-11 | Ephemeral logs never committed, or clean phase hard-fails harvest | Medium | High | Per-phase stage+commit by name with empty-state placeholders; harvest fails-loud only on missing section | 3.1, 3.2, 3.3 |
| RISK-12 | Rule-5 carve-out enables shell injection / cross-worktree merge collision | Medium | High | Argument-array invocation (no shell string); workspace-scoped mutex; merge-replay idempotence + deterministic ordering | 1.2, 5.1 |
| RISK-13 | Harvest block crashes downstream autopilot installs lacking the repo-infra scripts/ledger | Medium | High | `Test-Path` presence guard around the harvest block → fall through to standard finalization when absent | 5.1 |

## Phase 0: 006 dependency start-gate
<!-- worktree: (recorded by /ci when worktree is created) -->
<!-- Points: 1 = 1 -->

- [x] 0.1 Add `tests/skalary/Dependency.Tests.ps1` (`Skalary.Dependency.Plan006Present`) **and** an off-container non-Pester check both asserting 006 **behaviorally** (resolve the `file:` evaluator via the public path — `Get-Command`/module export OR `(Get-Command Test-Plan).Parameters.ContainsKey('VerifyEvidence')` — + probe a known pass/fail; assert the guides, amended Rule 5, evidence vocab, `test:unit` gate). Wire the non-Pester check into the autopilot runner plan-start hook + the `/ci` harvest entry as a **hard start-gate** (hard-fail/exit if 006 absent), independent of skip-on-absent `test:unit`. (REQ-13, RISK-3) `S`

## Phase 1: Ledger store + append script + tests
<!-- worktree: (recorded by /ci when worktree is created) -->
<!-- Points: 2+3+2 = 7 → over 6 cap (advisory); cohesive store + append + its tests -->

- [x] 1.1 Create `docs/review-ledger/README.md` (seven-category taxonomy; entry format; `normalized-lesson` rules; idempotence-vs-recurrence keys; recurrence-count over active entries; retention/prune rules; `.archive/` tombstone location; "never auto-load, consult on demand") + seven empty category stubs + a `.archive/` placeholder. (REQ-1, RISK-1) `M`
- [x] 1.2 Create `scripts/skalary/Add-LedgerEntry.ps1` (`#requires -Version 7.0`, PSScriptAnalyzer-clean, repo-root-relative via `$PSScriptRoot`/`-RepoRoot`): `-Category`/`-Src`/`-Severity` (incl. `Critical`) `ValidateSet`; `-Entry`/`-Tags` sanitized (strip **full Unicode line-break set** U+000A–U+000D/0085/2028/2029/VT/FF + control, **neutralize structural delimiters** `( ) , #`/`src:`/`sev:`, cap, fail-loud); path from validated slug + repo-confined (006 helper); `normalized-lesson` normalization; append + idempotence-key dedup + **immutable recurrence append** (idempotent re-run); **workspace-scoped mutex** + temp-file atomic replace + deterministic ordering for merge-replay idempotence. (REQ-2, REQ-3, REQ-4, REQ-14, RISK-4, RISK-5, RISK-8, RISK-12) `L`
- [x] 1.3 Add `tests/skalary/Add-LedgerEntry.Tests.ps1` (dedup; recurrence-not-skipped; recurrence-re-run-idempotent; sanitize Unicode breaks + structural forgery; bad-category; concurrent append; **3-way merge fixture** vs single canonicalizing re-run; `normalized-lesson`) wired into `npm run test:unit`. (REQ-2, REQ-3, REQ-4, RISK-4, RISK-5) [after: 1.2] `M`

## Phase 2: Prune script + tests
<!-- worktree: (recorded by /ci when worktree is created) -->
<!-- Points: 2+2 = 4 -->

- [x] 2.1 Create `scripts/skalary/Remove-LedgerEntry.ps1` (`-Category -Match <normalized-line>`, **full-line `[string]::Equals(...,Ordinal)`**, regex disabled; same `-Category` ValidateSet + repo-confined resolution as `Add`): delete under the same lock; **move to `.archive/`** (not hard-delete); retention guard (never prune current-plan or above-active-recurrence-threshold; target prior-plan `/udn`-flagged obsolete entries); emit a visible diff. (REQ-5, RISK-6, RISK-8) [after: 1.2] `M`
- [x] 2.2 Add `tests/skalary/Remove-LedgerEntry.Tests.ps1` (full-line equality; rejects bad category; retention guard refuses current-plan even when matched; `.archive/` excluded from readers; no substring over-deletion) wired into `npm run test:unit`. (REQ-5, RISK-6) [after: 2.1] `M`

## Phase 3: Ephemeral capture mid-run (committed per phase)
<!-- worktree: (recorded by /ci when worktree is created) -->
<!-- Points: 1+1+1 = 3 -->

- [x] 3.1 Add `cr-log.md` persistence per mode + per-phase init/commit-by-name (stable header + `No entries for this phase.` placeholder) to `ci`/autopilot: interactive `ci`→`@cr` report+triage; autopilot→`code-review`/`rubber-duck` (`src:code-review`); standalone `cr` persists nothing. No durable ledger write here. (REQ-7, REQ-9, REQ-6, RISK-7, RISK-11) [after: 0.1] `S`
- [x] 3.2 Add `learnings.md` capture (triggers + hard cap + trigger-type/source-step) + per-phase init/commit-by-name with placeholder to `ci`/autopilot crosscheck guide: append only on rework>1 / plan-contradicting surprise / reusable pattern; hard per-plan cap with overflow→summary. (REQ-7, REQ-9, REQ-6, RISK-2, RISK-11) [after: 0.1] `S`
- [x] 3.3 Wire `cip`/`dr` capture into 006's `drafting-guide.md`/`dr-guide.md`: record interview decisions + notable/recurring `dr` findings to a **delimited `## Capture` section** of `evolution-log.md` (own schema, separate from DR-history); init/commit the section by name with a placeholder. (REQ-8, REQ-9, REQ-6, RISK-11) [after: 0.1] `S`

## Phase 4: Readers consult the ledger
<!-- worktree: (recorded by /ci when worktree is created) -->
<!-- Points: 1+1 = 2 -->

- [x] 4.1 Add `ledger-consult` to `cip` `drafting-guide.md`: a **full 7-category mapping rubric** (keyword/REQ-class → file) loading only relevant small files (optional `#tag` filter), **excluding `.archive/`**. (REQ-10, RISK-1) [after: 0.1, 1.1] `S`
- [x] 4.2 Add `ledger-consult` to `ci`/autopilot crosscheck guide: consult relevant category files before a CR round, excluding `.archive/`. (REQ-10, RISK-1) [after: 0.1, 1.1] `S`

## Phase 5: Harvest — guarded, two-branch, dual-host
<!-- worktree: (recorded by /ci when worktree is created) -->
<!-- Points: 3+2 = 5 -->

- [x] 5.1 Implement the **canonical** harvest procedure in `autopilot.agent.md`'s Finalization handling, wrapped in `if (Test-Path scripts/skalary/Add-LedgerEntry.ps1)` (else fall through to standard archive/push/PR): **append phase** (`Add-LedgerEntry` distilling `evolution-log`/`cr-log`/`learnings`, staging `docs/review-ledger/*` by name) runs + commits **before** the branch; then **autonomous branch** (commit→push→archive-commit→push→`gh pr create`) vs **escalation branch** (commit→push→`Remove`+`/udn`→commit→push→`gh pr create --draft`→marker→exit 42, never archive); invoke both scripts via **argument arrays** (no shell string); amend Absolute Rule 5 to authorize both by name; fail-loud only on a missing log section. (REQ-6, REQ-11, REQ-9, RISK-6, RISK-7, RISK-10, RISK-12, RISK-13) [after: 0.1, 1.2, 2.1, 3.1, 3.2, 3.3] `L`
- [x] 5.2 Add the host/interactive harvest trigger to `ci` `crosscheck-guide.md` as a **mirror** of the canonical spec (with a parity note pointing at `autopilot.agent.md`): `/ci` at interactive plan completion runs the same shared `Add`/`Remove` harvest (append always; prune+`/udn` with the user present). (REQ-12, REQ-11, RISK-10) [after: 5.1] `M`

## Phase 6: Design notes + registry + verification
<!-- worktree: (recorded by /ci when worktree is created) -->
<!-- Points: 2+1+1+1 = 5 -->

- [x] 6.1 Design notes: update `copilot-customizations.design.md` (two-branch harvest loop, ephemeral capture, readers), `plan-workflow.design.md` (taxonomy + dedup-key contract + `Add`/`Remove` scripts), `autopilot-execution.design.md` (harvest in agent, `Test-Path` guard, Rule-5 carve-out, branch ordering); add the `docs/review-ledger` reference to the `.design-notes.md` index. (REQ-15) [after: 5.1, 5.2] `M`
- [x] 6.2 Verify manifest scope: confirm **no `files[]` delta** is required (touched assets already registered by 006) and that `docs/review-ledger/**` + `Add-LedgerEntry.ps1` + `Remove-LedgerEntry.ps1` are in **no** manifest (not `dr`/`cr`). (REQ-16, RISK-9) [after: 3.1, 3.3, 5.1, 5.2] `S`
- [x] 6.3 Rebuild + verify: `Build-Registry.ps1`; `Sync-Dogfood.ps1 -WhatIf` shows only intended changes; `Test-Registry.ps1` passes. (REQ-16, RISK-9) [after: 6.2] `S`
- [x] 6.4 Quality gate: `Invoke-ScriptAnalyzer -Settings PSScriptAnalyzerSettings.psd1` zero warnings on `Add-LedgerEntry.ps1` + `Remove-LedgerEntry.ps1`; `npm run test:unit` green (incl. the dependency start-gate); `npm run validate-plan` green on 007. (REQ-2, REQ-5, REQ-13) [after: 1.3, 2.2, 5.1] `S`
