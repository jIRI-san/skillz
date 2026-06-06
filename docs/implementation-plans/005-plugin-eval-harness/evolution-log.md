# Evolution Log — 005 Plugin Eval Harness

Tracks design-review (DR) rounds: issues found, fixed, and deferred.

## Round 1
- Status: complete
- Models: Opus · Codex · Gemini (via @dr)
- Issues found: 15 (2 Critical, 5 High, 5 Medium, 3 Low)
- Issues fixed (applied to plan):
  - **[1] Critical** mutating headless agents → Tier 2 now runs in a **disposable git clone** (push blocked, synced, discarded); user chose to keep autopilot/cr/dr. (Decisions, REQ-13/21, RISK-2/10, steps 3.0/3.2/3.3/5.2)
  - **[2] Critical** link resolution false-fail → resolve from **simulated install (`dest`) base**. (Decisions, REQ-6, 1.1)
  - **[3] High** unimplementable schema-validate → **explicit dependency-free** field/type checks; schema file is documentation only. (Decisions, REQ-14/15, 3.1/3.2/3.3)
  - **[4] High** tests synced copy / staleness → sandbox syncs source + **sync-freshness drift gate** before agent cases. (REQ-21, 3.2/3.3)
  - **[5] High** transcript capture unspecified → added **spike step 3.0** (REQ-22, RISK-12) before backend build.
  - **[6] High** parser underspecified → narrowed to **top-level scalar presence**; nested/array opaque; tested vs cr/dr/ci/cip. (Decisions, 1.1)
  - **[7] High** cr/dr host mismatch → kept (user choice) with **fidelity caveat RISK-11**; rubrics target observable behaviour.
  - **[8] Medium** evals/ exclusion unverified → explicit verification in **5.2**.
  - **[9] Medium** no timeout → **hard per-invocation timeout + kill** in backend. (Decisions, REQ-13, 3.2)
  - **[10] Medium** "where applicable" → **per-type required-section table**. (Decisions, REQ-7)
  - **[11] Medium** name==stem wrong for skills → **type-aware name** (skill→folder). (REQ-4)
  - **[12] Medium** referenced-file extraction → **narrowed** to links + files[] + known assets. (Decisions, REQ-5)
  - **[13] Low** inlining → stated as **explicit non-goal**. (Decisions)
  - **[14] Low** report schema → **expanded** outcome enum + fields. (Decisions, REQ-11)
  - **[15] Low** resolver edge cases + config-missing → anchors/mailto/reference-style skip; **config-missing clean skip**. (Decisions, REQ-6/16)
- Issues deferred: none (all addressed or accepted).

