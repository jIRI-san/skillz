#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,

    [string]$Source,

    [string]$Ref,

    [string]$Repository
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

        return [pscustomobject]@{
            IsRemote = $false
            Label = "local:$sourceRepoRoot"
            Ref = $resolvedRef
            Sha = $resolvedSha
            SourceRepoRoot = $sourceRepoRoot
            TempPath = $null
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

    $sourceTempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skillz-install-" + [System.Guid]::NewGuid().ToString('N'))
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

function Assert-RegistryParityAtCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LocalRepoRoot,

        [Parameter(Mandatory)]
        [string]$Sha,

        [Parameter(Mandatory)]
        $SourceRegistry
    )

    git -C $LocalRepoRoot cat-file -e "$Sha`^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return
    }

    $registryJsonAtCommit = git -C $LocalRepoRoot show "$Sha`:registry.json" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($registryJsonAtCommit)) {
        throw "Unable to read registry.json at local commit '$Sha' for parity check."
    }

    $localRegistry = $registryJsonAtCommit | ConvertFrom-Json -Depth 100
    $sourcePluginByName = @{}
    foreach ($plugin in @($SourceRegistry.plugins)) {
        $sourcePluginByName[[string]$plugin.name] = $plugin
    }

    foreach ($localPlugin in @($localRegistry.plugins)) {
        $pluginName = [string]$localPlugin.name
        if (-not $sourcePluginByName.ContainsKey($pluginName)) {
            throw "Registry parity mismatch at '$Sha': plugin '$pluginName' missing from source snapshot registry."
        }

        $sourcePlugin = $sourcePluginByName[$pluginName]
        $localFileByKey = @{}
        foreach ($localFile in @($localPlugin.files)) {
            $key = "$([string]$localFile.src)|$([string]$localFile.dest)"
            $localFileByKey[$key] = [string]$localFile.sha256
        }

        foreach ($sourceFile in @($sourcePlugin.files)) {
            $key = "$([string]$sourceFile.src)|$([string]$sourceFile.dest)"
            if (-not $localFileByKey.ContainsKey($key)) {
                throw "Registry parity mismatch at '$Sha': file '$key' missing for plugin '$pluginName'."
            }
            if ($localFileByKey[$key] -ne [string]$sourceFile.sha256) {
                throw "Registry parity mismatch at '$Sha': hash mismatch for '$pluginName' file '$key'."
            }
        }
    }
}

function Get-PluginSourceRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRepoRoot,

        [Parameter(Mandatory)]
        [string]$PluginName
    )

    $pluginRoot = Join-Path $SourceRepoRoot "plugins/$PluginName"
    if (-not (Test-Path -LiteralPath $pluginRoot -PathType Container)) {
        throw "Plugin '$PluginName' not found under '$SourceRepoRoot/plugins/'."
    }
    return $pluginRoot
}

function Get-ReceiptOwnerMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $ownerByDest = @{}
    $receiptsRoot = Join-Path $RepoRoot '.github/.skillz/receipts'
    if (-not (Test-Path -LiteralPath $receiptsRoot -PathType Container)) {
        return $ownerByDest
    }

    $receiptFiles = Get-ChildItem -LiteralPath $receiptsRoot -File -Filter '*.json'
    foreach ($receiptFile in $receiptFiles) {
        $receipt = Read-JsonFile -Path $receiptFile.FullName
        $owner = [string]$receipt.name
        foreach ($entry in @($receipt.files)) {
            $dest = [string]$entry.dest
            if ([string]::IsNullOrWhiteSpace($dest)) {
                continue
            }
            $resolvedTarget = Resolve-GithubConstrainedPath -RepoRoot $RepoRoot -RelativePath $dest
            $destKey = [System.IO.Path]::GetFullPath($resolvedTarget).ToLowerInvariant()
            if ($ownerByDest.ContainsKey($destKey) -and $ownerByDest[$destKey] -ne $owner) {
                throw "Existing receipt ownership collision for '$dest' between '$owner' and '$($ownerByDest[$destKey])'."
            }
            $ownerByDest[$destKey] = $owner
        }
    }

    return $ownerByDest
}

