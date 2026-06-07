---
description: Plan workflow contracts for cip/ci/autopilot — validator stages, typed evidence, script-only validation, and legacy migration behavior
globs:
  - docs/implementation-plans/**
  - scripts/skalary/Test-Plan.ps1
  - scripts/skalary/PlanEvidence.psm1
  - scripts/skalary/Validate-Plan.ps1
  - scripts/validate.ps1
  - plugins/cip/**
  - plugins/ci/**
---

# Plan Workflow

## Architecture

| Component | Responsibility | Notes |
|---|---|---|
| `plugins/cip/skills/cip/SKILL.md` | Orchestrates interview, drafting, DR rounds | Stays orchestration-only; calls validator scripts, does not embed validation logic |
| `plugins/ci/skills/ci/SKILL.md` | Orchestrates step execution and crosschecks | Uses deterministic script entry points before execution/crosscheck |
| `scripts/skalary/Test-Plan.ps1` | Deterministic plan validator and file-evidence verifier | Supports `-Stage Draft|PhaseCrosscheck|PlanCrosscheck`; reusable evidence verification path |
| `scripts/skalary/PlanEvidence.psm1` | Confined `file:` marker evaluator | Canonicalize-then-confine path checks, assertion vocabulary, regex/time budget enforcement |
| `scripts/skalary/Validate-Plan.ps1` + `scripts/validate.ps1` | Repo-level and single-plan entry points | Keep validation pre-approvable and composable via npm scripts |
| `docs/implementation-plans/*/evidence.md` | Receipt of typed evidence checks | Source of truth for archival-gate decisions |

## Key Patterns

| Pattern | Contract |
|---|---|
| Validator stages | `Draft` blocks structural integrity but treats unresolved evidence targets as warnings; `PhaseCrosscheck`/`PlanCrosscheck` make target resolution blocking. |
| Typed evidence markers | Acceptance criteria use only `test:<TestId>`, `file:<path>#<assertion>`, and `review:cr|dr`. |
| `file:` assertions | Closed vocabulary: `exists`, `contains:<regex>`, `count>=N`, `dircount>=N`. |
| Script-only validation | `cip`/`ci`/autopilot delegate validation to committed `.ps1` scripts; no in-chat or inline markdown validation logic. |
| Evidence receipt gating | Crosschecks rebuild `evidence.md`; archival/finalization is blocked on unresolved `✗` or unrun required markers unless explicitly deferred in Decisions. |

## Design Decisions

- `Test-Plan.ps1` is the single validation authority so approval/allowlist models stay stable across host/container/autopilot execution.
- Stage-aware validation avoids self-blocking plans during drafting while still enforcing strict verification at crosscheck/finalization.
- Evidence is machine-checkable only; non-deterministic markers (`cmd:`/`manual:`) are excluded to preserve autopilot safety and repeatability.

## Constraints

- Plan text is untrusted input. Validation scripts must use pure parsing/bound parameters (no dynamic command execution from plan content).
- Legacy plans without `<!-- evidence: required -->` run in warn-only mode for strict integrity classes; opted-in plans enforce blocking behavior.
- Any workflow change that alters marker grammar, stage semantics, or completion gates must update this note and the relevant `cip`/`ci` assets in the same change.
