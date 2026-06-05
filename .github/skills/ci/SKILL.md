---
name: ci
description: 'Continue Implementation — use when executing an implementation plan created by /cip. Selects the active plan from docs/implementation-plans/, detects git branch/worktree state and creates a worktree when on main/master, implements one step at a time, runs dotnet build and dotnet test, invokes @cr for code review, and commits with explicit user approval. Invoke with /ci or /ci <plan-slug>.'
argument-hint: 'Optional: plan slug or filename to select a specific plan (e.g. "001-data-persistence")'
user-invocable: true
disable-model-invocation: true
context: fork
---

# Continue Implementation

> This skill requires **agent mode** — it writes files, runs terminal commands, and manages git. If you are in plan or ask mode, switch to agent mode before continuing.

> **Interaction rule:** Every question that offers predefined choices (e.g. plan selection, approve/autopilot, yes/no confirmations, continue/stop) **must** use the `vscode_askQuestions` tool with `options` — never plain-text prompts. Free-form questions (e.g. "describe the issue") can remain as regular text.

## Step 1: Select Plan

Scan `docs/implementation-plans/` for plan folders (exclude `archived/`). Each plan is a folder containing `plan.md`.

### Legacy Single-File Migration

If `docs/implementation-plans/` contains loose `.md` files (not inside a folder, excluding `archived/`), migrate them first:

1. For each loose `NNN-implementation-plan-<slug>.md`:
   - Derive folder name: strip `implementation-plan-` prefix → `NNN-<slug>`
   - Create folder: `docs/implementation-plans/NNN-<slug>/`
   - Move the file into it as `plan.md`: `Move-Item <file> docs/implementation-plans/NNN-<slug>/plan.md`
2. Stage and commit: `git commit -m "chore: migrate legacy plan files to folder structure"`
3. Inform the user: "Migrated N legacy plan(s) to folder structure."

### Selection

- **Argument given** → find the folder whose name contains the argument slug; load its `plan.md`; confirm with user.
- **One plan folder found** → load its `plan.md`; confirm: "Working on: NNN — Plan Title. Correct?"
- **Multiple plan folders found** → list them with a status summary (count of `[ ]`/`[~]`/`[x]` steps per plan); ask which to use.

### Progress Summary

After selecting the plan, always print a progress snapshot:

```
Progress: X of Y steps done (Z in-progress)
Current phase: Phase N — Name
Last completed: Step A.B — title
Next pending:   Step C.D — title
```

This gives the user orientation, especially when resuming across sessions.

### Execution Mode

Detect or ask for execution mode:

1. **On a feature branch** — infer mode from branch name:
   - Branch matches `feature/<plan-slug>` (no phase/step suffix) → **autopilot**. Inform: "Detected autopilot mode from branch name."
   - Branch matches `feature/<plan-slug>-<phase-slug>-<step-N>` → **approve**. Inform: "Detected approve mode from branch name."
   - Unrecognized pattern → ask (see below).
2. **On `main`/`master` or unrecognized branch** — after showing the progress summary, ask:

**"Approve each step, or autopilot?"**
- **Approve** — stop after each step for review before proceeding. Worktree naming: `feature/<plan-slug>-<phase-slug>-<step-N>` (scoped to current step).
- **Autopilot** — implement all remaining steps with minimal user input. Single worktree for the entire plan, named `feature/<plan-slug>`. All phases and steps execute on this one worktree from start to end. Skip per-step confirmations (Step 4 "Proceed?", Step 10 "Ready to commit?", Step 11 "Continue or stop?"). Still run build, tests, acceptance criteria validation, and code review — and still log CR findings with triage — but auto-fix unambiguous CR findings and auto-commit without asking. Continue to next phase without confirmation. Only stop for: `@human` steps, ambiguous CR trade-offs, failing tests that can't be auto-fixed, or blocking dependency issues. The user reviews everything at the end.
- **Host autopilot (autonomous)** — delegate execution to Copilot CLI running autonomously in a host worktree. Invokes `scripts/autopilot/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime host`. The agent runs without user interaction, commits per-step, and pushes on phase completion. After invoking, report that autonomous execution has started and exit the `/ci` flow.
- **Container autopilot (autonomous)** — same as host autopilot but runs inside a Docker container cloned from remote. Requires Docker Desktop. After the user selects this option, ask a follow-up question:

  **"Start from which branch?"**
  - **Current branch (`<current-branch>`)** — the container clones the repo and checks out this branch as the starting point, then creates `feature/<plan-slug>` from it. Requires the branch to be pushed to remote.
  - **main** (default) — the container starts from main and creates `feature/<plan-slug>` from it.

  Then invoke: `scripts/autopilot/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime container -Branch <chosen-branch>`