function Get-InstallOperationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetRepoRoot,

        [Parameter(Mandatory)]
        [string]$SourceRepoRoot,

        [Parameter(Mandatory)]
        [object[]]$PendingPlugins,

        [Parameter(Mandatory)]
        [string]$StageRoot,

        [Parameter(Mandatory)]
        [hashtable]$OwnerByDest
    )

    $pendingNames = @{}
    foreach ($plugin in $PendingPlugins) {
        $pendingNames[[string]$plugin.name] = $true
    }

    $operations = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($plugin in $PendingPlugins) {
        $pluginName = [string]$plugin.name
        $pluginRoot = Get-PluginSourceRoot -SourceRepoRoot $SourceRepoRoot -PluginName $pluginName
        foreach ($file in @($plugin.files)) {
            $src = [string]$file.src
            if ($src -match '^evals(?:/|$)') {
                continue
            }

            $dest = [string]$file.dest
            $targetPath = Resolve-GithubConstrainedPath -RepoRoot $TargetRepoRoot -RelativePath $dest
            $destKey = [System.IO.Path]::GetFullPath($targetPath).ToLowerInvariant()
            if ($OwnerByDest.ContainsKey($destKey)) {
                $owner = [string]$OwnerByDest[$destKey]
                if ($owner -ne $pluginName -and -not $pendingNames.ContainsKey($owner)) {
                    throw "Refusing overwrite of '$dest': owned by installed plugin '$owner'."
                }
            }

            $sourcePath = Resolve-PluginConstrainedPath -PluginRoot $pluginRoot -RelativePath $src
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Plugin '$pluginName' source '$src' is missing from source snapshot."
            }

            $relativeStageName = '{0:d5}-{1}' -f $index, ([System.IO.Path]::GetFileName($dest))
            $stagePath = Join-Path $StageRoot $relativeStageName
            Copy-Item -LiteralPath $sourcePath -Destination $stagePath -Force

            $expectedHash = [string]$file.sha256
            $actualHash = Get-FileSha256 -Path $stagePath
            if ($actualHash -ne $expectedHash) {
                throw "Staged hash mismatch for '$pluginName' file '$src': expected '$expectedHash', got '$actualHash'."
            }

            $operation = [pscustomobject]@{
                Dest = $dest
                DestKey = $destKey
                PluginName = $pluginName
                Sha256 = $expectedHash
                SourcePath = $sourcePath
                StagePath = $stagePath
                TargetPath = $targetPath
            }
            $operations.Add($operation)
            $index++
        }
    }

    return @($operations | Sort-Object Dest, PluginName)
}

function Invoke-InstallTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Operations,

        [Parameter(Mandatory)]
        [string]$BackupRoot
    )

    $applied = [System.Collections.Generic.List[object]]::new()
    $backupIndex = 0
    foreach ($operation in $Operations) {
        $targetDir = Split-Path -Parent $operation.TargetPath
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $targetDir -Force)
        }

        $backupPath = $null
        if (Test-Path -LiteralPath $operation.TargetPath -PathType Leaf) {
            $backupName = '{0:d5}-{1}' -f $backupIndex, ([System.IO.Path]::GetFileName($operation.TargetPath))
            $backupPath = Join-Path $BackupRoot $backupName
            Move-Item -LiteralPath $operation.TargetPath -Destination $backupPath -Force
        }

        $appliedEntry = [pscustomobject]@{
            Operation = $operation
            BackupPath = $backupPath
            Replaced = $false
        }
        $applied.Add($appliedEntry)
        Move-Item -LiteralPath $operation.StagePath -Destination $operation.TargetPath -Force
        $appliedEntry.Replaced = $true
        $backupIndex++
    }

    return @($applied)
}

function Restore-InstallTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$AppliedEntries
    )

    foreach ($entry in @($AppliedEntries) | Sort-Object { $_.Operation.Dest } -Descending) {
        $targetPath = [string]$entry.Operation.TargetPath
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            Remove-Item -LiteralPath $targetPath -Force
        }

        $backupPath = [string]$entry.BackupPath
        if (-not [string]::IsNullOrWhiteSpace($backupPath) -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            $targetDir = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $targetDir -Force)
            }
            Move-Item -LiteralPath $backupPath -Destination $targetPath -Force
        }
    }
}

