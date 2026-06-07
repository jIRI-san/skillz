---
description: Initialize the design-notes scaffold. Usage: /design-notes init (or /design-notes bootstrap) — creates the docs/design-notes/ structure from the templates bundled with this prompt.
name: design-notes
agent: agent
---

Create the initial `docs/design-notes/` structure from the templates bundled alongside this prompt.

## Usage

- `/design-notes init` — scaffold the design-notes structure.
- `/design-notes bootstrap` — alias for `init`.

Both arguments behave identically. If no argument (or an unrecognized one) is given, default to `init` behavior.

## Steps

1. **Check whether the scaffold already exists** at [docs/design-notes/.design-notes.md](../../docs/design-notes/.design-notes.md).
   - If it exists, report `design-notes already initialized` and stop. Do **not** overwrite anything.

2. **Create the folders** `docs/design-notes/` and `docs/design-notes/project/`.

3. **Copy the bundled templates** (never overwrite an existing target):
   - [./design-notes/templates/design-notes-index.template.md](./design-notes/templates/design-notes-index.template.md) → `docs/design-notes/.design-notes.md`
   - [./design-notes/templates/design-note-writing-style.template.md](./design-notes/templates/design-note-writing-style.template.md) → `docs/design-notes/project/design-note-writing-style.design.md`

4. **Report** the created files and point the user at the next steps:
   - `/cdn <name>` — create a new design note.
   - `/udn` — update design notes from the current chat session.

> The templates are repo-agnostic starting points. After init, edit `docs/design-notes/.design-notes.md` to describe your project and add rows to the Available Skills table as you create notes.
