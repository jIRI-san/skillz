#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$PlanPath,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DefaultPlanPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $plans = Get-ChildItem -LiteralPath (Join-Path $Root 'docs/implementation-plans') -File -Recurse -Filter 'plan.md' |
        Where-Object { $_.FullName -notmatch '/archived/' } |
        Sort-Object FullName
    if ($plans.Count -eq 0) {
        throw 'No plan.md files found in docs/implementation-plans/.'
    }

    foreach ($plan in $plans) {
        $content = Get-Content -LiteralPath $plan.FullName -Raw
        if ($content -match '(?m)^\s*-\s\[(?:~|\s)\]\s+\d+\.\d+[a-z]?\s') {
            return $plan.FullName
        }
    }

    return $plans[0].FullName
}

$targetPlan = if ([string]::IsNullOrWhiteSpace($PlanPath)) { Resolve-DefaultPlanPath -Root $RepoRoot } else { $PlanPath }
$validatorPath = Join-Path $RepoRoot 'scripts/skalary/Test-Plan.ps1'
& $validatorPath -PlanPath $targetPlan -RepoRoot $RepoRoot -Stage Draft
exit $LASTEXITCODE
