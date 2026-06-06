#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-PprcNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory)]
        [string]$FailureMessage
    )

    try {
        $output = & $Command @Arguments 2>&1
    }
    catch {
        $message = "$_".Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            throw $FailureMessage
        }

        throw "$FailureMessage Details: $message"
    }

    $exitCode = $LASTEXITCODE
    $text = (($output | ForEach-Object { "$_".Trim() }) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw $FailureMessage
        }

        throw "$FailureMessage Details: $text"
    }

    return $text.Trim()
}

function Get-GitHubToken {
    [CmdletBinding()]
    param()

    [void](Invoke-PprcNativeCommand -Command 'gh' -Arguments @('--version') -FailureMessage "GitHub CLI ('gh') is not available. Install it, then run 'gh auth login'.")
    [void](Invoke-PprcNativeCommand -Command 'gh' -Arguments @('auth', 'status') -FailureMessage "GitHub CLI is not authenticated for this user. Run 'gh auth login' and retry.")

    $token = Invoke-PprcNativeCommand -Command 'gh' -Arguments @('auth', 'token') -FailureMessage "Unable to resolve a GitHub token from gh. Run 'gh auth login' and retry."
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "GitHub CLI returned an empty token. Run 'gh auth login' and retry."
    }

    Write-Verbose 'Resolved GitHub token via gh auth token: [REDACTED]'
    return $token.Trim()
}

function Get-RepoSlug {
    [CmdletBinding()]
    param(
        [string]$RemoteName = 'origin'
    )

    $remoteUrl = Invoke-PprcNativeCommand -Command 'git' -Arguments @('remote', 'get-url', $RemoteName) -FailureMessage "Unable to resolve git remote '$RemoteName' URL."
    $remoteUrl = $remoteUrl.Trim()

    $path = $null
    if ($remoteUrl -match '^git@[^:]+:(?<path>.+)$') {
        $path = $Matches.path
    }
    elseif ($remoteUrl -match '^https?://[^/]+/(?<path>.+)$') {
        $path = $Matches.path
    }
    elseif ($remoteUrl -match '^ssh://(?:[^@]+@)?[^/]+/(?<path>.+)$') {
        $path = $Matches.path
    }
    else {
        throw "Unsupported remote URL format for '$RemoteName': '$remoteUrl'."
    }

    $normalizedPath = $path.Split('?', 2)[0].Split('#', 2)[0].Trim('/')
    $segments = $normalizedPath.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($segments.Count -lt 2) {
        throw "Remote URL for '$RemoteName' does not contain an owner and repository: '$remoteUrl'."
    }

    $owner = $segments[$segments.Count - 2].Trim()
    $repo = $segments[$segments.Count - 1].Trim() -replace '\.git$', ''
    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
        throw "Unable to parse owner/repository from '$remoteUrl'."
    }

    return [pscustomobject]@{
        Owner = $owner
        Repo = $repo
        FullName = "$owner/$repo"
    }
}

Export-ModuleMember -Function @(
    'Get-GitHubToken',
    'Get-RepoSlug'
)
