#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Remove-LedgerEntry script' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $addScriptPath = Join-Path $repoRoot 'scripts/skalary/Add-LedgerEntry.ps1'
        $removeScriptPath = Join-Path $repoRoot 'scripts/skalary/Remove-LedgerEntry.ps1'
        $tempRoots = [System.Collections.Generic.List[string]]::new()

        function New-TestRepoRoot {
            [CmdletBinding()]
            param()

            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("remove-ledger-tests-" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $path 'docs/review-ledger') -Force | Out-Null
            foreach ($category in @('security', 'performance', 'error-handling', 'consistency', 'plan-structure', 'testing', 'observability')) {
                Set-Content -LiteralPath (Join-Path $path "docs/review-ledger/$category.md") -Value '' -Encoding utf8NoBOM
            }
            New-Item -ItemType Directory -Path (Join-Path $path 'docs/review-ledger/.archive') -Force | Out-Null
            foreach ($category in @('security', 'performance', 'error-handling', 'consistency', 'plan-structure', 'testing', 'observability')) {
                Set-Content -LiteralPath (Join-Path $path "docs/review-ledger/.archive/$category.md") -Value '' -Encoding utf8NoBOM
            }
            $tempRoots.Add($path)
            return $path
        }

        function Invoke-AddLedger {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Root,
                [string]$Category = 'security',
                [string]$Plan = '007',
                [string]$Src = 'ci',
                [string]$Severity = 'High',
                [string]$Entry = 'default lesson',
                [string[]]$Tags = @()
            )

            $argList = @(
                '-NoProfile',
                '-File', $addScriptPath,
                '-RepoRoot', $Root,
                '-Category', $Category,
                '-Plan', $Plan,
                '-Src', $Src,
                '-Severity', $Severity,
                '-Entry', $Entry
            )
            if (@($Tags).Count -gt 0) {
                $argList += '-Tags'
                $argList += $Tags
            }

            $output = @(& pwsh @argList 2>&1)
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = ($output | ForEach-Object { "$_" }) -join "`n"
            }
        }

        function Invoke-RemoveLedger {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Root,
                [Parameter(Mandatory)]
                [object]$Match,
                [string]$Category = 'security',
                [string]$CurrentPlan = '007',
                [int]$RecurrenceThreshold = 1
            )

            $matchLine = @($Match) | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace([string]$matchLine)) {
                throw 'Match line must resolve to a non-empty string.'
            }
            $encodedMatch = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$matchLine))
            $argList = @(
                '-NoProfile',
                '-File', $removeScriptPath,
                '-RepoRoot', $Root,
                '-Category', $Category,
                '-MatchBase64', $encodedMatch,
                '-CurrentPlan', $CurrentPlan,
                '-RecurrenceThreshold', $RecurrenceThreshold.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            )

            $output = @(& pwsh @argList 2>&1)
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = ($output | ForEach-Object { "$_" }) -join "`n"
            }
        }

        function Get-LedgerLines {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Root,
                [string]$Category = 'security'
            )

            $path = Join-Path $Root "docs/review-ledger/$Category.md"
            return [string[]]@((Get-Content -LiteralPath $path -Encoding utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        function Get-ArchiveLines {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Root,
                [string]$Category = 'security'
            )

            $path = Join-Path $Root "docs/review-ledger/.archive/$Category.md"
            return [string[]]@((Get-Content -LiteralPath $path -Encoding utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    AfterAll {
        foreach ($root in $tempRoots) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }

    It 'Remove-LedgerEntry.FullLineEquality' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Plan '006' -Entry 'Alpha lesson').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $root -Plan '005' -Entry 'Alpha lesson extra').ExitCode | Should -Be 0

        $lineToRemove = @((Get-LedgerLines -Root $root) | Where-Object { $_ -match 'plan-006' })[0]
        $lineToRemove | Should -Not -BeNullOrEmpty

        $remove = Invoke-RemoveLedger -Root $root -Match $lineToRemove -CurrentPlan '007'
        $remove.ExitCode | Should -Be 0
        $remove.Output | Should -Match 'Removed ledger entry'
        $remove.Output | Should -Match ([regex]::Escape("- $lineToRemove"))

        $active = @(Get-LedgerLines -Root $root)
        $archive = @(Get-ArchiveLines -Root $root)

        @($active).Count | Should -Be 1
        $active[0] | Should -Match 'plan-005'
        @($archive).Count | Should -Be 1
        $archive[0] | Should -Be $lineToRemove
    }

    It 'Remove-LedgerEntry.RejectsBadCategory' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Plan '006' -Entry 'Guarded lesson').ExitCode | Should -Be 0
        $line = @(Get-LedgerLines -Root $root)[0]
        $result = Invoke-RemoveLedger -Root $root -Category 'bad-category' -Match $line -CurrentPlan '007'
        $result.ExitCode | Should -Not -Be 0
    }

    It 'Remove-LedgerEntry.RetentionGuard' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Plan '007' -Entry 'Current plan lesson').ExitCode | Should -Be 0
        $currentPlanLine = @(Get-LedgerLines -Root $root)[0]
        $currentPlanRemove = Invoke-RemoveLedger -Root $root -Match $currentPlanLine -CurrentPlan '007'
        $currentPlanRemove.ExitCode | Should -Not -Be 0
        $currentPlanRemove.Output | Should -Match 'current plan'

        (Invoke-AddLedger -Root $root -Plan '006' -Entry 'Recurring retention lesson').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $root -Plan '005' -Entry 'Recurring retention lesson').ExitCode | Should -Be 0
        $protectedLine = @((Get-LedgerLines -Root $root) | Where-Object { $_ -match 'plan-006' -and $_ -match 'Recurring retention lesson' })[0]
        $protectedRemove = Invoke-RemoveLedger -Root $root -Match $protectedLine -CurrentPlan '009' -RecurrenceThreshold 1
        $protectedRemove.ExitCode | Should -Not -Be 0
        $protectedRemove.Output | Should -Match 'recurrence count'
    }

    It 'Remove-LedgerEntry.NoSubstringOverDelete' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Plan '006' -Entry 'Cache miss').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $root -Plan '005' -Entry 'Cache miss resolved').ExitCode | Should -Be 0

        $lineToRemove = @((Get-LedgerLines -Root $root) | Where-Object { $_ -match 'Cache miss \(' })[0]
        $remove = Invoke-RemoveLedger -Root $root -Match $lineToRemove -CurrentPlan '009'
        $remove.ExitCode | Should -Be 0

        $active = @(Get-LedgerLines -Root $root)
        @($active).Count | Should -Be 1
        $active[0] | Should -Match 'Cache miss resolved'
    }

    It 'Remove-LedgerEntry.ArchiveExcludedFromReaders' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Plan '006' -Entry 'Archive isolated lesson').ExitCode | Should -Be 0
        $lineToRemove = @(Get-LedgerLines -Root $root)[0]

        $archivedPrior = '- [2026-01-01] Archive isolated lesson (plan-004, src:ci, sev:High)'
        Set-Content -LiteralPath (Join-Path $root 'docs/review-ledger/.archive/security.md') -Value "$archivedPrior`n" -Encoding utf8NoBOM

        $remove = Invoke-RemoveLedger -Root $root -Match $lineToRemove -CurrentPlan '009' -RecurrenceThreshold 1
        $remove.ExitCode | Should -Be 0

        $archive = @(Get-ArchiveLines -Root $root)
        @($archive).Count | Should -Be 2
    }
}