---
description: Two-tier plugin evaluation harness (structural + LLM), report generation, sandboxed backend execution, and judge contract
globs:
  - plugins/**/evals/**
  - scripts/skalary/Test-Evals.ps1
  - tests/evals/**
  - schemas/eval-case.schema.json
---

# Plugin Evals

## Architecture

| Tier | Scope | Execution mode | Gate policy |
|---|---|---|---|
| Structural | Pester evals in `plugins/<name>/evals/*.Tests.ps1` validate frontmatter, required keys, names, links, and referenced assets | Always-on via `scripts/skalary/Test-Evals.ps1` | Always-on in `npm run eval`; not part of `npm test` / `scripts/validate.ps1` |
| LLM | Declarative scenarios in `plugins/<name>/evals/llm/*.eval.json` scored by LLM-as-judge | Opt-in with `-IncludeLlm` | Never part of `npm test` / `scripts/validate.ps1` |

The harness entry point is `scripts/skalary/Test-Evals.ps1`. `npm run eval` is the documented pre-commit path for this subsystem.

## File Layout and Contracts

| Surface | Contract |
|---|---|
| `plugins/<name>/evals/*.Tests.ps1` | Tier-1 structural assertions per plugin, using shared helpers |
| `plugins/<name>/evals/llm/*.eval.json` | Tier-2 cases with `{ artifact, scenario, rubric[], passThreshold }` |
| `tests/evals/EvalCommon.psm1` | Structural helper module (frontmatter parse, required keys, link/file resolution, section checks) |
| `tests/evals/EvalLlm.psm1` | LLM helper module (config/auth preflight, sandbox lifecycle, backend invocation, judge validation) |
| `schemas/eval-case.schema.json` | Documentation/IDE aid for case shape; runtime validation is explicit field/type checks in PowerShell |

## Backend and Isolation Boundary

Tier-2 execution is backend-pluggable (`copilot-cli` now, `container` reserved). Current execution uses Copilot CLI headless inside a disposable sandbox clone created once per run:

- clone repo to temp dir
- replace sandbox `plugins/` with live working-tree `plugins/` (delete-then-copy)
- run `Sync-Dogfood.ps1` in sandbox
- set sandbox `origin` fetch URL to the real GitHub URL
- disable sandbox push URL (`DISABLED`)
- run cases, then delete sandbox in `finally`

This prevents live-tree mutation during no-approval `--allow-all` eval runs. The isolation boundary is sandbox cwd only; container backend is the stronger filesystem boundary. Under `--allow-all`, a scenario can still target live-repo absolute paths, so sandbox cwd is not a filesystem containment guarantee.

## Config and Auth

Tier-2 reads a gitignored `.eval.config.json` (shape documented by committed `.eval.config.json.example`):

| Key | Purpose |
|---|---|
| `judgeModel` | Judge model slug (no identity hardcoded in committed files) |
| `credentialTarget` | Optional Windows Credential Manager target holding the eval PAT; loaded into `COPILOT_GITHUB_TOKEN`/`GH_TOKEN`, mirroring autopilot `copilotAuth.credentialTarget`. A dedicated eval secret (e.g. `copilot-eval`) keeps eval auth separate from `copilot-autopilot` |
| `temperature` / `passThreshold` / `timeoutSeconds` | Judge/run tuning; optional fields fall back to `.example` defaults |

Credential resolution is skip-not-error: an unset `credentialTarget` falls back to ambient `copilot` auth; a set-but-missing target (or missing `CredentialManager` module) records an actionable `skip` and keeps the run green.

On first `-IncludeLlm` run, a missing `.eval.config.json` is bootstrapped from the example; the scaffolded file keeps the `<slug>` placeholder so the run skips with a note pointing at the new file to fill in.

## Known Limitations

| Limitation | Current handling |
|---|---|
| `cr`/`dr` CLI fidelity | `cr`/`dr` are VS Code-hosted orchestrators; headless `copilot --agent` may not reproduce full subagent fan-out/model-vendor resolution. Tier-2 rubrics for these plugins target observable orchestrator behavior (e.g., injection-safe handling and structured findings), not exact multi-model consensus output. |

## Judge Contract and Injection Guard

| Aspect | Contract |
|---|---|
| Verdict format | Strict JSON `{ pass, score, rationale }` |
| Validation | Explicit field/type/range checks; non-JSON verdict fails loudly |
| Prompt safety | Captured output wrapped in GUID-suffixed `<<<UNTRUSTED_OUTPUT_*:{guid}>>>` markers with quad-tick fencing |
| Boundary hardening | Any literal boundary token in captured output is neutralized before wrapping |
| Pass decision | `pass` requires `score >= passThreshold` |

## Report and Writeback Model

Each run writes a timestamped folder `tests/evals/output/<yyyy-MM-dd_HH-mm-ss>/` (gitignored) containing `report.json` (structured summary + per-entry verdicts), `report.md` (human-readable summary + judge rationale), and any Tier-2 transcripts (`<plugin>-<case>.eval.txt`). The folder name uses filesystem-safe separators (no `:`); collisions in the same second get a `-<fff>` suffix. Registry/manifests/receipts stay unchanged:

| Surface | Status |
|---|---|
| `plugin.json` `evals` seams (`status`, `lastRun`) | Reserved, not populated by harness |
| `registry.json` `evals.status` | Reserved-seam summary, not runtime writeback |
| `.github/.skalary/receipts/*` `evalStatus` | Reserved, not populated by harness |

Receipt/registry writeback is intentionally deferred; harness is report-only to preserve deterministic registry output and dogfood drift behavior.

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
