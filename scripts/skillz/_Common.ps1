#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    [CmdletBinding()]
    param(
        [string]$StartPath = $PSScriptRoot
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $repoRoot = git rev-parse --show-toplevel 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($repoRoot)) {
        return [System.IO.Path]::GetFullPath($repoRoot.Trim())
    }

    $current = [System.IO.Path]::GetFullPath($StartPath)
    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            return $current
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            throw "Unable to resolve repository root from '$StartPath'."
        }
        $current = $parent
    }
}

function Test-GithubRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $false
    }

    if ($RelativePath.StartsWith('/') -or $RelativePath.StartsWith('\')) {
        return $false
    }

    if ($RelativePath -match '^[A-Za-z]:') {
        return $false
    }

    if ($RelativePath -match '\\\\') {
        return $false
    }

    if ($RelativePath.Contains(':')) {
        return $false
    }

    $segments = ($RelativePath -replace '\\', '/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments) {
        if ($segment -eq '..') {
            return $false
        }
    }

    return $true
}

function Resolve-GithubConstrainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if (-not (Test-GithubRelativePath -RelativePath $RelativePath)) {
        throw "Path '$RelativePath' is not a valid .github-relative destination."
    }

    $githubRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot '.github'))
    $relativeSystemPath = ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $githubRoot $relativeSystemPath))

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $githubRootWithSeparator = $githubRoot.TrimEnd($separator) + $separator
    if (-not $candidate.StartsWith($githubRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved path '$candidate' escapes .github root '$githubRoot'."
    }

    return $candidate
}

function Get-FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Parse-SemVer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    $semverPattern = '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+(?<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
    if ($Version -notmatch $semverPattern) {
        throw "Invalid semantic version '$Version'."
    }

    return [pscustomobject]@{
        Original   = $Version
        Major      = [int]$Matches.major
        Minor      = [int]$Matches.minor
        Patch      = [int]$Matches.patch
        PreRelease = if ($Matches.ContainsKey('pre')) { $Matches.pre } else { $null }
        Build      = if ($Matches.ContainsKey('build')) { $Matches.build } else { $null }
    }
}

function Compare-PreRelease {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Left,

        [AllowNull()]
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -and [string]::IsNullOrWhiteSpace($Right)) {
        return 0
    }
    if ([string]::IsNullOrWhiteSpace($Left)) {
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($Right)) {
        return -1
    }

    $leftParts = $Left.Split('.')
    $rightParts = $Right.Split('.')
    $max = [Math]::Max($leftParts.Count, $rightParts.Count)

    for ($index = 0; $index -lt $max; $index++) {
        if ($index -ge $leftParts.Count) { return -1 }
        if ($index -ge $rightParts.Count) { return 1 }

        $leftPart = $leftParts[$index]
        $rightPart = $rightParts[$index]

        $leftNumeric = $leftPart -match '^[0-9]+$'
        $rightNumeric = $rightPart -match '^[0-9]+$'

        if ($leftNumeric -and $rightNumeric) {
            $comparison = [int]$leftPart - [int]$rightPart
            if ($comparison -ne 0) {
                return [Math]::Sign($comparison)
            }
            continue
        }

        if ($leftNumeric -and -not $rightNumeric) { return -1 }
        if (-not $leftNumeric -and $rightNumeric) { return 1 }

        $stringComparison = [string]::CompareOrdinal($leftPart, $rightPart)
        if ($stringComparison -ne 0) {
            return [Math]::Sign($stringComparison)
        }
    }

    return 0
}

function Compare-SemVer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right
    )

    $leftVersion = Parse-SemVer -Version $Left
    $rightVersion = Parse-SemVer -Version $Right

    foreach ($part in 'Major', 'Minor', 'Patch') {
        if ($leftVersion.$part -lt $rightVersion.$part) { return -1 }
        if ($leftVersion.$part -gt $rightVersion.$part) { return 1 }
    }

    return Compare-PreRelease -Left $leftVersion.PreRelease -Right $rightVersion.PreRelease
}

function ConvertTo-SortedObject {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in ($InputObject.Keys | Sort-Object)) {
            $ordered[$key] = ConvertTo-SortedObject -InputObject $InputObject[$key]
        }
        return [pscustomobject]$ordered
    }

    if ($InputObject -is [pscustomobject]) {
        $ordered = [ordered]@{}
        foreach ($property in ($InputObject.PSObject.Properties.Name | Sort-Object)) {
            $ordered[$property] = ConvertTo-SortedObject -InputObject $InputObject.$property
        }
        return [pscustomobject]$ordered
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-SortedObject -InputObject $item)
        }
        return ,$items
    }

    return $InputObject
}

function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}

function Write-JsonFileStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        $InputObject
    )

    $sorted = ConvertTo-SortedObject -InputObject $InputObject
    $json = $sorted | ConvertTo-Json -Depth 100
    Set-Content -LiteralPath $Path -Value "$json`n" -Encoding utf8
}
