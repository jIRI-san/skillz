#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Query,

    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

$repoRootPath = Resolve-RepoRoot -StartPath $RepoRoot
$registryPath = Join-Path $repoRootPath 'registry.json'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "registry.json not found at '$repoRootPath'."
}

$needle = $Query.Trim()
if ([string]::IsNullOrWhiteSpace($needle)) {
    throw 'Query must not be empty.'
}
$needle = $needle.ToLowerInvariant()

$registry = Read-JsonFile -Path $registryPath
$searchResults = @()
foreach ($plugin in @($registry.plugins)) {
    $name = [string]$plugin.name
    $description = [string]$plugin.description
    $tags = @($plugin.tags | ForEach-Object { [string]$_ })
    $status = if ($plugin.PSObject.Properties.Name -contains 'status' -and -not [string]::IsNullOrWhiteSpace([string]$plugin.status)) { [string]$plugin.status } else { 'stable' }

    $isMatch = $name.ToLowerInvariant().Contains($needle) -or $description.ToLowerInvariant().Contains($needle) -or (@($tags | Where-Object { $_.ToLowerInvariant().Contains($needle) }).Count -gt 0)
    if (-not $isMatch) {
        continue
    }

    $searchResults += [pscustomobject]@{
        name = $name
        version = [string]$plugin.version
        status = $status
        description = $description
        tags = $tags
        dependencies = @($plugin.dependencies | ForEach-Object { [string]$_ })
    }
}

$searchResults | Sort-Object name
