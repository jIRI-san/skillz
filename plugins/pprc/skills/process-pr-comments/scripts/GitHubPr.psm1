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

function Get-PprcHeaderValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Headers,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Headers) {
        return $null
    }

    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = $Headers[$key]
                if ($value -is [System.Array]) {
                    return ($value -join ',')
                }

                return [string]$value
            }
        }
        return $null
    }

    if ($Headers.PSObject.Methods.Name -contains 'TryGetValues') {
        $values = $null
        $found = $Headers.TryGetValues($Name, [ref]$values)
        if ($found) {
            return (@($values) -join ',')
        }
    }

    if ($Headers.PSObject.Methods.Name -contains 'GetEnumerator') {
        foreach ($entry in $Headers.GetEnumerator()) {
            if ([string]::Equals([string]$entry.Key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return (@($entry.Value) -join ',')
            }
        }
    }

    return $null
}

function ConvertTo-PprcLocalTime {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    $raw = [string]$Value
    $seconds = 0
    if ([long]::TryParse($raw, [ref]$seconds)) {
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).ToLocalTime().ToString('u')
    }

    $dateTime = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($raw, [ref]$dateTime)) {
        return $dateTime.ToLocalTime().ToString('u')
    }

    return $raw
}

function Get-PprcNextLink {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$LinkHeader
    )

    if ([string]::IsNullOrWhiteSpace($LinkHeader)) {
        return $null
    }

    $segments = $LinkHeader.Split(',')
    foreach ($segment in $segments) {
        $trimmed = $segment.Trim()
        if ($trimmed -match '^\s*<(?<url>[^>]+)>\s*;\s*rel="(?<rel>[^"]+)"') {
            if ($Matches.rel -eq 'next') {
                return $Matches.url
            }
        }
    }

    return $null
}

function New-PprcGitHubUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [hashtable]$Query = @{}
    )

    $normalizedPath = if ($Path.StartsWith('/')) { $Path } else { "/$Path" }
    $uri = "https://api.github.com$normalizedPath"
    if ($Query.Count -eq 0) {
        return $uri
    }

    $parts = @()
    foreach ($key in ($Query.Keys | Sort-Object)) {
        $value = $Query[$key]
        if ($null -eq $value) {
            continue
        }

        $parts += "{0}={1}" -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$value)
    }

    if ($parts.Count -eq 0) {
        return $uri
    }

    return "$uri?$(($parts -join '&'))"
}

function Throw-PprcRateLimitError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$StatusCode,

        [AllowNull()]
        $Headers
    )

    if ($StatusCode -ne 403 -and $StatusCode -ne 429) {
        return
    }

    $remaining = Get-PprcHeaderValue -Headers $Headers -Name 'X-RateLimit-Remaining'
    $retryAfter = Get-PprcHeaderValue -Headers $Headers -Name 'Retry-After'
    if ($remaining -ne '0' -and [string]::IsNullOrWhiteSpace($retryAfter)) {
        return
    }

    $retryLocal = ConvertTo-PprcLocalTime -Value $retryAfter
    $resetLocal = ConvertTo-PprcLocalTime -Value (Get-PprcHeaderValue -Headers $Headers -Name 'X-RateLimit-Reset')
    if (-not [string]::IsNullOrWhiteSpace($retryLocal)) {
        throw "GitHub API rate limit reached. Retry after $retryLocal (local time)."
    }

    if (-not [string]::IsNullOrWhiteSpace($resetLocal)) {
        throw "GitHub API rate limit reached. Reset at $resetLocal (local time)."
    }

    throw 'GitHub API rate limit reached.'
}

