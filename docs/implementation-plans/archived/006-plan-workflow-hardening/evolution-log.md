# Evolution Log — 006 Plan Workflow Hardening

Records design-review (DR) round history for this plan. DR agents are given this log to avoid re-reporting fixed issues or contradicting prior deliberate decisions.

## Pre-DR (drafting)

- Interview completed across all `cip` dimensions; key reframe mid-interview: the **central goal is a repo-scoped self-improving feedback loop** — persist all interview decisions, all DR/CR outputs, and execution learnings, then feed them back into `cip`/`ci` so results improve over time.
- Architecture locked in Decisions: thin-orchestrator + bundled assets; per-category workflow-memory ledger (`docs/review-ledger/`) with four feeders (cip/dr/cr/ci) and two readers (cip/ci); persisted `cr-log.md` (CR was previously ephemeral); typed `Evidence` column with `ci` execution + `evidence.md` receipt; `Test-Plan.ps1` deterministic validation; S/M/L phase-budget points (cap 6, advisory).
- Manual cross-reference check: 25 REQ / 10 RISK / 22 steps — no orphans, all `[after:]` deps resolve, every step references ≥1 REQ (5.5 fixed to add REQ-6/REQ-8).
- Phase budgets: Phases 1/2/4 exceed the 6-point cap (8/7/7). Accepted as advisory warnings — plan is `execution-mode: manual` and phases are cohesive. Flagged inline.
- Size: ~28.5KB / 132 lines — under the active 30KB warn; dense tables, not prose bloat.

## Round 1

Three models (Opus, Codex, Gemini). 19 findings (1 Critical, 7 High, 8 Medium, 3 Low).

**Critical/High fixed:**
- **#1 (Critical) `cmd:` executes untrusted plan text** → removed `cmd:` **and** `manual:` evidence types entirely (user decision: everything must work under autopilot, the primary mode). Remaining types `test:`/`file:`/`review:` are all machine-verifiable inside autopilot. Trust-boundary contradiction (autopilot Rule 5) eliminated.
- **#2 overclaimed determinism** → reframed orchestrator instructions as best-effort prompts; hard enforcement concentrated in `Test-Plan.ps1` + gates.
- **#3 autopilot bypasses the loop** → autopilot now a first-class loop participant (deterministic appends: ledger, `evidence.md`, `cr-log.md`); design split so all loop parts run under autopilot. Plus a **conditional `@human` Finalization** step (user idea): autopilot self-assesses and escalates via exit 42 only when evidence is unverifiable or harvest needs judgment, else completes autonomously.
- **#4 `test:` had no executor** → added a `test:unit` Pester gate (`npm run test:unit` over `tests/skalary/**`); documented Pester-in-container requirement.
- **#5 legacy plans vs evidence enforcement** → defined `<!-- evidence: required -->` opt-in marker; evidence/size checks warn-only without it; integrity checks apply to all plans.
- **#6 bootstrap circularity** → integrity always enforced; `test:`/`file:` target resolution warns at draft, blocks at crosscheck — so 006 validates green before Phase 4 lands its validator.
- **#7 ledger over-engineered** (user decision: compromise) → kept per-category files (user's explicit choice for scoped consultation) but **dropped per-append dedup**; dedup+prune happen once at finalization.
- **#8 `file:` anchors uncheckable** → closed assertion vocabulary `exists | contains:<regex> | count>=N`; validator rejects free-form anchors.

**Medium/Low fixed:** #9 folded `Test-Plan` integrity into the real `validate.ps1` gate; #10 merged typed evidence markers into the Acceptance Criteria column (user decision — no separate column); #11 dedup moved to finalization (resolves on-demand contradiction); #12 added asset-preservation checklist + inline non-negotiables; #13 phase budget kept advisory; #14 parser skips fenced code blocks + documented grammar + real-plan fixtures; #15 target-resolution timing (warn-at-draft/block-at-crosscheck); #16 design-note reconciliation of Rule 5 + Pester dependency added to REQ-26; #17 prune trigger defined (finalization); #18 REQ-25 no-op dropped, restated as one-time assertion in 2.6; #19 `cr` diff-scope trade-off noted (committed branch deltas retained).

**New risks added:** RISK-11 (autopilot escalation mis-judgement), RISK-12 (Pester unavailable in container).

**Plan grew:** 28 REQ / 12 RISK / 24 steps; 32.4KB (over the new 20KB warn it introduces — dense tables; under 35KB block). Integrity re-verified clean: no orphans, all `[after:]` deps resolve, every step references ≥1 REQ.

## Round 2

Three models (Opus, Codex, Gemini). 9 findings (4 Critical, 4 High, 1 Medium).

**Decisive outcome — SPLIT.** All three models independently flagged the plan as two coupled deliverables (28 REQ / 32.4KB), and the coupling was the *root cause* of round-1's bootstrapping Criticals. User accepted the split: **006 = enforcement spine** (thin orchestrators + `Test-Plan.ps1` + evidence + autopilot-loop coherence); **007 = workflow-memory ledger + capture/harvest** (created as a sibling plan, `depends-on: 006`). The ledger/feeders/readers/`cr-log`/`learnings`/harvest REQs moved out of 006 into 007.

**Critical fixed:**
- **#1 stateless `validate.ps1` can't know draft vs crosscheck** → `Test-Plan.ps1` gains an explicit `-Stage Draft|PhaseCrosscheck|PlanCrosscheck`; the repo-wide gate runs `-Stage Draft` (target resolution warn-only) so 006 never self-blocks on later-phase artifacts; crosscheck/finalization run blocking stages.
- **#2 Pester never installed in the container** → a pinned `Install-Module Pester` step added to the autopilot Dockerfile (REQ-15 / step 2.5), not just documented.
- **#3 exit 42 conflates mid-plan block with done-needs-human and drops the PR** → finalization now creates a **draft PR (`@human` label) + a distinct status marker** (`.autopilot-finalize-needed`) **before** exit 42; `container-entrypoint.sh` maps the marker to "request human finalization"; archive/PR ordering defined (REQ-21 / step 4.3).
- **#4 DAG inversion** (`3.1 [after: 4.2]` — evidence verification depended on a later validator phase) → reordered so the **validator (Phase 2) precedes evidence verification (Phase 3)**; deps now point backward only.

