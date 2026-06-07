#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'plugins' 'pprc' 'skills' 'process-pr-comments' 'scripts' 'GitHubPr.psm1')).Path
$moduleName = (Import-Module $modulePath -Force -PassThru).Name

Describe 'pprc GitHubPr module' {
    InModuleScope $moduleName {
        BeforeEach {
            $script:PprcCachedUserToken = $null
            $script:PprcCachedUserLogin = $null
        }

        Context 'Get-GitHubToken' {
            It 'throws actionable error when gh is unauthenticated' {
                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq '--version') {
                        return 'gh 2.0.0'
                    }

                    if ($Arguments[0] -eq 'auth' -and $Arguments[1] -eq 'status') {
                        throw "GitHub CLI is not authenticated for this user. Run 'gh auth login' and retry."
                    }

                    return ''
                }

                { Get-GitHubToken } | Should -Throw -ExpectedMessage "*Run 'gh auth login'*"
            }

            It 'throws when gh returns an empty token' {
                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq '--version') { return 'gh 2.0.0' }
                    if ($Arguments[0] -eq 'auth' -and $Arguments[1] -eq 'status') { return 'ok' }
                    if ($Arguments[0] -eq 'auth' -and $Arguments[1] -eq 'token') { return '   ' }
                    throw "unexpected args: $($Arguments -join ' ')"
                }

                { Get-GitHubToken } | Should -Throw -ExpectedMessage '*empty token*'
            }

            It 'writes only redacted verbose output' {
                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq '--version') { return 'gh 2.0.0' }
                    if ($Arguments[0] -eq 'auth' -and $Arguments[1] -eq 'status') { return 'ok' }
                    if ($Arguments[0] -eq 'auth' -and $Arguments[1] -eq 'token') { return 'super-secret-token' }
                    throw "unexpected args: $($Arguments -join ' ')"
                }

                Mock Write-Verbose {}

                $token = Get-GitHubToken -Verbose
                $token | Should -Be 'super-secret-token'

                Should -Invoke Write-Verbose -Times 1 -Exactly -ParameterFilter {
                    $Message -match '\[REDACTED\]' -and $Message -notmatch 'super-secret-token'
                }
            }
        }

        Context 'Get-RepoSlug parsing' {
            It 'parses SSH URLs and keeps dotted repository names' {
                $slug = Get-RepoSlug -RemoteUrl 'git@github.com:octo-org/my.repo.git'
                $slug.Owner | Should -Be 'octo-org'
                $slug.Repo | Should -Be 'my.repo'
            }

            It 'parses HTTPS URLs' {
                $slug = Get-RepoSlug -RemoteUrl 'https://github.com/octo-org/repo-name'
                $slug.Owner | Should -Be 'octo-org'
                $slug.Repo | Should -Be 'repo-name'
            }
        }

        Context 'Invoke-GitHubRest pagination and rate limits' {
            It 'follows Link rel=next pages' {
                Mock Invoke-PprcApiRequest {
                    if ([string]$Uri -match 'page=2') {
                        return [pscustomobject]@{
                            Body = @([pscustomobject]@{ id = 2 })
                            Headers = @{}
                        }
                    }

                    return [pscustomobject]@{
                        Body = @([pscustomobject]@{ id = 1 })
                        Headers = @{ Link = '<https://api.github.com/repos/o/r/pulls?page=2>; rel="next"' }
                    }
                }

                $result = Invoke-GitHubRest -Path '/repos/o/r/pulls' -Paginate -Token 't'
                @($result).Count | Should -Be 2
                @($result | ForEach-Object { [int]$_.id }) | Should -Be @(1, 2)
                Should -Invoke Invoke-PprcApiRequest -Times 2 -Exactly
            }

            It 'captures response headers via ResponseHeadersVariable in API wrapper' {
                Mock Invoke-RestMethod {
                    Set-Variable -Name 'responseHeaders' -Value @{ Link = '<https://example.test/next>; rel="next"' } -Scope 1 -ErrorAction SilentlyContinue
                    Set-Variable -Name 'responseHeaders' -Value @{ Link = '<https://example.test/next>; rel="next"' } -Scope 2 -ErrorAction SilentlyContinue
                    return [pscustomobject]@{ ok = $true }
                }

                $response = Invoke-PprcApiRequest -Method 'GET' -Uri 'https://api.github.com/repos/o/r/pulls' -Headers @{ Authorization = 'Bearer t' } -Body $null
                [bool]$response.Body.ok | Should -BeTrue
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                    $ResponseHeadersVariable -eq 'responseHeaders'
                }
            }

            It 'aborts on primary rate limit from thrown 403 headers' {
                Mock Invoke-RestMethod {
                    $ex = [System.Exception]::new('forbidden')
                    Add-Member -InputObject $ex -MemberType NoteProperty -Name Response -Value ([pscustomobject]@{
                            StatusCode = 403
                            Headers = @{
                                'X-RateLimit-Remaining' = '0'
                                'X-RateLimit-Reset' = '1718000000'
                            }
                        }) -Force
                    throw $ex
                }

                { Invoke-GitHubRest -Path '/repos/o/r/pulls' -Token 't' } | Should -Throw -ExpectedMessage '*rate limit reached*'
            }

            It 'aborts on secondary rate limit using Retry-After header' {
                Mock Invoke-RestMethod {
                    $ex = [System.Exception]::new('too many requests')
                    Add-Member -InputObject $ex -MemberType NoteProperty -Name Response -Value ([pscustomobject]@{
                            StatusCode = 429
                            Headers = @{
                                'Retry-After' = '120'
                            }
                        }) -Force
                    throw $ex
                }

                { Invoke-GitHubRest -Path '/repos/o/r/pulls' -Token 't' } | Should -Throw -ExpectedMessage '*Retry after*'
            }
        }

        Context 'Invoke-GitHubGraphQL pagination' {
            It 'paginates reviewThreads and drains nested thread comments' {
                $requests = [System.Collections.Generic.List[object]]::new()
                Mock Invoke-PprcApiRequest {
                    $requests.Add($Body)
                    if ($Body.query -match 'query \(\$owner: String!, \$repo: String!, \$number: Int!, \$first: Int!, \$after: String\)') {
                        if ($Body.variables.after) {
                            return [pscustomobject]@{
                                Body = @{
                                    errors = @()
                                    data = @{
                                        repository = @{
                                            pullRequest = @{
                                                reviewThreads = @{
                                                    nodes = @(
                                                        @{
                                                            id = 'T2'
                                                            isResolved = $true
                                                            comments = @{
                                                                nodes = @(@{ databaseId = 201 })
                                                                pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                                            }
                                                        }
                                                    )
                                                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                                }
                                            }
                                        }
                                    }
                                }
                                Headers = @{}
                            }
                        }

                        return [pscustomobject]@{
                            Body = @{
                                errors = @()
                                data = @{
                                    repository = @{
                                        pullRequest = @{
                                            reviewThreads = @{
                                                nodes = @(
                                                    @{
                                                        id = 'T1'
                                                        isResolved = $false
                                                        comments = @{
                                                            nodes = @(@{ databaseId = 101 })
                                                            pageInfo = @{ hasNextPage = $true; endCursor = 'c1' }
                                                        }
                                                    }
                                                )
                                                pageInfo = @{ hasNextPage = $true; endCursor = 't2' }
                                            }
                                        }
                                    }
                                }
                            }
                            Headers = @{}
                        }
                    }

                    if ($Body.query -match 'query \(\$threadId: ID!, \$first: Int!, \$after: String\)') {
                        return [pscustomobject]@{
                            Body = @{
                                errors = @()
                                data = @{
                                    node = @{
                                        comments = @{
                                            nodes = @(@{ databaseId = 102 })
                                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                                        }
                                    }
                                }
                            }
                            Headers = @{}
                        }
                    }

                    throw "Unexpected query: $($Body.query)"
                }

                $data = Invoke-GitHubGraphQL -Query @'
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
'@ -Variables @{ owner = 'o'; repo = 'r'; number = 1 } -PaginateReviewThreads -DrainThreadComments -Token 't'

                @($data.reviewThreads).Count | Should -Be 2
                @($data.reviewThreads[0].comments.nodes | ForEach-Object { [int]$_.databaseId }) | Should -Be @(101, 102)
                @($data.reviewThreads[1].comments.nodes | ForEach-Object { [int]$_.databaseId }) | Should -Be @(201)
            }
        }

        Context 'Resolve-TargetPr and branch safety' {
            It 'throws detached HEAD error' {
                Mock Get-PprcCurrentBranchName { throw 'detached HEAD; check out the PR branch first' }
                Mock Get-RepoSlug { [pscustomobject]@{ Owner = 'o'; Repo = 'r'; FullName = 'o/r' } }
                Mock Invoke-GitHubRest { @() }

                { Resolve-TargetPr -Token 't' } | Should -Throw -ExpectedMessage '*detached HEAD*'
            }

            It 'throws when no PR matches branch' {
                Mock Get-PprcCurrentBranchName { 'feature/a' }
                Mock Get-RepoSlug { [pscustomobject]@{ Owner = 'o'; Repo = 'r'; FullName = 'o/r' } }
                Mock Invoke-GitHubRest {
                    @(
                        [pscustomobject]@{
                            number = 10
                            head = [pscustomobject]@{
                                ref = 'other'
                                repo = [pscustomobject]@{ full_name = 'o/r' }
                            }
                            base = [pscustomobject]@{ repo = [pscustomobject]@{ full_name = 'o/r' } }
                            html_url = 'https://example/10'
                        }
                    )
                }

                { Resolve-TargetPr -Token 't' } | Should -Throw -ExpectedMessage '*No open pull request*'
            }

            It 'throws when branch has multiple open PRs' {
                Mock Get-PprcCurrentBranchName { 'feature/a' }
                Mock Get-RepoSlug { [pscustomobject]@{ Owner = 'o'; Repo = 'r'; FullName = 'o/r' } }
                Mock Invoke-GitHubRest {
                    @(
                        [pscustomobject]@{
                            number = 10
                            head = [pscustomobject]@{ ref = 'feature/a'; repo = [pscustomobject]@{ full_name = 'o/r' } }
                            base = [pscustomobject]@{ repo = [pscustomobject]@{ full_name = 'o/r' } }
                            html_url = 'https://example/10'
                        },
                        [pscustomobject]@{
                            number = 11
                            head = [pscustomobject]@{ ref = 'feature/a'; repo = [pscustomobject]@{ full_name = 'o/r' } }
                            base = [pscustomobject]@{ repo = [pscustomobject]@{ full_name = 'o/r' } }
                            html_url = 'https://example/11'
                        }
                    )
                }

                { Resolve-TargetPr -Token 't' } | Should -Throw -ExpectedMessage '*Multiple open pull requests*'
            }

            It 'marks fork PRs as cross repository and handles null head.repo' {
                Mock Get-PprcCurrentBranchName { 'feature/a' }
                Mock Get-RepoSlug { [pscustomobject]@{ Owner = 'o'; Repo = 'r'; FullName = 'o/r' } }

                Mock Invoke-GitHubRest {
                    @(
                        [pscustomobject]@{
                            number = 10
                            head = [pscustomobject]@{ ref = 'feature/a'; repo = [pscustomobject]@{ full_name = 'contrib/r' } }
                            base = [pscustomobject]@{ repo = [pscustomobject]@{ full_name = 'o/r' } }
                            html_url = 'https://example/10'
                        }
                    )
                }
                $target = Resolve-TargetPr -Token 't'
                $target.IsCrossRepository | Should -BeTrue

                Mock Invoke-GitHubRest {
                    @(
                        [pscustomobject]@{
                            number = 10
                            head = [pscustomobject]@{ ref = 'feature/a'; repo = $null }
                            base = [pscustomobject]@{ repo = [pscustomobject]@{ full_name = 'o/r' } }
                            html_url = 'https://example/10'
                        }
                    )
                }
                { Resolve-TargetPr -Token 't' } | Should -Throw -ExpectedMessage '*no head repository metadata*'
            }

            It 'refuses branch mismatch and passes when branch matches' {
                $targetPr = [pscustomobject]@{
                    Number = 20
                    HeadFullName = 'o/r'
                    BaseFullName = 'o/r'
                    IsCrossRepository = $false
                    HeadRefName = 'feature/a'
                }

                Mock Get-PprcCurrentBranchName { 'feature/b' }
                { Test-BranchSafety -TargetPr $targetPr } | Should -Throw -ExpectedMessage '*does not match PR head*'

                Mock Get-PprcCurrentBranchName { 'feature/a' }
                (Test-BranchSafety -TargetPr $targetPr) | Should -BeTrue
            }

            It 'refuses automated changes when pre-existing dirty worktree entries exist' {
                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq '--no-pager' -and $Arguments[1] -eq 'status' -and $Arguments[2] -eq '--porcelain') {
                        return "M src/file.ps1`n?? tests/new.ps1"
                    }

                    throw "Unexpected native call: $($Arguments -join ' ')"
                }

                { Assert-PprcCleanWorktree } | Should -Throw -ExpectedMessage '*pre-existing uncommitted changes*'

                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq '--no-pager' -and $Arguments[1] -eq 'status' -and $Arguments[2] -eq '--porcelain') {
                        return ''
                    }

                    throw "Unexpected native call: $($Arguments -join ' ')"
                }
                (Assert-PprcCleanWorktree) | Should -BeTrue
            }
        }

        Context 'Get-PrReviewThreads joins unresolved threads by root comment' {
            It 'returns unresolved thread roots and summary comments and handles reply items' {
                $targetPr = [pscustomobject]@{ Number = 3; BaseFullName = 'o/r' }
                Mock Invoke-GitHubGraphQL {
                    [pscustomobject]@{
                        reviewThreads = @(
                            [pscustomobject]@{
                                id = 'thread-a'
                                isResolved = $false
                                comments = [pscustomobject]@{
                                    nodes = @(
                                        [pscustomobject]@{ databaseId = 1001 },
                                        [pscustomobject]@{ databaseId = 1002 }
                                    )
                                }
                            },
                            [pscustomobject]@{
                                id = 'thread-b'
                                isResolved = $true
                                comments = [pscustomobject]@{
                                    nodes = @(
                                        [pscustomobject]@{ databaseId = 2001 }
                                    )
                                }
                            }
                        )
                    }
                }

                Mock Invoke-GitHubRest {
                    if ($Path -like '*/comments') {
                        return @(
                            [pscustomobject]@{
                                id = 1001
                                in_reply_to_id = $null
                                path = 'src/a.ps1'
                                line = 10
                                body = 'root'
                                user = [pscustomobject]@{ login = 'reviewer' }
                            },
                            [pscustomobject]@{
                                id = 1002
                                in_reply_to_id = 1001
                                path = 'src/a.ps1'
                                line = 11
                                body = 'reply'
                                user = [pscustomobject]@{ login = 'reviewer' }
                            },
                            [pscustomobject]@{
                                id = 2001
                                in_reply_to_id = $null
                                path = 'src/b.ps1'
                                line = 2
                                body = 'resolved root'
                                user = [pscustomobject]@{ login = 'reviewer' }
                            }
                        )
                    }

                    return @(
                        [pscustomobject]@{
                            id = 55
                            state = 'COMMENTED'
                            body = 'summary text'
                            user = [pscustomobject]@{ login = 'reviewer' }
                        }
                    )
                }

                $result = Get-PrReviewThreads -TargetPr $targetPr -Token 't'
                $result.Keys | Should -Contain '1001'
                $result.Keys | Should -Contain 'summary-55'
                $result.Keys | Should -Not -Contain '2001'
                $result['1001'].rootId | Should -Be 1001
                $result['1001'].kind | Should -Be 'inline'
                $result['summary-55'].kind | Should -Be 'summary'
            }

            It 'returns clean no-op shape when there are no threads or summaries' {
                $targetPr = [pscustomobject]@{ Number = 4; BaseFullName = 'o/r' }
                Mock Invoke-GitHubGraphQL { [pscustomobject]@{ reviewThreads = @() } }
                Mock Invoke-GitHubRest { @() }

                $result = Get-PrReviewThreads -TargetPr $targetPr -Token 't'
                $result.Keys.Count | Should -Be 0
            }

            It 'throws when unresolved thread has no root comment candidate' {
                $targetPr = [pscustomobject]@{ Number = 4; BaseFullName = 'o/r' }
                Mock Invoke-GitHubGraphQL {
                    [pscustomobject]@{
                        reviewThreads = @(
                            [pscustomobject]@{
                                id = 'thread-a'
                                isResolved = $false
                                comments = [pscustomobject]@{
                                    nodes = @([pscustomobject]@{ databaseId = 3002 })
                                }
                            }
                        )
                    }
                }
                Mock Invoke-GitHubRest {
                    if ($Path -like '*/comments') {
                        return @(
                            [pscustomobject]@{
                                id = 3002
                                in_reply_to_id = 3001
                                path = 'src/a.ps1'
                                line = 10
                                body = 'reply-only'
                                user = [pscustomobject]@{ login = 'reviewer' }
                            }
                        )
                    }

                    return @()
                }

                { Get-PrReviewThreads -TargetPr $targetPr -Token 't' } | Should -Throw -ExpectedMessage '*Unable to determine root comment*'
            }
        }

        Context 'Invoke-PrPush and Add-PrReply behavior' {
            It 'uses explicit refspec, enforces remote matching and reports non-fast-forward' {
                $targetPr = [pscustomobject]@{
                    Number = 5
                    BaseFullName = 'o/r'
                    HeadRefName = 'feature/a'
                    HeadFullName = 'o/r'
                    IsCrossRepository = $false
                }

                Mock Get-PprcCurrentBranchName { 'feature/a' }
                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq 'remote' -and $Arguments.Count -eq 1) {
                        return "origin`nupstream"
                    }
                    if ($Arguments[0] -eq 'remote' -and $Arguments[1] -eq 'get-url') {
                        if ($Arguments[-1] -eq 'origin') { return 'https://github.com/o/r.git' }
                        if ($Arguments[-1] -eq 'upstream') { return 'https://github.com/other/repo.git' }
                    }
                    if ($Arguments[0] -eq 'push') {
                        return 'ok'
                    }
                    throw "Unexpected native call: $($Arguments -join ' ')"
                }

                $push = Invoke-PrPush -TargetPr $targetPr
                $push.RefSpec | Should -Be 'HEAD:refs/heads/feature/a'
                Should -Invoke Invoke-PprcNativeCommand -Times 1 -ParameterFilter {
                    $Arguments[0] -eq 'push' -and $Arguments[1] -eq 'origin' -and $Arguments[2] -eq 'HEAD:refs/heads/feature/a'
                }

                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq 'remote' -and $Arguments.Count -eq 1) { return 'origin' }
                    if ($Arguments[0] -eq 'remote' -and $Arguments[1] -eq 'get-url') { return 'https://github.com/o/r.git' }
                    if ($Arguments[0] -eq 'push') { throw 'non-fast-forward update rejected' }
                    throw "Unexpected native call: $($Arguments -join ' ')"
                }
                { Invoke-PrPush -TargetPr $targetPr } | Should -Throw -ExpectedMessage "*git pull --rebase*"
            }

            It 'errors for zero and multiple matching push remotes' {
                $targetPr = [pscustomobject]@{
                    Number = 5
                    BaseFullName = 'o/r'
                    HeadRefName = 'feature/a'
                    HeadFullName = 'o/r'
                    IsCrossRepository = $false
                }
                Mock Get-PprcCurrentBranchName { 'feature/a' }

                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq 'remote' -and $Arguments.Count -eq 1) { return "origin`nbackup" }
                    if ($Arguments[0] -eq 'remote' -and $Arguments[1] -eq 'get-url') { return 'https://github.com/x/y.git' }
                    throw "Unexpected native call: $($Arguments -join ' ')"
                }
                { Invoke-PrPush -TargetPr $targetPr } | Should -Throw -ExpectedMessage "*No remote points at 'o/r'*"

                Mock Invoke-PprcNativeCommand {
                    if ($Arguments[0] -eq 'remote' -and $Arguments.Count -eq 1) { return "first`nsecond" }
                    if ($Arguments[0] -eq 'remote' -and $Arguments[1] -eq 'get-url') { return 'https://github.com/o/r.git' }
                    throw "Unexpected native call: $($Arguments -join ' ')"
                }
                { Invoke-PrPush -TargetPr $targetPr } | Should -Throw -ExpectedMessage '*Ambiguous remotes*'
            }

            It 'posts inline replies with in_reply_to and dedups by marker only for matching thread key' {
                $targetPr = [pscustomobject]@{ Number = 9; BaseFullName = 'o/r' }
                $thread = [pscustomobject]@{ rootId = '321'; kind = 'inline' }
                $calls = [System.Collections.Generic.List[hashtable]]::new()

                Mock Invoke-GitHubRest {
                    $record = @{
                        Path = $Path
                        Method = $Method
                        Query = $Query
                        Body = $Body
                    }
                    $calls.Add($record)

                    if ($Method -eq 'POST') {
                        return [pscustomobject]@{ id = 9991 }
                    }

                    return @(
                        [pscustomobject]@{
                            id = 88
                            body = "quoted reviewer text <!-- pprc:thread:999 -->"
                            user = [pscustomobject]@{ login = 'me' }
                        }
                    )
                }

                $reply = Add-PrReply -TargetPr $targetPr -Thread $thread -Body 'Done' -Token 't' -UserLogin 'me'
                $reply.Posted | Should -BeTrue
                $reply.AlreadyHandled | Should -BeFalse
                $reply.CommentId | Should -Be 9991
                $postCall = $calls | Where-Object { $_.Method -eq 'POST' } | Select-Object -First 1
                [int]$postCall.Body.in_reply_to | Should -Be 321
                [string]$postCall.Body.body | Should -Match '<!-- pprc:thread:321 -->'
            }

            It 'dedups inline replies when marker already exists for the same thread key' {
                $targetPr = [pscustomobject]@{ Number = 9; BaseFullName = 'o/r' }
                $thread = [pscustomobject]@{ rootId = '321'; kind = 'inline' }

                Mock Invoke-GitHubRest {
                    $resolvedMethod = if ([string]::IsNullOrWhiteSpace([string]$Method)) { 'GET' } else { [string]$Method }
                    if ($resolvedMethod -eq 'GET') {
                        return @(
                            [pscustomobject]@{
                                id = 912
                                body = "already handled`n`n<!-- pprc:thread:321 -->"
                                user = [pscustomobject]@{ login = 'me' }
                            }
                        )
                    }

                    throw "Unexpected POST for dedup case: $Path"
                }

                $reply = Add-PrReply -TargetPr $targetPr -Thread $thread -Body 'Done' -Token 't' -UserLogin 'me'
                $reply.Posted | Should -BeFalse
                $reply.AlreadyHandled | Should -BeTrue
                $reply.CommentId | Should -Be 912
            }

            It 'posts summary replies as issue comments and dedups existing markers' {
                $targetPr = [pscustomobject]@{ Number = 10; BaseFullName = 'o/r' }
                $thread = [pscustomobject]@{ rootId = 'summary-44'; kind = 'summary' }

                Mock Invoke-GitHubRest {
                    $resolvedMethod = if ([string]::IsNullOrWhiteSpace([string]$Method)) { 'GET' } else { [string]$Method }
                    if ($Path -like '*/issues/*/comments' -and $resolvedMethod -eq 'GET') {
                        return @(
                            [pscustomobject]@{
                                id = 501
                                body = "Already done`n`n<!-- pprc:thread:summary-44 -->"
                                user = [pscustomobject]@{ login = 'me' }
                            }
                        )
                    }

                    throw "Unexpected call for dedup scenario: $resolvedMethod $Path"
                }

                $dedup = Add-PrReply -TargetPr $targetPr -Thread $thread -Body 'Body' -Token 't' -UserLogin 'me'
                $dedup.Posted | Should -BeFalse
                $dedup.AlreadyHandled | Should -BeTrue
                $dedup.CommentId | Should -Be 501

                Mock Invoke-GitHubRest {
                    $resolvedMethod = if ([string]::IsNullOrWhiteSpace([string]$Method)) { 'GET' } else { [string]$Method }
                    if ($Path -like '*/issues/*/comments' -and $resolvedMethod -eq 'GET') {
                        return @()
                    }
                    if ($Path -like '*/issues/*/comments' -and $resolvedMethod -eq 'POST') {
                        return [pscustomobject]@{ id = 777 }
                    }
                    throw "Unexpected call for post scenario: $resolvedMethod $Path"
                }

                $posted = Add-PrReply -TargetPr $targetPr -Thread $thread -Body 'Summary body' -Token 't' -UserLogin 'me'
                $posted.Posted | Should -BeTrue
                $posted.CommentId | Should -Be 777
            }
        }
    }
}
