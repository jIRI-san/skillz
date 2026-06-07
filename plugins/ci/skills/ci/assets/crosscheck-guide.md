# Crosscheck Guide (`ci` Step 6)

> Read this asset when validating phase/plan completion and proving requirements with typed evidence.

## Evidence verification

At phase and plan crosschecks, verify each requirement's typed markers from Acceptance Criteria:
- `test:<TestId>` -> confirm named test exists and passes.
- `file:<path>#<assertion>` -> verify through the pre-approvable PlanEvidence/Test-Plan script path.
- `review:cr|dr` -> verify finding-class absence from review output.

Write results to the plan folder `evidence.md` using:

```text
✓/✗ REQ-N — <evidence> — <result> — <commit>
```

## Phase crosscheck

1. Collect REQ IDs referenced by steps in the current phase.
2. Validate each acceptance criterion against implementation + evidence checks.
3. Fail phase completion if blocking criteria are unsatisfied.

## Plan crosscheck

1. Validate all REQ and RISK rows before completion.
2. Ensure unresolved gaps are explicitly deferred in Decisions if not fixed.

## archival-gate

Before archive/PR completion, require:
- `evidence.md` exists and is current.
- No unrun or failing required evidence (`✗`) remains unless explicitly deferred in Decisions.

If the gate is not satisfied, block archival/completion.
