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

**Pre-extraction `/ci` launcher reference (for 3.4 baseline):** the live `/ci` Step 1 currently issues `scripts/autopilot/launch.ps1 -PlanSlug <slug> -Mode whole-plan -Runtime host|container|sandbox [-Branch <chosen-branch>]` — a fictional signature. Plan 001's real contract is `launch.ps1 -Mode host|container` with `planPath` from `.autopilot.json`. 3.4 verifies against the Plan 001 contract, not this.
