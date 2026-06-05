#requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the skillz autopilot orchestrators.
.DESCRIPTION
    Dot-sourced by launch.ps1 and the mode-specific orchestrators. Provides
    logging with token redaction, repo-root resolution, the trusted-command
    policy (tokenization + metacharacter/flag denylist + launcher allowlist),
    SSH->HTTPS remote conversion, an argv (no-shell) execution helper, and the
    per-phase exit-code contract constants.

    SECURITY: this file (together with schemas/autopilot.schema.json and
    launch.ps1) is the authoritative trusted-command boundary. It lives OUTSIDE
    the agent-editable .autopilot.json so an autopilot run cannot widen its own
    command policy by editing config.
#>

Set-StrictMode -Version Latest

# --- Exit-code contract (per-phase) -----------------------------------------
# 0   -> phase complete, advance to next phase
# 42  -> controlled halt to surface an @human step (NOT a failure)
# any other nonzero -> failure, stop
$script:AutopilotExit = @{
    Success = 0
    HumanHalt = 42
}

# Trusted launcher allowlist (mirrors schemas/autopilot.schema.json). Commands
# must begin with one of these executables.
$script:TrustedLaunchers = @(
    'dotnet', 'pwsh', 'powershell', 'npm', 'npx', 'node',
    'python', 'python3', 'pip', 'pytest', 'cargo', 'go',
    'make', 'ctest', 'gradle', 'mvn'
)

# Shell metacharacters that must never appear in a build/test command.
$script:CommandMetacharacters = @(';', '&', '|', '$', '`', '<', '>', '(', ')', '{', '}', '"', "'", '%')

# Sentinel file (repo-root relative) the agent writes to request an @human halt.
# A markdown agent cannot set the host process exit code, so the orchestrator
# translates this sentinel into the exit-code-42 contract.
$script:HumanHaltSentinel = '.autopilot-halt'

function Get-AutopilotExitCode {
    <#
        .SYNOPSIS
            Returns the exit-code contract constants ('Success' = 0, 'HumanHalt' = 42).
    #>
    [CmdletBinding()]
    param()
    return $script:AutopilotExit
}

function Get-HumanHaltSentinelPath {
    <#
        .SYNOPSIS
            Returns the absolute path to the @human-halt sentinel for a repo/worktree.
        .PARAMETER RepoRoot
            Absolute repo/worktree root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )
    return (Join-Path $RepoRoot $script:HumanHaltSentinel)
}

function Resolve-PhaseExitCode {
    <#
        .SYNOPSIS
            Maps a copilot CLI process exit code + halt sentinel to the contract.
        .DESCRIPTION
            Contract: 0 = phase complete (advance); 42 = @human halt (not a
            failure); any other nonzero = failure. If the sentinel file exists it
            takes precedence and yields 42; the sentinel is consumed (deleted).
        .PARAMETER RepoRoot
            Absolute repo/worktree root (where the agent runs and writes sentinel).
        .PARAMETER ProcessExitCode
            The exit code returned by the copilot CLI process.
        .OUTPUTS
            [int] one of: 0, 42, or the original nonzero process exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [int]$ProcessExitCode
    )
    $sentinel = Get-HumanHaltSentinelPath -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $sentinel -PathType Leaf) {
        $reason = (Get-Content -LiteralPath $sentinel -Raw -ErrorAction SilentlyContinue)
        Write-AutopilotLog "Human-halt sentinel found: $($reason.Trim())" -Level WARN
        Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
        return $script:AutopilotExit.HumanHalt
    }
    return $ProcessExitCode
}

function Protect-Secret {
    <#
        .SYNOPSIS
            Redacts token-shaped substrings so secrets never reach logs/transcripts.
        .PARAMETER Text
            Text to sanitize.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Text
    )
    process {
        if ([string]::IsNullOrEmpty($Text)) {
            return $Text
        }
        $patterns = @(
            'github_pat_[A-Za-z0-9_]{20,}',   # fine-grained PAT
            'gh[pousr]_[A-Za-z0-9]{20,}',     # classic PAT / OAuth / refresh / server tokens
            'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' # JWT
        )
        $result = $Text
        foreach ($p in $patterns) {
            $result = [regex]::Replace($result, $p, '***REDACTED***')
        }
        return $result
    }
}

function Write-AutopilotLog {
    <#
        .SYNOPSIS
            Writes a timestamped, secret-redacted log line to the host.
        .PARAMETER Message
            The message to log.
        .PARAMETER Level
            Severity label (INFO, WARN, ERROR).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    process {
        $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $safe = Protect-Secret -Text $Message
        $line = "[$stamp] [$Level] $safe"
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN' { Write-Host $line -ForegroundColor Yellow }
            default { Write-Host $line }
        }
    }
}

function Get-RepoRoot {
    <#
        .SYNOPSIS
            Resolves the repository root via `git rev-parse --show-toplevel`.
        .PARAMETER StartPath
            Directory to resolve from (defaults to the current location).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$StartPath = (Get-Location).Path
    )
    $top = git -C $StartPath rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($top)) {
        throw "Not inside a git repository (start: $StartPath)."
    }
    return ([System.IO.Path]::GetFullPath($top.Trim()))
}

