#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pesterModule) {
    Write-Host "Skipping test:unit — Pester is not installed. Install it with: Install-Module Pester -Scope CurrentUser -Force" -ForegroundColor Yellow
    exit 0
}

$testPath = Join-Path $RepoRoot 'tests'
if (-not (Test-Path -LiteralPath $testPath -PathType Container)) {
    throw "Unit test path not found: $testPath"
}

Import-Module Pester -MinimumVersion $pesterModule.Version -ErrorAction Stop
$result = Invoke-Pester -Path $testPath -CI -PassThru
if ($result.FailedCount -gt 0) {
    exit 1
}

exit 0
