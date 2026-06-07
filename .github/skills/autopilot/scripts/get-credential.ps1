#Requires -Modules CredentialManager
<#
.SYNOPSIS
    Reads authentication tokens from Windows Credential Manager for autopilot execution.
.DESCRIPTION
    Supports multiple credential targets:
    - 'copilot-autopilot' - Fine-grained PAT for Copilot CLI + git operations
    - 'copilot-cli' - OAuth token from `copilot login` pre-auth
    For ADO: validates `az account show` succeeds (token fetched separately by validate-auth.ps1).
.PARAMETER Target
    The credential target to retrieve. One of: 'copilot-autopilot', 'copilot-cli', 'ado'.
.OUTPUTS
    [string] The token value, or throws on failure.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('copilot-autopilot', 'copilot-cli', 'ado')]
    [string]$Target
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TokenFromCredentialManager {
    param([string]$CredentialTarget)

    # Check if CredentialManager module is available
    if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
        throw @"
CredentialManager PowerShell module not found.
Install it: Install-Module -Name CredentialManager -Scope CurrentUser
Then store your token: New-StoredCredential -Target '$CredentialTarget' -UserName 'autopilot' -Password '<your-token>' -Type Generic -Persist LocalMachine
"@
    }

    $cred = Get-StoredCredential -Target $CredentialTarget
    if (-not $cred) {
        throw @"
No credential found for target '$CredentialTarget' in Windows Credential Manager.
Store it: New-StoredCredential -Target '$CredentialTarget' -UserName 'autopilot' -Password '<your-token>' -Type Generic -Persist LocalMachine
"@
    }

    # Extract password from NetworkCredential
    $token = $cred.GetNetworkCredential().Password
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Credential '$CredentialTarget' exists but password is empty."
    }

    return $token
}

switch ($Target) {
    'copilot-autopilot' {
        return Get-TokenFromCredentialManager -CredentialTarget 'copilot-autopilot'
    }
    'copilot-cli' {
        return Get-TokenFromCredentialManager -CredentialTarget 'copilot-cli'
    }
    'ado' {
        # For ADO, verify az CLI is authenticated (token fetched by validate-auth.ps1)
        $azAccount = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw @"
Azure CLI not authenticated. Run:
  az login --use-device-code
Then retry.
"@
        }
        # Return success indicator - actual token fetched by validate-auth.ps1
        return 'ado-authenticated'
    }
}
