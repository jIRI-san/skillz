<#
.SYNOPSIS
    Host-mode orchestrator for autonomous plan execution.
.DESCRIPTION
    Creates a git worktree on a feature branch, loops over plan phases invoking
    Copilot CLI once per phase with live output streaming and timeout enforcement.
.PARAMETER PlanSlug
    The plan folder name (e.g. '002-persistent-storage-for-job-data').
.PARAMETER Mode
    Execution scope: 'whole-plan' or 'next-phase'.
.PARAMETER Config
    Parsed .autopilot.json object.
.PARAMETER Token
    GitHub token for Copilot CLI.
#>
param(
    [Parameter(Mandatory)]
    [string]$PlanSlug,

    [Parameter(Mandatory)]
    [ValidateSet('whole-plan', 'next-phase')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [string]$Token,

    [string]$Branch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BranchName = if ($Branch) { $Branch } else { "feature/$PlanSlug" }
$RepoRoot = git rev-parse --show-toplevel
$WorktreeRoot = Join-Path (Split-Path $RepoRoot -Parent) "$((Split-Path $RepoRoot -Leaf)).worktrees"
$WorktreePath = Join-Path $WorktreeRoot $BranchName.Replace('/', '-')
$PlanPath = "docs/implementation-plans/$PlanSlug/plan.md"
$TimeoutMinutes = $Config.timeout

# --- Worktree setup ---
if (-not (Test-Path $WorktreeRoot)) {
    New-Item -ItemType Directory -Path $WorktreeRoot -Force | Out-Null
}

if (Test-Path $WorktreePath) {
    Write-Host "Worktree already exists at $WorktreePath - resuming."
}
else {
    Write-Host "Creating worktree: $WorktreePath (branch: $BranchName)"
    # Check if branch exists
    $branchExists = git branch --list $BranchName
    if ($branchExists) {
        git worktree add $WorktreePath $BranchName
    }
    else {
        git worktree add $WorktreePath -b $BranchName
    }
}

# Validate plan exists in worktree
$fullPlanPath = Join-Path $WorktreePath $PlanPath
if (-not (Test-Path $fullPlanPath)) {
    throw "Plan not found at: $fullPlanPath"
}

# Configure git identity in worktree
Push-Location $WorktreePath
try {
    git config user.name $Config.git.name
    git config user.email $Config.git.email
}
finally {
    Pop-Location
}

# --- Phase detection ---
$planContent = Get-Content $fullPlanPath -Raw
$phaseMatches = [regex]::Matches($planContent, '## Phase (\d+)')
$totalPhases = $phaseMatches.Count
Write-Host "Plan has $totalPhases phases."

# --- Per-phase execution loop ---
function Invoke-CopilotPhase {
    param(
        [int]$PhaseNumber,
        [string]$CopilotToken,
        [string]$Cwd,
        [string]$PlanRelPath,
        [int]$TimeoutMin
    )

    $transcriptName = "session-transcript-phase$PhaseNumber.md"
    $prompt = "Execute $PlanRelPath, phase $PhaseNumber"

    Write-Host ""
    Write-Host "=== Invoking Copilot CLI for Phase $PhaseNumber (timeout: ${TimeoutMin}m) ==="

    # Resolve copilot CLI executable. Process.Start with UseShellExecute=$false
    # only finds .exe natively; .bat/.ps1 need explicit resolution.
    $copilotCmd = Get-Command copilot -ErrorAction SilentlyContinue
    if (-not $copilotCmd) { throw "Copilot CLI not found in PATH. Install via: npm install -g @github/copilot" }
    $copilotPath = $copilotCmd.Source

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($copilotPath -match '\.bat$') {
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/c `"$copilotPath`" -p `"$prompt`" --agent autopilot --no-ask-user --allow-all --share=./$transcriptName"
    } elseif ($copilotPath -match '\.ps1$') {
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-ExecutionPolicy Bypass -File `"$copilotPath`" -p `"$prompt`" --agent autopilot --no-ask-user --allow-all --share=./$transcriptName"
    } else {
        $psi.FileName = $copilotPath
        $psi.Arguments = "-p `"$prompt`" --agent autopilot --no-ask-user --allow-all --share=./$transcriptName"
    }
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['COPILOT_GITHUB_TOKEN'] = $CopilotToken
    $psi.EnvironmentVariables['GH_TOKEN'] = $CopilotToken
    $psi.EnvironmentVariables['COPILOT_ALLOW_ALL'] = 'true'
    $psi.EnvironmentVariables['COPILOT_MODEL'] = $Config.model

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $true

    # Live output streaming via events
    $outputHandler = {
        if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
            Write-Host $EventArgs.Data
        }
    }
    $errorHandler = {
        if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
            Write-Host "ERR: $($EventArgs.Data)" -ForegroundColor Yellow
        }
    }

    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outputHandler | Out-Null
    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $errorHandler | Out-Null

    $process.Start() | Out-Null
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    # Timeout enforcement via polling
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while (-not $process.HasExited) {
        if ((Get-Date) -gt $deadline) {
            Write-Warning "Phase $PhaseNumber timed out after ${TimeoutMin} minutes. Killing process."
            $process.Kill()
            $process.WaitForExit(5000)
            return @{ ExitCode = -1; TimedOut = $true }
        }
        Start-Sleep -Milliseconds 500
    }

    $process.WaitForExit() # Ensure all output flushed
    Get-EventSubscriber | Where-Object SourceObject -eq $process | Unregister-Event

    return @{ ExitCode = $process.ExitCode; TimedOut = $false }
}

# --- Main execution ---
$phasesExecuted = 0
for ($phase = 1; $phase -le $totalPhases; $phase++) {
    # Re-read plan to check current phase status
    $currentPlan = Get-Content $fullPlanPath -Raw

    # Simple heuristic: check if phase has uncompleted steps
    # Look for "- [ ]" or "- [~]" between this phase heading and the next
    $phasePattern = "## Phase ${phase}" + '.*?(?=## Phase ' + "$($phase + 1)" + '|## Known Constraints|$)'
    $phaseSection = [regex]::Match($currentPlan, $phasePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    if (-not $phaseSection.Success) { continue }

    $hasIncomplete = $phaseSection.Value -match '\- \[ \]|\- \[~\]'
    if (-not $hasIncomplete) {
        Write-Host "Phase ${phase}: all steps complete - skipping."
        continue
    }

    Write-Host "Phase ${phase}: has uncompleted steps - executing."
    $result = Invoke-CopilotPhase -PhaseNumber $phase -CopilotToken $Token -Cwd $WorktreePath -PlanRelPath $PlanPath -TimeoutMin $TimeoutMinutes

    $phasesExecuted++

    if ($result.TimedOut) {
        Write-Warning "Execution stopped due to timeout in Phase $phase."
        break
    }
    if ($result.ExitCode -eq 42) {
        Write-Host "@human step encountered in Phase $phase. Stopping."
        break
    }
    if ($result.ExitCode -ne 0) {
        Write-Warning "Phase $phase exited with code $($result.ExitCode). Stopping."
        break
    }

    if ($Mode -eq 'next-phase') {
        Write-Host "Mode is 'next-phase' - stopping after Phase ${phase}."
        break
    }
}

# --- Copy transcripts ---
$transcriptsDir = Join-Path $RepoRoot "docs/implementation-plans/$PlanSlug/transcripts"
if (-not (Test-Path $transcriptsDir)) {
    New-Item -ItemType Directory -Path $transcriptsDir -Force | Out-Null
}

Get-ChildItem -Path $WorktreePath -Filter 'session-transcript-phase*.md' -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item $_.FullName $transcriptsDir -Force }

Write-Host ""
Write-Host "=== Host-mode execution complete ==="
Write-Host "Phases executed: $phasesExecuted"
Write-Host "Worktree: $WorktreePath"
Write-Host "Transcripts: $transcriptsDir"
