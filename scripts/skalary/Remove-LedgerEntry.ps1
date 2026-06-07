#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('security', 'performance', 'error-handling', 'consistency', 'plan-structure', 'testing', 'observability')]
    [string]$Category,

    [Parameter(Mandatory, ParameterSetName = 'Line')]
    [ValidateNotNullOrEmpty()]
    [string]$Match,

    [Parameter(Mandatory, ParameterSetName = 'Encoded')]
    [ValidateNotNullOrEmpty()]
    [string]$MatchBase64,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{3}$')]
    [string]$CurrentPlan,

    [ValidateRange(1, 100)]
    [int]$RecurrenceThreshold = 1,

    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mutexWaitSeconds = 30

$effectiveMatch = if ($PSCmdlet.ParameterSetName -eq 'Encoded') {
    try {
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($MatchBase64))
    }
    catch {
        throw 'MatchBase64 must be valid base64-encoded UTF-8 text.'
    }
}
else {
    $Match
}

function Normalize-LedgerLesson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormC).ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()
    $normalized = [regex]::Replace($normalized, '\s*([,.:;!?])\s*', '$1 ')
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()
    return $normalized
}

function Resolve-RepoPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $path = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $RelativePath))
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootWithSeparator = $resolvedRoot.TrimEnd($separator) + $separator
    if (-not $path.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved path '$path' escapes repository root."
    }
    return $path
}

function ConvertTo-LedgerRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    $pattern = '^- \[(?<date>\d{4}-\d{2}-\d{2})\] (?<lesson>.+?) \(plan-(?<plan>\d{3}), src:(?<src>cip|dr|cr|code-review|ci|autopilot), sev:(?<severity>Critical|High|Med|Low)\)(?<tags>(?:\s+#\S+)*)$'
    if ($Line -notmatch $pattern) {
        return $null
    }

    $tagList = @()
    if (-not [string]::IsNullOrWhiteSpace($Matches.tags)) {
        $tagList = @($Matches.tags.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) | Sort-Object)
    }

    $lesson = [string]$Matches.lesson
    $lessonForKey = [regex]::Replace($lesson, '\s*\[recurrence:\d+\]\s*$', '').Trim()
    $normalizedLesson = Normalize-LedgerLesson -Text $lessonForKey
    $sortedTags = if ($tagList.Count -eq 0) { '' } else { ($tagList -join '|') }
    $recurrenceKey = "$Category|$normalizedLesson|$sortedTags"

    return [pscustomobject]@{
        Line = $Line
        Plan = [string]$Matches.plan
        RecurrenceKey = $recurrenceKey
    }
}

function Invoke-WithLedgerLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Scope,
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $scopeBytes = [System.Text.Encoding]::UTF8.GetBytes($Scope)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($scopeBytes)
    $hash = [Convert]::ToHexString($hashBytes).ToLowerInvariant().Substring(0, 32)
    $mutexName = "Global\skalary-ledger-$hash"
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds($mutexWaitSeconds))
        if (-not $hasLock) {
            throw "Timed out acquiring ledger lock '$mutexName'."
        }
        return & $Action
    }
    finally {
        if ($hasLock) {
            [void]$mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Set-FileAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $tempPath = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tempPath -Value $Content -Encoding utf8NoBOM
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

$ledgerPath = Resolve-RepoPath -Root $RepoRoot -RelativePath "docs/review-ledger/$Category.md"
if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
    throw "Ledger category file not found: $ledgerPath"
}

$archiveDir = Resolve-RepoPath -Root $RepoRoot -RelativePath 'docs/review-ledger/.archive'
if (-not (Test-Path -LiteralPath $archiveDir -PathType Container)) {
    throw "Ledger archive directory not found: $archiveDir"
}
$archivePath = Resolve-RepoPath -Root $RepoRoot -RelativePath "docs/review-ledger/.archive/$Category.md"
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    Set-Content -LiteralPath $archivePath -Value '' -Encoding utf8NoBOM
}

$currentPlanNumber = [int]$CurrentPlan

$lockScope = "$([System.IO.Path]::GetFullPath($RepoRoot))|$Category"
$result = Invoke-WithLedgerLock -Scope $lockScope -Action {
    $lines = @((Get-Content -LiteralPath $ledgerPath -Encoding utf8))
    $parseableRecords = @()
    $targetRecord = $null
    $remainingLines = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $record = ConvertTo-LedgerRecord -Line $line
        if ($null -ne $record) {
            $parseableRecords += $record
        }

        if ($null -eq $targetRecord -and [string]::Equals($line, $effectiveMatch, [System.StringComparison]::Ordinal)) {
            if ($null -eq $record) {
                throw 'Matched line is not parseable as a ledger entry.'
            }
            $targetRecord = $record
            continue
        }

        [void]$remainingLines.Add($line)
    }

    if ($null -eq $targetRecord) {
        throw 'No exact ledger entry match found for the provided -Match line.'
    }

    $targetPlan = [int]$targetRecord.Plan
    if ($targetPlan -eq $currentPlanNumber) {
        throw "Retention guard blocked prune: entry belongs to current plan $CurrentPlan."
    }
    if ($targetPlan -gt $currentPlanNumber) {
        throw "Retention guard blocked prune: entry plan '$($targetRecord.Plan)' is newer than current plan $CurrentPlan."
    }

    $activeRecurrenceCount = $parseableRecords.Where({ $_.RecurrenceKey -eq $targetRecord.RecurrenceKey }).Count
    if ($activeRecurrenceCount -gt $RecurrenceThreshold) {
        throw "Retention guard blocked prune: recurrence count $activeRecurrenceCount exceeds threshold $RecurrenceThreshold."
    }

    $updatedLedger = if ($remainingLines.Count -eq 0) { '' } else { ($remainingLines -join "`n") + "`n" }
    Set-FileAtomically -Path $ledgerPath -Content $updatedLedger

    $archiveLines = @((Get-Content -LiteralPath $archivePath -Encoding utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $updatedArchive = @($archiveLines + $targetRecord.Line)
    $archiveContent = if ($updatedArchive.Count -eq 0) { '' } else { ($updatedArchive -join "`n") + "`n" }
    Set-FileAtomically -Path $archivePath -Content $archiveContent

    return [pscustomobject]@{
        RemovedLine = $targetRecord.Line
        ActiveRecurrenceCount = $activeRecurrenceCount
    }
}

Write-Host "Removed ledger entry from '$Category':" -ForegroundColor Green
Write-Host "- $($result.RemovedLine)" -ForegroundColor Yellow
Write-Host "+ [archived] $($result.RemovedLine)" -ForegroundColor Yellow
exit 0