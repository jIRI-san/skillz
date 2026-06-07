# Drafting Guide (`cip` Step 4)

> Read this asset when drafting or refining `plan.md`. Keep the plan compact, executable, and machine-verifiable.

## Step drafting checklist

1. Use `./assets/plan-template.md` structure.
2. Keep steps as checklist lines, not prose blocks.
3. Every step references at least one `REQ-N`.
4. Add `[after: X.Y]` where dependencies exist.
5. Assign `S`, `M`, or `L` for each step.
6. Use `@human` only for true human-only actions.

## Evidence legend (required in Acceptance Criteria guidance)

Typed evidence markers:
- `test:<TestId>`
- `file:<path>#exists`
- `file:<path>#contains:<regex>`
- `file:<path>#count>=<N>`
- `file:<path>#dircount>=<N>`
- `review:cr|dr`

Every `REQ-N` must have at least one acceptance criterion containing at least one typed marker.

## Concision and decisions extraction

- Multi-paragraph rationale belongs in `decisions/<topic>.md`.
- Keep `plan.md` focused on requirements, risks, and executable steps.
- Link to extracted decisions from the Decisions section with one-line summaries.

## Size limits

- Warn at **20KB** or **400 lines**.
- Block at **35KB** or **700 lines**.

When approaching limits:
1. Extract rationale into `decisions/`.
2. Tighten step wording to action + scope + IDs.
3. Split oversized concerns into a sibling plan if needed.

## Phase budget guidance

- Include `<!-- phase-budget-points: N -->` in the plan header.
- Use `S=1`, `M=2`, `L=3` point mapping.
- Treat cap 6 per phase as advisory unless explicitly overridden in Decisions.

## State anchor and validator cadence

- Set/update `<!-- cip-stage: drafted -->` after drafting.
- Re-run `Test-Plan.ps1 -Stage Draft` after drafting and after each DR round.

## Capture section (`evolution-log.md`)

When drafting or refining a plan, initialize and maintain a delimited `## Capture` section in the plan folder `evolution-log.md` (separate from DR-round history):

```markdown
## Capture

No entries for this phase.
```

Record interview decisions and notable implementation assumptions in this section only, using one line per entry:

```text
- [interview] [step:<source-step>] <decision or assumption>
```

Initialize this section and commit `evolution-log.md` by explicit filename at phase start, even if no entries are added yet. Commit again whenever entries are appended.
