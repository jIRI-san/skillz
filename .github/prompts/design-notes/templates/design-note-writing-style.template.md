---
description: Required reading before writing or editing any design note. Defines audience, content priorities, and what to include vs omit. Load whenever creating or editing a design note.
globs:
  - docs/design-notes/**
---

# Design Note Writing Style

Design notes are **AI agent reference material** first, human digest second. Every content decision should optimize for fast, accurate agent context loading with minimal token consumption.

## Primary Audience: AI Agents

AI agents read design notes to:
- Understand project-specific conventions before generating code
- Apply architectural decisions without being told again each session
- Know what patterns to follow and what to avoid

Write for a capable developer who knows the technology but not **this project's specific choices**.

## Content Hierarchy

Include in priority order:

1. **Non-obvious project decisions** — why this approach over the alternative
2. **Architectural contracts** — key interfaces, types, data shapes (brief, not source copies)
3. **Patterns that deviate from the standard** — custom conventions the agent must know
4. **Hard constraints** — e.g. "feature names must not contain colons", "use actual node ID not container label"
5. **Minimal usage examples** — representative patterns for non-obvious API

Do not include:
- Tutorial walkthroughs (Step 1 / Step 2 / Step 3 sequences)
- DO/DON'T best-practice lists for general software engineering
- Future Enhancements, Conclusion, or Background context sections
- Code that mirrors source files verbatim — reference the file path instead
- Cross-cutting principles already stated elsewhere
- Date / Status header lines

## Format Rules

**Frontmatter description is the overview.** Never open the body with a "Purpose", "Overview", or "Background" section that paraphrases the frontmatter. Jump directly into architecture or patterns.

**Decision rationale is highest-value content.** Source code shows *what*; design notes must show *why*. Keep rationale dense and precise — it is the content the agent cannot derive from source.

**Tables beat bullet lists.** When describing multiple items with consistent attributes, use a table. Bullet lists with 3+ items that follow the same pattern should be a table.

**Compressed examples over full implementations.**

```text
// Show the essential pattern, not a 60-line full class definition
```

**Reference source over duplicating it.** `See <path/to/file>` is better than a copy of the file body.

**Cross-cutting principles live in one place.** Principles shared across many notes (e.g. "composition over inheritance") should live in a single conventions note; other notes reference it with a single sentence at most rather than repeating it.

## Required Frontmatter

```yaml
---
description: <what this covers and when to load it — this IS the overview>
globs:
  - <relevant path glob>
---
```

## Structure Template

```markdown
---
description: ...
globs: ...
---

# Title

[Optional: one sentence of context not captured in frontmatter — omit if redundant]

## Architecture

[Contracts, component map, key types — prefer table]

## Key Patterns

[Non-obvious usage with minimal code examples]

## Design Decisions

[Why this approach over alternatives — the highest-value section]

## Constraints

[Hard rules the agent must not violate]
```

Add sections only when the topic genuinely requires them. Never include empty sections.