function Invoke-PprcApiRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [AllowNull()]
        $Body
    )

    $responseHeaders = $null
    $params = @{
        Method = $Method
        Uri = $Uri
        Headers = $Headers
        ResponseHeadersVariable = 'responseHeaders'
    }

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
        $params.ContentType = 'application/json'
    }

    try {
        $responseBody = Invoke-RestMethod @params
    }
    catch {
        $statusCode = 0
        $errorHeaders = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $null -ne $_.Exception.Response) {
            $response = $_.Exception.Response
            if ($response.PSObject.Properties.Name -contains 'StatusCode' -and $null -ne $response.StatusCode) {
                $statusCode = [int]$response.StatusCode
            }

            if ($response.PSObject.Properties.Name -contains 'Headers') {
                $errorHeaders = $response.Headers
            }
        }

        Throw-PprcRateLimitError -StatusCode $statusCode -Headers $errorHeaders

        $message = "$_".Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            throw "GitHub request failed: $Method $Uri"
        }

        if ($statusCode -gt 0) {
            throw "GitHub request failed: $Method $Uri (HTTP $statusCode). Details: $message"
        }

        throw "GitHub request failed: $Method $Uri. Details: $message"
    }

    return [pscustomobject]@{
        Body = $responseBody
        Headers = $responseHeaders
    }
}

function Invoke-GitHubRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',

        [hashtable]$Query = @{},

        [AllowNull()]
        $Body,

        [string]$Token = (Get-GitHubToken),

        [switch]$Paginate
    )

    $headers = @{
        Authorization = "Bearer $Token"
        Accept = 'application/vnd.github+json'
    }

    $uri = New-PprcGitHubUri -Path $Path -Query $Query
    if ($Method -ne 'GET' -or -not $Paginate.IsPresent) {
        return (Invoke-PprcApiRequest -Method $Method -Uri $uri -Headers $headers -Body $Body).Body
    }

    $results = @()
    $nextUri = $uri
    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $response = Invoke-PprcApiRequest -Method 'GET' -Uri $nextUri -Headers $headers -Body $null
        $payload = $response.Body

        if ($payload -is [System.Array]) {
            $results += $payload
        }
        elseif ($null -ne $payload) {
            $results += ,$payload
        }

        $nextUri = Get-PprcNextLink -LinkHeader (Get-PprcHeaderValue -Headers $response.Headers -Name 'Link')
    }

    return $results
}

function Invoke-PprcGraphQLError {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Errors,

        [AllowNull()]
        $Data
    )

    if ($null -eq $Errors -or $Errors.Count -eq 0) {
        return
    }

    $rateError = $Errors | Where-Object {
        $_.PSObject.Properties.Name -contains 'type' -and $_.type -eq 'RATE_LIMITED'
    } | Select-Object -First 1
    if ($null -ne $rateError) {
        $resetAt = $null
        if ($rateError.PSObject.Properties.Name -contains 'extensions' -and $null -ne $rateError.extensions) {
            if ($rateError.extensions.PSObject.Properties.Name -contains 'resetAt') {
                $resetAt = $rateError.extensions.resetAt
            }
        }

        if ($null -eq $resetAt -and $null -ne $Data -and $Data.PSObject.Properties.Name -contains 'rateLimit' -and $null -ne $Data.rateLimit) {
            if ($Data.rateLimit.PSObject.Properties.Name -contains 'resetAt') {
                $resetAt = $Data.rateLimit.resetAt
            }
        }

        $resetLocal = ConvertTo-PprcLocalTime -Value $resetAt
        if ([string]::IsNullOrWhiteSpace($resetLocal)) {
            throw 'GitHub GraphQL rate limit reached.'
        }

        throw "GitHub GraphQL rate limit reached. Reset at $resetLocal (local time)."
    }

    $messages = @($Errors | ForEach-Object { $_.message } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($messages.Count -eq 0) {
        throw 'GitHub GraphQL request failed.'
    }

    throw "GitHub GraphQL request failed: $($messages -join '; ')"
}

