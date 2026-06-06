#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,

    [switch]$Installed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

function Get-ReceiptMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRootPath
    )

    $map = @{}
    $receiptsRoot = Join-Path $RepoRootPath '.github/.skalary/receipts'
    if (-not (Test-Path -LiteralPath $receiptsRoot -PathType Container)) {
        return $map
    }

    foreach ($receiptPath in (Get-ChildItem -LiteralPath $receiptsRoot -File -Filter '*.json' | Sort-Object Name)) {
        $receipt = Read-JsonFile -Path $receiptPath.FullName
        $name = [string]$receipt.name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $map[$name] = $receipt
        }
    }

    return $map
}

function Test-ReceiptModified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRootPath,

        [Parameter(Mandatory)]
        $Receipt
    )

    foreach ($entry in @($Receipt.files)) {
        $dest = [string]$entry.dest
        if ([string]::IsNullOrWhiteSpace($dest)) {
            continue
        }

        $targetPath = Resolve-GithubConstrainedPath -RepoRoot $RepoRootPath -RelativePath $dest
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            return $true
        }

        $actualSha = Get-FileSha256 -Path $targetPath
        if ($actualSha -ne [string]$entry.sha256) {
            return $true
        }
    }

    return $false
}

$repoRootPath = Resolve-RepoRoot -StartPath $RepoRoot
$registryPath = Join-Path $repoRootPath 'registry.json'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "registry.json not found at '$repoRootPath'."
}

$registry = Read-JsonFile -Path $registryPath
$receiptByName = Get-ReceiptMap -RepoRootPath $repoRootPath

$results = @()
foreach ($plugin in @($registry.plugins | Sort-Object name)) {
    $name = [string]$plugin.name
    $receipt = if ($receiptByName.ContainsKey($name)) { $receiptByName[$name] } else { $null }
    $isInstalled = $null -ne $receipt

    if ($Installed -and -not $isInstalled) {
        continue
    }

    $isModified = if ($isInstalled) { Test-ReceiptModified -RepoRootPath $repoRootPath -Receipt $receipt } else { $false }
    $isOutdated = if ($isInstalled) { [string]$receipt.version -ne [string]$plugin.version } else { $false }
    $status = if ($plugin.PSObject.Properties.Name -contains 'status' -and -not [string]::IsNullOrWhiteSpace([string]$plugin.status)) { [string]$plugin.status } else { 'stable' }

    $results += [pscustomobject]@{
        name = $name
        version = [string]$plugin.version
        installed = $isInstalled
        modified = $isModified
        outdated = $isOutdated
        status = $status
        description = [string]$plugin.description
    }
}

$results | Sort-Object name
