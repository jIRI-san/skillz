# get-diff-files.ps1
# Produces a diff scoped to a specific list of files (used in batch mode).
# The file list is derived from the active scope (uncommitted, branch, or N commits).
# Outputs: full diff for the given files to stdout.
#
# Usage:
#   .\get-diff-files.ps1 -Scope uncommitted -Files "src/Foo.cs","src/Bar.cs"
#   .\get-diff-files.ps1 -Scope branch -Files "src/Foo.cs","src/Bar.cs"
#   .\get-diff-files.ps1 -Scope commits -N 3 -Files "src/Foo.cs","src/Bar.cs"
#
# Scope values: uncommitted | branch | commits

param(
    [Parameter(Mandatory)][ValidateSet("uncommitted","branch","commits")][string]$Scope,
    [Parameter(Mandatory)][string[]]$Files,
    [int]$N = 1   # used only when Scope = commits
)

switch ($Scope) {
    "uncommitted" {
        git diff HEAD -- @Files
    }
    "branch" {
        $remoteHead = git rev-parse --abbrev-ref origin/HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $remoteHead) {
            $defaultBranch = if (git rev-parse --verify main 2>$null) { "main" } else { "master" }
        } else {
            $defaultBranch = $remoteHead -replace "^origin/", ""
        }
        git diff "${defaultBranch}...HEAD" -- @Files
    }
    "commits" {
        git log -p -$N --no-merges -- @Files
    }
}
