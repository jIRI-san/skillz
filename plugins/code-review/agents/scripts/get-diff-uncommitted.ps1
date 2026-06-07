# get-diff-uncommitted.ps1
# Collects staged + unstaged changes relative to HEAD.
# Outputs: file list to stdout (--files) or full diff to stdout (--diff, default).
#
# Usage:
#   .\get-diff-uncommitted.ps1 --files   # print changed file list
#   .\get-diff-uncommitted.ps1 --diff    # print full diff (default)

param(
    [switch]$Files,
    [switch]$Diff
)

if ($Files) {
    git diff HEAD --name-only
} else {
    git diff HEAD
}
