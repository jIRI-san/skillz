# get-diff-commits.ps1
# Collects diff for the last N commits (no merges).
# Outputs: file list to stdout (--files) or full patch to stdout (--diff, default).
#
# Usage:
#   .\get-diff-commits.ps1 -N 3 --files   # print changed file list for last 3 commits
#   .\get-diff-commits.ps1 -N 3 --diff    # print full diff for last 3 commits (default)

param(
    [Parameter(Mandatory)][int]$N,
    [switch]$Files,
    [switch]$Diff
)

if ($Files) {
    git log --name-only --format="" -$N --no-merges | Where-Object { $_ -ne "" } | Sort-Object -Unique
} else {
    git log -p -$N --no-merges
}
