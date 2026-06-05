---
description: Development and tooling rules for this repo — terminal commands, agent workflows, and conventions that affect CI/automation.
globs:
  - .github/**
  - .vscode/**
---

# Dev Rules

## Terminal Commands

- **Never start a PowerShell command with `&` or wrap `.ps1` scripts with `powershell -File`** — both break VS Code Copilot agent auto-approval (it won't approve commands starting with `&` or `powershell`). The terminal is already PowerShell; invoke everything directly:
  - `dotnet build` not `& dotnet build`
  - `.github/agents/scripts/get-diff-uncommitted.ps1 --files` not `powershell -File .github/agents/scripts/get-diff-uncommitted.ps1 --files`
  - If calling a variable-path executable, assign it first then call by name.

- **Never use `git add -A`, `git add .`, or `git add --all`** — stage only files the agent directly created or modified. Blanket staging risks committing unrelated or temporary files:
  - `git add src/Foo.cs src/Bar.cs` not `git add -A`

## Code Formatting

- **Always use the project formatter — never format code by manual edits.** In .NET repos with `.editorconfig`, run `dotnet format` before committing instead of reformatting code inline.
  - The formatter applies all `.editorconfig` rules consistently.
  - Do not attempt to fix formatting warnings by editing individual lines.

## Git History

- **Never use `git push --force`, `git push --force-with-lease`, or `git commit --amend` on pushed commits.** If a commit needs fixing, create a follow-up commit instead. Force-pushing rewrites shared history and can disrupt CI, other collaborators, and PR references.
