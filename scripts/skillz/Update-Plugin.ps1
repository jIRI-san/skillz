#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,

    [string]$Source,

    [string]$Ref,

    [string]$Repository,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

function Get-ResolvedSourceContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetRepoRoot,

        [string]$SourcePath,

        [string]$SourceRef,

        [string]$RemoteRepository
    )

    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $sourceRepoRoot = Resolve-RepoRoot -StartPath $SourcePath
        $resolvedRef = if ([string]::IsNullOrWhiteSpace($SourceRef)) { 'HEAD' } else { $SourceRef }
        $resolvedSha = (git -C $sourceRepoRoot rev-parse $resolvedRef).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolvedSha)) {
            throw "Unable to resolve ref '$resolvedRef' in source repository '$sourceRepoRoot'."
        }

        $sourceTempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skillz-update-" + [System.Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $sourceTempPath -Force)
        git -C $sourceRepoRoot archive $resolvedSha | tar -xf - -C $sourceTempPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to materialize local source snapshot '$resolvedSha' from '$sourceRepoRoot'."
        }

        return [pscustomobject]@{
            IsRemote = $false
            Label = "local:$sourceRepoRoot"
            Ref = $resolvedRef
            Sha = $resolvedSha
            SourceRepoRoot = $sourceTempPath
            TempPath = $sourceTempPath
        }
    }

    $remote = $RemoteRepository
    if ([string]::IsNullOrWhiteSpace($remote)) {
        $remote = (git -C $TargetRepoRoot remote get-url origin).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
            throw "Unable to resolve git remote 'origin' for '$TargetRepoRoot'."
        }
    }

    $resolvedRef = if ([string]::IsNullOrWhiteSpace($SourceRef)) { 'HEAD' } else { $SourceRef }
    $resolvedRefs = @(git ls-remote $remote $resolvedRef)
    $resolvedLine = $null
    foreach ($line in $resolvedRefs) {
        if ($line -match '\^\{\}\s*$') {
            $resolvedLine = $line
            break
        }
    }
    if ($null -eq $resolvedLine -and $resolvedRefs.Count -gt 0) {
        $resolvedLine = $resolvedRefs[0]
    }
    $resolvedSha = if ($null -ne $resolvedLine) { ($resolvedLine -split '\s+')[0] } else { $null }
    if ([string]::IsNullOrWhiteSpace($resolvedSha)) {
        throw "Unable to resolve remote ref '$resolvedRef' in '$remote'."
    }

    $sourceTempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skillz-update-" + [System.Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $sourceTempPath -Force)

    if ($resolvedRef -eq 'HEAD') {
        git clone -c core.autocrlf=false -c core.eol=lf --depth 1 $remote $sourceTempPath | Out-Null
    }
    else {
        git clone -c core.autocrlf=false -c core.eol=lf --depth 1 --branch $resolvedRef $remote $sourceTempPath | Out-Null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone '$remote' (ref '$resolvedRef')."
    }

    $clonedSha = (git -C $sourceTempPath rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($clonedSha)) {
        throw "Unable to resolve cloned SHA in '$sourceTempPath'."
    }
    if ($clonedSha -ne $resolvedSha) {
        throw "Remote ref '$resolvedRef' resolved to '$resolvedSha' but clone checked out '$clonedSha'."
    }

    return [pscustomobject]@{
        IsRemote = $true
        Label = "remote:$remote"
        Ref = $resolvedRef
        Sha = $resolvedSha
        SourceRepoRoot = $sourceTempPath
        TempPath = $sourceTempPath
    }
}

$targetRepoRoot = Resolve-RepoRoot -StartPath $RepoRoot
$sourceContext = $null

