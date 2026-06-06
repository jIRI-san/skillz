# Evolution Log — 004 Process PR Comments (`pprc`)

Tracks DR round history: issues found, fixed, and deferred.

## Pre-DR baseline

- Plan drafted from interview. Key decisions locked:
  - Single plugin `pprc`, skill `/process-pr-comments`.
  - Auth: token via `gh auth token`; **all** GitHub calls via `Invoke-RestMethod` against `api.github.com` (REST-only); GraphQL only for unresolved-thread state.
  - Dispositions: Fixed / WontFix / NeedsClarification.
  - Interactive per-comment approve/edit/skip gate before any post.
  - Strict branch-safety (refuse fork / branch mismatch); never force-push.
  - Threads left open (no auto-resolve).
  - Built on Plan 002 registry; Phase 5 dogfood gated on 002.

## Round 1 (Opus · Codex · Gemini)

17 findings. All applied except where superseded by a user decision.

**Critical (3) — fixed:**
- #1 `plugin.json` missing schema-required `author`/`license` → added (Step 1.1); version set to `1.0.0` (#17).
- #2 GraphQL `reviewThreads`/`comments` pagination unhandled → added cursor pagination for both connections (Steps 1.3, 2.2; REQ-2/5; RISK-2 elevated to High).
- #3 owner/repo regex `[^/.]+` truncates dotted repo names → new parser captures full segment, strips trailing `.git` (Step 1.2; new RISK-11).

**High (5) — fixed:**
- #4 PR detection fork-aware: list base-repo PRs, filter by `head.ref` (Step 2.1; REQ-3).
- #5 thread granularity + reply to thread-root id (`Get-PrReviewThreads`, root `in_reply_to`) (Steps 2.2, 3.6; REQ-5/10).
- #6 reviewer text untrusted at classify/fix/compose, not just reply (Steps 3.1/3.2/3.4; RISK-8 elevated Low→Medium/High).
- #7 push-approval gate added (new Step 3.2a, diff approval before push) — **user decision: gate the push too**.
- #8 non-interactive behavior — **user decision: interactive-only, documented limitation** (REQ-9, Notes); no headless detection logic.

**Medium (5) — fixed:**
- #9 header capture on success+failure, `Retry-After` secondary limits (Step 1.3; REQ-2; RISK-5).
- #10 explicit push refspec `HEAD:refs/heads/{headRefName}` to base-matching remote (Step 3.3; REQ-4).
- #11 URL-encode branch in PR query (Step 2.1).
- #12 dedup: `GET /user` identity + hidden per-thread marker (Steps 3.4/3.6; RISK-7).
- #13 dirty-worktree protection: snapshot + explicit-path staging (Step 3.2; new RISK-12).

**Low (4) — fixed:**
- #14 REQ-14 ↔ Step 3.3 cross-ref corrected.
- #15 null `head.repo`, zero-thread no-op, git ambient-credential note (Steps 2.1, 3.3, 3.7).
- #16 Phase 5 fallback decoupled from the 002-only Build-Registry step (Step 5.2 details).
- #17 version `1.0.0` — **user decision**.

Deferred: none. No over-engineering flagged. No prompt-injection in plan content.

## Round 2 (Opus · Codex · Gemini)

10 new findings (no re-reports of Round 1). All applied. Reviewers confirmed the Round-1 fixes sound (`databaseId`↔`comment.id` join, dotted-repo parser, PS7 two-path header handling).

**High (3) — fixed:**
- #1 push/reply ordering was self-contradictory (per-thread loop vs batched gate) and a reply could post before its push succeeded → rewrote to an explicit **two-phase** flow: Phase A commit-all → single push gate → one push; Phase B per-thread reply gated on a verified push (Decisions two-gate, Step 3.7).
- #2 nested GraphQL `comments` had no per-thread drain path → specified per-thread follow-up queries (select thread by `id`, page to exhaustion) (Decisions, REQ-2, Steps 1.3/2.2; RISK-2 added to Step 1.3).
- #3 reviewer text could spoof the dedup marker (confused-deputy) → strip/encode `<!-- pprc:` … `-->` from quoted reviewer text, place genuine marker outside quoted region, add forged-marker test (Decisions dedup+security, Steps 3.4/4.1; RISK-7 row gains Step 3.4).

**Medium (5) — fixed:**
- #4 thread-root selection rule unspecified → pinned to the REST member comment with `in_reply_to_id == null` (order-independent); multi-comment-thread test (Decisions, Steps 2.2/4.1).
- #5 summary-reply dedup conflicted with the out-of-scope rule and `rootId` was undefined for summaries → narrow exception to read the user's own issue comments for dedup (best-effort); summary key = `summary-<reviewId>` (Decisions comment-scope+dedup, Step 3.6).
- #6 push remote-matching undefined for zero/multiple/normalization → normalize via `Get-RepoSlug`, prefer `origin`, else require exactly one match with actionable zero/multiple errors; tests (Step 3.3, REQ-15, Step 4.1).
- #7 Pester header mocking underspecified for `-ResponseHeadersVariable` → header-aware adapter / caller-scope `Set-Variable`, plus the separate thrown-403 `Exception.Response.Headers` path (Step 4.1).
- #8 cross-reference mismatches → reconciled RISK-2→1.3, RISK-3→3.3, RISK-7→3.4, RISK-9→5.3, and dropped stray REQ-19 from Step 5.3.

**Low (2) — fixed:**
- #9 detached HEAD produced a misleading "no PR" error → detect literal `HEAD` / `symbolic-ref` failure first with a distinct message (Step 2.1, REQ-15).
- #10 GraphQL rate-limit (`errors[].type == RATE_LIMITED`, HTTP 200) could evade the REST-framed detector → explicit handling with GraphQL reset time (Step 1.3, REQ-2).

Deferred: none. Reviewers confirmed no new over-engineering and no prompt-injection in plan content.
