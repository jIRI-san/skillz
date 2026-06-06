#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    [CmdletBinding()]
    param(
        [string]$StartPath = $PSScriptRoot
    )

    $candidateStartPath = [System.IO.Path]::GetFullPath($StartPath)
    if (Test-Path -LiteralPath $candidateStartPath -PathType Leaf) {
        $candidateStartPath = Split-Path -Parent $candidateStartPath
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $repoRoot = git -C $candidateStartPath rev-parse --show-toplevel 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($repoRoot)) {
        return [System.IO.Path]::GetFullPath($repoRoot.Trim())
    }

    $current = $candidateStartPath
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

function Resolve-PluginConstrainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw 'Source path is empty.'
    }

    if ($RelativePath.StartsWith('/') -or $RelativePath.StartsWith('\')) {
        throw "Source path '$RelativePath' must be relative."
    }

    if ($RelativePath -match '^[A-Za-z]:') {
        throw "Source path '$RelativePath' cannot be drive-relative or absolute."
    }

    if ($RelativePath -match '\\\\') {
        throw "Source path '$RelativePath' cannot be UNC."
    }

    if ($RelativePath.Contains(':')) {
        throw "Source path '$RelativePath' cannot contain ':'."
    }

    $segments = ($RelativePath -replace '\\', '/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments) {
        if ($segment -eq '..') {
            throw "Source path '$RelativePath' cannot traverse parent directories."
        }
    }

    $normalizedRoot = [System.IO.Path]::GetFullPath($PluginRoot)
    $normalizedRelativePath = ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $normalizedRoot $normalizedRelativePath))
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootWithSeparator = $normalizedRoot.TrimEnd($separator) + $separator
    if (-not $candidate.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source path '$RelativePath' resolves outside plugin root '$normalizedRoot'."
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

function ConvertTo-SemVer {
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
        Original = $Version
        Major = [int]$Matches.major
        Minor = [int]$Matches.minor
        Patch = [int]$Matches.patch
        PreRelease = if ($Matches.ContainsKey('pre')) { $Matches.pre } else { $null }
        Build = if ($Matches.ContainsKey('build')) { $Matches.build } else { $null }
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

    $leftVersion = ConvertTo-SemVer -Version $Left
    $rightVersion = ConvertTo-SemVer -Version $Right

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

    if ($InputObject -is [pscustomobject] -and -not ($InputObject -is [string])) {
        $ordered = [ordered]@{}
        foreach ($property in ($InputObject.PSObject.Properties.Name | Sort-Object)) {
            $ordered[$property] = ConvertTo-SortedObject -InputObject $InputObject.$property
        }
        return [pscustomobject]$ordered
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += , (ConvertTo-SortedObject -InputObject $item)
        }
        return , ([object[]]$items)
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

function Get-PluginReceiptPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$PluginName
    )

    $receiptsRoot = Join-Path $RepoRoot '.github/.skillz/receipts'
    return Join-Path $receiptsRoot "$PluginName.json"
}

function Read-PluginReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$PluginName
    )

    $receiptPath = Get-PluginReceiptPath -RepoRoot $RepoRoot -PluginName $PluginName
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        return $null
    }

    return Read-JsonFile -Path $receiptPath
}

function Test-PluginReceiptUpToDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        $Plugin
    )

    $receipt = Read-PluginReceipt -RepoRoot $RepoRoot -PluginName ([string]$Plugin.name)
    if ($null -eq $receipt) {
        return $false
    }

    if ([string]$receipt.version -ne [string]$Plugin.version) {
        return $false
    }

    $receiptFiles = @($receipt.files)
    if ($receiptFiles.Count -eq 0) {
        return $false
    }

    $receiptByDest = @{}
    foreach ($receiptFile in $receiptFiles) {
        $dest = [string]$receiptFile.dest
        if (-not [string]::IsNullOrWhiteSpace($dest)) {
            $receiptByDest[$dest] = $receiptFile
        }
    }

    foreach ($pluginFile in @($Plugin.files)) {
        $src = [string]$pluginFile.src
        if ($src -match '^evals(?:/|$)') {
            continue
        }

        $dest = [string]$pluginFile.dest
        if (-not $receiptByDest.ContainsKey($dest)) {
            return $false
        }

        if ([string]$receiptByDest[$dest].sha256 -ne [string]$pluginFile.sha256) {
            return $false
        }

        $targetPath = Resolve-GithubConstrainedPath -RepoRoot $RepoRoot -RelativePath $dest
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            return $false
        }
        if ((Get-FileSha256 -Path $targetPath) -ne [string]$pluginFile.sha256) {
            return $false
        }
    }

    return $true
}

function Resolve-PluginDependencyOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$PluginsByName,

        [Parameter(Mandatory)]
        [string]$RootPluginName,

        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    if (-not $PluginsByName.ContainsKey($RootPluginName)) {
        throw "Plugin '$RootPluginName' is not present in registry.json."
    }

    $stateByName = @{}
    $topologicalNames = [System.Collections.Generic.List[string]]::new()

    function Search-DependencyNode {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [string[]]$Stack
        )

        if (-not $PluginsByName.ContainsKey($Name)) {
            $parentName = if ($Stack.Count -gt 0) { $Stack[$Stack.Count - 1] } else { $RootPluginName }
            throw "Plugin '$parentName' depends on missing plugin '$Name'."
        }

        $state = if ($stateByName.ContainsKey($Name)) { [int]$stateByName[$Name] } else { 0 }
        if ($state -eq 1) {
            $cycle = @($Stack + $Name) -join ' -> '
            throw "Dependency cycle detected: $cycle"
        }
        if ($state -eq 2) {
            return
        }

        $stateByName[$Name] = 1
        $plugin = $PluginsByName[$Name]
        $dependencies = @($plugin.dependencies | ForEach-Object { [string]$_ } | Sort-Object)
        foreach ($dependencyName in $dependencies) {
            Search-DependencyNode -Name $dependencyName -Stack ($Stack + $Name)
        }

        $stateByName[$Name] = 2
        $topologicalNames.Add($Name)
    }

    Search-DependencyNode -Name $RootPluginName -Stack @()

    $ordered = @()
    $pending = @()
    foreach ($name in $topologicalNames) {
        $plugin = $PluginsByName[$name]
        $ordered += , $plugin
        if (-not (Test-PluginReceiptUpToDate -RepoRoot $RepoRoot -Plugin $plugin)) {
            $pending += , $plugin
        }
    }

    return [pscustomobject]@{
        Ordered = $ordered
        Pending = $pending
    }
}
