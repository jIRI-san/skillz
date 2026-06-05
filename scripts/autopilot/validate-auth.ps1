<#
.SYNOPSIS
    Validates authentication tokens work before launching autopilot execution.
.DESCRIPTION
    For GitHub: runs capability probes (GET /user, GET /repos, copilot probe).
    For ADO: fetches access token on host to verify az CLI auth works.
.PARAMETER Config
    Parsed .autopilot.json object.
.PARAMETER Token
    The GitHub token to validate.
.OUTPUTS
    [hashtable] with 'Valid' [bool] and 'AdoToken' [string] if ADO.
    Throws on auth failure with re-auth guidance.
#>
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [string]$Token
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$result = @{ Valid = $false; AdoToken = $null }

# --- GitHub token validation ---
Write-Host "Validating GitHub token..."

# Probe 1: GET /user - confirms token is valid
$headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json' }
try {
    $userResponse = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -Method Get
    Write-Host "  Token valid for user: $($userResponse.login)"
}
catch {
    throw @"
GitHub token validation failed (GET /user).
HTTP error: $($_.Exception.Message)

Re-auth guidance:
- PAT: Create a new fine-grained PAT at https://github.com/settings/tokens?type=beta
  Required permissions: Copilot Requests, Contents (read/write), Pull Requests (read/write)
  Store it: New-StoredCredential -Target 'copilot-autopilot' -UserName 'autopilot' -Password '<token>' -Type Generic -Persist LocalMachine
- OAuth: Run 'copilot login' and retry.
"@
}

# Probe 2: GET /repos/{owner}/{repo} - confirms Contents access
$remote = git remote get-url origin 2>$null
if ($remote -match 'github\.com[:/]([^/]+)/([^/.]+)') {
    $owner = $Matches[1]
    $repo = $Matches[2]
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo" -Headers $headers -Method Get | Out-Null
        Write-Host "  Contents access confirmed for $owner/$repo"
    }
    catch {
        throw @"
GitHub token lacks Contents access to $owner/$repo.
HTTP error: $($_.Exception.Message)

Ensure your fine-grained PAT includes 'Contents' permission for this repository.
"@
    }
}
else {
    Write-Host "  Skipping repo access probe (non-GitHub remote or no remote configured)."
}

# Probe 3: Copilot Requests permission (lightweight)
Write-Host "  Validating Copilot CLI access..."
$env:COPILOT_GITHUB_TOKEN = $Token
try {
    $copilotResult = copilot -p "echo hello" -s 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "copilot CLI returned exit code $LASTEXITCODE"
    }
    Write-Host "  Copilot CLI access confirmed."
}
catch {
    Write-Warning "Copilot CLI probe failed: $($_.Exception.Message). Token may lack Copilot Requests permission."
    # Non-fatal - the token might still work for the actual execution
}
finally {
    Remove-Item Env:\COPILOT_GITHUB_TOKEN -ErrorAction SilentlyContinue
}

# --- ADO validation (if applicable) ---
if ($Config.gitProvider -eq 'ado') {
    Write-Host "Validating ADO authentication..."
    try {
        $tokenJson = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "az account get-access-token failed: $tokenJson"
        }
        $result.AdoToken = $tokenJson.Trim()
        Write-Host "  ADO token acquired successfully."
    }
    catch {
        throw @"
ADO authentication failed. Cannot fetch access token.
Error: $($_.Exception.Message)

Re-auth guidance:
  az login --use-device-code
Then retry.
"@
    }
}

$result.Valid = $true
Write-Host "Authentication validation passed."
return $result
