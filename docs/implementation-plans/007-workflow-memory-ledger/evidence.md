Phase 1 Crosscheck:
✓ REQ-1 — file:docs/review-ledger/README.md#contains:recurrence — passed — 271068b
✓ REQ-1 — file:docs/review-ledger#dircount>=8 — passed — 271068b
✓ REQ-2 — test:Add-LedgerEntry.Dedup — passed — 271068b
✓ REQ-2 — test:Add-LedgerEntry.RecurrenceNotSkipped — passed — 271068b
✓ REQ-2 — test:Add-LedgerEntry.RecurrenceReRunIdempotent — passed — 271068b
✓ REQ-3 — test:Add-LedgerEntry.SanitizesUnicodeBreaks — passed — 271068b
✓ REQ-3 — test:Add-LedgerEntry.RejectsForgery — passed — 271068b
✓ REQ-3 — test:Add-LedgerEntry.RejectsBadCategory — passed — 271068b
✓ REQ-4 — test:Add-LedgerEntry.ConcurrentAppend — passed — 271068b
✓ REQ-4 — test:Add-LedgerEntry.ThreeWayMergeReplay — passed — 271068b
✓ REQ-14 — file:scripts/skalary/Add-LedgerEntry.ps1#contains:PSScriptRoot — passed — 271068b

Phase 2 Crosscheck:
✓ REQ-5 — test:Remove-LedgerEntry.FullLineEquality — passed — 7d651a9
✓ REQ-5 — test:Remove-LedgerEntry.RejectsBadCategory — passed — 7d651a9
✓ REQ-5 — test:Remove-LedgerEntry.RetentionGuard — passed — 7d651a9
✓ REQ-5 — test:Remove-LedgerEntry.NoSubstringOverDelete — passed — 7d651a9