try {
    $receipt = Read-PluginReceipt -RepoRoot $targetRepoRoot -PluginName $Name
    if ($null -eq $receipt) {
        throw "Plugin '$Name' is not installed (receipt missing)."
    }

    $sourceContext = Get-ResolvedSourceContext -TargetRepoRoot $targetRepoRoot -SourcePath $Source -SourceRef $Ref -RemoteRepository $Repository
    $sourceRepoRoot = [string]$sourceContext.SourceRepoRoot
    $resolvedSha = [string]$sourceContext.Sha
    $sourceLabel = [string]$sourceContext.Label

    $registryPath = Join-Path $sourceRepoRoot 'registry.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "registry.json not found at source '$sourceRepoRoot'."
    }
    $registry = Read-JsonFile -Path $registryPath
    $plugin = @($registry.plugins | Where-Object { [string]$_.name -eq $Name } | Select-Object -First 1)
    if ($plugin.Count -eq 0) {
        throw "Plugin '$Name' is not present in source registry."
    }
    $plugin = $plugin[0]

    $versionComparison = Compare-SemVer -Left ([string]$receipt.version) -Right ([string]$plugin.version)
    if ($versionComparison -gt 0) {
        throw "Installed version '$($receipt.version)' is newer than registry version '$($plugin.version)'. Refusing downgrade."
    }

    $pluginRoot = Join-Path $sourceRepoRoot "plugins/$Name"
    if (-not (Test-Path -LiteralPath $pluginRoot -PathType Container)) {
        throw "Plugin '$Name' source directory is missing in '$sourceRepoRoot/plugins/'."
    }

    $registryFiles = @($plugin.files | Where-Object { [string]$_.src -notmatch '^evals(?:/|$)' } | Sort-Object dest, src)
    if ($registryFiles.Count -eq 0) {
        throw "Plugin '$Name' has no installable files in registry."
    }

    $receiptByDest = @{}
    foreach ($receiptFile in @($receipt.files)) {
        $receiptByDest[[string]$receiptFile.dest] = $receiptFile
    }

    $updatedCount = 0
    $skippedCount = 0
    $nextReceiptFiles = @()

    foreach ($file in $registryFiles) {
        $src = [string]$file.src
        $dest = [string]$file.dest
        $expectedNewSha = [string]$file.sha256
        $targetPath = Resolve-GithubConstrainedPath -RepoRoot $targetRepoRoot -RelativePath $dest
        $sourcePath = Resolve-PluginConstrainedPath -PluginRoot $pluginRoot -RelativePath $src

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Plugin '$Name' source '$src' is missing from source snapshot."
        }
        $sourceHash = Get-FileSha256 -Path $sourcePath
        if ($sourceHash -ne $expectedNewSha) {
            throw "Source hash mismatch for '$Name' file '$src': expected '$expectedNewSha', got '$sourceHash'."
        }

        $hasTarget = Test-Path -LiteralPath $targetPath -PathType Leaf
        $actualCurrentSha = if ($hasTarget) { Get-FileSha256 -Path $targetPath } else { $null }
        $expectedCurrentSha = if ($receiptByDest.ContainsKey($dest)) { [string]$receiptByDest[$dest].sha256 } else { $null }

        if (-not $Force) {
            if ([string]::IsNullOrWhiteSpace($expectedCurrentSha)) {
                throw "Installed receipt for '$Name' is missing destination '$dest'. Use -Force to overwrite."
            }
            if (-not $hasTarget) {
                throw "Installed destination '$dest' is missing on disk. Use -Force to recreate it."
            }
            if ($actualCurrentSha -ne $expectedCurrentSha) {
                $nextReceiptFiles += [pscustomobject]@{
                    dest = $dest
                    outcome = 'skipped-modified'
                    sha256 = $actualCurrentSha
                }
                $skippedCount++
                continue
            }
        }

        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $targetDir -Force)
        }

        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
        $writtenSha = Get-FileSha256 -Path $targetPath
        if ($writtenSha -ne $expectedNewSha) {
            throw "Write verification failed for '$dest': expected '$expectedNewSha', got '$writtenSha'."
        }

        $nextReceiptFiles += [pscustomobject]@{
            dest = $dest
            outcome = 'updated'
            sha256 = $expectedNewSha
        }
        $updatedCount++
    }

    $allUpdated = ($updatedCount -eq $registryFiles.Count -and $skippedCount -eq 0)
    $receiptVersion = if ($allUpdated) { [string]$plugin.version } else { [string]$receipt.version }
    $receiptOutput = [ordered]@{
        evalStatus = if ($receipt.PSObject.Properties.Name -contains 'evalStatus' -and $null -ne $receipt.evalStatus) { [string]$receipt.evalStatus } else { 'none' }
        files = $nextReceiptFiles
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
        name = $Name
        ref = $resolvedSha
        source = "$sourceLabel@$resolvedSha"
        version = $receiptVersion
    }
    if (-not $allUpdated) {
        $receiptOutput.degraded = $true
    }

    $receiptPath = Get-PluginReceiptPath -RepoRoot $targetRepoRoot -PluginName $Name
    Write-JsonFileStable -Path $receiptPath -InputObject ([pscustomobject]$receiptOutput)

    if ($allUpdated) {
        Write-Output "Updated plugin '$Name' to version '$($plugin.version)' at '$resolvedSha'."
    }
    else {
        Write-Warning "Plugin '$Name' updated partially: $skippedCount file(s) skipped as modified. Receipt marked degraded."
        Write-Output "Plugin '$Name' remains at version '$($receipt.version)' with refreshed ref '$resolvedSha'."
    }
}
finally {
    if ($null -ne $sourceContext -and -not [string]::IsNullOrWhiteSpace([string]$sourceContext.TempPath)) {
        Remove-Item -LiteralPath ([string]$sourceContext.TempPath) -Recurse -Force -ErrorAction SilentlyContinue
    }
}
