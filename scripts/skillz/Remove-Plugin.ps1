#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

function Get-InstalledPluginName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRootPath
    )

    $receiptsRoot = Join-Path $RepoRootPath '.github/.skillz/receipts'
    if (-not (Test-Path -LiteralPath $receiptsRoot -PathType Container)) {
        return @()
    }

    $installed = @()
    foreach ($receiptPath in (Get-ChildItem -LiteralPath $receiptsRoot -File -Filter '*.json' | Sort-Object Name)) {
        $receipt = Read-JsonFile -Path $receiptPath.FullName
        if (-not [string]::IsNullOrWhiteSpace([string]$receipt.name)) {
            $installed += , ([string]$receipt.name)
        }
    }

    return @($installed | Sort-Object -Unique)
}

function Assert-NoInstalledDependent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRootPath,

        [Parameter(Mandatory)]
        [string]$PluginName
    )

    $registryPath = Join-Path $RepoRootPath 'registry.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "registry.json not found at '$RepoRootPath'."
    }
    $registry = Read-JsonFile -Path $registryPath
    $registryByName = @{}
    foreach ($plugin in @($registry.plugins)) {
        $registryByName[[string]$plugin.name] = $plugin
    }

    $dependents = @()
    foreach ($installedPlugin in (Get-InstalledPluginName -RepoRootPath $RepoRootPath)) {
        if ($installedPlugin -eq $PluginName) {
            continue
        }
        if (-not $registryByName.ContainsKey($installedPlugin)) {
            continue
        }

        $dependencies = @($registryByName[$installedPlugin].dependencies | ForEach-Object { [string]$_ })
        if ($dependencies -contains $PluginName) {
            $dependents += , $installedPlugin
        }
    }

    if ($dependents.Count -gt 0) {
        $dependentList = ($dependents | Sort-Object) -join ', '
        throw "Cannot remove plugin '$PluginName': installed dependent plugin(s): $dependentList. Use -Force to override."
    }
}

function Invoke-ParentDirectoryPrune {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Directories,

        [Parameter(Mandatory)]
        [string]$GithubRoot
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $normalizedGithubRoot = [System.IO.Path]::GetFullPath($GithubRoot).TrimEnd($separator)
    $rootWithSeparator = $normalizedGithubRoot + $separator
    $queue = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($directory in $Directories) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }
        $current = [System.IO.Path]::GetFullPath($directory)
        while (-not [string]::IsNullOrWhiteSpace($current) -and $current.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (-not $queue.Add($current)) {
                break
            }

            $parent = Split-Path -Parent $current
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
                break
            }
            $current = $parent
        }
    }

    foreach ($directory in ($queue | Sort-Object Length -Descending)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }

        $childCount = @(Get-ChildItem -LiteralPath $directory -Force).Count
        if ($childCount -eq 0) {
            Remove-Item -LiteralPath $directory -Force
        }
    }
}

$repoRootPath = Resolve-RepoRoot -StartPath $RepoRoot
$receipt = Read-PluginReceipt -RepoRoot $repoRootPath -PluginName $Name
if ($null -eq $receipt) {
    throw "Plugin '$Name' is not installed (receipt missing)."
}

if (-not $Force) {
    Assert-NoInstalledDependent -RepoRootPath $repoRootPath -PluginName $Name
}

$removedCount = 0
$skippedModified = 0
$deletedParentDirs = @()
foreach ($entry in @($receipt.files)) {
    $dest = [string]$entry.dest
    if ([string]::IsNullOrWhiteSpace($dest)) {
        continue
    }

    $targetPath = Resolve-GithubConstrainedPath -RepoRoot $repoRootPath -RelativePath $dest
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        continue
    }

    $actualSha = Get-FileSha256 -Path $targetPath
    $expectedSha = [string]$entry.sha256
    if (-not $Force -and $actualSha -ne $expectedSha) {
        Write-Warning "Skipping modified file '$dest' (expected '$expectedSha', actual '$actualSha')."
        $skippedModified++
        continue
    }

    Remove-Item -LiteralPath $targetPath -Force
    $removedCount++
    $deletedParentDirs += , (Split-Path -Parent $targetPath)
}

$githubRoot = Join-Path $repoRootPath '.github'
Invoke-ParentDirectoryPrune -Directories $deletedParentDirs -GithubRoot $githubRoot

$receiptPath = Get-PluginReceiptPath -RepoRoot $repoRootPath -PluginName $Name
if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
    Remove-Item -LiteralPath $receiptPath -Force
}

Write-Output "Removed plugin '$Name'. Deleted file count: $removedCount. Skipped modified files: $skippedModified."
