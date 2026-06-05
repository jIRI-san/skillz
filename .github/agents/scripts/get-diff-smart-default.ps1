# get-diff-smart-default.ps1
# Determines scope automatically based on current branch:
#   - Feature branch: uncommitted changes + all commits not yet in the default remote branch
#   - Default branch: uncommitted changes + commits not yet pushed (origin/HEAD..HEAD)
# Outputs: file list to stdout (--files) or full diff to stdout (--diff, default).
#
# Usage:
#   .\get-diff-smart-default.ps1 --files   # print combined changed file list
#   .\get-diff-smart-default.ps1 --diff    # print combined full diff (default)

param(
    [switch]$Files,
    [switch]$Diff
)

# Resolve current branch
$currentBranch = git branch --show-current

# Resolve default remote branch
$remoteHead = git rev-parse --abbrev-ref origin/HEAD 2>$null
if ($LASTEXITCODE -ne 0 -or -not $remoteHead) {
    $defaultRef = git rev-parse --verify main 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $defaultBranch = "main" } else { $defaultBranch = "master" }
    $defaultRef = $defaultBranch
} else {
    $defaultBranch = $remoteHead -replace "^origin/", ""
    $defaultRef = $remoteHead
}

$onDefaultBranch = ($currentBranch -eq $defaultBranch)

if ($Files) {
    if ($onDefaultBranch) {
        # Uncommitted
        git diff HEAD --name-only
        # Unpushed commits
        git log "$defaultRef..HEAD" --name-only --format="" | Where-Object { $_ -ne "" }
    } else {
        # Uncommitted
        git diff HEAD --name-only
        # Branch commits
        git diff "${defaultBranch}...HEAD" --name-only
    }
} else {
    if ($onDefaultBranch) {
        # Uncommitted
        git diff HEAD
        # Unpushed commits
        git log -p "$defaultRef..HEAD" --no-merges
    } else {
        # Uncommitted
        git diff HEAD
        # Branch commits
        git diff "${defaultBranch}...HEAD"
    }
}
