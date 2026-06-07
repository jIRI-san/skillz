#!/bin/bash
# container-entrypoint.sh — Autonomous plan execution inside Docker container
# Invoked by: docker run ... /usr/local/bin/container-entrypoint.sh <plan-slug> <mode>
#
# Environment variables expected:
#   GH_TOKEN / COPILOT_GITHUB_TOKEN — GitHub auth
#   ADO_TOKEN (optional) — Azure DevOps access token
#   ADO_ORG, ADO_PROJECT (optional) — ADO config
#   COPILOT_ALLOW_ALL=true
#   COPILOT_MODEL — model override
#   REPO_REMOTE — git remote URL to clone

set -euo pipefail

PLAN_SLUG="${1:?Usage: container-entrypoint.sh <plan-slug> <mode>}"
MODE="${2:?Usage: container-entrypoint.sh <plan-slug> <mode>}"
BRANCH="${REPO_BRANCH:-feature/${PLAN_SLUG}}"
REPO_REMOTE="${REPO_REMOTE:?REPO_REMOTE env var required}"

echo "=== Autopilot Container Entry-Point ==="
echo "Plan: ${PLAN_SLUG}"
echo "Mode: ${MODE}"
echo "Branch: ${BRANCH}"
echo "Model: ${COPILOT_MODEL:-<CLI default>}"
echo "Copilot CLI: $(copilot --version 2>/dev/null || echo 'unknown')"

# --- Git credential setup ---
gh auth setup-git

# ADO credential helper (if ADO_TOKEN is set)
if [ -n "${ADO_TOKEN:-}" ]; then
    echo "Configuring ADO credential helper..."
    if [ -n "${ADO_ORG:-}" ]; then
        az devops configure --defaults "organization=${ADO_ORG}" "project=${ADO_PROJECT:-}"
    fi
    git config --global credential.helper '!f() { echo "username=x-token"; echo "password=${ADO_TOKEN}"; }; f'
fi

# --- Clone and branch ---
echo "Cloning ${REPO_REMOTE}..."
git clone "${REPO_REMOTE}" /work
cd /work

# Determine target branch
WORK_BRANCH="feature/${PLAN_SLUG}"

if git ls-remote --exit-code origin "refs/heads/${WORK_BRANCH}" > /dev/null 2>&1; then
    echo "Work branch ${WORK_BRANCH} exists on remote — resuming..."
    git fetch origin "${WORK_BRANCH}"
    git checkout "${WORK_BRANCH}"
elif [ "${BRANCH}" != "${WORK_BRANCH}" ] && git ls-remote --exit-code origin "refs/heads/${BRANCH}" > /dev/null 2>&1; then
    echo "Starting from branch ${BRANCH}..."
    git fetch origin "${BRANCH}"
    git checkout "${BRANCH}"
    echo "Creating work branch ${WORK_BRANCH} from ${BRANCH}..."
    git checkout -b "${WORK_BRANCH}"
else
    echo "Creating new branch ${WORK_BRANCH} from $(git branch --show-current)..."
    git checkout -b "${WORK_BRANCH}"
fi

# --- Configure git identity ---
git config user.name "${GIT_USER_NAME:-autopilot}"
git config user.email "${GIT_USER_EMAIL:-autopilot@noreply}"

# --- Execute plan phases ---
PLAN_PATH="docs/implementation-plans/${PLAN_SLUG}/plan.md"

if [ ! -f "${PLAN_PATH}" ]; then
    echo "ERROR: Plan not found at ${PLAN_PATH}"
    exit 1
fi

# Count phases by looking for "## Phase" headings
PHASE_COUNT=$(grep -c '^## Phase' "${PLAN_PATH}" || echo "0")
echo "Found ${PHASE_COUNT} phases in plan."

# Per-phase copilot invocations
for PHASE_NUM in $(seq 1 "${PHASE_COUNT}"); do
    echo ""
    echo "=== Phase ${PHASE_NUM} of ${PHASE_COUNT} ==="

    # Check if phase has uncompleted steps
    if ! grep -q '^\- \[ \]\|^\- \[\~\]' "${PLAN_PATH}"; then
        echo "No uncompleted steps remain — skipping."
        continue
    fi

    TRANSCRIPT="session-transcript-phase${PHASE_NUM}.md"

    # Pass --model explicitly when set so model selection is deterministic
    # (not just implied by COPILOT_MODEL) and visible in logs.
    MODEL_ARGS=()
    if [ -n "${COPILOT_MODEL:-}" ]; then
        MODEL_ARGS=(--model "${COPILOT_MODEL}")
        echo "Invoking Copilot CLI with model: ${COPILOT_MODEL}"
    else
        echo "Invoking Copilot CLI with CLI default model (COPILOT_MODEL unset)"
    fi

    copilot -p "Execute ${PLAN_PATH}, phase ${PHASE_NUM}" \
        "${MODEL_ARGS[@]}" \
        --agent autopilot \
        --no-ask-user \
        --share="./${TRANSCRIPT}" \
        || {
            EXIT_CODE=$?
            echo "Phase ${PHASE_NUM} exited with code ${EXIT_CODE}"
            if [ ${EXIT_CODE} -eq 42 ]; then
                echo "@human step encountered — stopping."
                break
            fi
            # Non-zero but not @human — continue to allow partial progress
        }

    echo "Phase ${PHASE_NUM} complete."
done

echo ""
echo "=== Execution finished ==="
if [ -f ".autopilot-finalize-needed" ]; then
    echo "Human finalization requested (container mode only)."
    echo "Draft PR should already exist from the Finalization flow."
    echo "Skipping entrypoint push because Finalization already pushed the branch."
    exit 42
fi

echo "Pushing branch ${WORK_BRANCH}..."
git push origin "${WORK_BRANCH}"

# Note: PR creation is handled by the autopilot agent in its Plan Completion step
# with a structured title and body. The entrypoint only ensures the branch is pushed.

echo "Done."
