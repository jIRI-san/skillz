#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PprcCachedUserToken = $null
$script:PprcCachedUserLogin = $null

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
        [string]$RemoteName = 'origin',

        [string]$RemoteUrl,

        [switch]$UsePushUrl
    )

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        $arguments = @('remote', 'get-url')
        if ($UsePushUrl.IsPresent) {
            $arguments += '--push'
        }
        $arguments += $RemoteName
        $RemoteUrl = Invoke-PprcNativeCommand -Command 'git' -Arguments $arguments -FailureMessage "Unable to resolve git remote '$RemoteName' URL."
    }

    $remoteUrl = $RemoteUrl
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

function Get-PprcAuthenticatedUserLogin {
    [CmdletBinding()]
    param(
        [string]$Token = (Get-GitHubToken)
    )

    if (
        -not [string]::IsNullOrWhiteSpace($script:PprcCachedUserToken) -and
        -not [string]::IsNullOrWhiteSpace($script:PprcCachedUserLogin) -and
        [string]::Equals($script:PprcCachedUserToken, $Token, [System.StringComparison]::Ordinal)
    ) {
        return $script:PprcCachedUserLogin
    }

    $currentUser = Invoke-GitHubRest -Path '/user' -Token $Token
    if ($null -eq $currentUser -or [string]::IsNullOrWhiteSpace([string]$currentUser.login)) {
        throw 'Unable to resolve authenticated GitHub user login from GET /user.'
    }

    $script:PprcCachedUserToken = $Token
    $script:PprcCachedUserLogin = [string]$currentUser.login
    return $script:PprcCachedUserLogin
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

function Get-PprcCurrentBranchName {
    [CmdletBinding()]
    param()

    $branch = Invoke-PprcNativeCommand -Command 'git' -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') -FailureMessage 'Unable to resolve the current git branch.'
    if ([string]::Equals($branch.Trim(), 'HEAD', [System.StringComparison]::Ordinal)) {
        throw 'detached HEAD; check out the PR branch first'
    }

    [void](& git symbolic-ref -q HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'detached HEAD; check out the PR branch first'
    }

    return $branch.Trim()
}

function Resolve-TargetPr {
    [CmdletBinding()]
    param(
        [string]$Token = (Get-GitHubToken)
    )

    $currentBranch = Get-PprcCurrentBranchName
    $repo = Get-RepoSlug
    $owner = [uri]::EscapeDataString($repo.Owner)
    $name = [uri]::EscapeDataString($repo.Repo)

    $openPrs = Invoke-GitHubRest -Path "/repos/$owner/$name/pulls" -Query @{ state = 'open' } -Paginate -Token $Token
    $matchingPrs = @($openPrs | Where-Object {
            $_.PSObject.Properties.Name -contains 'head' -and
            $null -ne $_.head -and
            $_.head.PSObject.Properties.Name -contains 'ref' -and
            [string]::Equals([string]$_.head.ref, $currentBranch, [System.StringComparison]::Ordinal)
        })

    if ($matchingPrs.Count -eq 0) {
        throw "No open pull request in $($repo.FullName) matches branch '$currentBranch'. Ensure the branch has an open PR."
    }

    if ($matchingPrs.Count -gt 1) {
        throw "Multiple open pull requests in $($repo.FullName) match branch '$currentBranch'. Narrow the branch or close duplicates."
    }

    $target = $matchingPrs[0]
    if ($null -eq $target.head.repo) {
        throw "Pull request #$($target.number) has no head repository metadata (possibly a deleted fork)."
    }

    $baseFullName = [string]$repo.FullName
    if ($null -ne $target.base -and $null -ne $target.base.repo -and -not [string]::IsNullOrWhiteSpace([string]$target.base.repo.full_name)) {
        $baseFullName = [string]$target.base.repo.full_name
    }

    $headFullName = [string]$target.head.repo.full_name
    $isCrossRepository = -not [string]::Equals($headFullName, $baseFullName, [System.StringComparison]::OrdinalIgnoreCase)

    $result = [pscustomobject]@{
        PSTypeName = 'Pprc.TargetPr'
        Number = [int]$target.number
        Url = [string]$target.html_url
        BaseFullName = $baseFullName
        HeadFullName = $headFullName
        HeadRefName = [string]$target.head.ref
        IsCrossRepository = [bool]$isCrossRepository
        CurrentBranch = $currentBranch
    }

    return $result
}

function Test-BranchSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$TargetPr
    )

    if ($null -eq $TargetPr) {
        throw 'TargetPr is required for branch safety checks.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$TargetPr.HeadFullName)) {
        throw "Pull request #$($TargetPr.Number) has no head repository metadata (possibly a deleted fork)."
    }

    if ([bool]$TargetPr.IsCrossRepository) {
        throw "Refusing push: PR #$($TargetPr.Number) is cross-repository ($($TargetPr.HeadFullName) -> $($TargetPr.BaseFullName))."
    }

    $currentBranch = Get-PprcCurrentBranchName
    if (-not [string]::Equals($currentBranch, [string]$TargetPr.HeadRefName, [System.StringComparison]::Ordinal)) {
        throw "Refusing push: local branch '$currentBranch' does not match PR head '$($TargetPr.HeadRefName)'."
    }

    return $true
}

