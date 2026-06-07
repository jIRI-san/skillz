# Crosscheck Guide (`ci` Step 6)

> Read this asset when validating phase/plan completion and proving requirements with typed evidence.

## Evidence verification

At phase and plan crosschecks, verify each requirement's typed markers from Acceptance Criteria:
- `test:<TestId>` -> run only the named Pester test and fail if the test is missing or failing.
- `file:<path>#<assertion>` -> verify via `scripts/skalary/Test-Plan.ps1 -EvidenceMarker ...` (which delegates to the dot-sourceable `PlanEvidence` callable).
- `review:cr|dr` -> verify the relevant review run reports no remaining findings for the claimed class (`cr` or `dr`).

Use deterministic, pre-approvable commands only. Parse markers into typed variables and pass them as bound arguments (no shell-string interpolation, no eval):

```powershell
# test:
$testId = $marker.Substring('test:'.Length)
Import-Module Pester -ErrorAction Stop
$config = [PesterConfiguration]::Default
$config.Run.Path = 'tests/skalary'
$config.Filter.FullName = @($testId)
$result = Invoke-Pester -Configuration $config -CI -PassThru
if ($result.TotalCount -eq 0 -or $result.FailedCount -gt 0) { exit 1 }

# file:
$fileMarker = $marker
$evidenceStage = 'PhaseCrosscheck' # Use 'PlanCrosscheck' at true finalization.
pwsh -NoProfile -File scripts/skalary/Test-Plan.ps1 -RepoRoot . -EvidenceMarker $fileMarker -EvidenceStage $evidenceStage
```

For `review:cr|dr`, treat "no review run" as unrun evidence (fail the gate until a review result exists).

Write results to the plan folder `evidence.md` using:

```text
✓/✗ REQ-N — <evidence> — <result> — <commit>
```

Receipt rules:
- Rebuild `evidence.md` on each phase/plan crosscheck run (do not append to stale results from old commits).
- Emit one line per required marker; if a marker is not executed, emit `✗ ... — unrun`.
- Use the current `HEAD` commit SHA in every emitted line.

## Phase crosscheck

1. Collect REQ IDs referenced by steps in the current phase.
2. Validate each acceptance criterion against implementation + typed evidence checks (`test:`/`file:`/`review:`).
3. Append one receipt line per marker to `evidence.md` with the current commit SHA.
4. Fail phase completion if blocking criteria are unsatisfied.

## Plan crosscheck

1. Validate all REQ and RISK rows before completion.
2. Ensure unresolved gaps are explicitly deferred in Decisions if not fixed.
3. Re-run typed evidence checks at plan scope before completion (target resolution blocking is `PlanCrosscheck` stage at true finalization time).

## archival-gate

Before archive/PR completion, require:
- `evidence.md` exists and is current.
- No unrun or failing required evidence (`✗`) remains unless explicitly deferred in Decisions (defer by REQ ID with rationale).
- This step wires the gate only; run `PlanCrosscheck` blocking target resolution only at true plan finalization (after all phases).

If the gate is not satisfied, block archival/completion.

## Dependency preflight (hard start-gate)

For plans declaring `<!-- depends-on: 006 -->`, run this deterministic non-Pester check at plan start and again immediately before any interactive harvest/finalization branch:

```powershell
pwsh -NoProfile -File scripts/skalary/Test-DependencyPlan006.ps1 -RepoRoot . -PlanPath <selected-plan-path>
```

It validates 006 behavior contracts through public script paths (including pass/fail `file:` probes, evidence vocabulary contracts, Rule 5 wording, and the `test:unit` gate). If it exits non-zero, stop execution immediately.

## Interactive harvest trigger (`/ci`) — mirror of canonical autopilot flow

This section is a **mirror** of the canonical harvest procedure in `plugins/autopilot/agents/autopilot.agent.md`. Keep parity with that file whenever harvest behavior changes.

At interactive plan completion, `/ci` runs harvest with the same shared scripts and ordering:

1. Run dependency preflight (`Test-DependencyPlan006.ps1`) before entering harvest/finalization.
2. If repo infra is present (`Test-Path scripts/skalary/Add-LedgerEntry.ps1`, `Test-Path scripts/skalary/Remove-LedgerEntry.ps1`, and `Test-Path docs/review-ledger`), execute append harvest first:
   - Require `Test-Path docs/review-ledger/.archive` and required category files before invoking harvest scripts.
   - Distill entries from `evolution-log.md` (`## Capture`), `cr-log.md`, and `learnings.md`.
   - Map candidates deterministically into `Add-LedgerEntry` inputs:
     - `-Category` from the 7-category rubric (`ledger-consult` mapping),
     - `-Plan` from the current plan id,
     - `-Src` = `ci` for this interactive trigger,
     - `-Severity` from captured finding severity or default `Med`,
     - `-Entry` one sanitized one-line lesson,
     - `-Tags` deterministic sorted tags.
   - Invoke `Add-LedgerEntry.ps1` via argument arrays / `ArgumentList` only (no shell-string interpolation).
   - Stage and commit ledger updates by explicit file names under `docs/review-ledger/`.
   - If harvest is idempotent/no-op and there is no staged ledger delta, skip the append commit and continue to branch selection.
