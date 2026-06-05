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

    [switch]$SkipWorktree,

    [switch]$PrepareOnly,

    [hashtable]$CopilotLauncher,

    [string]$LogRoot,

    [string]$TokenEnvVar
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

function Resolve-CopilotLauncher {
    <#
        .SYNOPSIS
            Resolves how to launch the `copilot` CLI as FileName + base argv.
        .DESCRIPTION
            Returns @{ FileName; BaseArgs }. A sibling `copilot.ps1` is preferred
            (launched via the current pwsh with -File for clean argv quoting); an
            .exe is launched directly; a .cmd/.bat goes through ComSpec /c.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$CopilotCommand = 'copilot'
    )
    $cmd = Get-Command $CopilotCommand -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Copilot CLI '$CopilotCommand' not found on PATH. Install @github/copilot (npm i -g @github/copilot)."
    }
    $source = $cmd.Source
    $pwshPath = (Get-Process -Id $PID).Path

    # Prefer a sibling .ps1 shim for clean ArgumentList quoting.
    $sibling = [System.IO.Path]::ChangeExtension($source, '.ps1')
    if ((Test-Path -LiteralPath $sibling) -and ([System.IO.Path]::GetExtension($source).ToLowerInvariant() -ne '.ps1')) {
        return @{ FileName = $pwshPath; BaseArgs = @('-NoProfile', '-File', $sibling) }
    }

    switch ([System.IO.Path]::GetExtension($source).ToLowerInvariant()) {
        '.ps1' { return @{ FileName = $pwshPath; BaseArgs = @('-NoProfile', '-File', $source) } }
        '.cmd' { return @{ FileName = $env:ComSpec; BaseArgs = @('/c', $source) } }
        '.bat' { return @{ FileName = $env:ComSpec; BaseArgs = @('/c', $source) } }
        default { return @{ FileName = $source; BaseArgs = @() } }
    }
}

function Get-CopilotPhaseArgs {
    <#
        .SYNOPSIS
            Builds the per-phase `copilot` CLI argument array (selects the
            autopilot agent, non-interactive, with transcript + log dir).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = '"Args" names the returned array of CLI arguments.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Agent,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$PlanRelPath,

        [Parameter(Mandatory)]
        [int]$PhaseNumber,

        [Parameter(Mandatory)]
        [string]$TranscriptPath,

        [Parameter(Mandatory)]
        [string]$LogDir,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [string]$TokenEnvVar
    )
    $argv = [System.Collections.Generic.List[string]]::new()
    [string[]]$base = @(
        '--agent', $Agent,
        '--model', $Model,
        '--prompt', "Execute $PlanRelPath, phase $PhaseNumber",
        '--allow-all-tools',
        '--no-ask-user',
        '--share', $TranscriptPath,
        '--log-dir', $LogDir,
        '-C', $WorkingDirectory
    )
    $argv.AddRange($base)
    if ($TokenEnvVar) {
        $argv.Add('--secret-env-vars')
        $argv.Add($TokenEnvVar)
    }
    return $argv.ToArray()
}

function Write-DrainedLine {
    <#
        .SYNOPSIS
            Drains all currently-queued lines and logs them (redacted).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue,

        [switch]$Stderr
    )
    $line = $null
    while ($Queue.TryDequeue([ref]$line)) {
        if ($Stderr) {
            Write-AutopilotLog "[copilot:stderr] $line"
        }
        else {
            Write-AutopilotLog "[copilot] $line"
        }
    }
}

