---
description: Create a new design note file. Usage: /cdn <name> — e.g. "/cdn architecture update" creates architecture-update.design.md
name: cdn
agent: agent
---

Create a new design note based on the name provided after `/cdn`.

## Step 0: Ensure the design-notes scaffold exists

Before anything else, confirm the design-notes scaffold is present in this repository:

1. Check whether [docs/design-notes/.design-notes.md](../../docs/design-notes/.design-notes.md) exists.
2. **If it is missing**, run the `/design-notes init` bootstrap first — it creates `docs/design-notes/` + `docs/design-notes/project/` from the bundled templates (see [design-notes.prompt.md](./design-notes.prompt.md)). Then continue.
3. **If it already exists**, continue.

## Derive the filename

Take the name that follows `/cdn` in the chat input, convert it to lowercase kebab-case, and append `.design.md`.

Examples:
- `architecture update` → `architecture-update.design.md`
- `job scheduling` → `job-scheduling.design.md`
- `retry policies` → `retry-policies.design.md`

## Steps

1. **Read the governance rules** from [docs/design-notes/.design-notes.md](../../docs/design-notes/.design-notes.md). Pay attention to the frontmatter format and the "Adding a New Skill" checklist. Also read the writing-style guide at `docs/design-notes/project/design-note-writing-style.design.md`.

2. **Infer scope and content** from:
   - Relevant source files already in the workspace that relate to the named topic
   - Anything discussed in this chat session about the topic
   - If neither applies, generate a well-structured skeleton with placeholder sections

3. **Create `docs/design-notes/<subfolder>/<derived-filename>`** choosing the appropriate subfolder (`testing/`, `orchestration/`, `ui/`, or `project/`) based on the topic:
   - YAML frontmatter (`description`, `globs` covering the relevant source paths)
   - An _Overview_ section explaining what the subsystem/topic is
   - An _Implementation_ section with current patterns and code examples
   - A _Design Decisions_ section explaining key "why" choices
   - A _Limitations / Trade-offs_ section for known constraints

4. **Update `docs/design-notes/.design-notes.md`**:
   - Add a row to the Available Skills table for the new file

> No change to `.github/copilot-instructions.md` is required — it loads `.design-notes.md` as the single discovery layer, so a new row in the Available Skills table is enough for the agent to find the note.
