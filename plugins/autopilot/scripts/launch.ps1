<#
.SYNOPSIS
    Entry point for autonomous plan execution.
.DESCRIPTION
    Validates inputs, runs pre-flight checks, and dispatches to
    host or container mode orchestrator.
.PARAMETER PlanSlug
    Plan folder name (e.g. '002-persistent-storage-for-job-data').
.PARAMETER Mode
    Execution scope: 'whole-plan' or 'next-phase'.
.PARAMETER Runtime
    Override runtime from config: 'host' or 'container'. Uses config value if omitted.
#>
param(
    [Parameter(Mandatory)]
    [string]$PlanSlug,

    [Parameter(Mandatory)]
    [ValidateSet('whole-plan', 'next-phase')]
    [string]$Mode,

    [ValidateSet('host', 'container', 'sandbox')]
    [string]$Runtime,

    [string]$Branch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = git rev-parse --show-toplevel
$ScriptDir = $PSScriptRoot

# --- Validate slug ---
if ($PlanSlug -notmatch '^[a-z0-9-]+$') {
    Write-Error "Invalid plan slug '$PlanSlug'. Must match ^[a-z0-9-]+$."
    exit 1
}

$PlanFolder = Join-Path $RepoRoot "docs/implementation-plans/$PlanSlug"
if (-not (Test-Path (Join-Path $PlanFolder 'plan.md'))) {
    Write-Error "Plan not found: $PlanFolder/plan.md"
    exit 1
}

# --- Load and validate config ---
$ConfigPath = Join-Path $RepoRoot '.autopilot.json'
if (-not (Test-Path $ConfigPath)) {
    Write-Error ".autopilot.json not found — run '/ci' Autonomous to generate it, or create it from .autopilot.json.example."
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Validate required fields
$requiredFields = @('runtime', 'copilotAuth', 'gitProvider', 'gitAuth', 'model', 'git', 'timeout', 'maxIterationsPerStep', 'build', 'test')
foreach ($field in $requiredFields) {
    if (-not ($Config.PSObject.Properties.Name -contains $field)) {
        Write-Error "Missing required field '$field' in .autopilot.json"
        exit 1
    }
}

# --- Validate build/test commands against allowlist ---
$buildPrefixes = @('dotnet build', 'dotnet publish', 'npm run', 'yarn run', 'pnpm run', 'make', 'cargo build', 'gradle ', 'mvn ')
$testPrefixes = @('dotnet test', 'npm test', 'npm run test', 'yarn test', 'pnpm test', 'make test', 'cargo test', 'gradle test', 'mvn test')

$buildAllowed = $false
foreach ($prefix in $buildPrefixes) {
    if ($Config.build.StartsWith($prefix)) { $buildAllowed = $true; break }
}
if (-not $buildAllowed) {
    Write-Error "Build command '$($Config.build)' does not match allowed prefixes: $($buildPrefixes -join ', ')"
    exit 1
}

$testAllowed = $false
foreach ($prefix in $testPrefixes) {
    if ($Config.test.StartsWith($prefix)) { $testAllowed = $true; break }
}
if (-not $testAllowed) {
    Write-Error "Test command '$($Config.test)' does not match allowed prefixes: $($testPrefixes -join ', ')"
    exit 1
}

# --- Determine runtime ---
$effectiveRuntime = if ($Runtime) { $Runtime } else { $Config.runtime }
Write-Host "Runtime: $effectiveRuntime"

if ($effectiveRuntime -eq 'host' -and $env:AUTOPILOT_DISABLE_HOST -eq 'true') {
    Write-Error "Host runtime disabled via AUTOPILOT_DISABLE_HOST."
    exit 1
}

# --- Docker pre-flight (container mode) ---
if ($effectiveRuntime -eq 'container') {
    Write-Host "Checking Docker daemon..."
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    docker info > $null 2>&1
    $dockerExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($dockerExit -ne 0) {
        Write-Error "Docker daemon not available. Start Docker Desktop or switch to host mode."
        exit 1
    }
    Write-Host "Docker OK."
}

# --- Sandbox pre-flight ---
if ($effectiveRuntime -eq 'sandbox') {
    if (-not (Test-Path 'C:\Windows\System32\WindowsSandbox.exe')) {
        Write-Error "Windows Sandbox not available. Enable it: Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM'"
        exit 1
    }
    Write-Host "Windows Sandbox OK."
}

# --- Detect partial state ---
$branchName = "feature/$PlanSlug"
if ($effectiveRuntime -eq 'host') {
    $worktreePath = Join-Path (Split-Path $RepoRoot -Parent) "autopilot-$PlanSlug"
    if (Test-Path $worktreePath) {
        Write-Host ""
        Write-Host "NOTICE: Existing worktree detected at $worktreePath"
        Write-Host "This indicates a previous run. Will resume from current state."
        Write-Host ""
    }
}
else {
    # Check if remote branch exists (container/sandbox mode resume)
    $remoteBranch = git ls-remote --heads origin $branchName 2>$null
    if ($remoteBranch) {
        Write-Host ""
        Write-Host "NOTICE: Remote branch '$branchName' already exists."
        Write-Host "Container will resume from that branch state."
        Write-Host ""
    }
}

# --- Sweep stale env files ---
Write-Host "Sweeping stale env files..."
$envSessionDir = Join-Path $env:LOCALAPPDATA 'autopilot-sessions'
if (Test-Path $envSessionDir) {
    $staleThreshold = (Get-Date).AddHours(-24)
    Get-ChildItem $envSessionDir -Directory | Where-Object { $_.LastWriteTime -lt $staleThreshold } | ForEach-Object {
        Write-Host "  Removing stale session: $($_.Name)"
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Get credentials ---
Write-Host "Fetching credentials..."
$credTarget = switch ($Config.copilotAuth) {
    'pat' { 'copilot-autopilot' }
    'oauth' { 'copilot-cli' }
}
$Token = & (Join-Path $ScriptDir 'get-credential.ps1') -Target $credTarget
if (-not $Token) {
    Write-Error "Failed to retrieve token for target '$credTarget'."
    exit 1
}

$AdoToken = $null
if ($Config.gitProvider -eq 'ado') {
    $AdoToken = & (Join-Path $ScriptDir 'get-credential.ps1') -Target 'ado'
    if (-not $AdoToken) {
        Write-Error "Failed to retrieve ADO token."
        exit 1
    }
}

# --- Validate authentication ---
Write-Host "Validating authentication..."
& (Join-Path $ScriptDir 'validate-auth.ps1') -Config $Config -Token $Token
if ($LASTEXITCODE -ne 0) {
    Write-Error "Authentication validation failed. Run validate-auth.ps1 manually for details."
    exit 1
}
Write-Host "Auth OK."

# --- Dispatch ---
Write-Host ""
Write-Host "=== Launching $effectiveRuntime mode ==="
Write-Host "Plan: $PlanSlug"
Write-Host "Mode: $Mode"
Write-Host "Timeout: $($Config.timeout) minutes/phase"
Write-Host ""

$dispatchParams = @{
    PlanSlug = $PlanSlug
    Mode     = $Mode
    Config   = $Config
    Token    = $Token
    Branch   = if ($Branch) { $Branch } else { "feature/$PlanSlug" }
}
if ($AdoToken) { $dispatchParams.AdoToken = $AdoToken }

switch ($effectiveRuntime) {
    'host' {
        & (Join-Path $ScriptDir 'launch-host.ps1') @dispatchParams
    }
    'container' {
        & (Join-Path $ScriptDir 'launch-container.ps1') @dispatchParams
    }
    'sandbox' {
        & (Join-Path $ScriptDir 'launch-sandbox.ps1') @dispatchParams
    }
}

$exitCode = $LASTEXITCODE
Write-Host ""
Write-Host "=== Autopilot finished with exit code: $exitCode ==="
exit $exitCode
