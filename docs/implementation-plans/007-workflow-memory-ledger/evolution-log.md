# Evolution Log — 007 Workflow-Memory Ledger & Learning Capture

Records design-review (DR) round history for this plan. DR agents are given this log to avoid re-reporting fixed issues or contradicting prior deliberate decisions.

## Capture

No entries for this phase.

## Origin — split from 006 (round 2)

- Created at 006's DR round-2 simplicity gate. All three models flagged 006 as two coupled deliverables; the coupling caused 006's round-1 bootstrapping Criticals. The **workflow-memory ledger + learning capture/harvest** subsystem was extracted here.
- `depends-on: 006` — the ledger-write/consult hooks target 006's `assets/*.md`, and the harvest routes through 006's conditional finalization step. Sequence 007 after 006 is archived.

## Pre-DR (drafting)

- Inherits all user-accepted ledger decisions: per-category files under `docs/review-ledger/` (security, performance, error-handling, consistency, plan-structure, testing, observability + README); entry format `- [YYYY-MM-DD] <lesson> (plan-NNN, src:.., sev:..) #tags`; five feeders (cip/dr/cr/ci/autopilot), two readers (cip/ci); persisted `cr-log.md` + `learnings.md`; harvest+prune at finalization; never auto-loaded.
- **Reversed a round-1 006 deferral with a better mechanism:** round-1 dropped per-append dedup because "an LLM can't reliably dedup a file it hasn't read." 007 introduces `Add-LedgerEntry.ps1` — a pre-approvable script doing **deterministic** append + dedup — so per-append dedup is now cheap and safe (it reads the single small category file). This also satisfies 006's new validation-in-scripts principle (REQ-9): no LLM-improvised ledger edits.
- Stateless review subagents never write; only orchestrators invoke the script. Ledger + script are repo infra (not plugin payload).
- Integrity check: 9 REQ / 5 RISK / 12 steps, 13KB — no orphans, all `[after:]` deps resolve backward, every step references ≥1 REQ. Phase budgets all within the 6-point cap.

## Round 1

Three models (Opus, Codex, Gemini) in parallel. 20 findings (2 Critical, 9 High, 6 Medium, 3 Low). Triaged with the user; all applied via a structural redesign.

**Root-cause redesign — harvest-only durable write.** The cluster #1 (autopilot ledger writes vs Rule 5), #2 (`dr` has no `execute` tool), #4 (mid-run + harvest double/triple-write), #11 (autopilot has no "CR round"), #12 (standalone `cr` has no plan id), #16 (`cr` can't label recurrence) shared one root cause: "five live feeders each writing the durable ledger" is mechanically broken. **Resolution (user-approved):** mid-run, orchestrators write only to per-plan **ephemeral logs** (`evolution-log.md`/`cr-log.md`/`learnings.md`); the durable ledger is written **once at harvest** (the Finalization step) via the pre-approvable scripts. One script, one place, one Rule-5 carve-out — same outcome (all sources reach the ledger). This collapsed #1/#2/#4/#11/#12/#16 together.

**Critical fixed:** #1 + #2 — via the harvest-only redesign (no mid-run autopilot/dr ledger writes); the single finalization carve-out names `Add-LedgerEntry.ps1` + `Remove-LedgerEntry.ps1` in Rule 5.

**High fixed:**
- **#3 prune was an unscripted destructive LLM edit** → added `Remove-LedgerEntry.ps1` (script-mediated delete, retention guard, tombstone/archive, visible diff). REQ-5 + step 1.3.
- **#4 double/triple-write** → single durable-write path (REQ-6).
- **#5 no step authored the Pester tests REQ-2 needs** → added test-authoring step 1.4 + quality gate 5.4.
- **#6 untrusted entry text can forge ledger lines** → sanitize `-Entry`/`-Tags` (strip CR/LF/control, collapse ws, cap, fail-loud). REQ-3 + RISK-5.
- **#7 "atomic append" not concurrency-safe (TOCTOU)** → exclusive per-category `Mutex` + temp-file replace. REQ-4.
- **#8 dedup key undefined** → idempotence key (date-excluded, plan-included) vs recurrence key (lesson+category+tags), the latter annotate-only. REQ-2.
- **#9 no enforceable 006 preflight** → phase-0 `Skalary.Dependency.Plan006Present` test that blocks/escalates. REQ-12 + step 0.1.
- **#10 category→path not confined** → lowercase-slug `ValidateSet` + path from slug only + reuse 006's confinement helper. REQ-3 + RISK-8.
- **#11 + #12** — `cr-log.md` defined per mode (interactive `@cr` vs autopilot `code-review`, `src:code-review`); standalone `cr` persists nothing. REQ-7.

