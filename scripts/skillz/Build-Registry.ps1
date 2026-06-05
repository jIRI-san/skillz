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
    $url = "https://raw.githubusercontent.com/$($repository.Owner)/$($repository.Repo)/$Ref/scripts/skillz/bootstrap.ps1"
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

$repoRootPath = Resolve-RepoRoot -StartPath $RepoRoot
$pluginsRoot = Join-Path $repoRootPath 'plugins'
$registryPath = Join-Path $repoRootPath 'registry.json'

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

$bootstrapRef = Resolve-BootstrapRef
$bootstrap = New-BootstrapMetadata -Ref $bootstrapRef

$registryBody = [pscustomobject]@{
    bootstrap = $bootstrap
    plugins = $pluginEntries
}

$existingRegistry = $null
if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
    $existingRegistry = Read-JsonFile -Path $registryPath
}

$generatedAt = (Get-Date).ToUniversalTime().ToString('o')
if ($null -ne $existingRegistry -and $existingRegistry.PSObject.Properties.Name -contains 'generatedAt') {
    $existingBody = [pscustomobject]@{
        bootstrap = $existingRegistry.bootstrap
        plugins = $existingRegistry.plugins
    }
    if ((Get-ComparableJson -InputObject $existingBody) -eq (Get-ComparableJson -InputObject $registryBody)) {
        $generatedAt = [string]$existingRegistry.generatedAt
    }
}

$registry = [pscustomobject]@{
    bootstrap = $bootstrap
    generatedAt = $generatedAt
    plugins = $pluginEntries
}

Write-JsonFileStable -Path $registryPath -InputObject $registry
Write-Host "Generated registry at '$registryPath' with $($pluginEntries.Count) plugin(s)."
Write-Host "Bootstrap ref: $bootstrapRef"

