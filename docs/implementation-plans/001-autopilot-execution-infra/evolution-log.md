# Evolution Log — Plan 001: Autopilot Execution Infrastructure

Records design-review (DR) round history. Given to DR agents as context to prevent re-reporting fixed issues or contradicting deliberate decisions.

## Round 1

**Models:** Opus · Codex · Gemini. 3 Critical, 5 High, 7 Medium, 2 Low.

### Fixed (applied to plan)
- **#1 (Critical) command-allowlist bypass** → execute build/test as argv (no shell), reject shell metacharacters, trusted prefixes moved into schema/launcher OUTSIDE agent-editable `.autopilot.json`; test mutated-config rejection. (RISK-5, steps 1.2/2.1/5.1)
- **#2 (Critical) missing agent definition** → new step 2.5 authors `.github/agents/autopilot.agent.md` with absolute safety rules + exit-42; orchestrators select it explicitly. (REQ-8, RISK-7, steps 3.2/4.3)
- **#3 (Critical) cross-platform vs Credential Manager** → dropped cross-platform claim; orchestrator declared Windows-only; auth/orchestration tests Windows-only, lint/schema anywhere. (RISK-6)
- **#4 (High) config contract divergence** → `.autopilot.json` restored to design-note shape (`runtime`, `build`/`test` strings, `timeout`, `planPath`, `copilotAuth`, `gitProvider`, `gitAuth`, `model`, `git.{name,email}`, `maxIterationsPerStep`). (REQ-1, step 1.1)
- **#5 (High) PAT leak via env-file** → token never in `--env-file`/`Config.Env`; stdin/tmpfs read-then-delete; unset before workspace build/test. (REQ-6, RISK-4, steps 4.2/4.3)
- **#6 (High) stderr drain + tree-kill** → redirect both streams, `ErrorDataReceived`, `BeginErrorReadLine`, `Kill($true)`, `WaitForExit`. (RISK-3, steps 3.2/3.3, test 5.2)
- **#7 (High) exit-code contract** → 0→next, 42→`@human` halt, other→failure; `maxIterationsPerStep` cap. (REQ-7, steps 3.3/4.4)
- **#8 (High) no orchestration tests** → stub `copilot` for host-loop streaming/timeout/exit-code tests; mocked container lifecycle smoke. (REQ-9, steps 5.2/5.3)
- **#9 (Medium) container concurrency** → detached run + background log stream + main-thread poll; `docker cp` before `docker rm`; state machine. (step 4.4)
- **#10 (Medium) silent host fallback** → container mode fails loudly; host requires explicit `-Mode host`. (RISK-2, steps 2.1/4.1)
- **#11 (Medium) plan path + phase grammar** → `planPath` config field; `## Phase N` boundaries. (step 1.1/3.2)
- **#12 (Medium) Test-Json draft** → schema targets draft-07. (RISK-8, step 1.2)
- **#13 (Medium) unpinned toolchain** → pin Node/gh/Copilot CLI + base-image digest. (RISK-9, step 4.1)
- **#14 (Medium) duplicated token reader** → single `get-credential.ps1` consumed by validate-auth + prepare-env-file. (step 2.3)
- **#15 (Medium) SSH→HTTPS robustness + redaction** → tested conversion helper, no token in remote URL, log/transcript redaction. (steps 2.2/4.3, test 5.3)
- **#16 (Medium) dependency ordering** → added 2.3 (get-credential) before 2.4/4.2; tightened `[after:]` edges.
- **#17 (Low) redundant lint steps** → collapsed per-phase lint steps into the local validation gate; dropped empty-tree check. (REQ-13, step 6.1)
- **#18 (Low) secret-erasure overstatement** → softened to best-effort overwrite + delete. (RISK-4, step 4.5)

### User directive (post-review)
- **No GitHub Actions for autopilot** (Actions cost). Phase 6 CI workflow replaced with `scripts/autopilot/validate-local.ps1` run locally as the pre-commit/pre-merge gate. (REQ-10/REQ-13, step 6.1)

### Declined / softened
- None beyond #17 simplification.

### Deferred → Known Plan Issues
- None.