**High fixed:**
- **#5 `test:unit` not wired into autopilot + Rule 5 contradiction** → `.autopilot.json` `test` = composite `npm run validate-plan && npm run test:unit && npm test`; Absolute Rule 5 **amended** to authorize this fixed, committed, config-defined evidence-runner (plan-text strings still never executed); reconciled in the design note (REQ-19, REQ-24).
- **#6 unconditional integrity fails legacy plans** → integrity blocking gated on `<!-- evidence: required -->`; legacy plans (003/004/005) warn-only; suffix-tolerant ID grammar `\d+\.\d+[a-z]?` (verified — plan 004 uses `3.2a`); legacy added as passing fixtures (RISK-5).
- **#7 `file:` evaluator lacks path-confinement / ReDoS guard** → repo-root confinement (reject absolute/`..`/symlink), size caps, `contains:` regex compiled with a timeout; covered by `Test-Plan.Security.NoCodeExec` + `FileConfinement` (REQ-14, RISK-9).
- **#8 simplicity gate** → the split (above).

**Medium fixed:** #9 `contains:` colon-parsing ambiguity + missing directory count → `contains:` is literal-to-end-of-token, plus a distinct `dircount>=N` verb separate from file `count>=N`.

**New this round (user directive):** all `cip`/`ci`/autopilot validation must run through pre-approvable `.ps1` scripts — added as cross-cutting **REQ-9** (no inline validation; existing inline checks extracted into `Test-Plan.ps1`) with a verification step (5.1).

**Plan shrank:** 26 REQ / 12 RISK / 19 steps; 29.7KB (under 35KB block; over 20KB warn — dense meta-plan). Integrity re-verified clean: no orphans, all `[after:]` deps resolve backward, every step references ≥1 REQ.

## Round 3

Three models (Opus, Codex, Gemini); `dr-codex` drifted onto 007 and was discarded, its logic/timing slot covered by the orchestrator. 9 findings (1 Critical, 3 High, 5 Medium) — all in round-3 deltas; none re-litigate a locked decision. All applied.

**Critical fixed:**
- **#1 composite `.autopilot.json` `test` is rejected by the host allowlist + lets the agent rewrite its own evidence-runner** — verified against [launch.ps1](../../../scripts/autopilot/launch.ps1) (`StartsWith` check, `&&` forbidden) and [autopilot.schema.json](../../../schemas/autopilot.schema.json) (`test` regex). The composite `npm run validate-plan && …` can never launch, and step 4.1 had the agent edit `.autopilot.json` mid-run (un-fixing "fixed evidence-runner"). → composite moved into **`package.json` `test`** (`npm run validate-plan && npm run test:unit && pwsh -NoProfile -File scripts/validate.ps1` — direct call, no `npm test` recursion); `.autopilot.json` `test` stays allowlist-clean `npm test`; Rule 5 blesses only the unchanged `npm test`; REQ-19 evidence → `file:package.json#contains:validate-plan`; RISK-8 reframed.

**High fixed:**
- **#2 `file:` evaluator "exposed for reuse" had no callable contract** (whole-plan script only) → extracted into a dot-sourceable `PlanEvidence` callable (or `-VerifyEvidence` param set) imported by both `Test-Plan.ps1` and the crosscheck verify entrypoint, so delegation is a real script not in-chat (honors REQ-9). REQ-14 + steps 2.2/3.1 updated.
- **#3 REQ-18 archival gate lived only in the ci asset; `autopilot.agent.md` archives unconditionally** → step 4.3 rewrites the agent's "On Plan Completion" to read `evidence.md` and block on `✗`/unrun; REQ-18 evidence → `file:…autopilot.agent.md#contains:archival-gate`.
- **#4 `file:` evaluator residual security** (symlink-loop in `dircount`, lexical vs semantic `..` normalization, per-match-only ReDoS budget) → canonicalize-then-confine, no-follow-symlinks/cycle-safe walk, global per-file regex budget. REQ-14 + step 2.2.

**Medium fixed:**
- **#5 step 3.2 `-Stage PlanCrosscheck` in Phase 3 self-blocks on later-phase targets** → 3.2 only *wires* the gate; the blocking stage *executes* only at true finalization after Phase 5.
- **#6 Finalization `@human` collides with Absolute Rule 7** (immediate exit-42, no PR) → step 4.3 carves the Finalization step out of Rule 7: verify → push → draft-PR → marker → exit 42.
- **#7 composite gate needs Pester on host/local but only the container Dockerfile patched** → `test:unit` skips-with-actionable-message when Pester absent; `validate.ps1` stays dependency-free. REQ-15 + step 2.4.
- **#8 finalization wired only into `container-entrypoint.sh`; host mode mishandles the marker** → conditional finalization scoped to container-autopilot; host mode stated unsupported in REQ-21.
- **#9 marker commit-status + push/PR ordering undefined** → uncommitted gitignored marker; sequence commit → push → `gh pr create --draft` → marker → exit 42; marker added to `.gitignore` in step 4.3.

**Plan after fixes:** 26 REQ / 12 RISK / 19 steps; 34.4KB (under the 35KB block, but tight — round-3 rationale added bulk; candidate for `decisions/` extraction if it grows). Integrity re-verified clean.
