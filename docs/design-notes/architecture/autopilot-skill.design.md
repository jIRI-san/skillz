---
description: The internal autopilot SKILL.md — /ci Autonomous-mode handoff, first-run .autopilot.json bootstrap, mode sub-menu, and the launcher contract. Load when editing the autopilot skill, the /ci execution-mode menu, or the custom host-command flow.
globs:
  - plugins/autopilot/skills/**
  - plugins/ci/skills/**
  - .autopilot.json
  - .autopilot.host.json
---

# Autopilot Skill

The `autopilot` plugin ships two same-named customizations distinguished by type: the **agent** (`agents/autopilot.agent.md`, the per-phase executor invoked by `launch.ps1`) and the **skill** (`skills/autopilot/SKILL.md`, the in-editor mode-selection + bootstrap entry point). They never collide because VS Code keys customizations by type.

## Architecture

| Concern | Owner | Notes |
|---|---|---|
| Mode selection (`/ci` Autonomous) | skill | Presents Host / Container / Sandbox sub-menu |
| First-run `.autopilot.json` bootstrap | skill | Interviews user, writes config, structurally validates |
| Per-phase code execution | agent | Loaded by Copilot CLI inside the launcher loop |
| Headless launch + dispatch | `launch.ps1` | Validates config, dispatches to mode orchestrator |
| `.autopilot.host.json` read | `launch-host.ps1` only | Sole reader — neither skill nor agent touches it |

## Key Patterns

**Read-by-path, not skill-invocation.** The skill sets `user-invocable: false` + `disable-model-invocation: true` (no `context: fork`). `/ci` does not *invoke* it as a skill — it **reads `.github/skills/autopilot/SKILL.md` by path** and follows the steps inline. There is no `/autopilot` slash command.

**Launcher signature is reproduced verbatim** from the install path, only re-pathed:

```text
.github/skills/autopilot/scripts/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime host|container|sandbox [-Branch <branch>]
```

Container and Sandbox carry the "Start from which branch? (Current / main)" follow-up via `-Branch`. Host uses its own `feature/<slug>` worktree and omits the follow-up. **The plan path is not a config field** — `launch.ps1`/`launch-host.ps1` derive `docs/implementation-plans/<PlanSlug>/plan.md` from `-PlanSlug`, so `.autopilot.json` never carries a (stale) plan path.

**First-run bootstrap is in-editor only.** When the user picks Autonomous, the skill checks for repo-root `.autopilot.json`; if absent it interviews (runtime, auth target, git provider/auth, build/test, model, timeout), writes from `.autopilot.json.example`, then **structurally validates** required fields/types — mirroring `launch.ps1`'s hand-rolled checks, *not* JSON-Schema validation (`Test-Json` cannot validate draft 2020-12). Headless `launch.ps1` never interviews; it fails loud if the file is missing.

## Design Decisions

**Skill ships in `autopilot`, not `ci`.** It co-locates with the scripts it drives (reverses an earlier `ci`-ownership decision). `ci` keeps its existing `autopilot` dependency. This makes `autopilot` a single self-contained plugin — agent + skill + scripts + schemas + devcontainer + config templates all install under `.github/skills/autopilot/**` (agent stays at `.github/agents/`).

**`/ci` menu collapsed to three options:** Approve · Autopilot · **Autonomous**. The prior inline Host/Container/Sandbox prose moved entirely into this skill. `AUTOPILOT_CONTAINER=true` suppresses Autonomous in `/ci` (already inside an autonomous container).

**Static Host label.** The skill shows a fixed "Host autopilot" label and never reads `.autopilot.host.json` — preserving the "launcher is sole reader" invariant and the agent/skill no-read rule (agent Absolute Rule #10).

## Custom Host Command

`launch-host.ps1` may run a custom Copilot CLI executable (e.g. a corporate wrapper injecting MCP servers) instead of vanilla `copilot`. Configured via operator-provisioned, gitignored `.autopilot.host.json` at the repo root, validated by `schemas/autopilot.host.schema.json` (draft 2020-12). `Resolve-HostCommand` (in `host-command.ps1`, dot-sourced by `launch-host.ps1` only) reads it once, resolves `command` to an absolute path, classifies type (`exe`/`bat`/`cmd`/`ps1` by extension), and returns `@{ Path; Type; ExtraArgs }`.

Security layers (defense in depth — the host launcher runs **headlessly with no approval prompt**):

| Layer | Control |
|---|---|
| Default | Absent config → `copilot`, type classified by the resolved shim's extension (npm shims are `*.cmd`), no extra args |
| Fail-loud | Present-but-invalid (malformed JSON, empty `command`, shell metachar) → throw before any phase starts; never silent-fallback |
| No-shell | Direct-`.exe` branch uses `ProcessStartInfo.ArgumentList`; `.bat`/`.cmd`→`cmd.exe /c` and `.ps1`→`powershell.exe -File` use denylist-backed per-token quoting |
| Operator toggle | `AUTOPILOT_DISABLE_HOST=true` → skill omits Host **and** `launch.ps1` refuses `-Runtime host` |
| Trust model | Host = trusted env; gitignore keeps the file host-local and out of PRs/clones; agent/skill forbidden to read or write it |

The residual local-persistence risk (an untrusted build/test script planting `.autopilot.host.json` for the next headless launch) is **accepted and documented** — see RISK-5 in the plan and the schema `description`.
