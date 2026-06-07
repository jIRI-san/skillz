#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,
    [Parameter(Mandatory)]
    [string]$PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PlanDependsOn006 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    foreach ($match in [regex]::Matches($content, '<!--\s*depends-on:\s*(?<deps>[^>]+?)-->', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $deps = $match.Groups['deps'].Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($deps -contains '006') {
            return $true
        }
    }

    return $false
}

function Assert-FileContains {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [string]$RelativePath,
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    $fullPath = Join-Path $Root ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Missing required dependency file '$RelativePath'."
    }

    $text = Get-Content -LiteralPath $fullPath -Raw -Encoding utf8
    if ($text -notmatch $Pattern) {
        throw "Dependency contract missing in '$RelativePath' (pattern '$Pattern')."
    }
}

function Invoke-TestPlanEvidenceProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [Parameter(Mandatory)]
        [string]$Marker
    )

    $output = @(
        & pwsh -NoProfile -File $ScriptPath -RepoRoot $Root -EvidenceMarker $Marker -EvidenceStage PhaseCrosscheck 2>&1
    )

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | ForEach-Object { "$_" }) -join "`n"
    }
}

try {
    $resolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoRoot).Path)
    $resolvedPlanPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $PlanPath).Path)

    $rootWithSeparator = $resolvedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedPlanPath -ne $resolvedRoot -and -not $resolvedPlanPath.StartsWith($rootWithSeparator, [System.StringComparison]::Ordinal)) {
        throw "Plan path '$resolvedPlanPath' is outside repository root '$resolvedRoot'."
    }

    if (-not (Test-PlanDependsOn006 -Path $resolvedPlanPath)) {
        Write-Host 'Plan does not declare depends-on: 006; dependency gate skipped.'
        exit 0
    }

    $testPlanPath = Join-Path $resolvedRoot 'scripts/skalary/Test-Plan.ps1'
    if (-not (Test-Path -LiteralPath $testPlanPath -PathType Leaf)) {
        throw "Missing required script 'scripts/skalary/Test-Plan.ps1'."
    }

    $testPlanCommand = Get-Command -Name $testPlanPath -CommandType ExternalScript -ErrorAction Stop
    $hasPublicEvaluatorPath = $testPlanCommand.Parameters.ContainsKey('EvidenceMarker') -or $testPlanCommand.Parameters.ContainsKey('VerifyEvidence')
    if (-not $hasPublicEvaluatorPath) {
        throw "Test-Plan public file-evidence path is unavailable (expected parameter 'EvidenceMarker' or 'VerifyEvidence')."
    }

    $passProbe = Invoke-TestPlanEvidenceProbe -Root $resolvedRoot -ScriptPath $testPlanPath -Marker 'file:README.md#exists'
    if ($passProbe.ExitCode -ne 0) {
        throw "Expected file-evidence pass probe failed.`n$($passProbe.Output)"
    }

    $failProbe = Invoke-TestPlanEvidenceProbe -Root $resolvedRoot -ScriptPath $testPlanPath -Marker 'file:README.md#contains:__SKALARY_PLAN006_DEPENDENCY_PROBE_SHOULD_FAIL__'
    if ($failProbe.ExitCode -eq 0) {
        throw 'Expected file-evidence fail probe unexpectedly passed.'
    }

    Assert-FileContains -Root $resolvedRoot -RelativePath 'plugins/create-implementation-plan/skills/cip/assets/drafting-guide.md' -Pattern 'Test-Plan\.ps1'
    Assert-FileContains -Root $resolvedRoot -RelativePath 'plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md' -Pattern 'test:<TestId>'
    Assert-FileContains -Root $resolvedRoot -RelativePath 'plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md' -Pattern 'file:<path>#<assertion>'
    Assert-FileContains -Root $resolvedRoot -RelativePath 'plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md' -Pattern 'review:cr\|dr'
    Assert-FileContains -Root $resolvedRoot -RelativePath 'plugins/autopilot/agents/autopilot.agent.md' -Pattern 'In this repo, `test` stays allowlist-clean as `npm test`'

    $packageJsonPath = Join-Path $resolvedRoot 'package.json'
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
        throw "Missing required dependency file 'package.json'."
    }

    $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $packageJson.scripts.PSObject.Properties.Name.Contains('test:unit')) {
        throw "package.json is missing the 'test:unit' script."
    }
    if ([string]$packageJson.scripts.test -notmatch 'npm run test:unit') {
        throw "package.json script 'test' must include 'npm run test:unit'."
    }

    Write-Host 'Plan 006 dependency preflight passed.'
    exit 0
}
catch {
    Write-Host "Plan 006 dependency preflight failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
