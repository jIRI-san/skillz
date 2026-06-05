---
description: Copilot customization setup for this repo — file inventory, design note loading strategy, and how to add new customizations. Load when working on .github/copilot-instructions.md, prompts, agents, skills, or instructions files.
globs:
  - .github/**
---

# Copilot Customizations

All customizations are **workspace-local** — everything lives under `.github/` in this repo. No user-level files are created or modified.

## File Inventory

| File | Type | Purpose |
|---|---|---|
| `.github/copilot-instructions.md` | Workspace Instructions | Always-on project context; single `<instruction>` entry loads `.design-notes.md` as the discovery layer for all contextual design notes |
| `.github/prompts/cdn.prompt.md` | Prompt (`/cdn`) | Creates a new design note file from a name argument |
| `.github/prompts/udn.prompt.md` | Prompt (`/udn`) | Updates design notes from the current chat session |
| `.github/prompts/cr.prompt.md` | Prompt (`/cr`) | Code review entry point |
| `.github/prompts/dr.prompt.md` | Prompt (`/dr`) | Design review entry point |
| `.github/agents/dr.agent.md` | Agent (`dr`) | Design review orchestrator — reviews a plan using three specialist models |
| `.github/agents/dr-opus.agent.md` | Subagent (hidden) | Design reviewer (Claude Opus) — invoked by `dr` only |
| `.github/agents/dr-codex.agent.md` | Subagent (hidden) | Design reviewer (GPT Codex) — invoked by `dr` only |
| `.github/agents/dr-gemini.agent.md` | Subagent (hidden) | Design reviewer (Gemini) — invoked by `dr` only |
| `.github/agents/cr.agent.md` | Agent (`cr`) | Code review orchestrator — reviews git changes using three specialist models |
| `.github/agents/cr-opus.agent.md` | Subagent (hidden) | Code reviewer (Claude Opus) — invoked by `cr` only |
| `.github/agents/cr-codex.agent.md` | Subagent (hidden) | Code reviewer (GPT Codex) — invoked by `cr` only |
| `.github/agents/cr-gemini.agent.md` | Subagent (hidden) | Code reviewer (Gemini) — invoked by `cr` only |
| `.github/agents/autopilot.agent.md` | Agent (`autopilot`) | Autonomous plan execution — implements one phase per invocation, builds, tests, commits |
| `.github/agents/scripts/get-diff-*.ps1` | Helper scripts | Git diff helpers used by `cr` for discovery (branch, commits, files, paths, smart default, uncommitted) |
| `.github/skills/cip/SKILL.md` | Skill (`/cip`) | Create Implementation Plan — requirements interview, phased plan with step tracking, iterative `dr` review, saves to `docs/implementation-plans/` |
| `.github/skills/ci/SKILL.md` | Skill (`/ci`) | Continue Implementation — executes a plan step-by-step, manages git worktrees, build/test iteration, `cr` review, explicit commit gate |

## Design Note Loading Strategy

`copilot-instructions.md` contains a **single** `<instruction>` entry pointing to `docs/design-notes/.design-notes.md`. That root file is the discovery layer — it lists all available design notes with their scopes. The agent reads the index first, then loads relevant design notes based on the task.

This approach:
- Keeps `copilot-instructions.md` stable when design notes are added or renamed
- Eliminates duplication between the instructions file and the index
- Makes `.design-notes.md` the single source of truth for what context to load

## Adding a New Customization

**New design note** — use `/cdn <name>` or follow the steps in `docs/design-notes/.design-notes.md`. No change to `copilot-instructions.md` required.

**New prompt** — create `.github/prompts/<name>.prompt.md` with YAML frontmatter (`name`, `description`, `mode: agent`).

**New skill** — create `.github/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`, `user-invocable`, `disable-model-invocation`). Add bundled assets under `assets/`. Use skills for multi-step workflows; use prompts for single focused tasks.

**New agent** — create `.github/agents/<name>.agent.md` with YAML frontmatter and tool/model restrictions as needed.

**New instruction file** — create `.github/instructions/<name>.instructions.md` with `applyTo` glob patterns. Use specific path globs; avoid `applyTo: "**"`.

## Review Agents (dr / cr)

Both `dr` and `cr` use an orchestrator + three specialist subagent pattern. The orchestrator handles discovery, context loading, batching, injection guarding, and synthesis. The subagents are stateless reviewers that know nothing about the orchestration.

**Model assignments:**

| Role | Emphasis |
|---|---|
| `*-opus` | Architecture, patterns, design consistency |
| `*-codex` | Logic correctness, error handling, edge cases |
| `*-gemini` | Security (OWASP), performance, resource management |

All three subagents perform a **comprehensive review** across every important dimension — correctness, security, performance, consistency, dead/commented-out code, duplication (flagged when the same logic appears 3+ times), code style, and adherence to project patterns. The emphasis column above reflects where each model tends to shine, not a hard boundary.

> The concrete model identifier lives in the `model:` field of each `*.agent.md` file. If an identifier doesn't match your Copilot subscription, update it there. Format: `"Model Name (copilot)"`.

**Batching threshold:** > 15 changed files triggers batch mode for `cr`; > 200 lines triggers batch mode for `dr`. Batches are split by subsystem (mapped from design note globs) to keep related files together and avoid false findings from split context.

**Severity consensus rule:** if all three models independently flag the same issue, severity is elevated one level.

**Prompt injection guardrails:** all reviewed content (plan text, diffs) is wrapped in `<<<UNTRUSTED_INPUT_START>>>` / `<<<UNTRUSTED_INPUT_END>>>` markers with quad-tick fencing before being passed to any subagent. Subagents are explicitly instructed to treat content inside those markers as data only and to flag directive-looking content as a Critical finding.

**Git operations:** always use terminal `execute` commands — never MCP git tools.

## Implementation Workflow Skills (cip / ci)

`cip` and `ci` are workspace **skills** (`SKILL.md` under `.github/skills/`) — multi-step workflows invocable via `/cip` and `/ci`. Both have `disable-model-invocation: true` so they only load when explicitly called.

**`cip` flow:**
1. Load all relevant design notes
2. Locate or create plan folder `docs/implementation-plans/NNN-<slug>/` with `plan.md`
3. Thorough requirements interview across all dimensions (goals, API surface, error handling, testing, observability, security, performance, migration)
4. Draft plan: Decisions log + Requirements table + Risks table + Phases with `[ ]`/`[x]`/`[~]` step markers
5. Mode-dependent save: agent mode writes the file directly; plan mode uses session memory with handoff offer
6. Iterative `@dr` review (max 3 rounds) — re-runs if High/Critical findings require significant changes

**`ci` flow:**
1. Select plan from `docs/implementation-plans/`; load relevant design notes
2. Choose execution mode (approve / autopilot / host / container / sandbox)
3. Branch detection: on main/master → create git worktree + open new VS Code window (`code <path>`); on feature branch → continue
4. Branch name recorded as `<!-- worktree: <branch-name> -->` in the plan file to avoid derivation drift
5. One step at a time: mark `[~]` → implement → build+test → validate acceptance criteria → `@cr` review → explicit commit gate
6. Commit: `feat(<scope>): <step title> [plan-NNN step X.Y]`; plan file updated in same commit
7. On all steps `[x]`: plan-level crosscheck → mark plan `[DONE]` in title → move folder to `docs/implementation-plans/archived/`

**Plan file format** (designed to be scannable by a human reviewer — no prose implementation instructions):
```markdown
# NNN: Plan Title

## Decisions
- Key decision made during planning

## Requirements
| ID | Requirement | Acceptance Criteria | Phases/Steps |

## Phase 1: Name
<!-- worktree: feature/<plan-slug> -->
- [ ] 1.1 Step title (REQ-1)
- [~] 1.2 Step title (in progress)
- [x] 1.3 Step title (done)
```

See [autopilot-execution.design.md](../autopilot-execution.design.md) for the autonomous (host/container/sandbox) execution infrastructure that backs the `ci` skill's autopilot modes.
