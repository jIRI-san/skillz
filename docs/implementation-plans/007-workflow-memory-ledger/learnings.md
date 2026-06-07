## Learnings Capture
Phase: 4

- [4.2] [trigger:rework>1] Place pre-CR context requirements in the Step 5 execution path, not only in Step 6 crosscheck guidance.

## Learnings Capture
Phase: 5

- [5.2] [trigger:rework>1] Mirror documentation must restate command-construction safety constraints for both Add and Remove script invocations, not just one side.

## Learnings Capture
Phase: 6

- [6.1] [trigger:rework>1] Design-note deltas that update finalization behavior should retire legacy ordering rows in the same edit to avoid split-contract drift.
- [6.4] [trigger:reusable-pattern] ScriptAnalyzer can miss parameter use inside scriptblocks; capture to a local variable before lock/closure blocks to keep analyzer-clean intent explicit.
- [6.4] [trigger:reusable-pattern] Typed evidence markers should map to explicit, grepable Pester test IDs to keep phase crosschecks machine-verifiable.
