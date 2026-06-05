#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

function New-ReadmeCatalogTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Registry
    )

    $lines = @(
        '| Plugin | Version | Status | Dependencies | Files | Description |',
        '|--------|---------|--------|--------------|-------|-------------|'
    )

    foreach ($plugin in ($Registry.plugins | Sort-Object name)) {
        $deps = if (@($plugin.dependencies).Count -gt 0) { ($plugin.dependencies -join ', ') } else { '—' }
        $status = if ([string]::IsNullOrWhiteSpace($plugin.status)) { 'stable' } else { $plugin.status }
        $fileCount = @($plugin.files).Count
        $description = ([string]$plugin.description).Replace('|', '\|')
        $lines += "| ``$($plugin.name)`` | $($plugin.version) | $status | $deps | $fileCount | $description |"
    }

    return ($lines -join "`n")
}

function Get-NormalizedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    return ($Text -replace "`r`n", "`n").Trim()
}

function Get-ComparableJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    return (ConvertTo-SortedObject -InputObject $InputObject | ConvertTo-Json -Depth 100 -Compress)
}

function Add-RegistryError {
    [CmdletBinding()]
    param(
        [System.Collections.Generic.List[string]]$Errors,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $Errors.Add($Message)
}

function Add-RegistryWarning {
    [CmdletBinding()]
    param(
        [System.Collections.Generic.List[string]]$Warnings,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $Warnings.Add($Message)
}

function Get-PluginStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Plugin
    )

    if ($Plugin.PSObject.Properties.Name -contains 'status' -and -not [string]::IsNullOrWhiteSpace($Plugin.status)) {
        return [string]$Plugin.status
    }

    return 'stable'
}

function Resolve-PluginSourcePath {
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
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $normalizedRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootWithSeparator = $normalizedRoot.TrimEnd($separator) + $separator
    if (-not $candidate.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source path '$RelativePath' resolves outside plugin root '$normalizedRoot'."
    }

    return $candidate
}

function Test-DependencyCycles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$PluginsByName,

        [System.Collections.Generic.List[string]]$Errors
    )

    $states = @{}

    function Visit-Plugin {
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [string[]]$Stack
        )

        $state = if ($states.ContainsKey($Name)) { [int]$states[$Name] } else { 0 }
        if ($state -eq 1) {
            Add-RegistryError -Errors $Errors -Message "Dependency cycle detected: $(([string[]]($Stack + $Name)) -join ' -> ')"
            return
        }
        if ($state -eq 2) {
            return
        }

        $states[$Name] = 1
        $plugin = $PluginsByName[$Name]
        foreach ($dependency in (@($plugin.dependencies) | Sort-Object)) {
            if ($PluginsByName.ContainsKey([string]$dependency)) {
                Visit-Plugin -Name ([string]$dependency) -Stack ($Stack + $Name)
            }
        }
        $states[$Name] = 2
    }

    foreach ($name in ($PluginsByName.Keys | Sort-Object)) {
        Visit-Plugin -Name $name -Stack @()
    }
}

$repoRootPath = Resolve-RepoRoot -StartPath $RepoRoot
$pluginsRoot = Join-Path $repoRootPath 'plugins'
$registryPath = Join-Path $repoRootPath 'registry.json'
$readmePath = Join-Path $repoRootPath 'README.md'

$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "Registry file not found: $registryPath"
}

$registry = Read-JsonFile -Path $registryPath
$registryPlugins = @($registry.plugins | Sort-Object name)
$registryByName = @{}
foreach ($plugin in $registryPlugins) {
    $name = [string]$plugin.name
    if ($registryByName.ContainsKey($name)) {
        Add-RegistryError -Errors $errors -Message "Duplicate plugin '$name' in registry.json."
        continue
    }
    $registryByName[$name] = $plugin
}

