---
description: Two-tier plugin evaluation harness (structural + LLM), report generation, sandboxed backend execution, and judge contract
globs:
  - plugins/**/evals/**
  - scripts/skalary/Test-Evals.ps1
  - tests/evals/**
  - schemas/eval-case.schema.json
---

# Plugin Evals

## Transcript Capture Contract

Tier-2 backend capture is based on direct `copilot -p` process output plus optional `--share` export.

| Topic | Confirmed contract |
|---|---|
| Invocation | Run non-interactive `copilot -p "<prompt>" --no-ask-user --allow-all`; add `--agent <name>` for agent artifacts. |
| Assistant text channel | Assistant text is written to **stdout** and can be captured directly from the child process stream. |
| Tooling/stats noise | Usage stats and export notices are written to **stderr** (`Changes`, `AI Credits`, `Tokens`, `Session exported to...`), so stdout remains parseable assistant prose. |
| Completion signal | Process completion is the contract boundary: wait for exit, then consume full stdout buffer. Exit code `0` indicates normal completion. |
| Share transcript | `--share <path>` writes a markdown transcript file after completion; this is useful for debugging but not required for runtime extraction. |
| Timeout behavior | External timeout termination yields non-zero exit (observed `124` via `timeout`), with no guaranteed transcript payload; treat as backend failure/skip per policy. |
| Size behavior | Large outputs (observed ~5.4 KB content) are delivered on stdout without truncation in these probes; harness still enforces an input-size ceiling before invocation. |
| Cleanup | Harness owns temp transcript artifacts and deletes sandbox state in `finally`; only copied-out `.eval-artifacts/*.txt` files persist. |

### Off-ramp outcome (DR2-#8)

Off-ramp was **not required** in this spike: both a prompt-only invocation and an agent invocation produced parseable stdout assistant text.
