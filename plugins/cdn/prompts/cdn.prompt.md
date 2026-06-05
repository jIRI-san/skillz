---
description: Create a new design note file. Usage: /cdn <name> — e.g. "/cdn architecture update" creates architecture-update.design.md
name: cdn
agent: agent
---

Create a new design note based on the name provided after `/cdn`.

## Derive the filename

Take the name that follows `/cdn` in the chat input, convert it to lowercase kebab-case, and append `.design.md`.

Examples:
- `architecture update` → `architecture-update.design.md`
- `job scheduling` → `job-scheduling.design.md`
- `retry policies` → `retry-policies.design.md`

## Steps

1. **Read the governance rules** from [docs/design-notes/.design-notes.md](../../docs/design-notes/.design-notes.md). Pay attention to the frontmatter format and the "Adding a New Skill" checklist.

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

5. **Update `.github/copilot-instructions.md`**:
   - Add an `<instruction>` entry inside the `<instructions>` block that describes when to load the new design note (mirror the style of the existing entries)
