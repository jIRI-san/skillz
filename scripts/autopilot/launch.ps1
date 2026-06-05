#requires -Version 7.0
<#
.SYNOPSIS
    Autopilot entry point: validate config + command policy + auth, then dispatch.
.DESCRIPTION
    Loads and schema-validates .autopilot.json, enforces the trusted-command
    policy (tokenizing build/test into argv via the authoritative checks in
    _autopilot-common.ps1), canonicalizes the plan path, resolves the execution
    mode, runs a Docker pre-flight for container mode (fail loudly, no host
    fallback), sweeps stale secret/session files, validates auth, and dispatches
    to the mode-specific orchestrator.

    The configuration is read EXACTLY ONCE here. The command policy lives in this
    launcher and the schema (both outside the agent-editable .autopilot.json), so
    an autopilot run cannot widen its own command policy mid-run.
.PARAMETER Mode
    Overrides the runtime from config. One of: host, container.
.PARAMETER ConfigPath
    Path to the autopilot config (default: <repo>/.autopilot.json).
.PARAMETER ValidateOnly
    Run config/schema/policy/mode/Docker pre-flight checks and return a result
    object WITHOUT validating auth or dispatching. Used by tests and dry runs.
.EXAMPLE
    ./launch.ps1 -Mode host
.EXAMPLE
    ./launch.ps1 -ValidateOnly
#>
[CmdletBinding()]
param(
    [ValidateSet('host', 'container')]
    [string]$Mode,

    [string]$ConfigPath,

    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_autopilot-common.ps1"

function Invoke-AutopilotLaunch {
    [CmdletBinding()]
    param(
        [string]$Mode,
        [string]$ConfigPath,
        [switch]$ValidateOnly
    )

    $repoRoot = Get-RepoRoot -StartPath $PSScriptRoot
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $repoRoot '.autopilot.json'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Config not found: $ConfigPath"
    }

    # --- 1. Load + schema-validate (draft-07) -------------------------------
    $schemaPath = Join-Path $repoRoot 'schemas/autopilot.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Schema not found: $schemaPath"
    }
    $rawConfig = Get-Content -LiteralPath $ConfigPath -Raw
    if (-not (Test-Json -Json $rawConfig -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw "Config failed schema validation: $ConfigPath"
    }
    $config = $rawConfig | ConvertFrom-Json
    Write-AutopilotLog "Config validated: $ConfigPath"

    # --- 2. Enforce command policy (authoritative; tokenize to argv) --------
    $buildArgv = Assert-TrustedCommand -Command $config.build
    $testArgv = Assert-TrustedCommand -Command $config.test
    Write-AutopilotLog "Command policy OK (build launcher: $($buildArgv[0]), test launcher: $($testArgv[0]))"

    # --- 3. Canonicalize plan path ------------------------------------------
    $planFile = Resolve-PlanPath -RepoRoot $repoRoot -PlanPath $config.planPath
    $phases = Get-PlanPhase -PlanFile $planFile
    if ($phases.Count -lt 1) {
        throw "Plan has no '## Phase N' headings: $planFile"
    }
    Write-AutopilotLog "Plan resolved: $planFile ($($phases.Count) phase(s))"

    # --- 4. Resolve execution mode (param overrides config) -----------------
    $effectiveMode = if ($Mode) { $Mode } else { $config.runtime }
    if ($effectiveMode -notin @('host', 'container')) {
        throw "Unsupported mode '$effectiveMode' (host|container; sandbox is out of scope)."
    }
    Write-AutopilotLog "Mode: $effectiveMode"

    # --- 5. Docker pre-flight for container mode (fail loudly) --------------
    if ($effectiveMode -eq 'container') {
        $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
        if (-not $dockerCmd) {
            throw 'Container mode requires Docker, but `docker` was not found on PATH. Install Docker Desktop or run with -Mode host (removes container isolation).'
        }
        & docker info *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Container mode requires a running Docker daemon, but `docker info` failed. Start Docker Desktop or run with -Mode host (removes container isolation).'
        }
        Write-AutopilotLog 'Docker pre-flight OK.'
    }

    # --- 6. Sweep stale secret/session files (>24h) -------------------------
    Clear-StaleSession

    $result = [pscustomobject]@{
        RepoRoot = $repoRoot
        ConfigPath = $ConfigPath
        PlanFile = $planFile
        Mode = $effectiveMode
        PhaseCount = $phases.Count
        BuildArgv = $buildArgv
        TestArgv = $testArgv
        Config = $config
    }

    if ($ValidateOnly) {
        Write-AutopilotLog 'Validation-only run complete.'
        return $result
    }

    # --- 7. Validate auth ---------------------------------------------------
    $validateAuth = Join-Path $PSScriptRoot 'validate-auth.ps1'
    if (-not (Test-Path -LiteralPath $validateAuth -PathType Leaf)) {
        throw "Auth validator not found: $validateAuth"
    }
    & $validateAuth -CredentialTarget $config.copilotAuth.credentialTarget
    if ($LASTEXITCODE -ne 0) {
        throw 'Auth validation failed; aborting before any work.'
    }

    # --- 8. Dispatch to mode-specific orchestrator --------------------------
    $orchestrator = switch ($effectiveMode) {
        'host' { Join-Path $PSScriptRoot 'launch-host.ps1' }
        'container' { Join-Path $PSScriptRoot 'launch-container.ps1' }
    }
    if (-not (Test-Path -LiteralPath $orchestrator -PathType Leaf)) {
        throw "Orchestrator for mode '$effectiveMode' not found: $orchestrator"
    }
    Write-AutopilotLog "Dispatching to $([System.IO.Path]::GetFileName($orchestrator))"
    & $orchestrator -Result $result
    return $result
}

function Clear-StaleSession {
    <#
        .SYNOPSIS
            Deletes autopilot session/secret files older than 24 hours.
    #>
    [CmdletBinding()]
    param()
    $sessionRoot = Join-Path $env:LOCALAPPDATA 'autopilot-sessions'
    if (-not (Test-Path -LiteralPath $sessionRoot)) {
        return
    }
    $cutoff = [DateTime]::UtcNow.AddHours(-24)
    Get-ChildItem -LiteralPath $sessionRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                Write-AutopilotLog "Swept stale session file: $($_.Name)"
            }
            catch {
                Write-AutopilotLog "Could not remove stale file $($_.Name): $($_.Exception.Message)" -Level WARN
            }
        }
}

# Only execute when run directly (not when dot-sourced for testing).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AutopilotLaunch -Mode $Mode -ConfigPath $ConfigPath -ValidateOnly:$ValidateOnly
}
