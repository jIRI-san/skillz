#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'autopilot structural evals' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $script:repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $pluginRoot = Join-Path $script:repoRoot 'plugins/autopilot'
        $manifestPath = Join-Path $pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
        $agentEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'agents/autopilot.agent.md' })
        $agentEntries.Count | Should -Be 1

        $script:artifactPath = Join-Path $pluginRoot 'agents/autopilot.agent.md'
        $script:destinationPath = [string]$agentEntries[0].dest
    }

    It 'validates agent frontmatter, required keys, and stem alignment' {
        $artifactType = Get-ArtifactType -DestinationPath $script:destinationPath
        $artifactType | Should -Be 'agent'

        $frontmatter = Get-PluginFrontmatter -Path $script:artifactPath
        Test-RequiredFrontmatter -ArtifactType 'agent' -Frontmatter $frontmatter -Path $script:artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be 'autopilot'
    }

    It 'requires agent body headings and non-empty non-heading content' {
        Test-BodySection -ArtifactType 'agent' -Path $script:artifactPath | Should -BeTrue
    }

    It 'resolves markdown links and design-note references when present' {
        $raw = Get-Content -LiteralPath $script:artifactPath -Raw
        $linkMatches = [regex]::Matches($raw, '\[[^\]]+\]\((?<target>[^)]+)\)')

        $resolvedTargets = [System.Collections.Generic.List[string]]::new()
        foreach ($match in $linkMatches) {
            $target = [string]$match.Groups['target'].Value
            $resolved = Resolve-MarkdownLink -RepoRoot $script:repoRoot -ArtifactDestinationPath $script:destinationPath -LinkTarget $target
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
                $resolvedTargets.Add(([string]$resolved).Replace('\', '/'))
            }
        }

        $designNoteLinksInArtifact = @($linkMatches | Where-Object { [string]$_.Groups['target'].Value -match 'docs/design-notes/' }).Count
        if ($designNoteLinksInArtifact -gt 0) {
            @($resolvedTargets | Where-Object { $_ -match '/docs/design-notes/' }).Count | Should -BeGreaterThan 0
        }
    }
}
