---
name: cip
description: 'Create Implementation Plan — use when planning a new feature, designing an implementation, starting development work, or resuming/refining an existing plan. Conducts thorough requirements gathering across all aspects (goals, constraints, API surface, error handling, testing, observability, security, performance), drafts a phased plan with step-level tracking, runs iterative design review via @dr, and saves to docs/implementation-plans/. Invoke with /cip <name> for a new plan or /cip <slug> to resume an existing one.'
argument-hint: 'Plan name for a new plan (e.g. "data persistence"), or an existing plan slug to resume (e.g. "001-data-persistence")'
user-invocable: true
disable-model-invocation: true
context: fork
---

# Create Implementation Plan

> **Goal:** produce a plan concrete and precise enough that each step can be executed with minimal ambiguity. Eliminate uncertainty during the interview — don't defer it to implementation. If an answer is vague, dig deeper. If a design choice is open, resolve it now. The plan should read as a clear checklist, not a wishlist.

> **Interaction rule:** Every question that offers predefined choices (e.g. plan selection, new/resume, yes/no confirmations, continue/stop) **must** use the `vscode_askQuestions` tool with `options` — never plain-text prompts. Free-form questions (e.g. interview topics, open-ended design input) can remain as regular text.

## Step 1: Load Context

1. Read `docs/design-notes/.design-notes.md` to get the index of all available design notes.
2. Identify which subsystems are likely touched by this plan (from argument or prior chat context).
3. Load the relevant design notes to ground the planning session.

## Step 2: Locate or Create Plan Folder

Scan `docs/implementation-plans/` for existing plan folders (exclude `archived/`). Each plan lives in its own folder:

```
docs/implementation-plans/NNN-<slug>/
  plan.md              ← the main plan document
  evolution-log.md     ← DR round history (created in Step 6)
  decisions/           ← extracted decision rationale (created as needed)
    <topic>.md
```

- **Argument matches an existing folder slug** → load `plan.md` from that folder; enter *resume mode* (skip Step 3 if plan is already well-specified; otherwise re-interview for gaps).
- **No argument and plan folders exist** → list them with a one-line status summary; ask the user which to work on (or "new").
- **"new" or no existing plans** → ask for the plan name, derive a kebab-case slug, assign the next sequential number `NNN`, create folder: `docs/implementation-plans/NNN-<slug>/`. The plan file is `docs/implementation-plans/NNN-<slug>/plan.md`.

### Persist to Repo Immediately

As soon as the slug is known (new plan) or the folder is located (resume), **write `plan.md` to the repo** — do not keep the plan in session memory. VS Code access control requires approvals for temporary/out-of-repo files, so every subsequent pass (interview updates, drafting, DR) must operate on the in-repo file path.

- **New plan**: create the folder and write a stub `plan.md` (title + empty template sections from [./assets/plan-template.md](./assets/plan-template.md)) right away. Refine it in place during the interview and drafting.
- **Resume**: the file already exists; edit it in place.

From this point on, all steps below reference the in-repo path `docs/implementation-plans/NNN-<slug>/plan.md`.

### Legacy Single-File Migration

If `docs/implementation-plans/` contains loose `.md` files (not inside a folder, excluding `archived/`), these are legacy plans from the old single-file format. Migrate before proceeding:

1. For each loose `NNN-implementation-plan-<slug>.md`:
   - Derive folder name: strip `implementation-plan-` prefix → `NNN-<slug>`
   - Create folder: `docs/implementation-plans/NNN-<slug>/`
   - Move the file into it as `plan.md`: `Move-Item <file> docs/implementation-plans/NNN-<slug>/plan.md`
2. Stage and commit: `git commit -m "chore: migrate legacy plan files to folder structure"`
3. Inform the user: "Migrated N legacy plan(s) to folder structure."

## Step 3: Interview User

Do not proceed to drafting until you have solid answers to all of the following. Ask follow-ups on vague or incomplete answers — push for specifics. Treat every "TBD", "maybe", or "we'll figure it out later" as a blocker: resolve it now or record it as an explicit risk with a mitigation.

**Goals & scope**
- What behaviour or capability is being added or changed?
- What is explicitly out of scope?

**Requirements**
- What are the functional requirements? List them individually.
- What are the non-functional requirements (performance, scale, SLA)?

**Affected subsystems**
- Which source files, services, or components need to change?
- Are there data model changes (schema, EF migrations)?

**API surface**
- New endpoints, messages, or events? Request/response shape?
- Breaking changes to existing APIs?

