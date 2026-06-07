# Design Notes

Pattern-specific context documents for AI-assisted development. Each file contains implementation guidance, design decisions, and conventions for a specific subsystem.

## How These Work

These documents serve as **contextual skills** that AI agents load automatically when working on relevant code:

- **VS Code Copilot**: `.github/copilot-instructions.md` contains a single `<instruction>` entry for this file. The agent loads this index first, then reads the relevant design note(s) from the table below based on the task at hand.

## Maintenance Protocol (Required)

Whenever implementation changes touch any component covered by these design notes, updating the corresponding `*.design.md` file(s) is required as part of the same change.

Update the relevant design note(s) to include:

- Current implementation details and behavior changes
- Relevant examples (or updated existing examples)
- Design decisions and rationale (the "why")
- Limitations, constraints, or trade-offs explicitly imposed by the user/request

Do not treat design-note updates as optional follow-up documentation; they are part of the implementation definition of done.

When a new component/subsystem is created, create the corresponding design note in `docs/design-notes/` as part of the same implementation change.

Prefer consistency: design and implement so changes fit existing architecture, patterns, naming, and stylistic conventions. Follow established project patterns unless a documented design decision explicitly requires divergence.

## Frontmatter Format

```yaml
---
description: What this skill covers and when to use it
globs:
  - .github/**
---
```

## Available Skills

| File | Scope | Key Patterns |
|---|---|---|
| [design-note-writing-style.design.md](project/design-note-writing-style.design.md) | `docs/design-notes/**` | AI agent audience, content hierarchy, format rules, what to include vs omit |

## Adding a New Skill

1. Create `<topic>.design.md` in the appropriate subfolder (`project/` for meta/tooling notes; add new subfolders per subsystem as the repo grows).
2. Add YAML frontmatter with `description` and `globs`.
3. Add a row to the Available Skills table above.
4. No changes to `.github/copilot-instructions.md` required.
