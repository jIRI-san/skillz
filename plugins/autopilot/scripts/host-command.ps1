Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HostCommandType {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        '.bat' { return 'bat' }
        '.cmd' { return 'cmd' }
        '.ps1' { return 'ps1' }
        default { return 'exe' }
    }
}

function Test-UnsafeShellToken {
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    # Reject shell metacharacters across all launch types.
    $unsafePattern = '[;&|$`<>\r\n]'
    return $Token -match $unsafePattern
}

function Test-UnsafeCmdToken {
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    # Additional cmd.exe-sensitive metacharacters for bat/cmd launch paths.
    $unsafePattern = '[%\^(),!]'
    return $Token -match $unsafePattern
}

function Resolve-HostCommandPath {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw "Invalid .autopilot.host.json: 'command' must be a non-empty string."
    }

    if ([System.IO.Path]::IsPathRooted($Command)) {
        if (-not (Test-Path -LiteralPath $Command)) {
            throw "Configured host command path not found: $Command"
        }
        return (Resolve-Path -LiteralPath $Command -ErrorAction Stop).Path
    }

    $cmd = Get-Command -Name $Command -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cmd) {
        throw "Configured host command '$Command' was not found in PATH."
    }
    return $cmd.Source
}

function Resolve-HostCommand {
    $repoRoot = (git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if (-not $repoRoot) {
        throw "Failed to resolve repository root via 'git rev-parse --show-toplevel'."
    }
    $repoRoot = $repoRoot.Trim()
    $configPath = Join-Path $repoRoot '.autopilot.host.json'

    if (-not (Test-Path -LiteralPath $configPath)) {
        $defaultPath = Resolve-HostCommandPath -Command 'copilot'
        return @{
            Path      = $defaultPath
            Type      = Get-HostCommandType -Path $defaultPath
            ExtraArgs = @()
        }
    }

    $rawConfig = Get-Content -LiteralPath $configPath -Raw
    try {
        $config = $rawConfig | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON in $configPath. Fix the file or remove it. Inner error: $($_.Exception.Message)"
    }

    if ($null -eq $config -or -not ($config.PSObject.Properties.Name -contains 'command')) {
        throw "Invalid ${configPath}: missing required property 'command'."
    }
    if ($config.command -isnot [string] -or [string]::IsNullOrWhiteSpace($config.command)) {
        throw "Invalid ${configPath}: 'command' must be a non-empty string."
    }
    if (Test-UnsafeShellToken -Token $config.command) {
        throw "Invalid ${configPath}: 'command' contains disallowed shell metacharacters."
    }

    $extraArgs = @()
    if ($config.PSObject.Properties.Name -contains 'args') {
        if ($null -eq $config.args) {
            $extraArgs = @()
        }
        elseif ($config.args -is [System.Array]) {
            foreach ($arg in $config.args) {
                if ($arg -isnot [string]) {
                    throw "Invalid ${configPath}: every value in 'args' must be a string."
                }
                if (Test-UnsafeShellToken -Token $arg) {
                    throw "Invalid ${configPath}: 'args' contains disallowed shell metacharacters."
                }
            }
            $extraArgs = @($config.args)
        }
        else {
            throw "Invalid ${configPath}: 'args' must be an array of strings."
        }
    }

    $resolvedPath = Resolve-HostCommandPath -Command $config.command
    $resolvedType = Get-HostCommandType -Path $resolvedPath

    if ($resolvedType -eq 'bat' -or $resolvedType -eq 'cmd') {
        if (Test-UnsafeCmdToken -Token $config.command) {
            throw "Invalid ${configPath}: 'command' contains disallowed cmd.exe metacharacters."
        }
        foreach ($arg in $extraArgs) {
            if (Test-UnsafeCmdToken -Token $arg) {
                throw "Invalid ${configPath}: 'args' contains disallowed cmd.exe metacharacters."
            }
        }
    }

    return @{
        Path      = $resolvedPath
        Type      = $resolvedType
        ExtraArgs = $extraArgs
    }
}
