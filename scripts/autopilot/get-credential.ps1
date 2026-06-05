#requires -Version 7.0
<#
.SYNOPSIS
    The single token reader for autopilot (Windows Credential Manager).
.DESCRIPTION
    Resolves a stored fine-grained GitHub PAT from Windows Credential Manager and
    returns it as a [PSCredential]. This is the ONLY token-reading code path;
    validate-auth.ps1 and prepare-env-file.ps1 both consume it so Credential
    Manager logic is never duplicated.

    The token is never written to the host, a log, or the pipeline as plaintext.
    Callers extract it only at the moment of use via
    `$cred.GetNetworkCredential().Password`.
.PARAMETER Target
    Windows Credential Manager target name (e.g. 'copilot-autopilot').
.OUTPUTS
    [System.Management.Automation.PSCredential]
.EXAMPLE
    $cred = ./get-credential.ps1 -Target copilot-autopilot
#>
[CmdletBinding()]
[OutputType([System.Management.Automation.PSCredential])]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Target
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
    throw @"
The CredentialManager module is required but not installed.
Install it once with:
  Install-Module CredentialManager -Scope CurrentUser
Then store the PAT:
  New-StoredCredential -Target '$Target' -UserName 'autopilot' -Password '<PAT>' -Type Generic -Persist LocalMachine
"@
}

Import-Module CredentialManager -ErrorAction Stop

$cred = Get-StoredCredential -Target $Target
if (-not $cred) {
    throw @"
No stored credential found for target '$Target'.
Create one with:
  New-StoredCredential -Target '$Target' -UserName 'autopilot' -Password '<fine-grained-PAT>' -Type Generic -Persist LocalMachine
Required PAT permissions: Contents R/W, Pull requests R/W, Copilot Requests R.
"@
}

# Guard against an empty password (corrupt/blank entry).
if ([string]::IsNullOrWhiteSpace($cred.GetNetworkCredential().Password)) {
    throw "Stored credential '$Target' has an empty password; re-create it."
}

return $cred
