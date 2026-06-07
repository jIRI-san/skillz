# Workflow-Memory Ledger

Repo-scoped durable lessons harvested from plan execution and review loops.

## Category taxonomy

1. `security.md`
2. `performance.md`
3. `error-handling.md`
4. `consistency.md`
5. `plan-structure.md`
6. `testing.md`
7. `observability.md`

## Entry format

Each entry is one line:

`- [YYYY-MM-DD] <one-line lesson> (plan-NNN, src:cip|dr|cr|code-review|ci|autopilot, sev:Critical|High|Med|Low) #tags`

## Normalization and dedup contract

`normalized-lesson` is computed deterministically from `<one-line lesson>`:

1. Trim leading/trailing whitespace
2. Convert to invariant lowercase
3. Collapse internal whitespace runs to one space
4. Standardize punctuation spacing
5. Normalize to Unicode NFC
6. Apply length cap after normalization

Two keys are derived from `normalized-lesson`:

1. **Idempotence key**: `category + normalized-lesson + plan + src + severity + sorted-tags`
2. **Recurrence key**: `category + normalized-lesson + sorted-tags`

Idempotence prevents duplicate appends for the same stage retry. Recurrence allows later-plan repeats and records recurrence as immutable append-only evidence.

## Recurrence count and retention

Recurrence count is computed only over active entries (category files), excluding anything in `.archive/`.

Pruning rules:

1. Never prune current-plan entries.
2. Never prune entries above the active recurrence threshold.
3. Prune only prior-plan entries explicitly flagged obsolete/superseded.
4. Pruned entries move to `docs/review-ledger/.archive/` as tombstones; no hard-delete.

## Reader behavior

This ledger is **never auto-loaded**. Consult it **on demand** and only read relevant categories.