function Invoke-GitHubGraphQL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [hashtable]$Variables = @{},

        [string]$Token = (Get-GitHubToken),

        [int]$First = 100,

        [switch]$PaginateReviewThreads,

        [switch]$DrainThreadComments
    )

    $headers = @{
        Authorization = "Bearer $Token"
        Accept = 'application/vnd.github+json'
    }

    $graphqlPath = '/graphql'
    if (-not $PaginateReviewThreads.IsPresent) {
        $payload = @{
            query = $Query
            variables = $Variables
        }
        $response = Invoke-PprcApiRequest -Method 'POST' -Uri (New-PprcGitHubUri -Path $graphqlPath) -Headers $headers -Body $payload
        Invoke-PprcGraphQLError -Errors @($response.Body.errors) -Data $response.Body.data
        return $response.Body.data
    }

    $allThreads = @()
    $cursor = $null
    $hasNextPage = $true
    while ($hasNextPage) {
        $pageVariables = @{}
        foreach ($key in $Variables.Keys) {
            $pageVariables[$key] = $Variables[$key]
        }
        $pageVariables.first = $First
        $pageVariables.after = $cursor

        $payload = @{
            query = $Query
            variables = $pageVariables
        }

        $response = Invoke-PprcApiRequest -Method 'POST' -Uri (New-PprcGitHubUri -Path $graphqlPath) -Headers $headers -Body $payload
        Invoke-PprcGraphQLError -Errors @($response.Body.errors) -Data $response.Body.data

        $reviewThreads = $response.Body.data.repository.pullRequest.reviewThreads
        if ($null -eq $reviewThreads) {
            throw 'GraphQL response is missing data.repository.pullRequest.reviewThreads.'
        }

        if ($reviewThreads.nodes -is [System.Array]) {
            $allThreads += $reviewThreads.nodes
        }
        elseif ($null -ne $reviewThreads.nodes) {
            $allThreads += ,$reviewThreads.nodes
        }

        $hasNextPage = [bool]$reviewThreads.pageInfo.hasNextPage
        $cursor = if ($hasNextPage) { [string]$reviewThreads.pageInfo.endCursor } else { $null }
    }

    if ($DrainThreadComments.IsPresent) {
        $threadCommentsQuery = @'
query ($threadId: ID!, $first: Int!, $after: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: $first, after: $after) {
        nodes {
          id
          databaseId
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}
'@
        foreach ($thread in $allThreads) {
            if ($null -eq $thread.comments -or $null -eq $thread.comments.pageInfo) {
                continue
            }

            $commentNodes = @()
            if ($thread.comments.nodes -is [System.Array]) {
                $commentNodes += $thread.comments.nodes
            }
            elseif ($null -ne $thread.comments.nodes) {
                $commentNodes += ,$thread.comments.nodes
            }

            $commentCursor = if ([bool]$thread.comments.pageInfo.hasNextPage) { [string]$thread.comments.pageInfo.endCursor } else { $null }
            while (-not [string]::IsNullOrWhiteSpace($commentCursor)) {
                $variables = @{
                    threadId = $thread.id
                    first = $First
                    after = $commentCursor
                }
                $response = Invoke-PprcApiRequest -Method 'POST' -Uri (New-PprcGitHubUri -Path $graphqlPath) -Headers $headers -Body @{
                    query = $threadCommentsQuery
                    variables = $variables
                }
                Invoke-PprcGraphQLError -Errors @($response.Body.errors) -Data $response.Body.data

                $comments = $response.Body.data.node.comments
                if ($comments.nodes -is [System.Array]) {
                    $commentNodes += $comments.nodes
                }
                elseif ($null -ne $comments.nodes) {
                    $commentNodes += ,$comments.nodes
                }

                $commentCursor = if ([bool]$comments.pageInfo.hasNextPage) { [string]$comments.pageInfo.endCursor } else { $null }
            }

            $thread.comments.nodes = $commentNodes
            $thread.comments.pageInfo.hasNextPage = $false
            $thread.comments.pageInfo.endCursor = $null
        }
    }

    return [pscustomobject]@{
        reviewThreads = $allThreads
    }
}

Export-ModuleMember -Function @(
    'Get-GitHubToken',
    'Get-RepoSlug',
    'Invoke-GitHubRest',
    'Invoke-GitHubGraphQL'
)
