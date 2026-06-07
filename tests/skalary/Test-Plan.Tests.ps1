#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Test-Plan validator' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $scriptPath = Join-Path $repoRoot 'scripts/skalary/Test-Plan.ps1'
        $fixturesRoot = Join-Path $PSScriptRoot 'fixtures'
        $invokeTestPlan = {
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
        }.GetNewClosure()
    }

    It 'passes a valid fixture' {
        $result = & $invokeTestPlan -PlanPath (Join-Path $fixturesRoot 'plan-valid.md')
        $result.ExitCode | Should -Be 0
    }

    It 'fails orphan requirement references' {
        $result = & $invokeTestPlan -PlanPath (Join-Path $fixturesRoot 'plan-orphan-req.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'unknown requirement'
    }

    It 'fails when evidence marker is missing on opted-in plan' {
        $result = & $invokeTestPlan -PlanPath (Join-Path $fixturesRoot 'plan-missing-evidence.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'no typed evidence marker'
    }

    It 'fails invalid file evidence assertion vocabulary' {
        $result = & $invokeTestPlan -PlanPath (Join-Path $fixturesRoot 'plan-bad-evidence.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Invalid file evidence assertion'
    }

    It 'fails unknown dependency targets' {
        $result = & $invokeTestPlan -PlanPath (Join-Path $fixturesRoot 'plan-bad-deps.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'depends on unknown step'
    }

    It 'warns when phase budget exceeds advisory cap' {
        $result = & $invokeTestPlan -PlanPath (Join-Path $fixturesRoot 'plan-budget-overflow.md')
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'phase-budget points'
    }

    It 'warns when plan is oversize' {
        $tempPlan = Join-Path ([System.IO.Path]::GetTempPath()) ("plan-oversize-" + [System.Guid]::NewGuid().ToString('N') + '.md')
        $oversizeContent = @(
            '# 908: Oversize fixture'
            '<!-- evidence: required -->'
            ''
            '## Requirements'
            ''
            '| ID | Requirement | Acceptance Criteria | Phases/Steps |'
            '|----|-------------|---------------------|--------------|'
            '| REQ-1 | Oversize warning emits | `test:Test-Plan.Size.Warns` | 1.1 |'
            ''
            '## Risks'
            ''
            '| ID | Risk | Likelihood | Impact | Mitigation | Steps |'
            '|----|------|------------|--------|------------|-------|'
            '| RISK-1 | Sample risk | Low | Low | Sample mitigation | 1.1 |'
            ''
            '## Phase 1: Oversize'
            ''
            '- [ ] 1.1 Step (REQ-1, RISK-1) `S`'
        )
        $oversizeContent += (1..420 | ForEach-Object { "padding line $_" })
        Set-Content -LiteralPath $tempPlan -Value ($oversizeContent -join "`n") -Encoding utf8
        try {
            $result = & $invokeTestPlan -PlanPath $tempPlan
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Plan size warning'
        }
        finally {
            if (Test-Path -LiteralPath $tempPlan -PathType Leaf) {
                Remove-Item -LiteralPath $tempPlan -Force
            }
        }
    }

    It 'skips fenced block IDs and markers' {
        $result = & $invokeTestPlan -PlanPath (Join-Path $fixturesRoot 'plan-fenced-ids.md')
        $result.ExitCode | Should -Be 0
    }

    It 'rejects path escapes for file markers' {
        $result = & $invokeTestPlan -PlanPath (Join-Path $fixturesRoot 'plan-path-escape.md')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'outside repository root|must be relative'
    }

    It 'treats legacy plans as warn-only for strict evidence checks' {
        $plan003 = Join-Path $repoRoot 'docs/implementation-plans/003-autopilot-skill-extraction/plan.md'
        $plan004 = Join-Path $repoRoot 'docs/implementation-plans/004-process-pr-comments/plan.md'
        (& $invokeTestPlan -PlanPath $plan003).ExitCode | Should -Be 0
        (& $invokeTestPlan -PlanPath $plan004).ExitCode | Should -Be 0
    }
}
