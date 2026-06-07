# Interview Guide (`cip` Step 3)

> Read this asset when conducting the requirements interview. Do not proceed to drafting until every area below has a solid, specific answer. Ask follow-ups on vague or incomplete answers — push for specifics.

## Gates (non-negotiable)

These gates are blocking. The orchestrator enforces them before drafting.

### `no-tbd` gate

Treat every "TBD", "maybe", "we'll figure it out later", or unresolved design choice as a **blocker**. For each one, either:
- **Resolve it now** in the interview, or
- **Record it as an explicit `RISK-N`** with likelihood, impact, and a concrete mitigation.

Never carry an unresolved decision silently into drafting. Architecture choices in particular (data model, communication pattern, storage, API contracts) must be decided before any step is drafted — changing them mid-plan is the #1 cause of rework.

### `evidence` gate

Every requirement must have **at least one acceptance criterion carrying at least one typed evidence marker**. The closed marker vocabulary is:
- `test:<TestId>` — a named test that must exist and pass.
- `file:<path>#<assertion>` — `<assertion>` ∈ `exists` · `contains:<regex>` · `count>=<N>` · `dircount>=<N>`.
- `review:cr|dr` — a finding-class confirmed absent by code/design review (use only for absence claims).

A requirement whose acceptance criteria contain **no** typed marker fails this gate. Prose-only criteria ("works correctly") are not acceptable — they are not machine-checkable and cannot be verified under autopilot.

### `pre-draft` gate

Before drafting, enumerate every unresolved item (open questions, undecided architecture, missing acceptance criteria, requirements lacking a typed evidence marker). If the list is non-empty, **refuse to draft**: present the list, resolve each item with the user (or convert it to a `RISK-N`), then re-check. Only when the list is empty may drafting begin.

## Question Bank

Ask follow-ups on vague or incomplete answers — push for specifics.

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
- **At least one criterion per requirement must carry a typed evidence marker** (`test:`/`file:`/`review:`) — see the `evidence` gate above.

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

## Closing the interview

Once all areas are covered, run the `pre-draft` gate. When it passes, present a structured summary back to the user and ask: **"Does this capture everything? Anything to add or correct?"** — wait for confirmation before drafting.
