# Evolution Log — Plan 003: Autopilot Skill Extraction

Tracks DR (design review) rounds. Each round records issues found, fixed, and deferred.

## Round 1

**Reviewers:** Opus · Codex · Gemini (via `@dr`).

**Issues found (11):**
1. [Critical] Skill reading `.autopilot.host.json` for menu label contradicts "launcher is sole reader" + agent rule.
2. [Critical] Verbatim `launch.ps1` signature (`-PlanSlug/-Runtime/-Mode whole-plan/-Branch`) doesn't match Plan 001's real `-Mode host|container` contract; byte-match verification entrenches the break. Sandbox deferred by Plan 001.
3. [High] RISK-2 mitigation too weak; skill plugin-ownership unresolved; Plan 002 drift-check would flag orphan.
4. [High] Gitignored local config is a persistent arbitrary-exec vector (untrusted build script plants file for next run).
5. [Medium] REQ-5 ACs assert runtime behavior this plan can't deliver/verify.
6. [Medium] Present-but-invalid `.autopilot.host.json` corner case unspecified.
7. [Medium] Byte-diff verification (3.4) reads wrong baseline (HEAD already thinned).
8. [Medium] Net-new custom-host feature overweight/misplaced in an extraction plan.
9. [Medium] Plan 002 "future Plan 003" numbering collision.
10. [Low] REQ-7 ".example validates against schema" only checked as valid JSON, not schema-conformant.
11. [Low] Inert invocation frontmatter; handoff is textual include not invocation; `context: fork` inert.

**Issues fixed (10):** 1 (static label, drop `displayName`, read+write rule), 2 (reconcile to `-Mode host|container`, sandbox marked unavailable, `-Branch`/`planPath` forward-spec, REQ-3/RISK-4 → semantic match), 3 (`ci`-plugin ownership decision + REQ-12, raised impact, durable embedding), 5 (REQ-5 rescoped to deliverables), 6 (fail-loud on present-but-invalid), 7 (3.4 verifies against Plan 001 contract, pre-extraction `/ci` captured here if needed), 9 (numbering-collision note + recommend eval harness → Plan 004), 10 (3.4 uses `Test-Json -SchemaFile`), 11 (drop `context: fork`, document include-vs-invoke).

**Issues deferred / open:**
- **#4 + #8 (custom-host-command config surface) — RESOLVED.** User chose to keep the gitignored `.autopilot.host.json` file (operator-trust model). Added: (1) honest note that the host launcher runs headless via `launch.ps1`→`Process` with **no VS Code approval popup** (so the vector isn't gated by a dialog); (2) loud security warning in design note + schema `description` + skill; (3) `AUTOPILOT_DISABLE_HOST=true` env-var toggle (mirrors `AUTOPILOT_CONTAINER`) so repo owners can disable host mode org-wide from outside the repo. Residual local-persistence risk accepted & documented in RISK-6. New REQ-13. #8's "split into a separate plan" rejected — user scoped the custom command into this plan.

No more DR rounds requested. Round 1 closed.

**Pre-extraction `/ci` launcher reference (for verification baseline):** the live `/ci` Step 1 issues `scripts/autopilot/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime host|container|sandbox [-Branch <chosen-branch>]`. ⚠️ **This was wrongly believed fictional in Round 1 — see Reconciliation below. It matches the delivered launcher exactly.**

## Reconciliation with delivered Plan 001 (post–Round 1)

**Trigger:** User reported Plan 001 is **complete** and shipped **differently** from its plan text — it supports **all three runtimes** (host/container/sandbox). Verified by reading the delivered scripts.

**Reality vs. Round-1 assumptions:**
- `scripts/autopilot/launch.ps1` real signature: `-PlanSlug <slug> -Mode whole-plan|next-phase -Runtime host|container|sandbox [-Branch]` — **matches the original `/ci` text verbatim**.
- `scripts/autopilot/launch-sandbox.ps1` exists — **sandbox is fully built, not deferred**.
- `-Branch` is a **real** parameter on `launch.ps1` + `launch-host.ps1`.
- `launch-host.ps1` `Invoke-CopilotPhase` exists and hardcodes `Get-Command copilot` — a **real seam** for the custom host command.
- `schemas/autopilot.schema.json` is **draft 2020-12**, not draft-07.
- `PSScriptAnalyzerSettings.psd1` + `.editorconfig` exist; **no Pester harness yet**.

