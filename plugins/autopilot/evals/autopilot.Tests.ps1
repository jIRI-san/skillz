#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'autopilot structural evals' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $pluginRoot = Join-Path $repoRoot 'plugins/autopilot'
        $manifestPath = Join-Path $pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
        $agentEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'agents/autopilot.agent.md' })
        $agentEntries.Count | Should -Be 1

        $artifactPath = Join-Path $pluginRoot 'agents/autopilot.agent.md'
        $destinationPath = [string]$agentEntries[0].dest
    }

    It 'validates agent frontmatter, required keys, and stem alignment' {
        $artifactType = Get-ArtifactType -DestinationPath $destinationPath
        $artifactType | Should -Be 'agent'

        $frontmatter = Get-PluginFrontmatter -Path $artifactPath
        Test-RequiredKeys -ArtifactType 'agent' -Frontmatter $frontmatter -Path $artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be 'autopilot'
    }

    It 'requires agent body headings and non-empty non-heading content' {
        Test-BodySection -ArtifactType 'agent' -Path $artifactPath | Should -BeTrue
    }

    It 'resolves markdown links and design-note references when present' {
        $raw = Get-Content -LiteralPath $artifactPath -Raw
        $matches = [regex]::Matches($raw, '\[[^\]]+\]\((?<target>[^)]+)\)')

        $resolvedTargets = [System.Collections.Generic.List[string]]::new()
        foreach ($match in $matches) {
            $target = [string]$match.Groups['target'].Value
            $resolved = Resolve-MarkdownLink -RepoRoot $repoRoot -ArtifactDestinationPath $destinationPath -LinkTarget $target
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
                $resolvedTargets.Add(([string]$resolved).Replace('\', '/'))
            }
        }

        $designNoteLinksInArtifact = @($matches | Where-Object { [string]$_.Groups['target'].Value -match 'docs/design-notes/' }).Count
        if ($designNoteLinksInArtifact -gt 0) {
            @($resolvedTargets | Where-Object { $_ -match '/docs/design-notes/' }).Count | Should -BeGreaterThan 0
        }
    }
}
