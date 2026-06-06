---
name: autopilot
description: Autonomous execution mode orchestration for /ci
user-invocable: false
disable-model-invocation: true
---

# Autopilot (Autonomous Execution)

## Overview

This skill is read by `/ci` when the user chooses **Autonomous** mode. It handles first-run `.autopilot.json` bootstrap and then launches autonomous execution through `.github/skills/autopilot/scripts/launch.ps1`.

The launcher is the sole reader of `.autopilot.host.json`. The skill and the autopilot agent never read, create, or modify `.autopilot.host.json` or `.autopilot.host.json.example`.

## When invoked by /ci

1. Confirm plan slug from `/ci` context.
2. Run first-run config bootstrap (next section).
3. Show autonomous mode sub-menu.
4. Run launcher command for the chosen runtime.
5. Print: "Autonomous execution started — exiting /ci flow."

## First-run config bootstrap

1. Check repo root for `.autopilot.json`.
2. If file exists, continue.
3. If file is missing:
   - Interview for: `runtime`, `copilotAuth`, `gitProvider`, `gitAuth`, `model`, `git.name`, `git.email`, `timeout`, `maxIterationsPerStep`, `build`, `test`.
   - Start from `.github/skills/autopilot/.autopilot.json.example`.
   - Write `.autopilot.json` at repo root.
4. Structurally validate `.autopilot.json` (no JSON-Schema validation):
   - Required fields exist: `runtime`, `copilotAuth`, `gitProvider`, `gitAuth`, `model`, `git`, `timeout`, `maxIterationsPerStep`, `build`, `test`.
   - Types: string fields are strings; `timeout` and `maxIterationsPerStep` are numbers; `git` is an object with string `name` and `email`.
5. If validation fails, stop with a loud actionable error. Do not invoke launcher.

## Mode sub-menu

Offer autonomous modes:

- **Host autopilot** (static label, never derived from host config)
- **Container autopilot**
- **Sandbox autopilot**

If `AUTOPILOT_DISABLE_HOST=true`, omit **Host autopilot** from this menu.

For container and sandbox only, ask:

**Start from which branch? (Current / main)**

- Current branch: pass `-Branch <current-branch>`
- main: pass `-Branch main`

Host mode does not ask branch follow-up.

## Custom host command

Host mode may use `.autopilot.host.json`, but only the launcher reads it.

Security warning:

- Host command runs headlessly with no approval prompt.
- Only point `command` to a trusted binary.
- Invalid host config fails loud before phase execution.
- If host config file is absent, launcher defaults to `copilot`.
- This file is host-only; container and sandbox never read it.

## Launcher invocations

Use the installed launcher path and the delivered signature:

- Host:
  - `.github/skills/autopilot/scripts/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime host`
- Container:
  - `.github/skills/autopilot/scripts/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime container -Branch <chosen-branch>`
- Sandbox:
  - `.github/skills/autopilot/scripts/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime sandbox -Branch <chosen-branch>`

After invoking, print: **Autonomous execution started — exit /ci flow.**