**DR-#2 reverted.** Round-1 finding #2 (treat the `/ci` signature as fictional, reconcile to `-Mode host|container`, mark sandbox unavailable, `-Branch`/`planPath` forward-spec) was based on **stale Plan 001 plan text**, not the delivered code. The original `/ci` text was authoritative. Reverted:
- REQ-3 / RISK-4 → **verbatim preservation** of the delivered signature (no semantic-match indirection).
- Sandbox → **available mode** (un-deferred) in skill + design note.
- `-Branch` → **real param** (forward-spec framing removed).

**Scope additions (user-approved):**
- **Custom host command implemented for real** in `launch-host.ps1` (new `Resolve-HostCommand` helper + `ArgumentList` no-shell exec), no longer forward-spec. New Phase 2.1.
- **`AUTOPILOT_DISABLE_HOST` is launcher-enforced** in `launch.ps1` (refuses `-Runtime host`), not just a skill menu omission. New Phase 2.2 (REQ-13 extended).
- **Pester coverage added** — repo's first harness: `tests/autopilot/Resolve-HostCommand.Tests.ps1`. New Phase 2.3 + REQ-14.
- Schema step → **draft 2020-12** (REQ-7). Verification → PSScriptAnalyzer zero-warning + Pester green (Phase 4.4).

**Structural change:** plan grew from 3 phases to **4** (Config → Launcher impl + Pester → Skill extraction → Design notes + verification). All REQ/RISK step references re-mapped. RISK-1 repurposed (launcher exists; risk is now regressing the live `launch-host.ps1`).

## Round 2

**Reviewers:** Opus · Codex · Gemini (via `@dr`), against the delivered scripts.

**Verdict:** architecture sound (signature reconciliation, sandbox/`-Branch` reality, `ci`-plugin ownership, disable-toggle all correct); two **High** blockers + factual/wording gaps required a targeted revision. All 9 findings applied.

**Issues found & fixed (9):**
1. [High] **Pester dot-source blocked.** `launch-host.ps1` has four `[Parameter(Mandatory)]` params that bind *before* any body guard → dot-sourcing prompts interactively; a body-level `if` guard can't prevent it. **Fix:** extract `Resolve-HostCommand` into a `param()`-less helper `scripts/autopilot/host-command.ps1`, dot-sourced by both `launch-host.ps1` and the test. (2.1, 2.3, REQ-5/9/14, Decisions, RISK-1)
2. [High] **Phase 2.1 mis-described the seam.** Real `Invoke-CopilotPhase` resolves once (`Get-Command copilot`) then branches at *invocation* (`.bat`→cmd.exe, `.ps1`→powershell, else direct) using `$psi.Arguments` **strings**, not `ArgumentList`; **no `.cmd` branch exists** (breaks npm `*.cmd` shims). **Fix:** separate resolution (`Resolve-HostCommand` returns `Path`/`Type`/`ExtraArgs`) from invocation; add explicit `.cmd`→`cmd.exe /c` branch; keep the string-`$psi.Arguments` approach (no wholesale `ArgumentList` migration). (2.1, REQ-9, Decisions)
3. [Medium] **"argv no-shell" overstated; denylist incomplete for cmd.** True only for direct-exe; `.bat`/`.cmd`/`.ps1` run via a shell where `ArgumentList` doesn't escape. **Fix:** qualify "no shell" to direct-exe; expand denylist with cmd-significant `% ^ ( ) , !`; denylist is the control for shell-wrapped types. (Decisions layer 4, REQ-9, RISK-6, 2.1)
4. [Medium] **False precedent:** `AUTOPILOT_CONTAINER` is **not** enforced in `launch.ps1` (only set by `prepare-env-file.ps1` + honored by agent rule #8 + menu). **Fix:** reword to "mirrors the env-var convention; launcher enforcement is net-new here." (Decisions, 2.2)
5. [Medium] **Wrong rule count.** Agent has **9** Absolute Rules (not 8); appending as "#9" would clobber "Atomic plan updates." **Fix:** append as **#10**. (1.5)
6. [Medium] **`Test-Json` can't validate draft 2020-12** (Newtonsoft = draft 04/06/07). **Fix:** validate the `.example` via explicit Pester structural assertion; align REQ-7 AC. (REQ-7, 4.4)
7. [Medium] **4.4 missing deps** on 1.4/1.5/2.3/3.2 it verifies. **Fix:** `[after: 1.4, 1.5, 2.3, 3.2, 4.2, 4.3]`. (4.4)
8. [Low] **Asymmetric REQ/RISK↔step tags.** **Fix:** reconciled REQ-5/9/10/11 + RISK-1/2 rows with step tags.
9. [Low] **"Verbatim diff against `param()`" infeasible** (concrete `-Mode whole-plan` vs `ValidateSet`). **Fix:** reworded 4.4(3)/RISK-4 to a semantic param-name/ValidateSet check.

Round 2 closed. No further rounds requested.
