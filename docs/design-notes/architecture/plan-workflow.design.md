---
description: Plan workflow contracts for cip/ci/autopilot — validator stages, typed evidence, script-only validation, and legacy migration behavior
globs:
  - docs/implementation-plans/**
  - docs/review-ledger/**
  - scripts/skalary/Add-LedgerEntry.ps1
  - scripts/skalary/Remove-LedgerEntry.ps1
  - scripts/skalary/Test-Plan.ps1
  - scripts/skalary/PlanEvidence.psm1
  - scripts/skalary/Validate-Plan.ps1
  - scripts/validate.ps1
  - plugins/create-implementation-plan/**
  - plugins/continue-implementation/**
---

# Plan Workflow

## Architecture

| Component | Responsibility | Notes |
|---|---|---|
| `plugins/create-implementation-plan/skills/cip/SKILL.md` | Orchestrates interview, drafting, DR rounds | Stays orchestration-only; calls validator scripts, does not embed validation logic |
| `plugins/continue-implementation/skills/ci/SKILL.md` | Orchestrates step execution and crosschecks | Uses deterministic script entry points before execution/crosscheck |
| `scripts/skalary/Test-Plan.ps1` | Deterministic plan validator and file-evidence verifier | Supports `-Stage Draft|PhaseCrosscheck|PlanCrosscheck`; reusable evidence verification path |
| `scripts/skalary/PlanEvidence.psm1` | Confined `file:` marker evaluator | Canonicalize-then-confine path checks, assertion vocabulary, regex/time budget enforcement |
| `scripts/skalary/Add-LedgerEntry.ps1` | Deterministic workflow-memory append and dedup writer | Sanitizes untrusted text, enforces category/src/severity enums, uses workspace lock + idempotent replay |
| `scripts/skalary/Remove-LedgerEntry.ps1` | Deterministic workflow-memory prune/tombstone path | Full-line ordinal match, retention guards, `.archive/` move, no regex-driven destructive deletes |
| `docs/review-ledger/**` | Durable workflow-memory store by category | Seven-category taxonomy + README contract; consulted on demand, never auto-loaded |
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
| Ledger dedup-key contract | `Add-LedgerEntry.ps1` keeps two keys: idempotence key (`category + normalized-lesson + plan + src + severity + sorted-tags`, date excluded) and recurrence key (`category + normalized-lesson + sorted-tags`, plan/src/date excluded). |
| Workflow-memory capture | Mid-run writes are ephemeral (`cr-log.md`, `learnings.md`, `evolution-log.md`) with explicit placeholders so missing sections fail loud while intentionally empty phases stay valid. |
| Workflow-memory harvest | Durable ledger writes happen only at finalization append-harvest via `Add-LedgerEntry.ps1`; prune is escalation-only and script-mediated via `Remove-LedgerEntry.ps1`. |

## Design Decisions

- `Test-Plan.ps1` is the single validation authority so approval/allowlist models stay stable across host/container/autopilot execution.
- Stage-aware validation avoids self-blocking plans during drafting while still enforcing strict verification at crosscheck/finalization.
- Evidence is machine-checkable only; non-deterministic markers (`cmd:`/`manual:`) are excluded to preserve autopilot safety and repeatability.
- Workflow-memory mutation is script-only (`Add`/`Remove`) and invoked through bound argument arrays; orchestrators do not hand-edit ledger files.

## Constraints

- Plan text is untrusted input. Validation scripts must use pure parsing/bound parameters (no dynamic command execution from plan content).
- Legacy plans without `<!-- evidence: required -->` run in warn-only mode for strict integrity classes; opted-in plans enforce blocking behavior.
- Any workflow change that alters marker grammar, stage semantics, or completion gates must update this note and the relevant `cip`/`ci` assets in the same change.