## Round 2
- Status: complete
- Models: Opus · Codex · Gemini (via @dr)
- Issues found: 15 (1 Critical, 2 High, 7 Medium, 5 Low)
- Issues fixed (applied to plan):
  - **[1] Critical** sandbox evaluated **committed HEAD, not the working tree** → `New-EvalSandbox` now **overlays the live working-tree `plugins/` (incl. untracked `evals/llm/*.eval.json`)** onto the clone before sync, so Tier 2 judges the payload under development. (Decisions sandbox bullet, REQ-21, 3.2)
  - **[2] High** repointing `origin` to a bogus URL leaves attack surface **and breaks `Build-Registry` (reads origin)** → use **`git remote remove origin`**; assert `Build-Registry.ps1` succeeds in-sandbox; document cwd-not-filesystem isolation limit (container = real boundary). (Decisions, REQ-21, 3.2)
  - **[3] High** one clone per case (≥11 clones) → **clone once per `-IncludeLlm` run**, reuse the shared sandbox across all scenarios, dispose in `finally`. (Decisions, 3.2/3.3)
  - **[4] Medium** drift gate checked the wrong invariant (live `.github/` vs `plugins/`, unrelated to agent execution) → **dropped** the `Sync-Dogfood -WhatIf` gate; overlay makes it moot. (Decisions, REQ-21, 3.3)
  - **[5] Medium** `-WhatIf` throws on drift → moot once gate dropped (#4).
  - **[6] Medium** two report schemas (1.2 vs canonical) → **unified to one canonical entry shape**; step 1.2 emits it from the start. (Decisions, REQ-11, 1.2)
  - **[7] Medium** skip-vs-error ambiguity → missing auth/config is always **`skip` (green)**; `error`/non-zero only for post-preflight backend/judge failures. (Decisions, REQ-16/REQ-23, 3.2/3.5)
  - **[8] Medium** spike had no off-ramp → added **fallback ladder** (raw-stream → prompt/skill-only → defer Tier 2) + concrete deliverable in `plugin-evals.design.md`. (3.0)
  - **[9] Medium** `transcriptPath` pointed into the discarded sandbox → **copy transcript out** to gitignored `.eval-artifacts/<plugin>-<case>.txt` before disposal. (Decisions, 1.4/3.2)
  - **[10] Medium** `.Kill()` orphans child Node processes → **`$process.Kill($true)` tree-kill**. (Decisions, REQ-13, 3.2)
  - **[11] Low** fixed judge marker breakout → **per-call GUID-suffixed** boundary markers + neutralize literal boundary tokens in output. (Decisions, REQ-15, RISK-4, 3.2)
  - **[12] Low** inlined body unbounded → **input-size ceiling**; oversized = `skip`. (Decisions, 3.2)
  - **[13] Low** required keys accepted empty values → assert **non-empty scalars**; define **last-occurrence-wins** duplicate-key precedence. (Decisions, REQ-3, 1.1)
  - **[14] Low** REQ-8 too broad → restricted to **markdown-link-only** design-note refs (aligns with REQ-5). (REQ-8)
  - **[15] Low** registry `evals.status:"none"` misleading → documented as a **Known Issue** in `plugin-registry.design.md`. (4.2)
- Issues deferred: none (all addressed; #5 moot).

## Round 3 (final — 3-round cap)
- Status: complete
- Models: Opus · Codex · Gemini (via @dr); top finding verified against source
- Issues found: 9 (1 Critical, 2 High, 2 Medium, 4 Low)
- Issues fixed (applied to plan):
  - **[1] Critical** Round-2's `git remote remove origin` **deterministically breaks `Build-Registry.ps1`** — verified: `Resolve-OriginRepository` runs `git remote get-url origin` on every build and throws when origin is absent; also a local-path clone yields a filesystem origin its `github.com[:/]owner/repo` regex rejects. → Keep a **GitHub-shaped fetch URL** (read from live repo before cloning) and **disable push only** (`git remote set-url --push origin DISABLED`); the in-sandbox `Build-Registry` assertion is now satisfiable. (Decisions sandbox bullet, REQ-21, RISK-2/10, 3.2)
  - **[2] High** scenario authoring (3.4) not ordered before wiring/verify; REQ-18 never checked → added `[after:3.4]` to 3.5 + 5.3; new **auth-free count check 5.5** (≥1/plugin, ≥2 for cip/ci/cr/dr). (REQ-18, 3.5/5.3/5.5)
  - **[3] High** the sandbox no-mutation invariant was never actually run (5.2 is structural-only) → new step **5.4 runs `Test-Evals.ps1 -IncludeLlm`** (or stub backend) and asserts the live tree is byte-clean; REQ-21/RISK-2/RISK-10 verification anchor repointed to 5.4. (5.4)
  - **[4] Medium** 5.2 `[after:]` omitted 1.2/1.4 → now `[after:1.2,1.4,2.1–2.4]`. (5.2)
  - **[5] Medium** additive overlay left deleted/renamed working-tree files in the sandbox → **delete clone's `plugins/` then copy (replace, not merge)**. (Decisions, 3.2)
  - **[6] Low** structural report entries didn't specify `plugin`/`tier` → 1.2 derives `plugin` from path, sets `tier='structural'`. (1.2)
  - **[7] Low** 1.4 confirmed `.example` not-ignored before it exists (3.1) → moved confirmation to 5.1. (1.4/5.1)
  - **[8] Low** transcript filename collisions → `<caseStem>` = sanitized, uniqueness-asserted eval-case filename stem. (3.2/3.3)
  - **[9] Low** REQ-22 listed after REQ-23 → reordered. (Requirements table)
- Issues deferred: none. Plan declared execution-ready by the round (no remaining material issues after these edits).
