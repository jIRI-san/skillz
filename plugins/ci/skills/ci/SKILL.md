---
name: ci
description: 'Continue Implementation — execute a plan from docs/implementation-plans/, track step state, implement one step at a time, validate with build/test, review with @cr, and commit progress.'
argument-hint: 'Optional plan slug (e.g. "006-plan-workflow-hardening")'
user-invocable: true
disable-model-invocation: true
context: fork
---

# Continue Implementation

> This skill requires agent mode. It edits files, runs commands, and commits.

> **Interaction rule:** every multiple-choice prompt uses `vscode_askQuestions` with `options`.

## Step 1: Select plan and load context

1. Locate plan folders in `docs/implementation-plans/` (exclude `archived/`), then pick the target `plan.md`.
2. Migrate any legacy loose plan files into folder structure before continuing.
3. Read the selected plan and any sibling `evolution-log.md` / `decisions/*.md`.
4. Read `docs/design-notes/.design-notes.md` and load relevant design notes for the current step.

## Step 2: Emit progress snapshot (always)

After selecting a plan and before starting work, always print:

```text
Progress: X of Y steps done (Z in-progress)
Current phase: Phase N — Name
Last completed: Step A.B — title
Next pending:   Step C.D — title
```

## Step 3: Determine execution mode and branch/worktree

1. Detect or ask for execution mode (approve, autopilot, or autonomous runtime options when available).
2. Validate or create the expected branch/worktree naming.
3. Record `<!-- worktree: <branch> -->` in the current phase when first running in that worktree.

## Step 4: Pick next eligible step

1. Find first `[ ]` or `[~]` step in top-down order.
2. Enforce `[after: X.Y]` dependencies.
3. Resume `[~]` steps from uncommitted changes if present; otherwise reset to `[ ]` and restart.
4. Mark active step as `[~]`.
5. Respect `@human` and `[discovery]` tags.

## Step 5: Implement (`./assets/execution-guide.md`)

Before implementing a step, run:

```powershell
npm run validate-plan
```

If validation reports blocking failures, do not start execution until they are fixed.

Do not add inline validation logic in this orchestrator. All plan validation must delegate to `scripts/skalary/Test-Plan.ps1` via `npm run validate-plan` or `scripts/validate.ps1`.

Use the execution asset for implementation/build/test/code-review/commit loop.

## Step 6: Crosscheck and completion (`./assets/crosscheck-guide.md`)

Use the crosscheck asset for:
- Phase crosscheck
- Plan crosscheck
- Evidence receipt (`evidence.md`)
- `archival-gate` checks before completion
