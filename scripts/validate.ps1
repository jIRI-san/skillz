#requires -Version 7.0
<#
.SYNOPSIS
    Repository validation gate for the skillz customizations repo.
.DESCRIPTION
    Dependency-free verification used as both the autopilot `build` and `test`
    command (wired through package.json so it satisfies the autopilot config
    schema's `npm run` / `npm test` prefixes). It:
      * parses every PowerShell script (*.ps1/*.psm1/*.psd1) and fails on syntax
        errors, and
      * validates every JSON file (*.json) parses.
    No external modules are required, so it runs identically on the Windows host
    and inside the Linux autopilot container (which ships pwsh).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$errors = [System.Collections.Generic.List[string]]::new()

# Skip noise / vendored / VCS directories.
$skip = '\\(\.git|node_modules|bin|obj|\.worktrees)\\'

Write-Host '== Validating PowerShell scripts =='
$psFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
    Where-Object { $_.FullName -notmatch $skip }
foreach ($file in $psFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($pe in $parseErrors) {
            $errors.Add("$($file.FullName):$($pe.Extent.StartLineNumber) $($pe.Message)")
        }
    }
}
Write-Host "  Parsed $($psFiles.Count) PowerShell file(s)."

Write-Host '== Validating JSON files =='
$jsonFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Include '*.json' |
    Where-Object { $_.FullName -notmatch $skip }
foreach ($file in $jsonFiles) {
    try {
        $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    }
    catch {
        $errors.Add("$($file.FullName): invalid JSON - $($_.Exception.Message)")
    }
}
Write-Host "  Parsed $($jsonFiles.Count) JSON file(s)."

if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host "VALIDATION FAILED ($($errors.Count) error(s)):" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'Validation passed.' -ForegroundColor Green
exit 0