**Error handling**
- What failure modes exist? How should each be handled?
- Retry policies, fallback behaviour, partial-failure semantics?

**Testing strategy**
- Unit tests, integration tests, or both?
- New Testcontainers-based fixtures needed?

**Observability**
- What structured log entries are needed?
- New metrics or health-check impacts?

**Security**
- Auth/authz implications?
- Any data sensitivity concerns?
- Input validation boundaries — where does untrusted data enter? (file paths, user config, external input)
- Path traversal, injection, or deserialization risks?

**Code quality & static analysis**
- What analyzer / warning level is the project using? (e.g. `<AnalysisLevel>`, `<TreatWarningsAsErrors>`, ESLint config, Clippy settings)
- Are there specific analyzer rules or lint categories the plan must satisfy from day one? Identify the active rules and plan around them.
- Target: **zero build warnings** at every step — bake analyzer-clean patterns into the plan steps, not as a post-hoc fix pass.

**Implementation patterns**
- For each subsystem, what concrete implementation patterns should the code follow? Push beyond "implement X" to specify:
  - Allocation strategy (e.g. cache expensive objects, pool buffers, avoid per-call allocations in hot paths)
  - Logging approach (e.g. source-generated delegates vs extension methods, structured vs unstructured)
  - Serialization (e.g. cached serializer options, source-generated serialization contexts)
  - Error handling style (e.g. Result types, exceptions, error codes — and where each applies)
  - Interface vs concrete type usage (e.g. public API boundaries vs internal wiring)
- These patterns prevent code-review churn — decisions made here avoid rework later.

**Corner cases**
- What edge/corner cases could break expected behaviour?
- Boundary conditions, race conditions, empty/null inputs, unusual user flows?
- How should each corner case be handled — error, fallback, or explicit design choice?

**Visual/spatial behaviour** (if the feature has UI or rendering)
- What happens visually after each user interaction? Describe the spatial result, not just the logical state change.
- Are there scaling, recentering, or layout-shift behaviours that only become obvious when seen? Specify them now.
- List all geometric/layout constraints (e.g. "cells must be square", "grid must fit viewport", "labels must be readable at 1080p"). Verify constraint compatibility — can all constraints be satisfied simultaneously? If not, define priority order.
- What are the visual acceptance criteria? ("User can read all labels at 1920×1080" > "labels have positive font size")

**Simplicity mandate**
- For each subsystem, what is the simplest possible implementation that satisfies the requirements?
- Are there complex mechanisms being proposed where a simple one would suffice? (e.g. "all keys configurable in config" vs "QWERTY detection + layout fallback + hardcoded defaults")
- Plan should mandate "try the simplest thing first" — complex solutions only after the simple approach demonstrably fails.

**Discovery phases** (for features with emergent behaviour)
- Does this feature involve interactions between multiple constraints where behaviour will only become clear during implementation? (e.g. visual layouts, physics, real-time feedback loops)
- If yes, allocate explicit "discovery" steps where implementation reveals missing requirements — these steps have lighter acceptance criteria and expect iteration.

**Performance**
- Expected throughput, latency targets, or load concerns?

**Migration / rollout**
- Feature-flagged? Backward-compatible?
- Any one-time migration steps?

**Acceptance criteria**
- For each functional requirement and corner case: what is the concrete, verifiable condition that proves it works?
- Express each criterion as a testable statement (e.g. "When X, then Y", "Given A, expect B").
- Cover both happy-path and failure/edge-case outcomes.

**Roles**
- For each step, who executes it? Assign one of:
  - `@ai-agent` — the AI agent implements this step autonomously (code changes, tests, config).
  - `@human` — a human performs this step (portal configuration, manual verification, external system setup, license activation, etc.).
- Default is `@ai-agent` if not specified. Ask explicitly for any step that might require human action.

**Estimation**
- For each step, assign a T-shirt size: `S` (< 30 min), `M` (30 min – 2 h), `L` (2 h+).
- Sizes are rough guidance, not commitments. Push back if the user skips sizing entirely.

**Risks**
- What could block or derail this plan? Think beyond corner cases: external dependencies, API rate limits, licensing, unclear requirements, tooling gaps.
- For each risk: likelihood (Low/Medium/High), impact (Low/Medium/High), and mitigation or contingency.

**Rollback**
- For `@ai-agent` steps: git revert is assumed. No special guidance needed unless the step has side effects beyond code (e.g. database migrations, published packages).
- For `@human` steps: what is the undo procedure? (e.g. "Delete the resource group", "Revert the portal setting to X").
- For steps with no clean rollback: note this explicitly as a risk.