function Get-PluginReceiptContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Plugin,

        [Parameter(Mandatory)]
        [string]$SourceLabel,

        [Parameter(Mandatory)]
        [string]$RefSha,

        [Parameter(Mandatory)]
        [string]$Outcome
    )

    $receiptFiles = @()
    foreach ($file in @($Plugin.files)) {
        $src = [string]$file.src
        if ($src -match '^evals(?:/|$)') {
            continue
        }

        $receiptFiles += [pscustomobject]@{
            dest = [string]$file.dest
            sha256 = [string]$file.sha256
            outcome = $Outcome
        }
    }

    return [pscustomobject]@{
        evalStatus = 'none'
        files = $receiptFiles
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
        name = [string]$Plugin.name
        ref = $RefSha
        source = "$SourceLabel@$RefSha"
        version = [string]$Plugin.version
    }
}

function Write-ReceiptSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [object[]]$PendingPlugins,

        [Parameter(Mandatory)]
        [string]$SourceLabel,

        [Parameter(Mandatory)]
        [string]$RefSha,

        [Parameter(Mandatory)]
        [string]$OperationRoot
    )

    $stagedReceiptsRoot = Join-Path $OperationRoot 'receipts-staged'
    $receiptBackupsRoot = Join-Path $OperationRoot 'receipts-backup'
    [void](New-Item -ItemType Directory -Path $stagedReceiptsRoot -Force)
    [void](New-Item -ItemType Directory -Path $receiptBackupsRoot -Force)

    $entries = [System.Collections.Generic.List[object]]::new()
    $backupIndex = 0
    foreach ($plugin in $PendingPlugins) {
        $pluginName = [string]$plugin.name
        $existingReceipt = Read-PluginReceipt -RepoRoot $RepoRoot -PluginName $pluginName
        $outcome = if ($null -ne $existingReceipt) { 'updated' } else { 'installed' }
        $receipt = Get-PluginReceiptContent -Plugin $plugin -SourceLabel $SourceLabel -RefSha $RefSha -Outcome $outcome

        $receiptPath = Get-PluginReceiptPath -RepoRoot $RepoRoot -PluginName $pluginName
        $stagedPath = Join-Path $stagedReceiptsRoot "$pluginName.json"
        Write-JsonFileStable -Path $stagedPath -InputObject $receipt
        $entry = [pscustomobject]@{
            ReceiptPath = $receiptPath
            StagedPath = $stagedPath
            BackupPath = $null
            Committed = $false
            BackupIndex = $backupIndex
        }
        $entries.Add($entry)
        $backupIndex++
    }

    foreach ($entry in $entries) {
        $receiptDir = Split-Path -Parent $entry.ReceiptPath
        if (-not (Test-Path -LiteralPath $receiptDir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $receiptDir -Force)
        }

        if (Test-Path -LiteralPath $entry.ReceiptPath -PathType Leaf) {
            $backupName = '{0:d5}-{1}' -f $entry.BackupIndex, ([System.IO.Path]::GetFileName($entry.ReceiptPath))
            $entry.BackupPath = Join-Path $receiptBackupsRoot $backupName
            Move-Item -LiteralPath $entry.ReceiptPath -Destination $entry.BackupPath -Force
        }

        Move-Item -LiteralPath $entry.StagedPath -Destination $entry.ReceiptPath -Force
        $entry.Committed = $true
    }

    return @($entries)
}

function Restore-ReceiptSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    foreach ($entry in @($Entries) | Sort-Object ReceiptPath -Descending) {
        $receiptPath = [string]$entry.ReceiptPath
        if ($entry.Committed -and (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            Remove-Item -LiteralPath $receiptPath -Force
        }

        $backupPath = [string]$entry.BackupPath
        if (-not [string]::IsNullOrWhiteSpace($backupPath) -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            $receiptDir = Split-Path -Parent $receiptPath
            if (-not (Test-Path -LiteralPath $receiptDir -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $receiptDir -Force)
            }
            Move-Item -LiteralPath $backupPath -Destination $receiptPath -Force
        }
    }
}

$targetRepoRoot = Resolve-RepoRoot -StartPath $RepoRoot
$sourceContext = $null
$operationRoot = $null
$appliedEntries = @()
$receiptEntries = @()

