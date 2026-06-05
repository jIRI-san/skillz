# get-diff-branch.ps1
# Collects diff of all commits on the current branch not yet in the default remote branch (main/master).
# Outputs: file list to stdout (--files) or full diff to stdout (--diff, default).
#
# Usage:
#   .\get-diff-branch.ps1 --files   # print changed file list
#   .\get-diff-branch.ps1 --diff    # print full diff (default)

param(
    [switch]$Files,
    [switch]$Diff
)

# Resolve default branch
$defaultBranch = git rev-parse --abbrev-ref origin/HEAD 2>$null
if ($LASTEXITCODE -ne 0 -or -not $defaultBranch) {
    # Fallback: try main, then master
    $defaultBranch = git rev-parse --verify main 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $defaultBranch = "main" }
    else { $defaultBranch = "master" }
} else {
    $defaultBranch = $defaultBranch -replace "^origin/", ""
}

if ($Files) {
    git diff "$defaultBranch...HEAD" --name-only
} else {
    git diff "$defaultBranch...HEAD"
}