- **Sandbox autopilot (autonomous)** — runs inside Windows Sandbox (isolated, disposable Win32 VM). Mounts repo read-only, clones locally inside sandbox. Same branch follow-up question as container mode. Requires Windows Pro/Enterprise with `Containers-DisposableClientVM` enabled. Invoke: `scripts/autopilot/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime sandbox -Branch <chosen-branch>`

> **Note:** The autonomous options (Host/Container/Sandbox autopilot) are hidden when the environment variable `AUTOPILOT_CONTAINER=true` is set (indicates execution is already inside an autonomous container). Only show Approve and Autopilot in that case.

Remember the chosen mode for the rest of the session.

## Step 2: Load Context

1. Read and parse the selected plan's `plan.md`.
2. If the plan folder contains `evolution-log.md` or `decisions/*.md`, note them as available context for later steps.
3. Read `docs/design-notes/.design-notes.md` to get the index.
4. Identify the subsystems touched by the next pending step.
5. Load the relevant design notes for those subsystems.

## Step 3: Branch Detection

Run `git branch --show-current`.

Ask the user: **"Create a new worktree for this work, or use the current branch `<current-branch>`?"**
- Option A: **New worktree** (default for `main`/`master`)
- Option B: **Use current branch** (for one-off or ad-hoc work; skips branch name validation)

### Option B: Use current branch
Proceed directly to Step 4 using the current branch — skip all worktree creation and branch-name matching. No `<!-- worktree: ... -->` comment is recorded.

### Option A: New worktree

#### If current branch is `main` or `master`
1. Find the next `[ ]` step across all phases.
2. Derive the worktree branch name based on execution mode (chosen in Step 1):
   - **Autopilot**: `feature/<plan-slug>` — single worktree for the entire plan.
   - **Approve**: `feature/<plan-slug>-<phase-slug>-<step-N>` — scoped to the current step.
   - `plan-slug`: the plan folder name (e.g. `007-navigation-modes`)
   - `phase-slug`: kebab-case of the phase heading (approve only)
   - `step-N`: step number, e.g. `step-1-1` (approve only)
3. Determine the worktree root: sibling folder to the repo named `<repo-folder>.worktrees` — e.g. `c:\dev\myrepo` → `c:\dev\myrepo.worktrees`. Create it if it does not exist (`mkdir` / `New-Item -ItemType Directory`).
4. Run: `git worktree add <worktree-root>/<branch-name> -b <branch-name>`
5. Run: `code <worktree-root>/<branch-name>` to open a new VS Code instance in the worktree.
6. Tell the user: "Worktree created at `<worktree-root>/<branch-name>`. New VS Code window opened. Run `/ci` there to continue."
7. **Stop** — do NOT record the branch in the plan file here; that happens on first run inside the worktree.

#### If current branch is a feature branch
Execution mode was already inferred from branch name in Step 1 (Execution Mode).

Check `plan.md` for a `<!-- worktree: <branch-name> -->` comment in the current or next pending phase:

- **Comment absent** — this is the first `/ci` run in this worktree. Record it now: add `<!-- worktree: <current-branch> -->` on the line immediately after the phase heading. In autopilot mode, add it to the first phase heading (all phases share this worktree). In approve mode, add it to the matching phase heading. This comment is committed with the first step's changes as part of that step's commit.
- **Comment present and matches current branch** → continue to Step 4.
- **Comment present but does not match** → warn: "Current branch `<current>` does not match plan branch `<recorded>`. Proceed anyway? (yes / no)"

## Step 4: Identify Next Step

1. Find the next `[ ]` or `[~]` step in the plan (top-down, first incomplete phase, first incomplete step).
2. **Dependency check** — if the step has `[after: X.Y]` annotations, verify each referenced step is `[x]`. If any dependency is not done, skip this step and move to the next eligible `[ ]` step. If no eligible step exists, tell the user which dependencies are blocking and stop.
3. **Resume check** — if the step is `[~]` (in-progress from a prior session):
   - Run `git diff --name-only HEAD` and `git status --short` to see what was already changed.
   - If there are uncommitted changes related to this step, present them: **"Step X.Y was in-progress. Found uncommitted changes in: [file list]. Continue from where it left off, or start fresh (discard changes)?"**
   - If no uncommitted changes exist, reset the step to `[ ]` and treat it as a fresh start.
