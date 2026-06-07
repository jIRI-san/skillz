## CR Capture
Phase: 4

- [4.2] [src:code-review] [sev:Med] Added pre-CR ledger-consult guidance to Step 5 execution flow so consult happens before `@cr`.

## CR Capture
Phase: 5

- [5.1] [src:code-review] [sev:Low] No substantive correctness or security findings in the canonical harvest finalization update.
- [5.2] [src:code-review] [sev:High] Mirrored harvest flow now requires `Remove-LedgerEntry.ps1` invocation via `ArgumentList` to preserve shell-injection safety parity with canonical autopilot guidance.
