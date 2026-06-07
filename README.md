# skalary

Plugin-based GitHub Copilot customizations for prompts, skills, and agents.

## Installation

Bootstrap scripts and registry into a target repository:

```powershell
irm https://raw.githubusercontent.com/jIRI-san/skalary/c0dd31cd7b7a4f5544b052080d4d9f9bd937e0dd/scripts/skalary/bootstrap.ps1 | iex
```

`bootstrap.ps1` downloads `scripts/skalary/*.ps1` and `registry.json` into `scripts/skalary/`, creates `.github/.skalary/`, and does not execute plugin payload.

### Review Guidance

Before running the one-liner:
1. Review `scripts/skalary/bootstrap.ps1` at the pinned ref.
2. Confirm the repo/ref pair is the source you trust.
3. Prefer pinning immutable SHAs (not moving branches).

## Usage

Install a plugin (dependencies are resolved and installed automatically):

```powershell
pwsh -NoProfile -File scripts/skalary/Install-Plugin.ps1 -Name ci
```

Update an installed plugin to the registry version:

```powershell
pwsh -NoProfile -File scripts/skalary/Update-Plugin.ps1 -Name ci
```

Remove a plugin:

```powershell
pwsh -NoProfile -File scripts/skalary/Remove-Plugin.ps1 -Name ci
```

List registry plugins with install/modified/outdated state:

```powershell
pwsh -NoProfile -File scripts/skalary/Get-Plugin.ps1
pwsh -NoProfile -File scripts/skalary/Get-Plugin.ps1 -Installed
```

Search plugins by name/description/tags:

```powershell
pwsh -NoProfile -File scripts/skalary/Find-Plugin.ps1 -Query review
```

### Plugin-specific prerequisites

- `process-pr-comments`: requires GitHub CLI (`gh`) installed and authenticated for the current user (`gh auth login`), because the plugin resolves auth exclusively via `gh auth token`.

## Security Note (`irm | iex`)

`irm ... | iex` executes downloaded content in-process. This repository mitigates risk by pinning to immutable refs and keeping bootstrap behavior minimal, but you should still inspect the script before execution and use only trusted refs.

## Plugin Catalog

Generated from `registry.json` by `scripts/skalary/Build-Registry.ps1`.

<!-- BEGIN SKALARY PLUGIN CATALOG -->
| Plugin | Version | Status | Dependencies | Files | Description |
|--------|---------|--------|--------------|-------|-------------|
| `autopilot` | 1.1.0 | partial | — | 18 | Self-contained autopilot plugin payload for agent, skill, scripts, schemas, and devcontainer. |
| `code-review` | 1.0.0 | stable | — | 11 | Code review orchestrator with specialist subagents and git diff helpers. |
| `continue-implementation` | 1.0.0 | stable | autopilot, code-review | 3 | Code implementation workflow skill with autonomous execution guidance. |
| `create-implementation-plan` | 1.0.0 | stable | design-review | 5 | Implementation plan generation skill for coding workflows. |
| `design-notes` | 1.0.0 | stable | — | 5 | Design notes toolkit — /design-notes init bootstraps the docs/design-notes scaffold from bundled templates; /cdn and /udn create and update notes. |
| `design-review` | 1.0.0 | stable | — | 5 | Design review orchestrator with specialist model agents. |
| `process-pr-comments` | 1.0.0 | stable | — | 2 | Process PR comments skill for classifying, fixing, and replying to review feedback. |
<!-- END SKALARY PLUGIN CATALOG -->





