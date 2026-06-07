#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Test-Plan validator' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $scriptPath = Join-Path $repoRoot 'scripts/skalary/Test-Plan.ps1'
        $fixturesRoot = Join-Path $PSScriptRoot 'fixtures'
    }

    function Invoke-TestPlan {
        param(
            [Parameter(Mandatory)]
            [string]$PlanPath,

            [ValidateSet('Draft', 'PhaseCrosscheck', 'PlanCrosscheck')]
            [string]$Stage = 'Draft'
        )

        $output = @(
            & pwsh -NoProfile -File $scriptPath -PlanPath $PlanPath -RepoRoot $repoRoot -Stage $Stage 2>&1
        )

        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = ($output | ForEach-Object { "$_" }) -join "`n"
        }
    }

    It 'passes a valid fixture' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-valid.md')
        $result.ExitCode | Should -Be 0
    }

    It 'fails orphan requirement references' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-orphan-req.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'unknown requirement'
    }

    It 'fails when evidence marker is missing on opted-in plan' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-missing-evidence.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'no typed evidence marker'
    }

    It 'fails invalid file evidence assertion vocabulary' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-bad-evidence.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Invalid file evidence assertion'
    }

    It 'fails unknown dependency targets' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-bad-deps.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'depends on unknown step'
    }

    It 'warns when phase budget exceeds advisory cap' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-budget-overflow.md')
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'phase-budget points'
    }

    It 'warns when plan is oversize' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-oversize.md')
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Plan size warning'
    }

    It 'skips fenced block IDs and markers' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-fenced-ids.md')
        $result.ExitCode | Should -Be 0
    }

    It 'rejects path escapes for file markers' {
        $result = Invoke-TestPlan -PlanPath (Join-Path $fixturesRoot 'plan-path-escape.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'outside repository root|must be relative'
    }

    It 'treats legacy plans as warn-only for strict evidence checks' {
        $plan003 = Join-Path $repoRoot 'docs/implementation-plans/003-autopilot-skill-extraction/plan.md'
        $plan004 = Join-Path $repoRoot 'docs/implementation-plans/004-process-pr-comments/plan.md'
        (Invoke-TestPlan -PlanPath $plan003).ExitCode | Should -Be 0
        (Invoke-TestPlan -PlanPath $plan004).ExitCode | Should -Be 0
    }
}
