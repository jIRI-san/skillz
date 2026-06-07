## CR Capture
Phase: 4

- [4.2] [src:code-review] [sev:Med] Added pre-CR ledger-consult guidance to Step 5 execution flow so consult happens before `@cr`.

## CR Capture
Phase: 5

- [5.1] [src:code-review] [sev:Low] No substantive correctness or security findings in the canonical harvest finalization update.
- [5.2] [src:code-review] [sev:High] Mirrored harvest flow now requires `Remove-LedgerEntry.ps1` invocation via `ArgumentList` to preserve shell-injection safety parity with canonical autopilot guidance.
- [5.2] [src:code-review] [sev:High] Infra-missing fallback now preserves conditional `@human` escalation semantics (draft PR + marker + exit 42, no archive) instead of silently allowing archive flow.
- [5.2] [src:code-review] [sev:High] `/ci` mirror fallback now matches canonical branch semantics so missing infra cannot bypass required `@human` draft escalation behavior.
- [5.2] [src:code-review] [sev:High] Harvest prune contract now requires `Remove-LedgerEntry` mandatory arguments (`-Category`, `-CurrentPlan`) and no-op append handling, with mirror parity in both plugin and `.github` assets.
- [5.2] [src:code-review] [sev:High] Finalization ordering now explicitly requires post-archive push before PR creation and `/udn`-before-Remove candidate derivation with prune preconditions.