3. Branch after the append commit:
   - Autonomous completion: push, archive commit, push, create non-draft PR.
   - `@human` escalation: push, run `Remove-LedgerEntry.ps1` + `/udn` reconciliation with the user present, commit prune/design-note edits, push, create draft PR, write marker, stop.
   - `/udn` contract: run deterministic reconciliation prompts/checks; if ambiguity remains, keep the draft-PR + marker path (no archive).
   - Invoke `Remove-LedgerEntry.ps1` via argument arrays / `ArgumentList` only (never shell-string interpolation).
   - Always pass required `Remove` inputs: `-Category`, `-CurrentPlan`, and full-line candidate match payload (`-Match`/`-MatchBase64`).
   - Feed `Remove-LedgerEntry` full-line match candidates only (`-Match`/`-MatchBase64`), never substring/regex targeting.
4. If repo infra is absent, skip harvest and keep branch semantics explicit: autonomous completion may continue standard completion flow, but `@human` completion must still route to draft PR + marker (no archive).

Fail-loud behavior: error only when expected log sections/placeholders are missing; `No entries for this phase.` is valid and must not fail harvest.

## `ledger-consult` (before a CR round)

Before launching a CR round (`@cr`, `code-review`, or `rubber-duck`), consult only the relevant category files from `docs/review-ledger/`:

- `security.md` for auth/trust-boundary/injection/secret/ACL concerns
- `performance.md` for latency/throughput/allocation/N+1 concerns
- `error-handling.md` for retry/timeout/fail-loud/exception-flow concerns
- `consistency.md` for contract drift/naming parity/duplication concerns
- `plan-structure.md` for dependency gates/phase order/evidence-flow concerns
- `testing.md` for flaky/missing/weak evidence coverage concerns
- `observability.md` for logs/metrics/tracing/audit concerns

Rules:
- Exclude `docs/review-ledger/.archive/` from all consult reads.
- Read only categories implied by the current step's REQ/RISK scope.
- Optional narrowing: within selected files, filter by relevant `#tag` values.
- This is on-demand context only; do not auto-load all ledger files by default.

## Ephemeral capture: `cr-log.md` (mid-run only)

During plan execution, capture review findings in the plan folder `cr-log.md` as ephemeral state (not durable ledger state):

- Interactive `ci`: persist `@cr` report + triage notes.
- Autopilot: persist `code-review`/`rubber-duck` findings with `src:code-review`.
- Standalone `cr`: persists nothing.

Per phase, initialize `cr-log.md` by name with a stable header and an explicit empty marker:

```text
## CR Capture
Phase: <N>

No entries for this phase.
```

When entries exist, replace the placeholder with one entry per capture:

```text
- [<source-step>] [src:code-review] [sev:<Critical|High|Med|Low>] <one-line finding or triage note>
```

Stage and commit the log by explicit filename when it changes. Do not write `docs/review-ledger/*` during this mid-run capture step.

## Ephemeral capture: `learnings.md` (trigger-based, mid-run only)

Capture learnings in the plan folder `learnings.md` only when one of these triggers fires:

- `rework>1`: more than one fix/retry iteration was needed.
- `plan-contradiction`: a run-time surprise contradicted the current plan.
- `reusable-pattern`: a pattern emerged that should be reused in future steps/plans.

Per phase, initialize `learnings.md` by name by appending a new phase section if missing (do not truncate prior phases):

```text
## Learnings Capture
Phase: <N>

No entries for this phase.
```

Entry shape (must include trigger-type and source-step):

```text
- [<source-step>] [trigger:<rework>1|plan-contradiction|reusable-pattern>] <one-line learning>
```

When appending the first real entry for a phase, replace that phase's `No entries for this phase.` line.

Enforce a hard per-plan cap of 10 learning entries across all phase sections in `learnings.md`. If new learnings exceed the cap, append one overflow summary entry and stop appending individual entries:

```text
- [<source-step>] [trigger:overflow-summary] Folded <N> additional learnings into this summary.
```

Stage and commit the log by explicit filename when it changes. Do not write `docs/review-ledger/*` during this mid-run capture step.
