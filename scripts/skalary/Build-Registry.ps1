#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

function Resolve-BootstrapRef {
    [CmdletBinding()]
    param()

    $tags = @(git tag --points-at HEAD)
    if ($LASTEXITCODE -eq 0 -and $tags.Count -gt 0) {
        $tag = $tags |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Descending |
            Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($tag)) {
            return $tag
        }
    }

    $sha = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
        throw 'Unable to resolve HEAD commit SHA for bootstrap pin.'
    }
    return $sha
}

function Resolve-OriginRepository {
    [CmdletBinding()]
    param()

    $remoteUrl = (git remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
        throw "Unable to resolve git remote 'origin' URL."
    }

    if ($remoteUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
        return [pscustomobject]@{
            Owner = $Matches.owner
            Repo = $Matches.repo
        }
    }

    throw "Unsupported origin URL format for bootstrap one-liner: '$remoteUrl'."
}

function New-BootstrapMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Ref
    )

    $repository = Resolve-OriginRepository
    $url = "https://raw.githubusercontent.com/$($repository.Owner)/$($repository.Repo)/$Ref/scripts/skalary/bootstrap.ps1"
    return [pscustomobject]@{
        oneLiner = "irm $url | iex"
        ref = $Ref
        scriptUrl = $url
    }
}

function New-RegistryPluginEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Manifest,

        [Parameter(Mandatory)]
        [string]$PluginRoot
    )

    $fileEntries = @()
    foreach ($file in ($Manifest.files | Sort-Object @{ Expression = 'dest'; Ascending = $true }, @{ Expression = 'src'; Ascending = $true })) {
        $sourcePath = Join-Path $PluginRoot $file.src
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Plugin '$($Manifest.name)' references missing file '$($file.src)'."
        }

        $fileEntries += [pscustomobject]@{
            dest = [string]$file.dest
            sha256 = Get-FileSha256 -Path $sourcePath
            src = [string]$file.src
        }
    }

    $entry = [ordered]@{
        author = [string]$Manifest.author
        dependencies = @($Manifest.dependencies | Sort-Object)
        description = [string]$Manifest.description
        files = $fileEntries
        license = [string]$Manifest.license
        name = [string]$Manifest.name
        tags = @($Manifest.tags | Sort-Object)
        version = [string]$Manifest.version
    }

    if ($Manifest.PSObject.Properties.Name -contains 'evals' -and $null -ne $Manifest.evals) {
        $entry.evals = [pscustomobject]@{
            status = [string]$Manifest.evals.status
        }
    }
    else {
        $entry.evals = [pscustomobject]@{
            status = 'none'
        }
    }

    if ($Manifest.PSObject.Properties.Name -contains 'status' -and -not [string]::IsNullOrWhiteSpace($Manifest.status)) {
        $entry.status = [string]$Manifest.status
    }
    else {
        $entry.status = 'stable'
    }

    return [pscustomobject]$entry
}

function Get-ComparableJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    return (ConvertTo-SortedObject -InputObject $InputObject | ConvertTo-Json -Depth 100 -Compress)
}

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
        $deps = if ($plugin.dependencies.Count -gt 0) { ($plugin.dependencies -join ', ') } else { '—' }
        $status = if ([string]::IsNullOrWhiteSpace($plugin.status)) { 'stable' } else { $plugin.status }
        $fileCount = @($plugin.files).Count
        $description = ([string]$plugin.description).Replace('|', '\|')
        $lines += "| ``$($plugin.name)`` | $($plugin.version) | $status | $deps | $fileCount | $description |"
    }

    return ($lines -join "`n")
}

function Update-ReadmeCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReadmePath,

        [Parameter(Mandatory)]
        $Registry
    )

    $beginMarker = '<!-- BEGIN SKALARY PLUGIN CATALOG -->'
    $endMarker = '<!-- END SKALARY PLUGIN CATALOG -->'
    $catalogTable = New-ReadmeCatalogTable -Registry $Registry
    $catalogBlock = @(
        $beginMarker,
        $catalogTable,
        $endMarker
    ) -join "`n"

    $readmeContent = if (Test-Path -LiteralPath $ReadmePath -PathType Leaf) {
        Get-Content -LiteralPath $ReadmePath -Raw
    }
    else {
        "# skalary`n"
    }

    if ($readmeContent.Contains($beginMarker) -and $readmeContent.Contains($endMarker)) {
        $escapedBegin = [regex]::Escape($beginMarker)
        $escapedEnd = [regex]::Escape($endMarker)
        $pattern = "(?s)$escapedBegin.*?$escapedEnd"
        $updated = [regex]::Replace($readmeContent, $pattern, $catalogBlock, 1)
    }
    else {
        $section = @(
            '',
            '## Plugin Catalog',
            '',
            $catalogBlock
        ) -join "`n"
        $updated = $readmeContent.TrimEnd("`r", "`n") + $section + "`n"
    }

    if ($updated -ne $readmeContent) {
        Set-Content -LiteralPath $ReadmePath -Value $updated -Encoding utf8
    }
}