function Invoke-CopilotProcess {
    <#
        .SYNOPSIS
            Runs one copilot invocation with live, deadlock-free streaming of
            both stdout and stderr; returns the process exit code.
        .DESCRIPTION
            Uses System.Diagnostics.Process with RedirectStandardOutput +
            RedirectStandardError and async BeginOutputReadLine /
            BeginErrorReadLine. Each stream's DataReceived event (handled on the
            PowerShell event-manager thread via -Action) enqueues lines into a
            thread-safe queue that the main loop drains, so a full pipe buffer can
            never deadlock the child. (Timeout / tree-kill is layered on in 3.3.)
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    foreach ($a in $ArgumentList) {
        [void]$psi.ArgumentList.Add($a)
    }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $stdoutQ = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $stderrQ = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    $outSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $stdoutQ -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    }
    $errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $stderrQ -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    }

    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        while (-not $proc.HasExited) {
            Write-DrainedLine -Queue $stdoutQ
            Write-DrainedLine -Queue $stderrQ -Stderr
            [void]$proc.WaitForExit(150)
        }
        # WaitForExit() (no timeout) guarantees async readers received their
        # terminating null and all buffered lines are queued before the final drain.
        $proc.WaitForExit()
        Write-DrainedLine -Queue $stdoutQ
        Write-DrainedLine -Queue $stderrQ -Stderr

        return $proc.ExitCode
    }
    finally {
        Unregister-Event -SourceIdentifier $outSub.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errSub.Name -ErrorAction SilentlyContinue
        $proc.Dispose()
    }
}

function Invoke-HostPhaseLoop {
    <#
        .SYNOPSIS
            Runs one copilot invocation per plan phase, streaming output live.
        .DESCRIPTION
            Step 3.2 scope: per-phase invocation + streaming + transcript. The
            full exit-code contract (0 advance / 42 @human halt / other failure),
            timeout/tree-kill and maxIterationsPerStep are layered on in step 3.3;
            for now the loop advances on exit 0 and stops on any non-zero exit.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [psobject]$HostContext,

        [hashtable]$CopilotLauncher,

        [string]$LogRoot,

        [string]$TokenEnvVar
    )
    if (-not $CopilotLauncher) {
        $CopilotLauncher = Resolve-CopilotLauncher
    }
    if (-not $LogRoot) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $LogRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'autopilot-sessions') "$($HostContext.Slug)-$stamp"
    }
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null

    $model = $HostContext.Config.model
    $planRel = $HostContext.Config.planPath
    $exitCode = 0
    for ($n = 1; $n -le $HostContext.PhaseCount; $n++) {
        Write-AutopilotLog "=== Phase $n/$($HostContext.PhaseCount) ==="
        $transcript = Join-Path $LogRoot "phase-$n.transcript.md"
        $phaseArgs = Get-CopilotPhaseArgs -Agent 'autopilot' -Model $model -PlanRelPath $planRel `
            -PhaseNumber $n -TranscriptPath $transcript -LogDir $LogRoot `
            -WorkingDirectory $HostContext.WorktreePath -TokenEnvVar $TokenEnvVar
        $allArgs = @($CopilotLauncher.BaseArgs) + $phaseArgs
        $exitCode = Invoke-CopilotProcess -FileName $CopilotLauncher.FileName -ArgumentList $allArgs `
            -WorkingDirectory $HostContext.WorktreePath
        Write-AutopilotLog "Phase $n exited with code $exitCode."
        if ($exitCode -ne 0) {
            Write-AutopilotLog 'Stopping phase loop (non-zero exit; contract handling lands in step 3.3).' -Level WARN
            break
        }
    }
    return $exitCode
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

        [switch]$SkipWorktree,

        [switch]$PrepareOnly,

        [hashtable]$CopilotLauncher,

        [string]$LogRoot,

        [string]$TokenEnvVar
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

    $hostContext = [pscustomobject]@{
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

    if ($PrepareOnly) {
        return $hostContext
    }

    $exitCode = Invoke-HostPhaseLoop -HostContext $hostContext -CopilotLauncher $CopilotLauncher `
        -LogRoot $LogRoot -TokenEnvVar $TokenEnvVar
    $hostContext | Add-Member -NotePropertyName ExitCode -NotePropertyValue $exitCode -PassThru
    return $hostContext
}

# Only execute when run directly (not when dot-sourced for testing).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AutopilotHost -Result $Result -SkipWorktree:$SkipWorktree -PrepareOnly:$PrepareOnly `
        -CopilotLauncher $CopilotLauncher -LogRoot $LogRoot -TokenEnvVar $TokenEnvVar
}
