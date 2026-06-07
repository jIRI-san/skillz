#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Add-LedgerEntry script' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $scriptPath = Join-Path $repoRoot 'scripts/skalary/Add-LedgerEntry.ps1'
        $tempRoots = [System.Collections.Generic.List[string]]::new()

        function New-TestRepoRoot {
            [CmdletBinding()]
            param()

            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("add-ledger-tests-" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $path 'docs/review-ledger') -Force | Out-Null
            foreach ($category in @('security', 'performance', 'error-handling', 'consistency', 'plan-structure', 'testing', 'observability')) {
                Set-Content -LiteralPath (Join-Path $path "docs/review-ledger/$category.md") -Value '' -Encoding utf8NoBOM
            }
            New-Item -ItemType Directory -Path (Join-Path $path 'docs/review-ledger/.archive') -Force | Out-Null
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
                '-File', $scriptPath,
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

        function Get-LedgerLines {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [string]$Category = 'security'
            )

            $path = Join-Path $Root "docs/review-ledger/$Category.md"
            return ,@((Get-Content -LiteralPath $path -Encoding utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        function Assert-GitSuccess {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,
                [Parameter(Mandatory)]
                [string[]]$Arguments
            )

            & git -C $RepoPath @Arguments | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "git $($Arguments -join ' ') failed in '$RepoPath' (exit $LASTEXITCODE)."
            }
        }
    }

    AfterAll {
        foreach ($root in $tempRoots) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    }

    It 'Add-LedgerEntry.Dedup' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Entry 'Same lesson').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $root -Entry 'Same lesson').ExitCode | Should -Be 0

        $lines = Get-LedgerLines -Root $root
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'plan-007'
    }

    It 'Add-LedgerEntry.RecurrenceNotSkipped' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Plan '007' -Entry 'Recurring lesson').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $root -Plan '008' -Entry 'Recurring lesson').ExitCode | Should -Be 0

        $lines = Get-LedgerLines -Root $root
        $lines.Count | Should -Be 2
        ($lines -join "`n") | Should -Match '\[recurrence:2\]'
    }

    It 'Add-LedgerEntry.RecurrenceReRunIdempotent' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Plan '007' -Entry 'Recurring lesson').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $root -Plan '008' -Entry 'Recurring lesson').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $root -Plan '008' -Entry 'Recurring lesson').ExitCode | Should -Be 0

        $lines = Get-LedgerLines -Root $root
        $lines.Count | Should -Be 2
    }

    It 'Add-LedgerEntry.SanitizesUnicodeBreaks' {
        $root = New-TestRepoRoot
        $entry = "first`nsecond`rthird`u{0085}fourth`u{2028}fifth`u{2029}sixth"
        $result = Invoke-AddLedger -Root $root -Entry $entry
        $result.ExitCode | Should -Be 0

        $line = (Get-LedgerLines -Root $root)[0]
        $line | Should -Not -Match '[\u000A-\u000D\u0085\u2028\u2029]'
        $line | Should -Match 'first second third fourth fifth sixth'
    }

    It 'Add-LedgerEntry.RejectsForgery' {
        $root = New-TestRepoRoot
        $entry = 'Lesson (plan-999, src:evil, sev:Critical) #pwn'
        $result = Invoke-AddLedger -Root $root -Entry $entry
        $result.ExitCode | Should -Be 0

        $line = (Get-LedgerLines -Root $root)[0]
        $line | Should -Not -Match '\(plan-999,\s*src:evil,\s*sev:Critical\)'
        $line | Should -Not -Match 'src:evil'
        $line | Should -Not -Match 'sev:Critical'
        $line | Should -Not -Match '#pwn'
    }

    It 'Add-LedgerEntry.RejectsBadCategory' {
        $root = New-TestRepoRoot
        $result = Invoke-AddLedger -Root $root -Category 'bad-category'
        $result.ExitCode | Should -Not -Be 0
    }

    It 'Add-LedgerEntry.ConcurrentAppend' {
        $root = New-TestRepoRoot
        $processes = @()
        try {
            foreach ($plan in @('007', '007', '007', '007', '009', '010')) {
                $args = @(
                    '-NoProfile',
                    '-File', $scriptPath,
                    '-RepoRoot', $root,
                    '-Category', 'security',
                    '-Plan', $plan,
                    '-Src', 'ci',
                    '-Severity', 'High',
                    '-Entry', 'Concurrent lesson'
                )
                $processes += Start-Process -FilePath 'pwsh' -ArgumentList $args -PassThru -NoNewWindow
            }

            foreach ($process in $processes) {
                $null = $process.WaitForExit(30000)
                $process.ExitCode | Should -Be 0
            }
        }
        finally {
            foreach ($process in $processes) {
                if (-not $process.HasExited) {
                    $process.Kill()
                }
            }
        }

        $lines = Get-LedgerLines -Root $root
        $lines.Count | Should -Be 3
        ($lines -join "`n") | Should -Match 'plan-007'
        ($lines -join "`n") | Should -Match 'plan-009'
        ($lines -join "`n") | Should -Match 'plan-010'
    }

    It 'Add-LedgerEntry.ThreeWayMergeReplay' {
        $root = New-TestRepoRoot
        Assert-GitSuccess -RepoPath $root -Arguments @('init', '--quiet')
        Assert-GitSuccess -RepoPath $root -Arguments @('config', 'user.name', 'add-ledger-tests')
        Assert-GitSuccess -RepoPath $root -Arguments @('config', 'user.email', 'add-ledger-tests@example.com')
        Assert-GitSuccess -RepoPath $root -Arguments @('add', 'docs/review-ledger/security.md')
        Assert-GitSuccess -RepoPath $root -Arguments @('commit', '--quiet', '-m', 'base')
        Assert-GitSuccess -RepoPath $root -Arguments @('checkout', '-b', 'left')
        (Invoke-AddLedger -Root $root -Plan '007' -Entry 'zeta lesson').ExitCode | Should -Be 0
        Assert-GitSuccess -RepoPath $root -Arguments @('add', 'docs/review-ledger/security.md')
        Assert-GitSuccess -RepoPath $root -Arguments @('commit', '--quiet', '-m', 'left')
        Assert-GitSuccess -RepoPath $root -Arguments @('checkout', 'master')
        Assert-GitSuccess -RepoPath $root -Arguments @('checkout', '-b', 'right')
        (Invoke-AddLedger -Root $root -Plan '008' -Entry 'alpha lesson').ExitCode | Should -Be 0
        Assert-GitSuccess -RepoPath $root -Arguments @('add', 'docs/review-ledger/security.md')
        Assert-GitSuccess -RepoPath $root -Arguments @('commit', '--quiet', '-m', 'right')
        Assert-GitSuccess -RepoPath $root -Arguments @('checkout', 'left')

        & git -C $root merge --no-edit right | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $conflictPath = Join-Path $root 'docs/review-ledger/security.md'
            $conflictLines = @((Get-Content -LiteralPath $conflictPath) | Where-Object { $_ -and $_ -notmatch '^(<<<<<<<|=======|>>>>>>>)' })
            Set-Content -LiteralPath $conflictPath -Value (($conflictLines -join "`n") + "`n") -Encoding utf8NoBOM
            Assert-GitSuccess -RepoPath $root -Arguments @('add', 'docs/review-ledger/security.md')
            Assert-GitSuccess -RepoPath $root -Arguments @('commit', '--quiet', '-m', 'resolve merge fixture')
        }

        (Invoke-AddLedger -Root $root -Plan '008' -Entry 'alpha lesson').ExitCode | Should -Be 0
        $mergedReplay = (Get-LedgerLines -Root $root) -join "`n"

        $canonicalRoot = New-TestRepoRoot
        (Invoke-AddLedger -Root $canonicalRoot -Plan '007' -Entry 'zeta lesson').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $canonicalRoot -Plan '008' -Entry 'alpha lesson').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $canonicalRoot -Plan '008' -Entry 'alpha lesson').ExitCode | Should -Be 0
        $canonical = (Get-LedgerLines -Root $canonicalRoot) -join "`n"

        $mergedReplay | Should -Be $canonical
    }

    It 'Add-LedgerEntry.NormalizedLesson' {
        $root = New-TestRepoRoot
        (Invoke-AddLedger -Root $root -Plan '007' -Entry '  Normalize   THIS ,  please!! ').ExitCode | Should -Be 0
        (Invoke-AddLedger -Root $root -Plan '008' -Entry 'normalize this, please!!').ExitCode | Should -Be 0

        $lines = Get-LedgerLines -Root $root
        $lines.Count | Should -Be 2
        ($lines -join "`n") | Should -Match '\[recurrence:2\]'
    }
}