function Get-PrReviewThreads {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function returns a keyed set of multiple review threads for one PR.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$TargetPr,

        [string]$Token = (Get-GitHubToken)
    )

    $ownerRepo = $TargetPr.BaseFullName -split '/', 2
    if ($ownerRepo.Count -ne 2 -or [string]::IsNullOrWhiteSpace($ownerRepo[0]) -or [string]::IsNullOrWhiteSpace($ownerRepo[1])) {
        throw "TargetPr.BaseFullName must be in 'owner/repo' format. Got '$($TargetPr.BaseFullName)'."
    }

    $owner = $ownerRepo[0]
    $repo = $ownerRepo[1]
    $encodedOwner = [uri]::EscapeDataString($owner)
    $encodedRepo = [uri]::EscapeDataString($repo)

    $threadsQuery = @'
query ($owner: String!, $repo: String!, $number: Int!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: $first, after: $after) {
        nodes {
          id
          isResolved
          comments(first: $first) {
            nodes {
              databaseId
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
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

    $graphqlData = Invoke-GitHubGraphQL -Query $threadsQuery -Variables @{
        owner = $owner
        repo = $repo
        number = [int]$TargetPr.Number
    } -PaginateReviewThreads -DrainThreadComments -Token $Token

    $threadByCommentId = @{}
    $threadIsResolved = @{}
    foreach ($thread in @($graphqlData.reviewThreads)) {
        if ($null -eq $thread -or [string]::IsNullOrWhiteSpace([string]$thread.id)) {
            continue
        }

        $threadId = [string]$thread.id
        $threadIsResolved[$threadId] = [bool]$thread.isResolved
        foreach ($comment in @($thread.comments.nodes)) {
            if ($null -eq $comment -or $null -eq $comment.databaseId) {
                continue
            }

            $threadByCommentId[[string]$comment.databaseId] = $threadId
        }
    }

    $inlineComments = Invoke-GitHubRest -Path "/repos/$encodedOwner/$encodedRepo/pulls/$([int]$TargetPr.Number)/comments" -Query @{ per_page = 100 } -Paginate -Token $Token
    $reviews = Invoke-GitHubRest -Path "/repos/$encodedOwner/$encodedRepo/pulls/$([int]$TargetPr.Number)/reviews" -Query @{ per_page = 100 } -Paginate -Token $Token

    $commentsByThread = @{}
    foreach ($comment in @($inlineComments)) {
        if ($null -eq $comment -or $null -eq $comment.id) {
            continue
        }

        $threadId = $threadByCommentId[[string]$comment.id]
        if ([string]::IsNullOrWhiteSpace([string]$threadId)) {
            continue
        }

        if (-not $commentsByThread.ContainsKey($threadId)) {
            $commentsByThread[$threadId] = @()
        }
        $commentsByThread[$threadId] += $comment
    }

    $result = [ordered]@{}
    foreach ($threadId in $commentsByThread.Keys) {
        if ($threadIsResolved[$threadId]) {
            continue
        }

        $root = @($commentsByThread[$threadId] | Where-Object { $null -eq $_.in_reply_to_id } | Select-Object -First 1)
        if ($root.Count -eq 0) {
            throw "Unable to determine root comment for review thread '$threadId'."
        }

        $rootComment = $root[0]
        $rootId = [string]$rootComment.id
        $result[$rootId] = [pscustomobject]@{
            rootId = [int]$rootComment.id
            kind = 'inline'
            path = [string]$rootComment.path
            line = if ($null -eq $rootComment.line) { $null } else { [int]$rootComment.line }
            author = [string]$rootComment.user.login
            body = [string]$rootComment.body
            threadResolved = $false
        }
    }

    foreach ($review in @($reviews)) {
        if (
            $null -eq $review -or
            $null -eq $review.id -or
            [string]::Equals([string]$review.state, 'PENDING', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::IsNullOrWhiteSpace([string]$review.body)
        ) {
            continue
        }

        $summaryKey = "summary-$([string]$review.id)"
        $result[$summaryKey] = [pscustomobject]@{
            rootId = $summaryKey
            kind = 'summary'
            path = $null
            line = $null
            author = [string]$review.user.login
            body = [string]$review.body
            threadResolved = $false
        }
    }

    return $result
}

function Resolve-PprcPushRemote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseFullName
    )

    $parts = $BaseFullName -split '/', 2
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "Target base repository must be in 'owner/repo' format. Got '$BaseFullName'."
    }

    $remoteNames = @(Invoke-PprcNativeCommand -Command 'git' -Arguments @('remote') -FailureMessage 'Unable to list git remotes.' -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remoteNames.Count -eq 0) {
        throw 'No git remotes are configured for this repository.'
    }

    $matching = @()
    foreach ($remoteName in $remoteNames) {
        $slug = $null
        try {
            $slug = Get-RepoSlug -RemoteName $remoteName -UsePushUrl
        }
        catch {
            Write-Verbose "Skipping remote '$remoteName' for push target matching. Details: $($_.Exception.Message)"
            continue
        }

        if ([string]::Equals($slug.Owner, $parts[0], [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($slug.Repo, $parts[1], [System.StringComparison]::OrdinalIgnoreCase)) {
            $matching += [pscustomobject]@{
                Name = $remoteName
                FullName = $slug.FullName
            }
        }
    }

    if ($matching.Count -eq 0) {
        throw "No remote points at '$BaseFullName'."
    }

    $originMatch = $matching | Where-Object { [string]::Equals($_.Name, 'origin', [System.StringComparison]::Ordinal) } | Select-Object -First 1
    if ($null -ne $originMatch) {
        return $originMatch.Name
    }

    if ($matching.Count -gt 1) {
        $remoteList = ($matching.Name | Sort-Object) -join ','
        throw "Ambiguous remotes: $remoteList target '$BaseFullName'."
    }

    return $matching[0].Name
}

function Invoke-PrPush {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$TargetPr
    )

    [void](Test-BranchSafety -TargetPr $TargetPr)

    $remoteName = Resolve-PprcPushRemote -BaseFullName ([string]$TargetPr.BaseFullName)
    $refSpec = "HEAD:refs/heads/$([string]$TargetPr.HeadRefName)"

    try {
        [void](Invoke-PprcNativeCommand -Command 'git' -Arguments @('push', $remoteName, $refSpec) -FailureMessage "Failed to push $refSpec to '$remoteName'.")
    }
    catch {
        $message = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "$_"
        }

        if ($message -match '(?i)non-fast-forward|fetch first|\[rejected\]') {
            throw "Push rejected as non-fast-forward. Run 'git pull --rebase' and retry. Never use '--force'."
        }

        throw
    }

    return [pscustomobject]@{
        Remote = $remoteName
        RefSpec = $refSpec
        Pushed = $true
    }
}

function Get-PprcThreadMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadKey
    )

    return "<!-- pprc:thread:$ThreadKey -->"
}