function ConvertTo-HttpsRemoteUrl {
    <#
        .SYNOPSIS
            Converts an SSH/scp git remote URL to its HTTPS equivalent.
        .DESCRIPTION
            Handles scp form (git@host:org/repo.git), ssh:// form (with optional
            user and port), enterprise hosts, and already-HTTPS URLs (returned
            unchanged). Tokens are never embedded in the result; the GitHub CLI
            credential helper supplies HTTPS auth.
        .PARAMETER Url
            The remote URL to convert.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Url
    )
    process {
        $u = $Url.Trim()
        if ([string]::IsNullOrWhiteSpace($u)) {
            throw 'Remote URL is empty.'
        }
        # Already HTTP(S): return unchanged.
        if ($u -match '^https?://') {
            return $u
        }
        # ssh:// form: ssh://[user@]host[:port]/path
        if ($u -match '^ssh://(?:[^@/]+@)?([^:/]+)(?::\d+)?/(.+)$') {
            $remoteHost = $Matches[1]
            $path = $Matches[2]
            return "https://$remoteHost/$path"
        }
        # scp form: [user@]host:path
        if ($u -match '^(?:[^@/]+@)?([^:/]+):(.+)$') {
            $remoteHost = $Matches[1]
            $path = $Matches[2]
            return "https://$remoteHost/$path"
        }
        throw "Unrecognized remote URL form: $Url"
    }
}

function Assert-TrustedCommand {
    <#
        .SYNOPSIS
            Validates a build/test command string against the trusted-command
            policy and returns the tokenized argv (exe + args).
        .DESCRIPTION
            Authoritative enforcement (the schema is only a coarse first filter):
              * rejects shell metacharacters
              * requires a trusted launcher prefix
              * applies a flag denylist (pwsh/powershell -EncodedCommand/-e/-Command/-c,
                npx, pip install, npm install/run) that can execute arbitrary code
              * tokenizes into argv with NO shell involvement
            Because the policy forbids quotes, whitespace splitting is unambiguous.
        .PARAMETER Command
            The command string from .autopilot.json (build or test).
        .OUTPUTS
            [string[]] argv array: element 0 is the launcher, the rest are args.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw 'Command is empty.'
    }
    if ($Command -ne $Command.Trim()) {
        throw "Command has leading/trailing whitespace: '$Command'"
    }

    foreach ($mc in $script:CommandMetacharacters) {
        if ($Command.Contains($mc)) {
            throw "Command contains forbidden shell metacharacter '$mc': $Command"
        }
    }
    if ($Command -match '[\r\n\t]') {
        throw "Command contains forbidden control whitespace: $Command"
    }

    $tokens = $Command -split ' +'
    $exe = $tokens[0]
    if ($script:TrustedLaunchers -notcontains $exe) {
        throw "Command launcher '$exe' is not in the trusted allowlist."
    }

    $argline = ($tokens | Select-Object -Skip 1) -join ' '
    # Flag denylist: forms that turn a trusted launcher into an arbitrary-code engine.
    $denied = @(
        '(?i)(^|\s)-e(n(c(o(d(e(d(c(o(m(m(a(n(d)?)?)?)?)?)?)?)?)?)?)?)?)?(\s|$)', # pwsh -e / -EncodedCommand (and prefixes)
        '(?i)(^|\s)-c(o(m(m(a(n(d)?)?)?)?)?)?(\s|$)'                              # pwsh -c / -Command (and prefixes)
    )
    if ($exe -in @('pwsh', 'powershell')) {
        foreach ($d in $denied) {
            if ($argline -match $d) {
                throw "Command uses a denied PowerShell flag (inline/encoded command execution): $Command"
            }
        }
    }
    if ($exe -eq 'npx') {
        throw "Command uses 'npx' (fetches and runs arbitrary packages); not permitted."
    }
    if ($exe -eq 'pip' -and $argline -match '(?i)(^|\s)install(\s|$)') {
        throw "Command uses 'pip install' (runs arbitrary setup.py); not permitted."
    }
    if ($exe -eq 'npm' -and $argline -match '(?i)(^|\s)(install|run|exec|i)(\s|$)') {
        throw "Command uses an npm lifecycle/exec form (runs arbitrary scripts); not permitted."
    }

    return , $tokens
}

function Resolve-PlanPath {
    <#
        .SYNOPSIS
            Canonicalizes a repo-relative plan path and confines it to the repo root.
        .PARAMETER RepoRoot
            Absolute repository root.
        .PARAMETER PlanPath
            Repo-relative plan path from config.
        .OUTPUTS
            Absolute, validated path to the plan file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$PlanPath
    )
    if ($PlanPath -match '\.\.' -or $PlanPath -match '^[\\/]' -or $PlanPath -match '^[A-Za-z]:') {
        throw "planPath must be repo-relative and traversal-free: $PlanPath"
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PlanPath))
    $rootFull = [System.IO.Path]::GetFullPath($RepoRoot)
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "planPath escapes the repository root: $PlanPath"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Plan file not found: $full"
    }
    return $full
}

function Get-PlanPhase {
    <#
        .SYNOPSIS
            Parses '## Phase N' headings from a plan markdown file.
        .PARAMETER PlanFile
            Absolute path to the plan markdown.
        .OUTPUTS
            Ordered list of objects: @{ Number; Title; Line }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PlanFile
    )
    $phases = [System.Collections.Generic.List[object]]::new()
    $lineNo = 0
    foreach ($line in Get-Content -LiteralPath $PlanFile) {
        $lineNo++
        if ($line -match '^##\s+Phase\s+(\d+)\s*:?\s*(.*)$') {
            $phases.Add([pscustomobject]@{
                    Number = [int]$Matches[1]
                    Title = $Matches[2].Trim()
                    Line = $lineNo
                })
        }
    }
    return $phases
}