**Medium fixed:** #13 reader taxonomy → map plan REQs/risks → category files (load only relevant small files); #14 weak/mis-typed evidence → retyped artifact REQs to `file:`/`test:`, reserved `review:` for absence claims; #15 `-Src`/`-Severity` unconstrained + missing `Critical` → `ValidateSet` both, `Critical` added to severity enum; #16 recurrence detection moved into `Add-LedgerEntry.ps1`; #17 capture triggers undefined → defined triggers (rework>1/surprise/reusable) + per-plan cap (REQ-8).

**Low fixed:** #18 repo-root-relative invocation via `$PSScriptRoot`/`-RepoRoot` (REQ-13); #19 stale `cip-stage: dr-round-2` → `dr-round-1`; #20 standard conditional `@human` Finalization step confirmed as the harvest/prune host (Phase 4). (The "no Phase headers" note was a condensed-copy artifact — not a real defect.)

**Plan after redesign:** 15 REQ / 9 RISK / 15 steps (+ Phase 0 preflight); 22.7KB (over 20KB warn, under 35KB block). Integrity verified clean: no orphans, all `[after:]` deps resolve backward, every step references ≥1 REQ.

## Round 2

Three models in parallel. 21 findings (3 Critical, 9 High, 8 Medium, 1 Low). Triaged with the user; all 21 applied, plus the user-chosen **host/interactive harvest trigger** for #4. **Theme:** the round-1 harvest-only redesign resolved the feeder problems but **concentrated the entire durable write into 006's container-only finalization step**, creating new coupling. The three Criticals are all consequences of that concentration.

**Critical fixed:**
- **#1 harvest body lived in a `ci` asset, but autopilot never loads `ci` assets** (006's own reason for putting the archival gate in the agent) → the ledger would never populate under autopilot. **Resolution:** the harvest procedure now lives in `autopilot.agent.md`; REQ-11 + step 4.1 edit the agent; evidence `file:plugins/autopilot/agents/autopilot.agent.md#contains:harvest`.
- **#2 phase-0 preflight only *authored* a test + "wired cip/ci"** — autopilot runs phases directly, so nothing blocked a missing-006 run until step 5.4. **Resolution:** 0.1 is now a **hard start-gate** the runner + `ci` honor (hard-fail/exit at plan start); every 006-touching step carries `[after: 0.1]`. REQ-13.
- **#3 step 4.1 bundled append (`Add`) + destructive prune (`Remove`) + `/udn` into one block** → either the autonomous path skipped the ledger or prune ran unsupervised. **Resolution (split harvest):** `Add` runs + commits **before** the autonomous-vs-escalate branch (populates on every completion, survives exit 42); `Remove` prune + `/udn` run **only on the `@human`-escalated branch**. REQ-6 + 4.1.