**Execution mode** (optional — sets defaults for `/ci` mode selection)
- Should this plan be executed manually (approve each step), autonomously on host, or autonomously in a container?
- Default is manual. Autonomous modes require `.autopilot.json` and auth setup.
- If autonomous: whole-plan or phase-at-a-time scope?
- Record as `<!-- execution-mode: manual | host-autopilot | container-autopilot -->` and `<!-- scope: step | phase | plan -->` metadata in the plan header.

Once all areas are covered, present a structured summary back to the user and ask: **"Does this capture everything? Anything to add or correct?"** — wait for confirmation before drafting.

## Step 4: Draft Plan

Build the plan document using the template at [./assets/plan-template.md](./assets/plan-template.md).

Guidelines:
- **Decisions** — record key choices made during the interview (e.g. "Use feature flag X to gate rollout").
- **Requirements table** — one row per requirement, ID format `REQ-N`. Corner cases identified during the interview become requirements too (e.g. `REQ-7 Handle empty grid when monitor is disconnected`). Each requirement must have at least one acceptance criterion in the `Acceptance Criteria` column. The `Phases/Steps` column must list every step that addresses this requirement.
- **Phases** — group related steps logically (e.g. "Phase 1: Data layer", "Phase 2: API", "Phase 3: Tests").
- **Steps** — each step line references all related IDs in parentheses: `(REQ-1, REQ-3, RISK-2)`. No implementation prose. Keep it scannable for human review.
- **Roles** — each step is tagged `@ai-agent` or `@human`. Default is `@ai-agent`; only annotate `@human` explicitly. For `@human` steps, add a `Details` sub-section under the step with actionable guidance (portal navigation, CLI commands, manual verification instructions, etc.).
- **Estimation** — each step gets a T-shirt size: `S`, `M`, or `L`.
- **Dependencies** — for each step, note which earlier steps it depends on using `[after: X.Y]` suffix. Steps with no dependency annotation (or `[after: none]`) can start immediately and run in parallel with other independent steps.
- **Risks** — populate the Risks table from the interview. One row per risk, ID format `RISK-N`. The `Steps` column must list every step affected by or mitigating this risk. Steps that relate to a risk must also reference the `RISK-N` ID in their parentheses.
- **Cross-reference integrity** — every `REQ-N` must appear in at least one step; every `RISK-N` must appear in at least one step; every step must reference at least one `REQ-N`. If any ID is orphaned (not linked to a step), either add a step or remove the ID.
- **Implementation specificity** — steps should name the exact pattern to use, not just what to build. Bad: "Add logging to service". Good: "Add source-generated log methods to OrderService (partial class); 5 Information + 2 Warning + 1 Error level, all with structured parameters". Bad: "Load config from file". Good: "Deserialize config via cached static serializer options; return `(Config, string? ParseError)` tuple to surface parse failures". The step should be precise enough that two different agents would produce near-identical code.
- **Zero-warning mandate** — if the project targets zero build warnings, every step producing code must specify the analyzer-clean pattern inline (e.g. discarding unused return values, using source-generated logging, matching the project's preferred type usage). Do not defer warning cleanup to a later step.
- **Security by design** — if a step processes external input (file paths, user config, API payloads, uploaded files), specify the validation inline: path traversal checks, input sanitization, schema validation, try-catch fallbacks. Do not defer security hardening to code review.
- **Architecture lock-in** — core architectural decisions (data model shape, communication patterns, rendering approach, storage strategy, API contracts) must be resolved and recorded in Decisions before drafting steps. Leaving these open leads to multi-plan rewrites. If the user is uncertain, push for a decision or record it as a High-impact risk with a spike step. Changing architecture mid-plan is the #1 cause of rework.
- **Format-from-start** — if the project uses a formatter (`.editorconfig`, `dotnet format`, Prettier, Black, rustfmt), include it in Phase 1 (scaffold) and mandate formatting validation at the end of each phase. A single late formatting commit touching dozens of files is noisy and hides real changes in git history.
- **UI/rendering complexity estimation** — UI rendering steps (custom drawing, layout algorithms, responsive/adaptive design, animation) are consistently underestimated. When a step involves non-trivial visual output with edge cases (overflow, scaling, RTL, accessibility), size it at `L` and consider splitting into sub-steps: (a) core rendering, (b) edge-case layout, (c) responsive/scaling behavior, (d) tests.
- **Feature completeness per phase** — each phase should produce a self-contained, testable increment. Do not split a feature across phases in a way that requires rework in a later phase (e.g. "Phase 3: basic list view" then "Phase 8: virtualized scrolling" forces a rewrite of the list component). Include the complete feature — including its known edge cases — in one phase, sized appropriately.
- **Discovery steps** — for visual/spatial/emergent-behaviour steps, mark them as discovery steps: `[discovery]`. These steps have lighter acceptance criteria ("renders correctly at 1080p" rather than pixel-precise specs), expect 1–3 steering interventions from the user, and should be sized `L`. The plan acknowledges that exact behaviour will be refined during implementation.
- **Simplest-first mandate** — steps must specify the simplest viable approach. Do not plan complex mechanisms (detection systems, multi-tier fallbacks, frame-gating) when a simpler approach could work. If a complex approach is truly needed, add a preceding spike step that demonstrates the simple approach is insufficient.
- **Constraint compatibility analysis** — for steps involving multiple geometric, layout, or concurrent constraints, add an explicit sub-section listing all constraints and verifying they don't conflict. Constraints that are individually reasonable can be mutually incompatible (e.g. square cells + log scaling + axis layout = grid wraps into corner).
- **Rollback** — for `@human` steps and steps with non-code side effects, record rollback instructions in the step's `Details` section.
- Status markers: `[ ]` TODO · `[x]` DONE · `[~]` IN-PROGRESS

## Step 5: Save Plan

The in-repo `plan.md` was created in Step 2 — keep updating it in place after each planning iteration. Never hold the plan only in session memory: VS Code access control requires approvals for temporary files, and DR plus every later pass must run against the in-repo path.

- **Agent mode** (can write files): update `docs/implementation-plans/NNN-<slug>/plan.md` after each iteration.
- **Plan mode** (read-only): you cannot write the repo file directly — hand off to agent mode to persist to `docs/implementation-plans/NNN-<slug>/plan.md` as early as possible so DR and later passes operate on the repo file, not session memory.

### Size Limits

Track plan size after each save. Large plans cannot be fully loaded into agent context, force lossy summarization during implementation, and make DR rounds inefficient.

- **Warn at 30KB (or ~600 lines)**: "Plan is getting large — consider extracting detailed decisions into separate files or splitting into sub-plans."
- **Block at 50KB (or ~1000 lines)**: "Plan exceeds recommended size. Apply one or more of these mitigations before continuing:
  1. **Extract decisions** — move multi-paragraph rationale to `decisions/<topic>.md` within the plan folder; reference with a one-liner in `plan.md`.
  2. **Split into sub-plans** — one sub-plan per phase (`phase-N.md` in the plan folder), with `plan.md` as the root index.
  3. **Trim implementation detail** — steps should be concise checklists, not prose."

## Step 6: Design Review (Iterative, Max 3 Rounds)

**Cap: 3 DR rounds by default.** Most real issues surface in rounds 1–3. Later rounds produce re-discoveries, contradictions between models, and increasingly theoretical edge cases that add bulk without value.

### Evolution Log

Create/update `evolution-log.md` in the plan folder (e.g. `docs/implementation-plans/NNN-<slug>/evolution-log.md`). After each DR round, append:
- Round number
- Issues found (brief)
- Issues fixed
- Issues deferred → "Known Plan Issues" section in the plan

DR agents **must be given the evolution log as context** to prevent re-reporting fixed issues or contradicting prior deliberate decisions.

### Simplicity Gate

After each DR round, before applying findings, evaluate:
- Has the plan grown more complex without proportional risk reduction?
- Are findings adding edge-case guards for scenarios that are unlikely in practice?
- Would a simpler approach satisfy the actual user requirement?

Flag overengineering explicitly. Reject findings that optimize for theoretical completeness over practical sufficiency.

### Procedure

1. Invoke `@dr` passing the in-repo plan file path (`docs/implementation-plans/NNN-<slug>/plan.md`) **and** the evolution log. DR always reviews the repo file — never session-memory content.
2. Apply agreed findings; update Decisions section. Append round summary to evolution log.
3. If `@dr` raised **High** or **Critical** findings requiring substantial plan changes, run another round (up to 3 total).
4. After round 3, if issues remain:
   - Record them in a "Known Plan Issues" section at the bottom of the plan.
   - Ask: **"3 DR rounds complete. Remaining issues recorded as Known Plan Issues. Continue reviewing or start implementation?"**
   - Only continue past 3 if user explicitly requests more rounds.

## Step 7: Finish

- Confirm final plan is saved.
- Ask: **"Ready to start implementation? Use `/ci` to begin."**
