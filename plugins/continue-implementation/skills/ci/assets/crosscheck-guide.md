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
