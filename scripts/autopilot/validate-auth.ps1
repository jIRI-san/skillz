#requires -Version 7.0
<#
.SYNOPSIS
    Validates that the stored PAT is live and reaches the GitHub/Copilot API.
.DESCRIPTION
    Consumes get-credential.ps1 (the single token reader), probes the GitHub API
    with the token, and aborts with actionable scope guidance on failure. The
    token is used only to build the Authorization header and is never logged.

    Exit codes: 0 = auth OK; 1 = auth failed (launcher aborts before any work).
.PARAMETER CredentialTarget
    Windows Credential Manager target holding the fine-grained PAT.
.PARAMETER ApiBase
    GitHub API base URL (default https://api.github.com); override for GHES.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialTarget',
    Justification = 'CredentialTarget is a Windows Credential Manager target NAME, not a secret value.')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialTarget,

    [string]$ApiBase = 'https://api.github.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_autopilot-common.ps1"

try {
    $cred = & "$PSScriptRoot/get-credential.ps1" -Target $CredentialTarget
}
catch {
    Write-AutopilotLog "Could not read credential '$CredentialTarget': $($_.Exception.Message)" -Level ERROR
    exit 1
}

$headers = @{
    Authorization = "Bearer $($cred.GetNetworkCredential().Password)"
    'User-Agent' = 'skillz-autopilot'
    Accept = 'application/vnd.github+json'
}

try {
    $resp = Invoke-WebRequest -Uri "$ApiBase/user" -Headers $headers -Method Get -SkipHttpErrorCheck
}
catch {
    Write-AutopilotLog "GitHub API unreachable at ${ApiBase}: $($_.Exception.Message)" -Level ERROR
    exit 1
}
finally {
    # Drop the plaintext header reference as soon as the request is issued.
    $headers['Authorization'] = $null
    $headers = $null
}

switch ([int]$resp.StatusCode) {
    200 {
        Write-AutopilotLog 'Auth validation OK (token live, GitHub API reachable).'
        exit 0
    }
    { $_ -in 401, 403 } {
        Write-AutopilotLog @"
Auth failed (HTTP $($resp.StatusCode)). The PAT is missing, expired, or lacks scope.
Required fine-grained PAT permissions: Contents R/W, Pull requests R/W, Copilot Requests R.
Re-create the token and store it:
  New-StoredCredential -Target '$CredentialTarget' -UserName 'autopilot' -Password '<PAT>' -Type Generic -Persist LocalMachine
"@ -Level ERROR
        exit 1
    }
    default {
        Write-AutopilotLog "Auth probe returned unexpected HTTP $($resp.StatusCode)." -Level ERROR
        exit 1
    }
}