4. Update its status to `[~]` in the plan file.
5. Determine the step's **role** — look for `@human` tag on the step line. If absent, the role is `@ai-agent`.
6. Determine if it's a **discovery step** — look for `[discovery]` tag. Discovery steps expect iterative steering from the user; acceptance criteria are softer.
7. Present the step to the user: **"Next: Step X.Y — [title] [role: @ai-agent|@human]. Scope: [brief description of what will change]. Proceed?"**
8. **Approve mode** — wait for confirmation before continuing. **Autopilot mode** — print the step info and proceed immediately (no confirmation needed for `@ai-agent` steps; still wait for `@human` steps).

## Step 5: Implement

### `@ai-agent` steps

Implement the single confirmed step — not the full phase.

- Follow patterns from the loaded design notes.
- Make only the changes necessary for this step.
- Do not refactor unrelated code.
- **Tests must encode invariants, not snapshots.** Assert the meaningful property (e.g. "cells grow outward from center") not an incidental observation (e.g. "all center-row cells have height 42px"). If a test would break from a valid future change to an unrelated aspect, it's asserting the wrong thing.
- **Try the simplest approach first.** If the plan specifies a complex solution but a simpler one might work, try the simple one. Only escalate to complexity when the simple approach demonstrably fails.

### `@human` steps

The agent cannot execute this step directly. Instead:

1. Read the step's `<details>` section from the plan for pre-authored guidance.
2. Present the human with a clear, actionable guide including all of the following that apply:
   - **Portal navigation** — exact click-paths (e.g. "Azure Portal → Resource Group → Settings → Configuration").
   - **CLI / shell commands** — copy-pasteable snippets with placeholders clearly marked.
   - **Code snippets** — if manual code edits are needed, show the exact before/after.
   - **Verification** — how to confirm the step succeeded (expected output, UI state, API response).
3. Ask: **"Let me know when this step is done, or if you need help with any part."**
4. Wait for the user to confirm completion before proceeding.
5. After confirmation, skip directly to Step 7 (Validate Acceptance Criteria). Steps 6 (Build and Test), 8 (Code Review), 9 (Update Design Notes) are skipped for `@human` steps unless the step produced code changes. If there are staged or unstaged code changes after a `@human` step, run the full flow (Steps 6–10).

## Step 6: Build and Test

```
dotnet build src/<Project>/<Project>.csproj
dotnet test src/<Project>.Tests/<Project>.Tests.csproj [--filter <relevant-filter>]
```

Substitute `<Project>` with the repository's main project name (the build/test commands above are illustrative — adapt them to the project's actual build tooling if it is not .NET).

If a relevant test filter can be identified from the changed subsystem (e.g. `Category=Scheduling`), use it. Otherwise run all tests.

If build or tests fail: diagnose, fix, and re-run. Iterate until both pass.

## Step 7: Validate Acceptance Criteria

1. Look up the requirement IDs referenced by the current step (e.g. `REQ-1`, `REQ-3`).
2. For each referenced requirement, read its **Acceptance Criteria** column from the plan's Requirements table.
3. Verify each criterion is satisfied by the implementation:
   - If a criterion maps to an automated test, confirm the test exists and passes.
   - If a criterion is behavioural and not covered by an automated test, describe how the implementation satisfies it and ask the user to confirm.
4. If any criterion is not met, fix the implementation and re-run build/tests before proceeding.

## Step 8: Code Review

Invoke `@cr` scoped to the current branch changes (`cr branch`).

- Print the **complete `@cr` output verbatim** — do not summarize or truncate. Every finding (title, severity, one-line summary) must be visible, even ones you'll auto-fix.
- **State your triage explicitly** after the output: list which findings you'll auto-fix (clear-cut bugs/improvements with no trade-offs) and which need a user decision. Never silently apply fixes — the user must see every finding raised even when no approval is required.
- **Default to "fix all"** — if all findings are unambiguous bugs or improvements with no trade-offs, implement all without asking (but still log the triage above). Only prompt for selection when findings involve trade-offs, conflicting approaches, or optional style preferences.
- If prompting: ask which findings to fix (by number, range, or "all").
- Apply the fixes.
- Re-run build and tests until both pass.

## Step 9: Update Design Notes

Run `/udn` to update any design notes affected by this step's changes.