$repoRootPath = Resolve-RepoRoot -StartPath $RepoRoot
$pluginsRoot = Join-Path $repoRootPath 'plugins'
$registryPath = Join-Path $repoRootPath 'registry.json'
$readmePath = Join-Path $repoRootPath 'README.md'

if (-not (Test-Path -LiteralPath $pluginsRoot -PathType Container)) {
    throw "Plugins directory not found: $pluginsRoot"
}

$manifestPaths = Get-ChildItem -LiteralPath $pluginsRoot -Recurse -File -Filter 'plugin.json' |
    Sort-Object FullName
if ($manifestPaths.Count -eq 0) {
    throw "No plugin manifests found under '$pluginsRoot'."
}

$pluginEntries = @()
foreach ($manifestPath in $manifestPaths) {
    $manifest = Read-JsonFile -Path $manifestPath.FullName
    $pluginRoot = Split-Path -Parent $manifestPath.FullName
    $pluginEntries += New-RegistryPluginEntry -Manifest $manifest -PluginRoot $pluginRoot
}
$pluginEntries = @($pluginEntries | Sort-Object name)

$existingRegistry = $null
if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
    $existingRegistry = Read-JsonFile -Path $registryPath
}

$bootstrapRef = $null
if ($null -ne $existingRegistry -and
    $existingRegistry.PSObject.Properties.Name -contains 'bootstrap' -and
    $null -ne $existingRegistry.bootstrap -and
    $existingRegistry.bootstrap.PSObject.Properties.Name -contains 'ref' -and
    -not [string]::IsNullOrWhiteSpace([string]$existingRegistry.bootstrap.ref)) {
    $bootstrapRef = [string]$existingRegistry.bootstrap.ref
}
else {
    $bootstrapRef = Resolve-BootstrapRef
}
$bootstrap = New-BootstrapMetadata -Ref $bootstrapRef

$registryBody = [pscustomobject]@{
    bootstrap = $bootstrap
    plugins = $pluginEntries
}

$generatedAt = (Get-Date).ToUniversalTime().ToString('o')
if ($null -ne $existingRegistry -and $existingRegistry.PSObject.Properties.Name -contains 'generatedAt') {
    $existingBody = [pscustomobject]@{
        bootstrap = $existingRegistry.bootstrap
        plugins = $existingRegistry.plugins
    }
    if ((Get-ComparableJson -InputObject $existingBody) -eq (Get-ComparableJson -InputObject $registryBody)) {
        # Preserve the prior timestamp, but normalize to canonical round-trip ISO.
        # ConvertFrom-Json may parse the ISO string into a [datetime] (platform/
        # version dependent); a bare [string] cast would then re-render it in the
        # host culture and churn the registry-up-to-date CI gate.
        $existingGeneratedAt = $existingRegistry.generatedAt
        $parsedGeneratedAt = [datetime]::MinValue
        if ($existingGeneratedAt -is [datetime]) {
            $generatedAt = ([datetime]$existingGeneratedAt).ToUniversalTime().ToString('o')
        }
        elseif ([datetime]::TryParse(
                [string]$existingGeneratedAt,
                [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsedGeneratedAt)) {
            $generatedAt = $parsedGeneratedAt.ToUniversalTime().ToString('o')
        }
        else {
            $generatedAt = [string]$existingGeneratedAt
        }
    }
}

$registry = [pscustomobject]@{
    bootstrap = $bootstrap
    generatedAt = $generatedAt
    plugins = $pluginEntries
}

Write-JsonFileStable -Path $registryPath -InputObject $registry
Update-ReadmeCatalog -ReadmePath $readmePath -Registry (Read-JsonFile -Path $registryPath)
Write-Host "Generated registry at '$registryPath' with $($pluginEntries.Count) plugin(s)."
Write-Host "Bootstrap ref: $bootstrapRef"

