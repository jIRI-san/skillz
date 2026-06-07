Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Run with: Invoke-Pester ./tests/autopilot

Describe 'Resolve-HostCommand' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '../../plugins/autopilot/scripts/host-command.ps1')
    }

    BeforeEach {
        $script:RepoRoot = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $script:RepoRoot -Force | Out-Null
        $script:HostConfigPath = Join-Path $script:RepoRoot '.autopilot.host.json'

        Mock git { $script:RepoRoot }
    }

    It 'returns default copilot command when config is absent and classifies by extension' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Tools\copilot.cmd'; CommandType = 'Application' } } -ParameterFilter { $Name -eq 'copilot' }

        $result = Resolve-HostCommand

        $result.Path | Should -Be 'C:\Tools\copilot.cmd'
        $result.Type | Should -Be 'cmd'
        @($result.ExtraArgs).Count | Should -Be 0
    }

    It 'returns resolved command, type, and args from valid config' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath }
        Mock Get-Content { '{"command":"wrapper","args":["--mcp","internal"]}' } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath -and $Raw }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Tools\wrapper.ps1'; CommandType = 'ExternalScript' } } -ParameterFilter { $Name -eq 'wrapper' }

        $result = Resolve-HostCommand

        $result.Path | Should -Be 'C:\Tools\wrapper.ps1'
        $result.Type | Should -Be 'ps1'
        $result.ExtraArgs | Should -Be @('--mcp', 'internal')
    }

    It 'throws for malformed json' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath }
        Mock Get-Content { '{"command":"wrapper",' } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath -and $Raw }

        { Resolve-HostCommand } | Should -Throw '*Invalid JSON*'
    }

    It 'throws when command is empty' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath }
        Mock Get-Content { '{"command":"   ","args":[]}' } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath -and $Raw }

        { Resolve-HostCommand } | Should -Throw "*'command' must be a non-empty string*"
    }

    It 'throws when command contains disallowed metacharacters' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath }
        Mock Get-Content { '{"command":"copilot;rm","args":[]}' } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath -and $Raw }

        { Resolve-HostCommand } | Should -Throw "*'command' contains disallowed shell metacharacters*"
    }

    It 'throws when args contain disallowed metacharacters' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath }
        Mock Get-Content { '{"command":"copilot","args":["--ok","bad&arg"]}' } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath -and $Raw }

        { Resolve-HostCommand } | Should -Throw "*'args' contains disallowed shell metacharacters*"
    }

    It 'allows parentheses in exe paths after type resolution' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath }
        Mock Get-Content { '{"command":"/opt/Copilot (x86)/copilot","args":[]}' } -ParameterFilter { $LiteralPath -eq $script:HostConfigPath -and $Raw }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq '/opt/Copilot (x86)/copilot' }
        Mock Resolve-Path { [pscustomobject]@{ Path = '/opt/Copilot (x86)/copilot' } } -ParameterFilter { $LiteralPath -eq '/opt/Copilot (x86)/copilot' }

        $result = Resolve-HostCommand

        $result.Path | Should -Be '/opt/Copilot (x86)/copilot'
        $result.Type | Should -Be 'exe'
    }
}
