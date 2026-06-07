#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('security', 'performance', 'error-handling', 'consistency', 'plan-structure', 'testing', 'observability')]
    [string]$Category,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{3}$')]
    [string]$Plan,

    [Parameter(Mandatory)]
    [ValidateSet('cip', 'dr', 'cr', 'code-review', 'ci', 'autopilot')]
    [string]$Src,

    [Parameter(Mandatory)]
    [ValidateSet('Critical', 'High', 'Med', 'Low')]
    [string]$Severity,

    [Parameter(Mandatory)]
    [string]$Entry,

    [string[]]$Tags = @(),
    [string]$Date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'),
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$maxEntryLength = 220
$maxTagLength = 40
$maxTagCount = 12
$mutexWaitSeconds = 30

function Normalize-LedgerLesson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [int]$MaxLength
    )

    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormC).ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()
    $normalized = [regex]::Replace($normalized, '\s*([,.:;!?])\s*', '$1 ')
    $normalized = [regex]::Replace($normalized, '\s+', ' ').Trim()
    if ($normalized.Length -gt $MaxLength) {
        $normalized = $normalized.Substring(0, $MaxLength).Trim()
    }
    return $normalized
}

function Sanitize-LedgerText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [int]$MaxLength
    )

    $sanitized = [regex]::Replace($Text, '[\u000A-\u000D\u0085\u2028\u2029\u000B\u000C]', ' ')
    $sanitized = [regex]::Replace($sanitized, '[\u0000-\u001F\u007F]', ' ')
    $sanitized = [regex]::Replace($sanitized, '(?i)src\s*:', 'src-')
    $sanitized = [regex]::Replace($sanitized, '(?i)sev\s*:', 'sev-')
    $sanitized = [regex]::Replace($sanitized, '(?i)\[recurrence\s*:\s*\d+\]', ' recurrence- ')
    $sanitized = [regex]::Replace($sanitized, '[(),#\[\]]', ' ')
    $sanitized = [regex]::Replace($sanitized, '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        throw 'Entry text is empty after sanitization.'
    }
    if ($sanitized.Length -gt $MaxLength) {
        $sanitized = $sanitized.Substring(0, $MaxLength).Trim()
    }
    return $sanitized
}

function Resolve-LedgerPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [string]$CategorySlug
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $path = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot "docs/review-ledger/$CategorySlug.md"))
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootWithSeparator = $resolvedRoot.TrimEnd($separator) + $separator
    if (-not $path.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved ledger path '$path' escapes repository root."
    }
    return $path
}

function Get-LedgerTagSet {
    [CmdletBinding()]
    param(
        [string[]]$InputTags
    )

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($tag in @($InputTags)) {
        if ($null -eq $tag) {
            continue
        }
        $sanitizedTag = Sanitize-LedgerText -Text ([string]$tag) -MaxLength $maxTagLength
        if ($sanitizedTag -match '\s') {
            throw "Tag '$tag' is invalid after sanitization. Tags must not contain spaces."
        }
        $candidate = '#' + $sanitizedTag.ToLowerInvariant()
        [void]$set.Add($candidate)
    }

    $ordered = @($set | Sort-Object)
    if ($ordered.Count -gt $maxTagCount) {
        throw "Too many tags ($($ordered.Count)); max is $maxTagCount."
    }
    return , $ordered
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
    $normalizedLesson = Normalize-LedgerLesson -Text $lessonForKey -MaxLength $maxEntryLength
    $sortedTags = if ($tagList.Count -eq 0) { '' } else { ($tagList -join '|') }
    $idempotenceKey = "$Category|$normalizedLesson|$($Matches.plan)|$($Matches.src)|$($Matches.severity)|$sortedTags"
    $recurrenceKey = "$Category|$normalizedLesson|$sortedTags"

    return [pscustomobject]@{
        Line = $Line
        Date = [string]$Matches.date
        Plan = [string]$Matches.plan
        Src = [string]$Matches.src
        Severity = [string]$Matches.severity
        Lesson = $lesson
        LessonForKey = $lessonForKey
        NormalizedLesson = $normalizedLesson
        Tags = $tagList
        SortedTags = $sortedTags
        IdempotenceKey = $idempotenceKey
        RecurrenceKey = $recurrenceKey
    }
}

