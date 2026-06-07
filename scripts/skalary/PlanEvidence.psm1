#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PlanEvidencePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw 'Evidence path is empty.'
    }

    if ($RelativePath.StartsWith('/') -or $RelativePath.StartsWith('\')) {
        throw "Evidence path '$RelativePath' must be relative."
    }

    if ($RelativePath -match '^[A-Za-z]:') {
        throw "Evidence path '$RelativePath' cannot be absolute."
    }

    if ($RelativePath -match '\\\\') {
        throw "Evidence path '$RelativePath' cannot be UNC."
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $repoRootFullPath = [System.IO.Path]::GetFullPath($RepoRoot)
    $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $repoRootFullPath ($RelativePath -replace '/', $separator)))
    $repoRootPrefix = $repoRootFullPath.TrimEnd($separator) + $separator
    if (-not $candidatePath.StartsWith($repoRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Evidence path '$RelativePath' resolves outside repository root."
    }

    if (Test-Path -LiteralPath $candidatePath) {
        $resolved = (Resolve-Path -LiteralPath $candidatePath -Force).Path
        if (-not $resolved.StartsWith($repoRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Evidence path '$RelativePath' escapes repository root via symlink."
        }
        return $resolved
    }

    return $candidatePath
}

function Parse-PlanFileEvidenceMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Marker
    )

    if ($Marker -notmatch '^file:(?<path>[^#]+)#(?<assertion>.+)$') {
        throw "Invalid file evidence marker '$Marker'. Expected file:<path>#<assertion>."
    }

    $relativePath = $Matches.path.Trim()
    $assertion = $Matches.assertion.Trim()
    if ($assertion -eq 'exists') {
        return [pscustomobject]@{
            Marker = $Marker
            RelativePath = $relativePath
            Assertion = 'exists'
            Threshold = $null
            Regex = $null
        }
    }

    if ($assertion -like 'contains:*') {
        $pattern = $assertion.Substring('contains:'.Length)
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            throw "Invalid contains assertion in '$Marker'."
        }
        return [pscustomobject]@{
            Marker = $Marker
            RelativePath = $relativePath
            Assertion = 'contains'
            Threshold = $null
            Regex = $pattern
        }
    }

    if ($assertion -match '^count>=(?<count>\d+)$') {
        return [pscustomobject]@{
            Marker = $Marker
            RelativePath = $relativePath
            Assertion = 'count'
            Threshold = [int]$Matches.count
            Regex = $null
        }
    }

    if ($assertion -match '^dircount>=(?<count>\d+)$') {
        return [pscustomobject]@{
            Marker = $Marker
            RelativePath = $relativePath
            Assertion = 'dircount'
            Threshold = [int]$Matches.count
            Regex = $null
        }
    }

    throw "Invalid file evidence assertion '$assertion' in '$Marker'. Allowed: exists, contains:, count>=N, dircount>=N."
}

function Get-PathWithinRootPrefix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Root).TrimEnd($separator) + $separator
}

function Get-FileRegexMatchCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [int]$PerMatchTimeoutMs = 100,

        [int]$PerFileBudgetMs = 750
    )

    $content = Get-Content -LiteralPath $Path -Raw -Force
    $remaining = [TimeSpan]::FromMilliseconds($PerFileBudgetMs)
    $start = [DateTimeOffset]::UtcNow
    $matchCount = 0
    $offset = 0
    $regex = [regex]::new(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::None,
        [TimeSpan]::FromMilliseconds($PerMatchTimeoutMs)
    )
    while ($offset -le $content.Length) {
        if ($remaining.TotalMilliseconds -le 0) {
            throw "Regex budget exhausted while scanning '$Path'."
        }

        $match = $regex.Match($content, $offset)
        if (-not $match.Success) {
            break
        }

        $matchCount++
        $offset = if ($match.Length -gt 0) { $match.Index + $match.Length } else { $match.Index + 1 }
        $elapsed = [DateTimeOffset]::UtcNow - $start
        $remaining = [TimeSpan]::FromMilliseconds($PerFileBudgetMs) - $elapsed
    }

    return $matchCount
}

