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

1. **Read the plan's declared execution mode.** Parse the plan header for `<!-- execution-mode: manual | host-autopilot | container-autopilot -->` and `<!-- scope: step | phase | plan -->`. This marker is a *runtime* selector, not a pacing hint — `*-autopilot` means the plan is meant to run autonomously (host or container), not interactively with approvals.
2. **Map the marker to a mode and present the selection.** Always use `vscode_askQuestions`, with the plan-declared mode marked recommended:
   | Plan marker | Recommended mode |
   |---|---|
   | `manual` or absent | **Approve** (interactive, approve each step) |
   | `host-autopilot` | **Autonomous → Host autopilot** |
   | `container-autopilot` | **Autonomous → Container autopilot** |
   | `sandbox-autopilot` | **Autonomous → Sandbox autopilot** |

   Never silently downgrade an `*-autopilot` plan to interactive Approve. When the plan declares an autopilot mode and the session is interactive, ask the user to confirm the declared runtime (Container/Host) or pick another — do not just proceed interactively.
3. **Hand off to the autopilot launcher when an autonomous mode is chosen.** Read `.github/skills/autopilot/SKILL.md` by path and follow its bootstrap + sub-menu + launcher steps. The declared `container-autopilot`/`host-autopilot` marker pre-selects the matching runtime in the autopilot sub-menu. After launch, exit the `/ci` flow.
4. **Suppression:** if `AUTOPILOT_CONTAINER=true` (already running inside the autopilot container), skip the autonomous handoff and execute in-place regardless of the marker.
5. For interactive (Approve) execution: validate or create the expected branch/worktree naming.
6. Record `<!-- worktree: <branch> -->` in the current phase when first running in that worktree.

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
