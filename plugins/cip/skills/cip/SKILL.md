---
name: cip
description: 'Create Implementation Plan — use when planning a new feature, designing an implementation, starting development work, or resuming/refining an existing plan. Conducts thorough requirements gathering across all aspects (goals, constraints, API surface, error handling, testing, observability, security, performance), drafts a phased plan with step-level tracking, runs iterative design review via @dr, and saves to docs/implementation-plans/. Invoke with /cip <name> for a new plan or /cip <slug> to resume an existing one.'
argument-hint: 'Plan name for a new plan (e.g. "data persistence"), or an existing plan slug to resume (e.g. "001-data-persistence")'
user-invocable: true
disable-model-invocation: true
context: fork
---

# Create Implementation Plan

> **Goal:** produce a concrete, implementation-ready plan with explicit evidence and phase-aware structure. Resolve ambiguity during interview, not during execution.

> **Interaction rule:** Every question that offers predefined choices (e.g. plan selection, new/resume, yes/no confirmations, continue/stop) **must** use the `vscode_askQuestions` tool with `options` — never plain-text prompts. Free-form questions (e.g. interview topics, open-ended design input) can remain as regular text.

## Non-negotiable planning summary

- Resolve architecture decisions before drafting; no silent TBDs.
- Keep steps checklist-style, specific, and implementation-oriented.
- Every requirement needs machine-checkable evidence markers in acceptance criteria.
- Keep plans phase-budget aware and size-bounded.
- Run `Test-Plan.ps1` after drafting and after each DR round.
- Maintain the state anchor `<!-- cip-stage: ... -->` in the plan header.

## Preservation checklist (legacy Step-4 rules -> assets)

- **Specificity / concise executable steps** -> `./assets/drafting-guide.md` ("Step drafting checklist")
- **Simplest-first mandate** -> `./assets/interview-guide.md` + `./assets/drafting-guide.md`
- **Security-by-design requirements** -> `./assets/interview-guide.md`
- **Architecture lock-in** -> `./assets/interview-guide.md`
- **Cross-reference + evidence integrity** -> `./assets/drafting-guide.md` + `Test-Plan.ps1` gate

## Step 1: Load context

1. Read `docs/design-notes/.design-notes.md`.
2. Load relevant design notes for touched subsystems.
3. Identify target plan folder in `docs/implementation-plans/` (exclude `archived/`), or create `NNN-<slug>/plan.md` for a new plan.
4. Migrate any legacy loose plan files into folder format before proceeding.

## Step 2: Run interview (`./assets/interview-guide.md`)

1. Follow the full question bank and the `no-tbd`, `evidence`, and `pre-draft` gates from the interview asset.
2. Do not allow unresolved architecture or evidence-less requirements.
3. Confirm interview summary with the user before drafting.

## Step 3: Draft plan (`./assets/drafting-guide.md` + template)

1. Build/update the plan in-repo using `./assets/plan-template.md`.
2. Follow the drafting checklist in `./assets/drafting-guide.md` (typed evidence legend, phase-budget points, concise steps, decisions extraction, size limits).
3. Set/update the stage anchor in plan header:

```md
<!-- cip-stage: drafted -->
```

4. Run:

```powershell
pwsh -NoProfile -File scripts/skalary/Test-Plan.ps1 -PlanPath <plan-path> -RepoRoot . -Stage Draft
```

## Step 4: Design review (`./assets/dr-guide.md`)

1. Run iterative DR (up to 3 rounds) using the DR asset process and evolution log.
2. After each round, set/update:

```md
<!-- cip-stage: dr-round-N -->
```

3. After each round, re-run:

```powershell
pwsh -NoProfile -File scripts/skalary/Test-Plan.ps1 -PlanPath <plan-path> -RepoRoot . -Stage Draft
```

## Step 5: Finish

1. Confirm `plan.md` is saved in repo.
2. Confirm state anchor reflects final stage reached.
3. Ask: **"Ready to start implementation? Use `/ci` to begin."**