function Add-PprcMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Body,

        [Parameter(Mandatory)]
        [string]$Marker
    )

    $trimmed = $Body.TrimEnd()
    if ($trimmed.Contains($Marker)) {
        return $trimmed
    }

    return "$trimmed`n`n$Marker"
}

function Test-PprcMarkerMatch {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Body,

        [Parameter(Mandatory)]
        [string]$Marker
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $false
    }

    return $Body.Contains($Marker)
}

function Add-PrReply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$TargetPr,

        [Parameter(Mandatory)]
        [psobject]$Thread,

        [Parameter(Mandatory)]
        [string]$Body,

        [string]$Token = (Get-GitHubToken),

        [string]$UserLogin
    )

    if ([string]::IsNullOrWhiteSpace($UserLogin)) {
        $UserLogin = Get-PprcAuthenticatedUserLogin -Token $Token
    }

    $kind = [string]$Thread.kind
    if ([string]::IsNullOrWhiteSpace($kind)) {
        throw 'Thread.kind is required.'
    }

    $threadKey = [string]$Thread.rootId
    if ([string]::IsNullOrWhiteSpace($threadKey)) {
        throw 'Thread.rootId is required.'
    }

    $ownerRepo = [string]$TargetPr.BaseFullName -split '/', 2
    if ($ownerRepo.Count -ne 2 -or [string]::IsNullOrWhiteSpace($ownerRepo[0]) -or [string]::IsNullOrWhiteSpace($ownerRepo[1])) {
        throw "TargetPr.BaseFullName must be in 'owner/repo' format. Got '$($TargetPr.BaseFullName)'."
    }

    $encodedOwner = [uri]::EscapeDataString($ownerRepo[0])
    $encodedRepo = [uri]::EscapeDataString($ownerRepo[1])
    $prNumber = [int]$TargetPr.Number

    $marker = Get-PprcThreadMarker -ThreadKey $threadKey
    $bodyWithMarker = Add-PprcMarker -Body $Body -Marker $marker

    if ([string]::Equals($kind, 'inline', [System.StringComparison]::OrdinalIgnoreCase)) {
        $rootId = 0
        if (-not [int]::TryParse($threadKey, [ref]$rootId)) {
            throw "Inline thread rootId must be an integer. Got '$threadKey'."
        }

        $existingInline = Invoke-GitHubRest -Path "/repos/$encodedOwner/$encodedRepo/pulls/$prNumber/comments" -Query @{ per_page = 100 } -Paginate -Token $Token
        $duplicateInline = @($existingInline | Where-Object {
                $null -ne $_ -and
                $null -ne $_.user -and
                [string]::Equals([string]$_.user.login, $UserLogin, [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-PprcMarkerMatch -Body ([string]$_.body) -Marker $marker)
            } | Select-Object -First 1)

        if ($duplicateInline.Count -gt 0) {
            return [pscustomobject]@{
                ThreadKey = $threadKey
                Kind = 'inline'
                Posted = $false
                AlreadyHandled = $true
                CommentId = [int]$duplicateInline[0].id
                Marker = $marker
            }
        }

        $createdInline = Invoke-GitHubRest -Path "/repos/$encodedOwner/$encodedRepo/pulls/$prNumber/comments" -Method 'POST' -Body @{
            body = $bodyWithMarker
            in_reply_to = [int]$rootId
        } -Token $Token

        if ($null -eq $createdInline -or $null -eq $createdInline.id) {
            throw "GitHub did not return a comment id after posting inline reply for thread '$threadKey'."
        }

        return [pscustomobject]@{
            ThreadKey = $threadKey
            Kind = 'inline'
            Posted = $true
            AlreadyHandled = $false
            CommentId = [int]$createdInline.id
            Marker = $marker
        }
    }

    $existingIssueComments = @()
    try {
        $existingIssueComments = @(Invoke-GitHubRest -Path "/repos/$encodedOwner/$encodedRepo/issues/$prNumber/comments" -Query @{ per_page = 100 } -Paginate -Token $Token)
    }
    catch {
        Write-Verbose "Summary dedup check unavailable for thread '$threadKey'; continuing with post. Details: $($_.Exception.Message)"
    }

    $duplicateIssue = @($existingIssueComments | Where-Object {
            $null -ne $_ -and
            $null -ne $_.user -and
            [string]::Equals([string]$_.user.login, $UserLogin, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-PprcMarkerMatch -Body ([string]$_.body) -Marker $marker)
        } | Select-Object -First 1)
    if ($duplicateIssue.Count -gt 0) {
        return [pscustomobject]@{
            ThreadKey = $threadKey
            Kind = [string]$kind
            Posted = $false
            AlreadyHandled = $true
            CommentId = [int]$duplicateIssue[0].id
            Marker = $marker
        }
    }

    $createdIssue = Invoke-GitHubRest -Path "/repos/$encodedOwner/$encodedRepo/issues/$prNumber/comments" -Method 'POST' -Body @{
        body = $bodyWithMarker
    } -Token $Token
    if ($null -eq $createdIssue -or $null -eq $createdIssue.id) {
        throw "GitHub did not return a comment id after posting summary reply for thread '$threadKey'."
    }

    return [pscustomobject]@{
        ThreadKey = $threadKey
        Kind = [string]$kind
        Posted = $true
        AlreadyHandled = $false
        CommentId = [int]$createdIssue.id
        Marker = $marker
    }
}

Export-ModuleMember -Function @(
    'Get-GitHubToken',
    'Get-RepoSlug',
    'Invoke-GitHubRest',
    'Invoke-GitHubGraphQL',
    'Resolve-TargetPr',
    'Test-BranchSafety',
    'Get-PrReviewThreads',
    'Invoke-PrPush',
    'Add-PrReply'
)
