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

# Probe 4: workflow push capability — required to push commits that add or
# modify .github/workflows/**. A missing scope/permission makes GitHub reject
# the final push, silently discarding every commit made inside the container.
# Surface it here, before the (potentially multi-hour) run starts.
#
# GitHub does NOT expose fine-grained permissions via any API, so the depth of
# the check depends on the token type (inferred from its prefix):
#   ghp_*        classic PAT        -> hard-verifiable via X-OAuth-Scopes header
#   github_pat_* fine-grained PAT   -> not introspectable; emit exact instruction
#   gho_/ghu_*   OAuth/user token   -> scopes header if present, else advisory
Write-Host "  Checking workflow push capability..."
$tokenType =
    if ($Token -like 'github_pat_*') { 'fine-grained' }
    elseif ($Token -like 'ghp_*') { 'classic' }
    elseif ($Token -like 'gho_*' -or $Token -like 'ghu_*') { 'oauth' }
    else { 'unknown' }

if ($tokenType -eq 'fine-grained') {
    # Fine-grained permissions are invisible to the API. Cannot verify; instruct.
    Write-Host "  Fine-grained PAT detected (github_pat_*)."
    Write-Host "  NOTE: Fine-grained permissions are not introspectable via the GitHub API."
    Write-Host "        If this plan edits .github/workflows/**, the PAT must grant"
    Write-Host "        Repository permissions -> Workflows -> Read and write,"
    Write-Host "        otherwise the push will be rejected and container commits lost."
}
else {
    try {
        $scopeResponse = Invoke-WebRequest -Uri 'https://api.github.com/user' -Headers $headers -Method Get -UseBasicParsing
        # Header access differs between Windows PowerShell 5.1 (string) and 7 (string[]).
        $scopeKey = $scopeResponse.Headers.Keys | Where-Object { $_ -ieq 'X-OAuth-Scopes' } | Select-Object -First 1
        if ($scopeKey) {
            $rawScopes = $scopeResponse.Headers[$scopeKey]
            if ($rawScopes -is [array]) { $rawScopes = $rawScopes -join ',' }
            $scopes = ([string]$rawScopes -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if ($scopes -contains 'workflow') {
                Write-Host "  Workflow scope present ($tokenType token)."
            }
            else {
                Write-Warning @"
GitHub $tokenType token is missing the 'workflow' scope.
Any push that adds or changes .github/workflows/** will be REJECTED by GitHub,
discarding ALL commits made inside the container.

Fix before running plans that touch workflows:
- Edit the token at https://github.com/settings/tokens and enable the 'workflow' scope.
- Re-store it:
  New-StoredCredential -Target 'copilot-autopilot' -UserName 'autopilot' -Password '<token>' -Type Generic -Persist LocalMachine
"@
            }
        }
        else {
            Write-Host "  Token type '$tokenType': no OAuth scopes header returned; cannot verify workflow scope. Ensure workflow push access if the plan edits .github/workflows/**."
        }
    }
    catch {
        Write-Warning "Could not determine token workflow scope: $($_.Exception.Message)"
    }
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