**High fixed:**
- **#4 durable write hung off 006's container-only finalization** → host `/ci` + interactive `/cip` captured but never harvested; loop dead off-container. **Resolution (user-chosen):** a parallel **host/interactive `/ci` harvest trigger** running the same shared scripts. New REQ-12 + step 4.2; RISK-10.
- **#5 ephemeral logs written outside a step's modified files** → Rule 3 (no `git add -A`) meant they might never commit, and fresh-context harvest couldn't read them. **Resolution:** each phase stages + commits its logs **by name**; harvest fails-loud if missing. REQ-9 + RISK-11; steps 2.1/2.2/2.3/4.1.
- **#6 harvest↔archive↔PR ordering undefined.** **Resolution:** order fixed — harvest→stage `review-ledger/*`→commit→push→[escalate: prune+`/udn`]→archive→`gh pr create`. REQ-6 + 4.1.
- **#7 preflight asserted "the `PlanEvidence` callable" but 006 ships it as `.psm1` OR a `-VerifyEvidence` param set** → false-fail. **Resolution:** assert **behaviorally** (`Get-Command`/param probe + known pass/fail), not by filename. REQ-13 + 0.1.
- **#8 recurrence "annotation" storage form undefined** → mutate-count breaks idempotent re-run. **Resolution:** immutable append model + "recurrence re-run idempotent" test. REQ-2.
- **#9 retention guard "above-recurrence-threshold" not computable.** **Resolution:** recurrence count = pure scan over **active** entries (excludes `.archive/`) by recurrence key. REQ-5.
- **#10 Rule-5 carve-out → shell injection** if the agent interpolates untrusted args. **Resolution:** mandate **argument-array / `Start-Process -ArgumentList`** invocation, never a shell string. REQ-11 + RISK-12; 4.1.
- **#11 `Remove -Match` from poisoned content → ReDoS / over-deletion.** **Resolution:** literal `-SimpleMatch`/`[string]::Equals`, regex disabled; over-deletion test. REQ-5 + RISK-6.
- **#12 tombstone location undefined** → `ledger-consult` globbing might re-load pruned content. **Resolution:** excluded `docs/review-ledger/.archive/`; readers omit it; test. REQ-5/REQ-10.

**Medium fixed:** #13 per-category Mutex defended a phantom (real collision is cross-worktree git-merge) → **workspace-scoped** Mutex + merge-time deterministic ordering + idempotent replay (REQ-4 + RISK-12); #14 `normalized-lesson` (basis of both keys) undefined → deterministic normalization (trim/invariant-lowercase/collapse/punctuation/NFC/cap) in contract + tests (REQ-2/REQ-3); #15 harvest "distill" had no durability rubric → explicit rubric + deterministic per-plan candidate staging (folded into 4.1/learnings triggers); #16 reader rubric covered only 2 of 7 categories → **full 7-category** mapping rubric in `drafting-guide.md` (REQ-10 + 3.1); #17 `evolution-log.md` overloaded (DR-history vs capture) → delimited `## Capture` section with its own schema (REQ-8 + 2.3); #18 sanitization stopped newlines but not in-line metadata forgery → neutralize structural delimiters `( ) , #`/`src:`/`sev:` in free text + forgery test (REQ-3 + RISK-5); #19 `/udn` is interactive but its autopilot invocation undefined → defined as inline reconciliation routing to draft-PR + exit 42 (REQ-11 + 4.1); #20 `learnings.md` "soft cap" unbounded → hard per-plan cap + overflow→summary, each learning carrying trigger-type + source step (REQ-7 + 2.2).

**Low fixed:** #21 step 5.2 named `dr`/`cr` agents no step edits → manifest scope aligned to actually-touched assets (`cip`/`ci` + `autopilot` agent), ledger-infra-excluded assertion kept. REQ-16 + 5.2.

**Plan after round 2:** 16 REQ / 12 RISK / 16 steps (+ Phase 0); 25.7KB (over 20KB warn, under 35KB block). Integrity verified clean: no orphans, no undefined refs, all `[after:]` deps resolve backward, every step references ≥1 REQ. Locked decisions for round 3: harvest-only durable write; harvest procedure in `autopilot.agent.md`; split append (always) vs prune+`/udn` (escalation); host/interactive `/ci` harvest trigger; per-phase ephemeral-log commit; behavioral 006 start-gate; literal-match prune; `.archive/` tombstones.

## Round 3 (final)

Three models in parallel. 13 findings (2 Critical, 1 High, 7 Medium, 3 Low) — all NEW, no re-reports. All 13 applied. **Theme:** emergent interactions between the round-2 locked decisions, not contradictions of them. The DR round budget (max 3) is now exhausted.

