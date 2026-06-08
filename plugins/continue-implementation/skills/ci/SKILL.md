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
5. Run dependency preflight as a hard gate when the selected plan declares `depends-on: 006`:

```powershell
pwsh -NoProfile -File scripts/skalary/Test-DependencyPlan006.ps1 -RepoRoot . -PlanPath <selected-plan-path>
```

## Step 2: Emit progress snapshot (always)

After selecting a plan and before starting work, always print:

```text
Progress: X of Y steps done (Z in-progress)
Current phase: Phase N — Name
Last completed: Step A.B — title
Next pending:   Step C.D — title
```

## Step 3: Determine execution mode and branch/worktree

1. **Read the plan's declared execution mode.** Parse the plan header for `<!-- execution-mode: manual | host-autopilot | container-autopilot | sandbox-autopilot -->` and `<!-- scope: step | phase | plan -->`. This marker is a *runtime* selector, not a pacing hint — `*-autopilot` means the plan is meant to run autonomously, not interactively with approvals.

2. **Always present the full mode menu.** Use `vscode_askQuestions` and list **every** mode below on every run, regardless of which configs exist. Mark the plan-declared mode as recommended. Never hide a mode because its config is missing — if the user picks an autonomous mode without config, the autopilot skill runs first-run bootstrap (Step 3.4).

   | Option | Kind | Description |
   |---|---|---|
   | **Interactive (approve each step)** | in-session | Pause for approval at each step. Recommended when marker is `manual` or absent. |
   | **Autopilot (autoapprove)** | in-session | Run in this session without per-step approval prompts. |
   | **Host autopilot** | autonomous | Headless via `launch.ps1 -Runtime host`. Recommended when marker is `host-autopilot`. |
   | **Container autopilot** | autonomous | Headless via `launch.ps1 -Runtime container`. Recommended when marker is `container-autopilot`. |
   | **Sandbox autopilot** | autonomous | Headless via `launch.ps1 -Runtime sandbox`. Recommended when marker is `sandbox-autopilot`. |

   Never silently downgrade an `*-autopilot` plan to interactive — always confirm with the user via this menu.

3. **Environment suppressions (security, not config gaps):**
   - `AUTOPILOT_CONTAINER=true` (already inside the autopilot container): omit all autonomous options **and** Autopilot; execute in-place per the marker.
   - `AUTOPILOT_DISABLE_HOST=true`: omit **Host autopilot** only (`launch.ps1` also refuses `-Runtime host`).

4. **Autonomous handoff.** When the user picks Host / Container / Sandbox autopilot, read `.github/skills/autopilot/SKILL.md` by path and follow its steps: first-run `.autopilot.json` bootstrap (if config missing), then invoke the launcher for the chosen runtime. The chosen runtime pre-selects the autopilot sub-menu. After launch, print the handoff line and exit the `/ci` flow.

5. **In-session execution (Interactive / Autopilot).** Validate or create the expected branch/worktree naming, then continue to Step 4. Autopilot skips per-step approval prompts; Interactive pauses at each step.

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
