#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'udn structural evals' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $pluginRoot = Join-Path $repoRoot 'plugins/udn'
        $manifestPath = Join-Path $pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
        $promptEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'prompts/udn.prompt.md' })
        $promptEntries.Count | Should -Be 1

        $artifactPath = Join-Path $pluginRoot 'prompts/udn.prompt.md'
        $destinationPath = [string]$promptEntries[0].dest
    }

    It 'validates prompt frontmatter, required keys, and name slug alignment' {
        $artifactType = Get-ArtifactType -DestinationPath $destinationPath
        $artifactType | Should -Be 'prompt'

        $frontmatter = Get-PluginFrontmatter -Path $artifactPath
        Test-RequiredKeys -ArtifactType 'prompt' -Frontmatter $frontmatter -Path $artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be 'udn'
    }

    It 'requires prompt body sections/procedure content' {
        Test-BodySection -ArtifactType 'prompt' -Path $artifactPath | Should -BeTrue
    }

    It 'resolves markdown links and design-note references from simulated install path' {
        $raw = Get-Content -LiteralPath $artifactPath -Raw
        $matches = [regex]::Matches($raw, '\[[^\]]+\]\((?<target>[^)]+)\)')
        @($matches).Count | Should -BeGreaterThan 0

        $resolvedTargets = [System.Collections.Generic.List[string]]::new()
        foreach ($match in $matches) {
            $target = [string]$match.Groups['target'].Value
            $resolved = Resolve-MarkdownLink -RepoRoot $repoRoot -ArtifactDestinationPath $destinationPath -LinkTarget $target
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
                $resolvedTargets.Add(([string]$resolved).Replace('\', '/'))
            }
        }

        @($resolvedTargets | Where-Object { $_ -match '/docs/design-notes/' }).Count | Should -BeGreaterThan 0
    }
}