- `/udn` analyzes the current chat session and edits the relevant files under `docs/design-notes/`
- Include the updated design notes in the commit in the next step

## Step 10: Commit

**Approve mode** — ask: **"Ready to commit? (yes / no)"** and wait for explicit "yes" before proceeding.

**Autopilot mode** — commit immediately without asking.

On commit:
1. Stage only the files touched in this step: `git add <file1> <file2> ...` (never `git add -A`)
2. Commit: `git commit -m "feat(<scope>): <step title> [plan-NNN step X.Y]"`
   - `scope`: the primary subsystem changed (e.g. `scheduling`, `orchestration`)
3. Mark the step `[x]` in the plan file.
4. Commit the updated plan file and any updated design notes: `git commit -m "chore: mark plan-NNN step X.Y done"`

## Step 11: Phase Crosscheck & Continue or Pause

After committing, check if all steps **in the current phase** are `[x]`. If the phase is complete, run a **phase-level crosscheck** before moving on:

1. List every `REQ-N` referenced by steps in this phase.
2. For each requirement, read its **Acceptance Criteria** from the Requirements table.
3. Review the actual changes made across all steps in this phase (use `git diff <phase-start-commit>..HEAD --stat` and inspect key files).
4. For each acceptance criterion, verify it is satisfied — either by a passing test or by observable implementation. Produce a checklist:
   ```
   Phase N Crosscheck:
   ✓ REQ-1 — criterion text — covered by TestX / implemented in File.cs
   ✗ REQ-3 — criterion text — NOT satisfied: [reason]
   ```
5. If any criterion is not met, flag it: **"Phase N complete but REQ-X acceptance criterion not satisfied: [detail]. Fix now or defer?"**
   - **Fix** → implement the fix, re-run build/test/CR, commit, then re-run this crosscheck.
   - **Defer** → record it as a known gap in the Decisions section of the plan.

6. **Phase-end CR** — scope the review to files changed in this phase plus their first-level dependencies (direct callers/callees) to validate architectural soundness without reviewing the entire codebase.
   1. Run `git diff <phase-start-commit>..HEAD --name-only` to get the list of changed files.
   2. For each changed `.cs` file, identify its first-level dependencies: files it references (`using`/calls into) and files that reference it (direct callers). Include these in the review scope.
   3. Run `@cr` on the combined file list (changed files + first-level dependencies).
   4. Print the **complete `@cr` output verbatim**, then **state your triage**: which findings you'll auto-fix and which need a user decision. Never silently apply fixes. Default to "fix all" for unambiguous findings; prompt only for trade-offs. Commit fixes separately: `fix(<scope>): phase N CR findings`.

If all steps in the plan are `[x]`, proceed to Step 12.

If not all done:

- **Approve mode** — ask: **"Continue to the next step or stop here?"** Continue → loop back to Step 4. Stop → summarize progress and exit.
- **Autopilot mode** — loop back to Step 4 immediately.

## Step 12: Plan Completion

After each commit, check whether every step across every phase is `[x]`.

If complete, run a **plan-level crosscheck**:

1. List **every** `REQ-N` in the Requirements table.
2. For each requirement, verify its acceptance criteria are satisfied by the final codebase — check tests, implementation, and any `@human` step confirmations recorded during execution.
3. List **every** `RISK-N` in the Risks table. For each, confirm the mitigation was applied or the risk did not materialize.
4. Produce a summary:
   ```
   Plan NNN Final Crosscheck:
   Requirements: X/Y satisfied
   ✓ REQ-1 — criterion — satisfied
   ✗ REQ-4 — criterion — gap: [detail]
   Risks: A/B mitigated
   ✓ RISK-1 — mitigated by step 2.1
   ✗ RISK-2 — not addressed: [detail]
   ```
5. If all requirements and risks are green, proceed to archival.
6. If any gaps exist, ask: **"Plan has unresolved gaps. Fix now, or archive with known gaps noted in Decisions?"**

On archival:
1. Edit the plan's `plan.md` title to append `[DONE]`: `# NNN: Plan Title [DONE]`
2. Move the entire plan folder to `docs/implementation-plans/archived/` using PowerShell:
   `Move-Item docs/implementation-plans/NNN-<slug> docs/implementation-plans/archived/NNN-<slug>`
3. Stage the move: `git add docs/implementation-plans/archived/NNN-<slug>` and stage the removal of the original folder.
4. Commit: `git commit -m "chore: archive completed plan NNN"`
5. Tell the user: "Plan NNN is complete and archived."
