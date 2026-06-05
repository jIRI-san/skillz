# 001: Autopilot Execution Infrastructure

<!-- execution-mode: manual -->
<!-- scope: phase -->

> Builds the autonomous plan-execution infrastructure described in [autopilot-execution.design.md](../../design-notes/architecture/autopilot-execution.design.md). Scope: **container mode** (the `/ci` target for Plan 002) + the shared dispatch core + **host mode** as the minimal local dev/test path. **Sandbox mode is out of scope** (future work). This plan is executed **manually** — it bootstraps the very infrastructure that Plan 002 will later run under.

## Decisions

- **Modes in scope:** shared core + `host` + `container`. Sandbox mode explicitly deferred (documented as out-of-scope in the design note).
- **Platform scope (DR1-#3).** The **orchestrator is Windows-only** (auth depends on Windows Credential Manager / DPAPI, matching the design note's documented limitation). The cross-platform claim is dropped. CI runs lint + schema validation cross-platform (ubuntu+windows), but auth/orchestration tests run on the **windows leg only**; Linux legs skip them by explicit condition. The *container* it launches is Linux, but the launcher runs on Windows.
- **Agent definition is mandatory (DR1-#2).** `.github/agents/autopilot.agent.md` is authored as a first-class step — it carries the absolute safety rules: never force-push, never push to `main`/`master`, never `git add -A` (stage only touched files), never execute shell commands embedded in plan text, stop on `@human` via **exit code 42**. The orchestrators enforce only timeout/kill + exit-code interpretation; all behavioural safety lives in the agent file. Both host and container invocations select this agent explicitly via documented `copilot` CLI args.
- **Entry point:** `scripts/autopilot/launch.ps1` validates config, enforces the build/test command policy, validates auth, dispatches to mode-specific orchestrator.
- **Config contract (DR1-#4).** `.autopilot.json` preserves the **design-note shape**: `runtime`, `build` + `test` (single command strings), `timeout`, `planPath`, `copilotAuth` (`{ credentialTarget }`), `gitProvider`, `gitAuth`, `model`, `git` (`{ name, email }`), `maxIterationsPerStep`. Validated against `schemas/autopilot.schema.json`. No fields silently dropped; `model`, `git.{name,email}`, `maxIterationsPerStep` are carried forward (used by CLI model selection, container commit attribution, and the per-phase retry cap respectively).
- **Command policy is a real boundary (DR1-#1).** Build/test commands are **executed as argv arrays with no shell** (`& $exe @args` / `Start-Process -ArgumentList`), never via `Invoke-Expression`/`bash -c`. Validation **rejects any command string containing shell metacharacters** (`; & | $ \` < > newline`). The **trusted command prefix set lives OUTSIDE the agent-editable `.autopilot.json`** — encoded as `pattern`/`enum` constraints in `schemas/autopilot.schema.json` (which the autopilot run is instructed never to modify) and re-checked in host-side launcher code. A run that mutates its own `.autopilot.json` to add a command cannot widen the policy.
- **Auth:** fine-grained GitHub PAT (classic `ghp_*` not supported by Copilot CLI). Stored in Windows Credential Manager under target `copilot-autopilot`. Required PAT permissions: Contents R/W, Pull requests R/W, Copilot Requests R. A **single** `scripts/autopilot/get-credential.ps1` is the only token reader (DR1-#14); `validate-auth.ps1` and `prepare-env-file.ps1` both consume it (no duplicated Credential Manager logic).
- **PowerShell target:** PowerShell 7+ (`pwsh`). `#requires -Version 7.0` in every script.
- **Container base + pinning (DR1-#13):** `.devcontainer/autopilot/Dockerfile` installs **version-pinned** Node, GitHub CLI, and `@github/copilot` (explicit versions, ideally base-image digest) for reproducibility and supply-chain control.
- **Container token handling (DR1-#5).** The PAT is **never** passed via `--env-file`/`-e` (would land in `Config.Env`, visible to `docker inspect` and inherited by untrusted build/test children). Instead it is delivered via **stdin or a tmpfs-mounted secret file** the entrypoint reads-then-deletes; the entrypoint **unsets the token from the environment before invoking any workspace build/test command**. Container removed (`docker rm -f`) promptly after transcript extraction.
- **Per-phase execution + exit-code contract (DR1-#7).** One `copilot` CLI invocation per plan phase (one context window). The orchestrator interprets the per-phase exit code: **`0` → advance to next phase**, **`42` → controlled halt surfacing `@human`** (not a failure), **other nonzero → stop with failure status**. `maxIterationsPerStep` bounds in-phase retry churn.
- **Phase grammar (DR1-#11):** the executed plan is `planPath` from config; phase boundaries are `## Phase N` markdown headings. Host and container orchestrators share this grammar.
- **Process I/O + kill (DR1-#6).** Host mode redirects **both** stdout and stderr with `OutputDataReceived` + `ErrorDataReceived` and `BeginOutputReadLine()`/`BeginErrorReadLine()` (prevents buffer-fill deadlock and captures real failures). Timeout uses **`Process.Kill($true)` (process-tree termination)** + `WaitForExit()` to flush async buffers and avoid orphaned node/git/build children.
- **Container concurrency (DR1-#9).** Container runs **detached** (`docker run -d`); logs streamed in a background job/runspace; timeout enforced by main-thread `docker inspect .State.Running` + elapsed-time polling → `docker stop` (grace) → `docker kill`. Modeled as a state machine: build → start → concurrent stream+poll → capture exit → `docker cp` transcript **if container exists** → `docker rm -f` in `finally`. Cleanup never runs before `docker cp` (diagnostics preserved).
- **No silent host fallback (DR1-#10).** Container mode **fails loudly** when Docker is unavailable; running on the host requires explicit `-Mode host` opt-in (documented security decision — host run removes the requested isolation).
- **Timeout:** elapsed-time polling + tree-kill (host) / `docker stop`→`docker kill` (container). Default per-phase timeout from `.autopilot.json` `timeout`.
- **Transcripts:** `copilot --share=<path>`; extracted via `docker cp` in container mode, container removed after. Token-shaped strings redacted from logs/transcripts (DR1-#15).
- **SSH→HTTPS remote conversion (DR1-#15):** a tested helper converts `git@github.com:org/repo.git`, `ssh://git@github.com/org/repo.git`, enterprise hosts, and already-HTTPS forms; tokens are **never** embedded in remote URLs (GitHub CLI credential helper provides HTTPS auth).
- **Security:** command policy as above; SSH→HTTPS for container push; token files written with restrictive ACL, short-lived, deleted after read (best-effort overwrite + delete — not a secure-erase guarantee on COW/SSD, DR1-#18).
- **Git staging:** scripts stage only files they create (no `git add -A`).
- **Schema draft (DR1-#12):** `schemas/autopilot.schema.json` targets **JSON Schema draft-07** (matches `Test-Json`'s real capability in PS7; needed keywords `enum`/`required`/`additionalProperties`/`pattern` are all draft-07).
- **Formatting:** repo gains an `.editorconfig` covering `*.ps1` (PSScriptAnalyzer-clean). Zero-warning is enforced by the **CI gate + a pre-commit hook** rather than discrete per-phase lint steps (DR1-#17).

## Requirements

| ID | Requirement | Acceptance Criteria | Phases/Steps |
|----|-------------|---------------------|--------------|
| REQ-1 | `.autopilot.json` config (design-note shape) + draft-07 schema | Given a valid config, schema validation passes; a config whose `build`/`test` contains a shell metacharacter or a non-trusted prefix is rejected; `model`/`git.{name,email}`/`maxIterationsPerStep`/`planPath` are present | 1.1, 1.2, 2.1 |
| REQ-2 | `launch.ps1` entry point (validate → policy → auth → dispatch) | Running `launch.ps1 -Mode host` with valid config dispatches to host orchestrator; invalid mode errors; container mode with no Docker fails loudly (no host fallback) | 2.1, 2.2 |
| REQ-3 | Auth validation + single token reader + secure handling | `get-credential.ps1` is the only token reader; `validate-auth.ps1` resolves the PAT and confirms Copilot API reachability; missing/invalid token aborts before any work; token never echoed | 2.3, 2.4 |
| REQ-4 | Host mode orchestrator (worktree + per-phase CLI + exit-code contract) | On a sample 1-phase plan: creates worktree, invokes Copilot CLI with the autopilot agent once, streams stdout+stderr live, honors timeout via tree-kill, and maps exit 0/42/other correctly | 3.1, 3.2, 3.3 |
| REQ-5 | Container mode orchestrator (Dockerfile + entrypoint + launcher) | Running container mode builds the pinned image, runs a 1-phase plan detached, streams logs while polling timeout, extracts the transcript before removing the container, and never leaks the token into `Config.Env` | 4.1, 4.2, 4.3, 4.4 |
| REQ-6 | Secure token delivery + cleanup | The PAT reaches the container via stdin/tmpfs read-then-delete (not `--env-file`); entrypoint unsets it before workspace build/test; host token/secret files have restrictive ACL and are deleted after use | 4.2, 4.3, 4.5 |
| REQ-7 | Timeout + exit-code enforcement (both modes) | A phase exceeding its timeout is tree-killed and reported; exit 0 advances, 42 halts for `@human`, other nonzero stops with failure; `maxIterationsPerStep` bounds retries | 3.3, 4.4 |
| REQ-8 | Autopilot agent definition with safety rules | `.github/agents/autopilot.agent.md` exists and encodes: no force-push, no push to main/master, no `git add -A`, no shell-from-plan-text, `@human`→exit 42; both orchestrators select it explicitly | 2.5, 3.2, 4.3 |
| REQ-9 | Tests incl. orchestration via stub CLI | Pester covers config/policy rejection, mode dispatch, auth-failure, SSH→HTTPS, exit-code mapping, stderr-drain + tree-kill (via a stub `copilot`), and container lifecycle smoke; all pass | 5.1, 5.2, 5.3 |
| REQ-10 | Local validation script (no GitHub Actions) | `scripts/autopilot/validate-local.ps1` runs PSScriptAnalyzer + Pester + schema self-check + `bash -n`/ShellCheck on entrypoint; documented as the pre-commit/pre-merge gate; **no `.github/workflows` for autopilot** | 6.1 |
| REQ-11 | Design note updated to reflect built state | `autopilot-execution.design.md` reflects implemented host/container surface, Windows-only orchestrator, the config contract, the command-policy boundary, and local-only validation | 6.2 |
| REQ-12 | Sandbox mode explicitly deferred | Design note states sandbox mode is not implemented; no sandbox scripts shipped; no dangling references | 6.2 |
| REQ-13 | Zero lint warnings (locally enforced) | `Invoke-ScriptAnalyzer` reports zero warnings across `scripts/autopilot/**`; enforced by `validate-local.ps1` + a pre-commit hook (not CI) | 1.3, 6.1 |

## Risks

| ID | Risk | Likelihood | Impact | Mitigation | Steps |
|----|------|------------|--------|------------|-------|
| RISK-1 | Copilot CLI auth model changes / PAT scopes shift | Medium | High | Isolate all auth in `get-credential.ps1`/`validate-auth.ps1`; document required scopes in design note; fail fast with actionable error | 2.3, 2.4, 6.2 |
| RISK-2 | Docker not installed / daemon unavailable on dev machine | Medium | Medium | `launch.ps1` container pre-flight checks `docker info`; **fails loudly** (no silent host fallback); host mode requires explicit `-Mode host` | 2.1, 4.1 |
| RISK-3 | Per-phase Copilot CLI invocation is non-deterministic / may hang | Medium | High | Hard timeout + **process-tree** kill; stderr drained to avoid deadlock; transcript capture; `maxIterationsPerStep` retry cap; manual execution keeps a human in the loop | 3.3, 4.4 |
| RISK-4 | Secret leakage via env/transcript/`docker inspect`/child processes | Medium | High | Token never in `--env-file`/`Config.Env`; delivered via stdin/tmpfs read-then-delete; unset before workspace build/test; restrictive ACL; redact token-shaped strings from logs/transcripts | 2.4, 4.2, 4.3, 4.5 |
| RISK-5 | Command-policy bypass lets autopilot run arbitrary commands | Medium | High | Execute build/test as **argv, no shell**; reject shell metacharacters; trusted prefixes live in schema/launcher **outside** agent-editable `.autopilot.json`; test mutated-config rejection | 1.2, 2.1, 5.1 |
| RISK-6 | Windows-only orchestrator vs cross-platform expectation | Low | Medium | Drop cross-platform claim; document Windows-only orchestrator; local validation runs auth/orchestration tests on Windows, lint/schema anywhere | 2.4, 6.1, 6.2 |
| RISK-7 | Missing agent safety rules → unsafe autonomous actions | Medium | High | Author `.github/agents/autopilot.agent.md` with absolute rules (no force-push, no main push, no `git add -A`, no shell-from-plan-text, exit-42 on `@human`); orchestrators select it explicitly | 2.5, 3.2, 4.3 |
| RISK-8 | `Test-Json` lacks draft 2020-12 support | Low | Medium | Target JSON Schema **draft-07** (matches `Test-Json` capability); needed keywords all draft-07 | 1.2 |
| RISK-9 | Unpinned container toolchain → non-reproducible / supply-chain | Low | Medium | Pin Node, gh, `@github/copilot` versions (ideally base-image digest) | 4.1 |

## Phase 1: Scaffold + Config Contract

<!-- worktree: (recorded by /ci when worktree is created) -->

- [x] 1.1 Add `.autopilot.json` at repo root using the **design-note shape**: `runtime`, `build` + `test` (single strings), `timeout`, `planPath`, `copilotAuth.{credentialTarget}`, `gitProvider`, `gitAuth`, `model`, `git.{name,email}`, `maxIterationsPerStep`, `mode` default (REQ-1) `S`
- [x] 1.2 Add `schemas/autopilot.schema.json` (**JSON Schema draft-07**): required keys, `enum` for `mode` (`host`|`container`), `additionalProperties:false`, and **`pattern` constraints encoding the trusted build/test command prefixes** (policy lives here, not in the agent-editable config) (REQ-1, RISK-5, RISK-8) `M`
- [x] 1.3 Add `.editorconfig` (`*.ps1`/`*.json`) + repo-root `PSScriptAnalyzerSettings.psd1`; add a pre-commit hook invoking `validate-local.ps1` (REQ-13) `S`

## Phase 2: Dispatch Core + Auth + Agent

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 2.1 `scripts/autopilot/launch.ps1`: `#requires -Version 7.0`; load + draft-07-validate `.autopilot.json` (`Test-Json -SchemaFile`); **enforce command policy** (re-check trusted prefixes from schema/launcher, reject shell metacharacters `; & | $ \` < > newline`, prepare argv execution — never `Invoke-Expression`/`bash -c`); docker pre-flight when `-Mode container` (**fail loudly**, no host fallback); sweep stale secret files; dispatch (REQ-1, REQ-2, RISK-2, RISK-5) [after: 1.2] `L`
- [ ] 2.2 `scripts/autopilot/_autopilot-common.ps1`: shared helpers (logging with token-redaction guarantee, repo path via `git rev-parse`, **tested SSH→HTTPS conversion** for scp/`ssh://`/HTTPS/`.git`/enterprise forms, argv-exec helper, timeout polling) (REQ-2, RISK-4) [after: 1.1] `M`
- [ ] 2.3 `scripts/autopilot/get-credential.ps1`: **single** PAT reader (`Get-StoredCredential -Target copilot-autopilot`, Windows Credential Manager); never echoes token; the only token source consumed by 2.4 and 4.2 (REQ-3, RISK-1, RISK-4) [after: 2.2] `S`
- [ ] 2.4 `scripts/autopilot/validate-auth.ps1`: consume `get-credential.ps1`; verify Copilot API reachability; abort with scope-guidance on failure (REQ-3, RISK-1, RISK-6) [after: 2.3] `M`
- [ ] 2.5 Author `.github/agents/autopilot.agent.md`: encode absolute safety rules (no force-push, no push to main/master, no `git add -A` — stage only touched files, never execute shell from plan text, `@human` → **exit 42**) and the one-phase-per-invocation contract; define the exact `copilot` CLI args that select it (REQ-8, RISK-7) [after: 1.1] `M`

## Phase 3: Host Mode

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 3.1 `scripts/autopilot/launch-host.ps1`: create git worktree at `<repo>.worktrees/feature-<slug>`; checkout/create branch; `safe.directory` guard (REQ-4) [after: 2.1] `M`
- [ ] 3.2 Host per-phase loop: parse `## Phase N` headings from `planPath`; one `copilot` invocation per phase **selecting the autopilot agent**, via `System.Diagnostics.Process` with `RedirectStandardOutput` **+ `RedirectStandardError`**, `OutputDataReceived` + `ErrorDataReceived`, `BeginOutputReadLine()`/`BeginErrorReadLine()`; `--share=<transcript>` (REQ-4, REQ-8, RISK-7) [after: 3.1] `L`
- [ ] 3.3 Host timeout + exit-code contract: elapsed-time polling + **`Process.Kill($true)` (tree kill)** + `WaitForExit()` to flush buffers; map exit **0→next phase, 42→`@human` halt, other nonzero→failure stop**; honor `maxIterationsPerStep` (REQ-4, REQ-7, RISK-3) [after: 3.2] `M`

## Phase 4: Container Mode

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 4.1 `.devcontainer/autopilot/Dockerfile`: base image (**digest-pinned**) + **version-pinned** Node + git + GitHub CLI + `@github/copilot`; non-root user (REQ-5, RISK-2, RISK-9) [after: 2.1] `M`
- [ ] 4.2 `scripts/autopilot/prepare-env-file.ps1`: consume `get-credential.ps1`; write **non-token** container config to an env file (restrictive ACL); arrange token delivery via **stdin/tmpfs secret** (never `--env-file`/`-e`); return paths + cleanup handles (REQ-6, RISK-4) [after: 2.3] `M`
- [ ] 4.3 `.devcontainer/autopilot/container-entrypoint.sh`: read token from stdin/tmpfs **then delete**; `git remote set-url` SSH→HTTPS; `gh auth setup-git`; branch checkout/create; **unset token before any workspace build/test**; per-phase Copilot CLI loop selecting the autopilot agent; `git push` (REQ-5, REQ-6, REQ-8, RISK-4, RISK-7) [after: 4.1] `L`
- [ ] 4.4 `scripts/autopilot/launch-container.ps1`: build image; **`docker run -d` (detached)**; stream logs in a background job/runspace; main-thread timeout via `docker inspect .State.Running` + elapsed polling → `docker stop`→`docker kill`; capture exit code (0/42/other contract); **`docker cp` transcript while container exists**; `docker rm -f` in `finally` (REQ-5, REQ-7, RISK-3) [after: 4.2, 4.3] `L`
- [ ] 4.5 Secret + container cleanup: best-effort overwrite + delete of host secret/env files in `finally`; never run before `docker cp`; stale-sweep on next launch (in 2.1) (REQ-6, RISK-4) [after: 4.4] `S`

## Phase 5: Tests (local Pester)

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 5.1 Pester: draft-07 schema validation (valid/invalid); **command-policy rejection** (shell metacharacters + mutated-`.autopilot.json` that adds a command → rejected); mode dispatch; container-no-docker fails loudly (REQ-9, RISK-5, RISK-2) [after: 2.1] `M`
- [ ] 5.2 Pester via **stub `copilot`** (prints lines, writes stderr, sleeps, returns chosen exit code): host-loop stdout+stderr streaming (no deadlock), tree-kill on timeout (no orphans), exit-code mapping (0/42/other) (REQ-9, REQ-7) [after: 3.3] `M`
- [ ] 5.3 Pester: auth-failure abort (mock Credential Manager, Windows-only — skipped on Linux), SSH→HTTPS conversion cases, token redaction; container lifecycle smoke (mocked Docker) incl. `docker cp`-before-`rm` ordering (REQ-9, REQ-6, RISK-4, RISK-6) [after: 2.4, 4.5] `M`

## Phase 6: Local Validation + Docs

<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 6.1 `scripts/autopilot/validate-local.ps1`: run PSScriptAnalyzer (zero-warning gate) + Pester + `Test-Json` schema self-check + `bash -n`/ShellCheck on `container-entrypoint.sh`; **no `.github/workflows` created**; documented as the pre-commit/pre-merge gate (REQ-10, REQ-13, RISK-6) [after: 5.3] `M`
- [ ] 6.2 Update `autopilot-execution.design.md`: reflect implemented host+container surface, **Windows-only orchestrator**, the config contract, the command-policy boundary, **local-only validation (no CI)**; mark sandbox **out of scope (future)**; document PAT scopes + Credential Manager setup; remove/guard sandbox references (REQ-11, REQ-12, RISK-1, RISK-6) [after: 4.5] `M`

## Notes

- This plan is the prerequisite for **Plan 002** running under container autopilot. Until 001 is complete, Plan 002 runs manually too.
- Sandbox mode from the design note is intentionally not built here; it remains a documented future option.
