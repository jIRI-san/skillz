#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

$repoRootPath = Resolve-RepoRoot -StartPath $RepoRoot
$pluginsRoot = Join-Path $repoRootPath 'plugins'

if (-not (Test-Path -LiteralPath $pluginsRoot -PathType Container)) {
    throw "Plugins directory not found: $pluginsRoot"
}

$manifestPaths = Get-ChildItem -LiteralPath $pluginsRoot -Recurse -File -Filter 'plugin.json' | Sort-Object FullName
if ($manifestPaths.Count -eq 0) {
    throw "No plugin manifests found under '$pluginsRoot'."
}

$copyPlan = @{}
foreach ($manifestPath in $manifestPaths) {
    $manifest = Read-JsonFile -Path $manifestPath.FullName
    $pluginName = [string]$manifest.name
    $pluginStatus = if ($manifest.PSObject.Properties.Name -contains 'status' -and -not [string]::IsNullOrWhiteSpace($manifest.status)) {
        [string]$manifest.status
    }
    else {
        'stable'
    }
    $pluginRoot = Split-Path -Parent $manifestPath.FullName

    foreach ($file in @($manifest.files)) {
        $dest = [string]$file.dest
        if (-not (Test-GithubRelativePath -RelativePath $dest)) {
            throw "Plugin '$pluginName' has invalid destination path '$dest'."
        }

        $targetPath = Resolve-GithubConstrainedPath -RepoRoot $repoRootPath -RelativePath $dest
        $sourcePath = Resolve-PluginConstrainedPath -PluginRoot $pluginRoot -RelativePath ([string]$file.src)

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            if ($pluginStatus -eq 'partial') {
                Write-Warning "Skipping missing source '$($file.src)' for partial plugin '$pluginName'."
                continue
            }
            throw "Plugin '$pluginName' source file missing: '$sourcePath'."
        }

        $destKey = ([System.IO.Path]::GetFullPath($targetPath)).ToLowerInvariant()
        if ($copyPlan.ContainsKey($destKey)) {
            throw "Destination collision for '$dest' between plugins '$pluginName' and '$($copyPlan[$destKey].PluginName)'."
        }

        $copyPlan[$destKey] = [pscustomobject]@{
            Dest = $dest
            PluginName = $pluginName
            SourcePath = $sourcePath
            TargetPath = $targetPath
        }
    }
}

$changedCount = 0
foreach ($entry in ($copyPlan.Values | Sort-Object Dest)) {
    $targetDir = Split-Path -Parent $entry.TargetPath
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container) -and -not $WhatIfPreference) {
        [void](New-Item -ItemType Directory -Path $targetDir -Force)
    }

    $sourceHash = Get-FileSha256 -Path $entry.SourcePath
    $targetHash = if (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf) {
        Get-FileSha256 -Path $entry.TargetPath
    }
    else {
        $null
    }

    if ($sourceHash -eq $targetHash) {
        continue
    }

    $changedCount++
    if ($PSCmdlet.ShouldProcess($entry.TargetPath, "Sync from plugin '$($entry.PluginName)' source '$($entry.SourcePath)'")) {
        Copy-Item -LiteralPath $entry.SourcePath -Destination $entry.TargetPath -Force
    }
}

if ($WhatIfPreference -and $changedCount -gt 0) {
    throw "Dogfood drift detected: $changedCount file(s) differ from plugins/ sources."
}

Write-Host "Dogfood sync completed. Changed file count: $changedCount."

