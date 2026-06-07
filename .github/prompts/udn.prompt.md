---
description: Update design notes based on what was implemented or changed in this chat session
name: udn
agent: agent
---

Review the current chat history and update the design notes in `docs/design-notes/` to reflect any implementation changes, new components, or architectural decisions that were made.

## Step 0: Bootstrap the design-notes scaffold (first run)

Before anything else, ensure the design-notes scaffold exists in this repository:

1. Check whether [docs/design-notes/.design-notes.md](../../docs/design-notes/.design-notes.md) exists.
2. **If it is missing**, bootstrap it (this is a fresh repo):
   - Create the folders `docs/design-notes/` and `docs/design-notes/project/`.
   - Copy the index seed [./design-notes/assets/design-notes-index.seed.md](./design-notes/assets/design-notes-index.seed.md) to `docs/design-notes/.design-notes.md`.
   - Copy the writing-style seed [./design-notes/assets/design-note-writing-style.seed.md](./design-notes/assets/design-note-writing-style.seed.md) to `docs/design-notes/project/design-note-writing-style.design.md`.
   - Do **not** overwrite either file if it already exists — bootstrap only fills in what is missing.
3. **If it already exists**, skip bootstrap and continue.

## Instructions

1. **Read the governance rules** from [docs/design-notes/.design-notes.md](../../docs/design-notes/.design-notes.md) first.

2. **Analyze the chat** for:
   - New components, subsystems, or files created
   - Changed behavior or implementation patterns
   - Architectural decisions and their rationale
   - Trade-offs, constraints, and limitations that were explicitly discussed or imposed

3. **Update existing design notes** that cover the changed areas. For each update include:
   - Current implementation details reflecting the new state
   - Code examples (add new ones or update existing)
   - The "why" behind decisions — not just what changed

4. **Create a new design note** if a new subsystem or component was introduced that has no existing design note. Follow the frontmatter format from the governance file.

5. **Update `docs/design-notes/.design-notes.md`** (the Available Skills table) if a new design note was created.

6. **Keep it accurate and specific** — only update sections that are actually affected by the changes in this chat. Do not rewrite unrelated content.

> Do not create a changelog or summary file. Update only the design notes in `docs/design-notes/`.
