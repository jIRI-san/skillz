#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,

    [string]$Repository = 'jIRI-san/skillz',

    [string]$Ref = 'c0dd31cd7b7a4f5544b052080d4d9f9bd937e0dd'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-TargetRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StartPath
    )

    $resolvedStart = [System.IO.Path]::GetFullPath($StartPath)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $root = git -C $resolvedStart rev-parse --show-toplevel 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previous

    if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($root)) {
        return [System.IO.Path]::GetFullPath($root.Trim())
    }

    return $resolvedStart
}

function New-RawContentUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Repo,

        [Parameter(Mandatory)]
        [string]$PinnedRef,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $repoPath = $Repo.Trim()
    if ([string]::IsNullOrWhiteSpace($repoPath)) {
        throw 'Repository cannot be empty.'
    }

    if ($repoPath -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "Repository '$Repo' must be in '<owner>/<repo>' format."
    }

    if ([string]::IsNullOrWhiteSpace($PinnedRef)) {
        throw 'Ref cannot be empty.'
    }

    return "https://raw.githubusercontent.com/$repoPath/$PinnedRef/$RelativePath"
}

function Get-RemoteContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    try {
        $response = Invoke-WebRequest -Uri $Url
    }
    catch {
        throw "Failed to fetch '$Url': $($_.Exception.Message)"
    }

    if ([string]::IsNullOrEmpty($response.Content)) {
        throw "Downloaded empty content from '$Url'."
    }

    return [string]$response.Content
}

$scriptFiles = @(
    '_Common.ps1',
    'Build-Registry.ps1',
    'Find-Plugin.ps1',
    'Get-Plugin.ps1',
    'Initialize-Autopilot.ps1',
    'Install-Plugin.ps1',
    'Remove-Plugin.ps1',
    'Sync-Dogfood.ps1',
    'Test-Registry.ps1',
    'Update-Plugin.ps1'
)

$targetRoot = Resolve-TargetRoot -StartPath $RepoRoot
$scriptsRoot = Join-Path $targetRoot 'scripts/skillz'
$skillzStateRoot = Join-Path $targetRoot '.github/.skillz'

[void](New-Item -ItemType Directory -Path $scriptsRoot -Force)
[void](New-Item -ItemType Directory -Path $skillzStateRoot -Force)

foreach ($scriptFile in $scriptFiles) {
    $relativeSourcePath = "scripts/skillz/$scriptFile"
    $url = New-RawContentUrl -Repo $Repository -PinnedRef $Ref -RelativePath $relativeSourcePath
    $content = Get-RemoteContent -Url $url
    $targetPath = Join-Path $scriptsRoot $scriptFile
    Set-Content -LiteralPath $targetPath -Value $content -Encoding utf8
}

$registryRelativePath = 'registry.json'
$registryUrl = New-RawContentUrl -Repo $Repository -PinnedRef $Ref -RelativePath $registryRelativePath
$registryContent = Get-RemoteContent -Url $registryUrl
Set-Content -LiteralPath (Join-Path $scriptsRoot 'registry.json') -Value $registryContent -Encoding utf8

Write-Host "Bootstrapped skillz scripts to '$scriptsRoot' from '$Repository' at ref '$Ref'."
Write-Host "Created skillz state directory '$skillzStateRoot'."
Write-Host "Next: review downloaded scripts and run:"
Write-Host "  pwsh -NoProfile -File scripts/skillz/Install-Plugin.ps1 -Name <plugin-name> -Repository $Repository -Ref $Ref"