try {
    $sourceContext = Get-ResolvedSourceContext -TargetRepoRoot $targetRepoRoot -SourcePath $Source -SourceRef $Ref -RemoteRepository $Repository
    $sourceRepoRoot = [string]$sourceContext.SourceRepoRoot
    $resolvedSha = [string]$sourceContext.Sha

    $sourceRegistryPath = Join-Path $sourceRepoRoot 'registry.json'
    if (-not (Test-Path -LiteralPath $sourceRegistryPath -PathType Leaf)) {
        throw "registry.json not found at source '$sourceRepoRoot'."
    }
    $registry = Read-JsonFile -Path $sourceRegistryPath
    if ($sourceContext.IsRemote) {
        Assert-RegistryParityAtCommit -LocalRepoRoot $targetRepoRoot -Sha $resolvedSha -SourceRegistry $registry
    }

    $pluginsByName = @{}
    foreach ($plugin in @($registry.plugins)) {
        $pluginName = [string]$plugin.name
        if ($pluginsByName.ContainsKey($pluginName)) {
            throw "Duplicate plugin '$pluginName' in source registry."
        }
        $pluginsByName[$pluginName] = $plugin
    }

    $resolvedOrder = Resolve-PluginDependencyOrder -PluginsByName $pluginsByName -RootPluginName $Name -RepoRoot $targetRepoRoot
    $orderedPlugins = @($resolvedOrder.Ordered)
    $pendingPlugins = @($resolvedOrder.Pending)

    if (@($orderedPlugins | Where-Object { [string]$_.name -eq 'ci' }).Count -gt 0) {
        & (Join-Path $PSScriptRoot 'Initialize-Autopilot.ps1') -RepoRoot $targetRepoRoot -SourceRoot $sourceRepoRoot
    }

    if ($pendingPlugins.Count -eq 0) {
        Write-Host "Plugin '$Name' is already up to date at '$resolvedSha'."
        exit 0
    }

    $skillzRoot = Join-Path $targetRepoRoot '.github/.skillz'
    if (-not (Test-Path -LiteralPath $skillzRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $skillzRoot -Force)
    }

    $operationRoot = Join-Path $skillzRoot ("tmp/install-" + [System.Guid]::NewGuid().ToString('N'))
    $stagedRoot = Join-Path $operationRoot 'staged'
    $backupRoot = Join-Path $operationRoot 'backups'
    [void](New-Item -ItemType Directory -Path $stagedRoot -Force)
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)

    $ownerByDest = Get-ReceiptOwnerMap -RepoRoot $targetRepoRoot
    $operations = Get-InstallOperationPlan -TargetRepoRoot $targetRepoRoot -SourceRepoRoot $sourceRepoRoot -PendingPlugins $pendingPlugins -StageRoot $stagedRoot -OwnerByDest $ownerByDest
    if ($operations.Count -eq 0) {
        throw "No installable payload files found for '$Name'."
    }

    $appliedEntries = Invoke-InstallTransaction -Operations $operations -BackupRoot $backupRoot
    Set-Content -LiteralPath (Join-Path $operationRoot 'success.marker') -Value ((Get-Date).ToUniversalTime().ToString('o')) -NoNewline -Encoding utf8

    $receiptEntries = Write-ReceiptSet -RepoRoot $targetRepoRoot -PendingPlugins $pendingPlugins -SourceLabel ([string]$sourceContext.Label) -RefSha $resolvedSha -OperationRoot $operationRoot

    Write-Host "Installed plugin '$Name' with $($pendingPlugins.Count) plugin(s) from '$([string]$sourceContext.Label)' at '$resolvedSha'."
}
catch {
    if ($receiptEntries.Count -gt 0) {
        Restore-ReceiptSet -Entries $receiptEntries
    }
    if ($appliedEntries.Count -gt 0) {
        Restore-InstallTransaction -AppliedEntries $appliedEntries
    }
    if (-not [string]::IsNullOrWhiteSpace($operationRoot) -and (Test-Path -LiteralPath $operationRoot -PathType Container)) {
        Remove-Item -LiteralPath $operationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    if ($null -ne $sourceContext -and $sourceContext.IsRemote -and -not [string]::IsNullOrWhiteSpace([string]$sourceContext.TempPath)) {
        Remove-Item -LiteralPath ([string]$sourceContext.TempPath) -Recurse -Force -ErrorAction SilentlyContinue
    }
}
