#requires -Version 7.0
<#
.SYNOPSIS
    Host-mode orchestrator (step 3.1): prepare an isolated git worktree + branch.
.DESCRIPTION
    Receives the validated launch result from launch.ps1 and prepares the host
    execution environment: a dedicated git worktree at
    `<repo>.worktrees/feature-<slug>` on branch `feature-<slug>`, with a
    `safe.directory` guard so git does not reject the worktree as dubiously
    owned. The per-phase Copilot CLI loop and timeout/exit-code handling are
    layered on top in steps 3.2 and 3.3.

    The slug is derived from the plan directory name (e.g.
    docs/implementation-plans/002-plugin-registry/plan.md -> 002-plugin-registry).
.PARAMETER Result
    The launch result object produced by launch.ps1 (RepoRoot, PlanFile, Config,
    BuildArgv, TestArgv, ...).
.PARAMETER SkipWorktree
    Reuse the current repo root as the working tree instead of creating a
    worktree. Used by tests; not part of the normal flow.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [psobject]$Result,

    [switch]$SkipWorktree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_autopilot-common.ps1"

function ConvertTo-BranchSlug {
    <#
        .SYNOPSIS
            Derives a safe branch slug from the plan directory name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$PlanFile
    )
    $planDir = Split-Path -Path $PlanFile -Parent
    $leaf = Split-Path -Path $planDir -Leaf
    $slug = (($leaf -replace '[^A-Za-z0-9._-]', '-').Trim('-')).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw "Cannot derive a branch slug from plan path: $PlanFile"
    }
    return $slug
}

function Add-SafeDirectory {
    <#
        .SYNOPSIS
            Idempotently registers a path in git's global safe.directory list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $existing = @(git config --global --get-all safe.directory 2>$null)
    $norm = $Path -replace '\\', '/'
    if ($existing -contains $Path -or $existing -contains $norm) {
        return
    }
    git config --global --add safe.directory $Path | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register safe.directory for: $Path"
    }
    Write-AutopilotLog "Registered git safe.directory: $Path"
}

function Test-WorktreeRegistered {
    <#
        .SYNOPSIS
            Returns $true if the given path is already a registered worktree.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$WorktreePath
    )
    $target = ([System.IO.Path]::GetFullPath($WorktreePath)) -replace '\\', '/'
    $lines = @(git -C $RepoRoot worktree list --porcelain 2>$null)
    foreach ($line in $lines) {
        if ($line -match '^worktree (.+)$') {
            $listed = ([System.IO.Path]::GetFullPath($Matches[1].Trim())) -replace '\\', '/'
            if ($listed -ieq $target) {
                return $true
            }
        }
    }
    return $false
}

function Initialize-HostWorktree {
    <#
        .SYNOPSIS
            Creates (or reuses) the worktree + branch and returns its path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$WorktreePath
    )

    if (Test-WorktreeRegistered -RepoRoot $RepoRoot -WorktreePath $WorktreePath) {
        Write-AutopilotLog "Reusing existing worktree: $WorktreePath"
        Add-SafeDirectory -Path $WorktreePath
        return $WorktreePath
    }

    $parent = Split-Path -Path $WorktreePath -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    git -C $RepoRoot rev-parse --verify --quiet "refs/heads/$Branch" *> $null
    $branchExists = ($LASTEXITCODE -eq 0)

    if ($branchExists) {
        Write-AutopilotLog "Adding worktree on existing branch '$Branch'."
        $null = git -C $RepoRoot worktree add $WorktreePath $Branch
    }
    else {
        Write-AutopilotLog "Adding worktree on new branch '$Branch'."
        $null = git -C $RepoRoot worktree add -b $Branch $WorktreePath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git worktree add failed for branch '$Branch' at: $WorktreePath"
    }

    Add-SafeDirectory -Path $WorktreePath
    return $WorktreePath
}

function Invoke-AutopilotHost {
    <#
        .SYNOPSIS
            Host-mode orchestrator entry point.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Result,

        [switch]$SkipWorktree
    )

    $repoRoot = $Result.RepoRoot
    $slug = ConvertTo-BranchSlug -PlanFile $Result.PlanFile
    $branch = "feature-$slug"

    if ($SkipWorktree) {
        $worktree = $repoRoot
        Write-AutopilotLog "SkipWorktree: using repo root as working tree ($repoRoot)."
    }
    else {
        $worktreePath = "$repoRoot.worktrees" + [System.IO.Path]::DirectorySeparatorChar + $branch
        $worktree = Initialize-HostWorktree -RepoRoot $repoRoot -Branch $branch -WorktreePath $worktreePath
    }

    Write-AutopilotLog "Host environment ready (branch '$branch', worktree '$worktree')."

    return [pscustomobject]@{
        RepoRoot = $repoRoot
        WorktreePath = $worktree
        Branch = $branch
        Slug = $slug
        PlanFile = $Result.PlanFile
        PhaseCount = $Result.PhaseCount
        Config = $Result.Config
        BuildArgv = $Result.BuildArgv
        TestArgv = $Result.TestArgv
    }
}

# Only execute when run directly (not when dot-sourced for testing).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AutopilotHost -Result $Result -SkipWorktree:$SkipWorktree
}
