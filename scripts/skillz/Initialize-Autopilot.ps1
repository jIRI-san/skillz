#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,
    [string]$SourceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

function Copy-IfDifferent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    $targetDir = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $targetDir -Force)
    }

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
        return $true
    }

    if ((Get-FileSha256 -Path $SourcePath) -eq (Get-FileSha256 -Path $TargetPath)) {
        return $false
    }

    Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
    return $true
}

$targetRepoRoot = Resolve-RepoRoot -StartPath $RepoRoot
$sourceRepoRoot = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $targetRepoRoot } else { Resolve-RepoRoot -StartPath $SourceRoot }

$requiredPaths = @(
    '.autopilot.json',
    'schemas/autopilot.schema.json',
    'scripts/autopilot',
    '.devcontainer/autopilot'
)

foreach ($relativePath in $requiredPaths) {
    $sourcePath = Join-Path $sourceRepoRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Autopilot prerequisite '$relativePath' is missing in source '$sourceRepoRoot'. Plan 001 infrastructure is required."
    }
}

$changed = 0
foreach ($relativePath in @('.autopilot.json', 'schemas/autopilot.schema.json')) {
    $sourcePath = Join-Path $sourceRepoRoot $relativePath
    $targetPath = Join-Path $targetRepoRoot $relativePath
    if (Copy-IfDifferent -SourcePath $sourcePath -TargetPath $targetPath) {
        $changed++
    }
}

foreach ($relativeDir in @('scripts/autopilot', '.devcontainer/autopilot')) {
    $sourceDir = Join-Path $sourceRepoRoot $relativeDir
    $targetDir = Join-Path $targetRepoRoot $relativeDir

    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $targetDir -Force)
    }

    $sourceFiles = Get-ChildItem -LiteralPath $sourceDir -Recurse -File | Sort-Object FullName
    foreach ($sourceFile in $sourceFiles) {
        $relativeFilePath = [System.IO.Path]::GetRelativePath($sourceDir, $sourceFile.FullName)
        $targetPath = Join-Path $targetDir $relativeFilePath
        if (Copy-IfDifferent -SourcePath $sourceFile.FullName -TargetPath $targetPath) {
            $changed++
        }
    }
}

Write-Host "Autopilot prerequisites initialized. Files changed: $changed."
