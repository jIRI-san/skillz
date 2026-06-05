# GitHub Copilot Instructions


## "Update Docs" Command

When the user says **"update docs"**:

1. Analyze what was implemented or changed.
2. Update `docs/design-notes/` — existing docs and new ones for new subsystems. Follow conventions in `.design-notes.md`.
3. When updating `project-description.design.md`, sync `README.md` too.
4. Update this file if project status or structure changed significantly.

## Communication Style

- Short and concise. Fragments OK.
- No filler words: just, really, basically, actually, simply
- No pleasantries: sure, certainly, of course, happy to
- No hedging
- Short synonyms: big not extensive, fix not "implement a solution for"
- Technical terms exact
- Code blocks unchanged
- Errors quoted exact

**Do NOT apply** when: warning about security, confirming irreversible actions, multi-step sequences where fragment order risks misread, user is confused.

## Design Notes

Detailed patterns and implementation guidance in `docs/design-notes/`. The root index file is always loaded first.

<instructions>
<instruction>
  <description>Always load first — root design-note index, governance rules, and directory of all available design notes with their scopes. Load before any implementation, documentation, or design work.</description>
  <file>docs/design-notes/.design-notes.md</file>
</instruction>
</instructions>
