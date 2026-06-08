#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Plan dependency start-gate' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $scriptPath = Join-Path $repoRoot 'scripts/skalary/Test-DependencyPlan006.ps1'
        $tempRoots = [System.Collections.Generic.List[string]]::new()

        function Invoke-DependencyGate {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Root,
                [Parameter(Mandatory)]
                [string]$PlanPath
            )

            $output = @(
                & pwsh -NoProfile -File $scriptPath -RepoRoot $Root -PlanPath $PlanPath 2>&1
            )

            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = ($output | ForEach-Object { "$_" }) -join "`n"
            }
        }

        function New-DependencyFixture {
            [CmdletBinding()]
            param()

            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("dependency-tests-" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null

            New-Item -ItemType Directory -Path (Join-Path $root 'scripts/skalary') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'plugins/create-implementation-plan/skills/cip/assets') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'plugins/continue-implementation/skills/ci/assets') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'plugins/autopilot/agents') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'docs/implementation-plans/007-workflow-memory-ledger') -Force | Out-Null

            Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/skalary/Test-Plan.ps1') -Destination (Join-Path $root 'scripts/skalary/Test-Plan.ps1') -Force
            Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/skalary/PlanEvidence.psm1') -Destination (Join-Path $root 'scripts/skalary/PlanEvidence.psm1') -Force

            Set-Content -LiteralPath (Join-Path $root 'README.md') -Value "# Fixture`n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $root 'plugins/create-implementation-plan/skills/cip/assets/drafting-guide.md') -Value "Use Test-Plan.ps1 for validation.`n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $root 'plugins/continue-implementation/skills/ci/assets/crosscheck-guide.md') -Value "- test:<TestId>`n- file:<path>#<assertion>`n- review:cr|dr`n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $root 'plugins/autopilot/agents/autopilot.agent.md') -Value 'In this repo, `test` stays allowlist-clean as `npm test`.' -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $root 'docs/implementation-plans/007-workflow-memory-ledger/plan.md') -Value "# 007`n<!-- depends-on: 006 -->`n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $root 'package.json') -Value @'
{
  "scripts": {
    "test": "npm run validate-plan && npm run test:unit",
    "test:unit": "pwsh -NoProfile -File scripts/skalary/Run-UnitTests.ps1"
  }
}
'@ -Encoding utf8NoBOM

            $tempRoots.Add($root)
            return $root
        }
    }

    AfterAll {
        foreach ($root in $tempRoots) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }

    It 'Skalary.Dependency.Plan006Present' {
        $planPath = Join-Path $repoRoot 'docs/implementation-plans/007-workflow-memory-ledger/plan.md'
        $result = Invoke-DependencyGate -Root $repoRoot -PlanPath $planPath
        $result.ExitCode | Should -Be 0
    }

    It 'fails when the test:unit gate is missing' {
        $fixture = New-DependencyFixture
        $planPath = Join-Path $fixture 'docs/implementation-plans/007-workflow-memory-ledger/plan.md'
        Set-Content -LiteralPath (Join-Path $fixture 'package.json') -Value @'
{
  "scripts": {
    "test": "npm run validate-plan"
  }
}
'@ -Encoding utf8NoBOM

        $result = Invoke-DependencyGate -Root $fixture -PlanPath $planPath
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match "test:unit"
    }
}