$manifestByName = @{}
$manifestRootByName = @{}
$manifestPaths = Get-ChildItem -LiteralPath $pluginsRoot -Recurse -File -Filter 'plugin.json' | Sort-Object FullName
foreach ($manifestPath in $manifestPaths) {
    $manifest = Read-JsonFile -Path $manifestPath.FullName
    $name = [string]$manifest.name
    if ($manifestByName.ContainsKey($name)) {
        Add-RegistryError -Errors $errors -Message "Duplicate plugin manifest for '$name'."
        continue
    }
    $manifestByName[$name] = $manifest
    $manifestRootByName[$name] = Split-Path -Parent $manifestPath.FullName
}

$destOwner = @{}
foreach ($plugin in $registryPlugins) {
    $name = [string]$plugin.name
    $status = Get-PluginStatus -Plugin $plugin

    if ([string]::IsNullOrWhiteSpace($name)) {
        Add-RegistryError -Errors $errors -Message 'Registry plugin has an empty name.'
        continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$plugin.description)) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' has an empty description."
    }

    try {
        [void](ConvertTo-SemVer -Version ([string]$plugin.version))
    }
    catch {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' has invalid semver '$($plugin.version)'."
    }

    foreach ($dependency in @($plugin.dependencies)) {
        $dependencyName = [string]$dependency
        if (-not $registryByName.ContainsKey($dependencyName)) {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' references missing dependency '$dependencyName'."
        }
    }

    foreach ($file in @($plugin.files)) {
        $dest = [string]$file.dest
        if (-not (Test-GithubRelativePath -RelativePath $dest)) {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' has invalid destination path '$dest'."
        }
        else {
            try {
                [void](Resolve-GithubConstrainedPath -RepoRoot $repoRootPath -RelativePath $dest)
            }
            catch {
                Add-RegistryError -Errors $errors -Message "Plugin '$name' destination '$dest' fails confinement guard: $($_.Exception.Message)"
            }
        }

        $destKey = ($dest -replace '\\', '/').ToLowerInvariant()
        if ($destOwner.ContainsKey($destKey) -and $destOwner[$destKey] -ne $name) {
            Add-RegistryError -Errors $errors -Message "Destination collision: '$dest' used by '$name' and '$($destOwner[$destKey])'."
        }
        else {
            $destOwner[$destKey] = $name
        }

        $sha = [string]$file.sha256
        if ($sha -notmatch '^[a-f0-9]{64}$') {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' file '$($file.src)' has invalid sha256 '$sha'."
        }
    }

    if (-not $manifestByName.ContainsKey($name)) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' exists in registry.json but has no plugins/$name/plugin.json."
        continue
    }

    $manifest = $manifestByName[$name]
    $manifestStatus = Get-PluginStatus -Plugin $manifest
    try {
        [void](ConvertTo-SemVer -Version ([string]$manifest.version))
    }
    catch {
        Add-RegistryError -Errors $errors -Message "Manifest '$name' has invalid semver '$($manifest.version)'."
    }

    if ([string]$plugin.version -ne [string]$manifest.version) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' version drift: registry '$($plugin.version)' vs manifest '$($manifest.version)'."
    }
    if ([string]$plugin.description -ne [string]$manifest.description) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' description drift between registry and manifest."
    }
    if ([string]$plugin.author -ne [string]$manifest.author) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' author drift between registry and manifest."
    }
    if ([string]$plugin.license -ne [string]$manifest.license) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' license drift between registry and manifest."
    }
    if ([string]$status -ne [string]$manifestStatus) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' status drift: registry '$status' vs manifest '$manifestStatus'."
    }

    $registryTags = @($plugin.tags | Sort-Object)
    $manifestTags = @($manifest.tags | Sort-Object)
    if ((Get-ComparableJson -InputObject $registryTags) -ne (Get-ComparableJson -InputObject $manifestTags)) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' tags drift between registry and manifest."
    }

    $registryDeps = @($plugin.dependencies | Sort-Object)
    $manifestDeps = @($manifest.dependencies | Sort-Object)
    if ((Get-ComparableJson -InputObject $registryDeps) -ne (Get-ComparableJson -InputObject $manifestDeps)) {
        Add-RegistryError -Errors $errors -Message "Plugin '$name' dependencies drift between registry and manifest."
    }

    $manifestFiles = @($manifest.files)
    $manifestFileMap = @{}
    foreach ($manifestFile in $manifestFiles) {
        $manifestKey = "$([string]$manifestFile.src)|$([string]$manifestFile.dest)"
        if ($manifestFileMap.ContainsKey($manifestKey)) {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' manifest contains duplicate file entry '$manifestKey'."
            continue
        }
        $manifestFileMap[$manifestKey] = $manifestFile
    }

    $registryFileMap = @{}
    foreach ($registryFile in @($plugin.files)) {
        $registryKey = "$([string]$registryFile.src)|$([string]$registryFile.dest)"
        if ($registryFileMap.ContainsKey($registryKey)) {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' registry contains duplicate file entry '$registryKey'."
            continue
        }
        $registryFileMap[$registryKey] = $registryFile
        if (-not $manifestFileMap.ContainsKey($registryKey)) {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' registry file '$registryKey' missing in manifest."
        }
    }

    foreach ($manifestKey in $manifestFileMap.Keys) {
        if (-not $registryFileMap.ContainsKey($manifestKey)) {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' manifest file '$manifestKey' missing in registry."
        }
    }

    $pluginRoot = [string]$manifestRootByName[$name]
    foreach ($registryFile in @($plugin.files)) {
        $sourcePath = $null
        try {
            $sourcePath = Resolve-PluginSourcePath -PluginRoot $pluginRoot -RelativePath ([string]$registryFile.src)
        }
        catch {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' source '$($registryFile.src)' fails source guard: $($_.Exception.Message)"
            continue
        }

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            if ($status -eq 'partial') {
                Add-RegistryWarning -Warnings $warnings -Message "Plugin '$name' file '$($registryFile.src)' is missing on disk but status=partial (allowed)."
            }
            else {
                Add-RegistryError -Errors $errors -Message "Plugin '$name' file '$($registryFile.src)' is missing on disk."
            }
            continue
        }

        $actualSha = Get-FileSha256 -Path $sourcePath
        if ($actualSha -ne [string]$registryFile.sha256) {
            Add-RegistryError -Errors $errors -Message "Plugin '$name' file '$($registryFile.src)' sha mismatch: registry '$($registryFile.sha256)' vs disk '$actualSha'."
        }
    }

    $evalPath = Join-Path $pluginRoot 'evals'
    if (-not (Test-Path -LiteralPath $evalPath -PathType Container)) {
        Add-RegistryWarning -Warnings $warnings -Message "Plugin '$name' has no evals/ folder (informational)."
    }
}

