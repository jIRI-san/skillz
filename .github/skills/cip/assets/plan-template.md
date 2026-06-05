# NNN: Plan Title

<!-- Optional execution metadata — defaults used by /ci mode selection -->
<!-- execution-mode: manual | host-autopilot | container-autopilot -->
<!-- scope: step | phase | plan -->

## Decisions
<!-- Key decisions made during planning — one bullet per decision -->
-

## Requirements

| ID | Requirement | Acceptance Criteria | Phases/Steps |
|----|-------------|---------------------|--------------|
| REQ-1 | | When X, then Y | |

## Risks

| ID | Risk | Likelihood | Impact | Mitigation | Steps |
|----|------|------------|--------|------------|-------|
| RISK-1 | | Low/Medium/High | Low/Medium/High | | 1.2 |

## Phase 1: Name
<!-- worktree: (recorded by /ci when worktree is created) -->
<!-- Steps with no [after:] annotation can start immediately and run in parallel. -->
<!-- Roles: @ai-agent (default, not annotated) or @human (explicit). -->
<!-- Sizes: S (< 30 min) · M (30 min – 2 h) · L (2 h+) -->

- [ ] 1.1 Step title (REQ-1) `S`
- [ ] 1.2 Step title (REQ-1, RISK-1) @human `M`
  <details><summary>Details</summary>

  **Steps:**
  1. Navigate to **Azure Portal > Resource Group > ...**
  2. Run: `az resource ...`
  3. Verify: expected outcome.

  **Rollback:** Delete the resource / revert the setting to X.

  </details>

## Phase 2: Name
<!-- worktree: (recorded by /ci when worktree is created) -->

- [ ] 2.1 Step title (REQ-1, RISK-1) [after: 1.1] `S`