**Critical fixed:**
- **#1 finalization written as one linear track but must be a two-branch decision tree** — the `archive→gh pr create` tail was unbracketed (read as applying to the escalation path too → re-opens RISK-7), plus two missing pushes (post-archive: PR head lacks the archive commit; post-prune: escalation edits left uncommitted before `exit 42`). **Resolution:** explicit autonomous vs escalation branches in the Decisions + step 5.1 + agent, archive/real-PR bracketed autonomous-only, both missing pushes added. REQ-6.
- **#2 harvest block in `autopilot.agent.md` (plugin payload, synced downstream) invokes `scripts/skalary/*.ps1` + `docs/review-ledger/` (repo infra, in no manifest)** → every downstream autopilot finalization would crash. **Resolution:** wrap the harvest block in `if (Test-Path scripts/skalary/Add-LedgerEntry.ps1)`, fall through to standard finalization when absent; new RISK-13 + REQ-11 marker `#contains:Test-Path scripts/skalary`. Step 5.1.

**High fixed:**
- **#3 escalation prune's target set undefined** given the locked current-plan retention guard (append ran first, so the only current-run entries are current-plan = guard-protected → prune was an under-specified no-op/destructive improvisation). **Resolution:** prune **tombstones prior-plan `/udn`-flagged obsolete/superseded entries**; current-plan + above-threshold stay guard-protected; `RetentionGuard` test refuses a matched current-plan entry. REQ-5 + step 2.1.

**Medium fixed:** #4 autopilot capture (primary mode) had weak markers (`#contains:commit`/`argument` already in the file) → added behavior-specific anchors `#contains:cr-log`, `#contains:learnings`, `#contains:ephemeral logs by name`, `#contains:ArgumentList`, `#contains:No entries for this phase` (REQ-9/REQ-11); #5 off-container 006 gate vacuous (Pester skips on host, where `Add` still needs a 006 helper) → added an off-container non-Pester hard-fail check wired into runner plan-start + `/ci` entry (REQ-13 + step 0.1); #6 "strip CR/LF/control" missed Unicode line separators (U+2028/2029/0085/VT/FF) → strip the full Unicode line-break set + forgery test (REQ-3 + RISK-5); #7 "fail-loud on missing logs" collided with legitimately-absent conditional logs → per-phase init/commit of placeholder logs with `No entries for this phase.`, harvest fails only on a missing section (REQ-9 + RISK-11); #8 Phase 1 was 9 pts bundling both security-critical scripts + tests in one fresh-context window → **split into Phase 1 (store + `Add` + tests) and Phase 2 (`Remove` + tests), renumbering all downstream phases** (capture→3, readers→4, harvest→5, design/registry→6); #9 "shared procedure" fiction (autopilot can't load `ci` assets) → `autopilot.agent.md` named **canonical**, `crosscheck-guide.md` a **marked mirror** with a parity note (REQ-12 + `#contains:mirror`); #10 `-SimpleMatch` is substring not line-equality → full-line `[string]::Equals(...,Ordinal)`, "SimpleMatch" reserved for the regex-disabled property, substring-collision test (REQ-5).

**Low fixed:** #11 `Remove` `-Category` confinement/ValidateSet not restated on the destructive path → restated + `RejectsBadCategory` test (REQ-5 + RISK-8 now references step 2.1); #12 step "update `files[]`" likely a no-op → reframed as verification (REQ-16 + step 6.2); #13 "merge-replay idempotence" asserted but untested → real 3-way merge fixture test + "re-run `Add` to resolve" documented (REQ-4 + step 1.3).

**Plan after round 3:** 16 REQ / 13 RISK / 17 steps across 7 phases (0–6); 29.2KB (over 20KB warn, under 35KB block). Integrity verified clean: no orphans, no undefined refs, all `[after:]` deps resolve backward, every step references ≥1 REQ. **DR rounds exhausted (3/3).** No residual Known Plan Issues — all surfaced findings across three rounds were applied.
