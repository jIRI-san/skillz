#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'ci structural evals' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $script:repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $pluginRoot = Join-Path $script:repoRoot 'plugins/continue-implementation'
        $manifestPath = Join-Path $pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
        $skillEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'skills/ci/SKILL.md' })
        $skillEntries.Count | Should -Be 1

        $script:artifactPath = Join-Path $pluginRoot 'skills/ci/SKILL.md'
        $script:destinationPath = [string]$skillEntries[0].dest
    }

    It 'validates skill frontmatter, required keys, and folder-name alignment' {
        $artifactType = Get-ArtifactType -DestinationPath $script:destinationPath
        $artifactType | Should -Be 'skill'

        $frontmatter = Get-PluginFrontmatter -Path $script:artifactPath
        Test-RequiredFrontmatter -ArtifactType 'skill' -Frontmatter $frontmatter -Path $script:artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be 'ci'
    }

    It 'requires skill body headings and step procedure content' {
        Test-BodySection -ArtifactType 'skill' -Path $script:artifactPath | Should -BeTrue
    }

    It 'resolves markdown links from the simulated install base' {
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