foreach ($manifestName in $manifestByName.Keys) {
    if (-not $registryByName.ContainsKey($manifestName)) {
        Add-RegistryError -Errors $errors -Message "Manifest plugin '$manifestName' missing from registry.json."
    }
}

Test-DependencyCycles -PluginsByName $registryByName -Errors $errors

if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
    Add-RegistryError -Errors $errors -Message "README missing at '$readmePath'."
}
else {
    $readme = Get-Content -LiteralPath $readmePath -Raw
    $beginMarker = '<!-- BEGIN SKILLZ PLUGIN CATALOG -->'
    $endMarker = '<!-- END SKILLZ PLUGIN CATALOG -->'
    $match = [regex]::Match(
        $readme,
        "(?s)$([regex]::Escape($beginMarker)).*?$([regex]::Escape($endMarker))"
    )
    if (-not $match.Success) {
        Add-RegistryError -Errors $errors -Message 'README plugin catalog markers are missing.'
    }
    else {
        $expectedCatalog = @(
            $beginMarker,
            (New-ReadmeCatalogTable -Registry $registry),
            $endMarker
        ) -join "`n"

        if ((Get-NormalizedText -Text $match.Value) -ne (Get-NormalizedText -Text $expectedCatalog)) {
            Add-RegistryError -Errors $errors -Message 'README plugin catalog does not match registry.json.'
        }
    }
}

if ($warnings.Count -gt 0) {
    Write-Host 'Test-Registry warnings:' -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

if ($errors.Count -gt 0) {
    Write-Host 'Test-Registry failed:' -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'Test-Registry passed.' -ForegroundColor Green
exit 0