function Invoke-PlanFileEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Marker,

        [ValidateSet('Draft', 'PhaseCrosscheck', 'PlanCrosscheck')]
        [string]$Stage = 'Draft',

        [long]$MaxFileBytes = 1048576,

        [int]$PerMatchTimeoutMs = 100,

        [int]$PerFileRegexBudgetMs = 750
    )

    $parsed = Parse-PlanFileEvidenceMarker -Marker $Marker
    $resolvedPath = Resolve-PlanEvidencePath -RepoRoot $RepoRoot -RelativePath $parsed.RelativePath
    $isBlockingStage = $Stage -ne 'Draft'
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        return [pscustomobject]@{
            Marker = $Marker
            Success = $false
            Blocking = $isBlockingStage
            Message = "Missing target '$($parsed.RelativePath)'."
        }
    }

    if ($parsed.Assertion -eq 'dircount') {
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            return [pscustomobject]@{
                Marker = $Marker
                Success = $false
                Blocking = $isBlockingStage
                Message = "Target '$($parsed.RelativePath)' is not a directory."
            }
        }

        $rootPrefix = Get-PathWithinRootPrefix -Root $RepoRoot
        $seenDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($resolvedPath)
        $count = 0
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $items = Get-ChildItem -LiteralPath $current -Force
            foreach ($item in $items) {
                if ($item.LinkType) {
                    continue
                }

                if ($item.PSIsContainer) {
                    $childPath = [System.IO.Path]::GetFullPath($item.FullName)
                    if (-not $childPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw "Directory walk escaped repository root through '$childPath'."
                    }
                    if ($seenDirectories.Add($childPath)) {
                        $queue.Enqueue($childPath)
                        $count++
                    }
                    continue
                }

                $count++
            }
        }

        return [pscustomobject]@{
            Marker = $Marker
            Success = $count -ge $parsed.Threshold
            Blocking = $isBlockingStage
            Message = "Counted $count item(s), required >= $($parsed.Threshold)."
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [pscustomobject]@{
            Marker = $Marker
            Success = $false
            Blocking = $isBlockingStage
            Message = "Target '$($parsed.RelativePath)' is not a file."
        }
    }

    $length = (Get-Item -LiteralPath $resolvedPath -Force).Length
    if ($length -gt $MaxFileBytes) {
        throw "File '$($parsed.RelativePath)' exceeds max size (${MaxFileBytes} bytes)."
    }

    if ($parsed.Assertion -eq 'exists') {
        return [pscustomobject]@{
            Marker = $Marker
            Success = $true
            Blocking = $isBlockingStage
            Message = "File '$($parsed.RelativePath)' exists."
        }
    }

    if ($parsed.Assertion -eq 'count') {
        $lineCount = @((Get-Content -LiteralPath $resolvedPath -Force)).Count
        return [pscustomobject]@{
            Marker = $Marker
            Success = $lineCount -ge $parsed.Threshold
            Blocking = $isBlockingStage
            Message = "File has $lineCount line(s), required >= $($parsed.Threshold)."
        }
    }

    $matchCount = Get-FileRegexMatchCount -Path $resolvedPath -Pattern $parsed.Regex -PerMatchTimeoutMs $PerMatchTimeoutMs -PerFileBudgetMs $PerFileRegexBudgetMs
    return [pscustomobject]@{
        Marker = $Marker
        Success = $matchCount -gt 0
        Blocking = $isBlockingStage
        Message = if ($matchCount -gt 0) { 'Regex matched.' } else { 'Regex did not match.' }
    }
}

Export-ModuleMember -Function Parse-PlanFileEvidenceMarker, Invoke-PlanFileEvidence