function Get-DeterministicOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Object[]]$Records
    )

    return , @(
        $Records | Sort-Object @{ Expression = { $_.NormalizedLesson } }, @{ Expression = { $_.SortedTags } }, @{ Expression = { $_.Plan } }, @{ Expression = { $_.Src } }, @{ Expression = { $_.Severity } }, @{ Expression = { $_.Date } }, @{ Expression = { $_.Line } }
    )
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

        function Set-FileAtomically {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Path,
                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string]$Content
            )

            $targetDirectory = [System.IO.Path]::GetDirectoryName($Path)
            $tempPath = Join-Path $targetDirectory ([System.IO.Path]::GetRandomFileName())
            try {
                New-Item -ItemType File -Path $tempPath -Force | Out-Null
                Set-Content -LiteralPath $tempPath -Value $Content -Encoding utf8NoBOM
                Move-Item -LiteralPath $tempPath -Destination $Path -Force
            }
            finally {
                if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                    Remove-Item -LiteralPath $tempPath -Force
                }
            }
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

if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') {
    throw "Date '$Date' must match yyyy-MM-dd."
}

$entrySanitized = Sanitize-LedgerText -Text $Entry -MaxLength $maxEntryLength
$normalizedLesson = Normalize-LedgerLesson -Text $entrySanitized -MaxLength $maxEntryLength
$tagSet = Get-LedgerTagSet -InputTags $Tags
$sortedTags = if ($tagSet.Count -eq 0) { '' } else { ($tagSet -join '|') }
$idempotenceKey = "$Category|$normalizedLesson|$Plan|$Src|$Severity|$sortedTags"
$recurrenceKey = "$Category|$normalizedLesson|$sortedTags"
$ledgerPath = Resolve-LedgerPath -Root $RepoRoot -CategorySlug $Category
if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
    throw "Ledger category file not found: $ledgerPath"
}

$lockScope = "$([System.IO.Path]::GetFullPath($RepoRoot))|$Category"
$result = Invoke-WithLedgerLock -Scope $lockScope -Action {
    $lines = @((Get-Content -LiteralPath $ledgerPath -Encoding utf8))
    $records = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $record = ConvertTo-LedgerRecord -Line $line
        if ($null -ne $record) {
            $records += $record
        }
    }

    $existingIdempotenceMatches = @($records.Where({ $_.IdempotenceKey -eq $idempotenceKey }))
    if ($existingIdempotenceMatches.Count -gt 0) {
        $orderedExisting = Get-DeterministicOrder -Records $records
        $orderedLines = @($orderedExisting | ForEach-Object { $_.Line })
        $existingContent = if ($lines.Count -eq 0) { '' } else { ($lines -join "`n") + "`n" }
        $canonicalContent = if ($orderedLines.Count -eq 0) { '' } else { ($orderedLines -join "`n") + "`n" }
        if ($existingContent -ne $canonicalContent) {
            Set-FileAtomically -Path $ledgerPath -Content $canonicalContent
        }
        return [pscustomobject]@{
            Added = $false
            Reason = 'idempotence-duplicate'
            Line = $null
        }
    }

    $activeRecurrenceCount = $records.Where({ $_.RecurrenceKey -eq $recurrenceKey }).Count
    $nextRecurrenceCount = $activeRecurrenceCount + 1
    $lessonText = if ($nextRecurrenceCount -gt 1) { "$entrySanitized [recurrence:$nextRecurrenceCount]" } else { $entrySanitized }
    $tagSuffix = if ($tagSet.Count -eq 0) { '' } else { ' ' + ($tagSet -join ' ') }
    $entryLine = "- [$Date] $lessonText (plan-$Plan, src:$Src, sev:$Severity)$tagSuffix"
    $newRecord = ConvertTo-LedgerRecord -Line $entryLine
    if ($null -eq $newRecord) {
        throw 'Failed to construct parseable ledger entry.'
    }

    $ordered = Get-DeterministicOrder -Records (@($records) + $newRecord)
    $updatedLines = @($ordered | ForEach-Object { $_.Line })
    $content = if ($updatedLines.Count -eq 0) { '' } else { ($updatedLines -join "`n") + "`n" }
    Set-FileAtomically -Path $ledgerPath -Content $content

    return [pscustomobject]@{
        Added = $true
        Reason = 'added'
        Line = $entryLine
    }
}

if (-not $result.Added) {
    Write-Host "Skipped duplicate ledger entry for category '$Category' (idempotence-key match)." -ForegroundColor Yellow
    exit 0
}

Write-Host "Added ledger entry to '$Category': $($result.Line)" -ForegroundColor Green
exit 0
