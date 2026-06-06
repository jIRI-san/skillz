#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'ci structural evals' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $pluginRoot = Join-Path $repoRoot 'plugins/ci'
        $manifestPath = Join-Path $pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
        $skillEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'skills/ci/SKILL.md' })
        $skillEntries.Count | Should -Be 1

        $artifactPath = Join-Path $pluginRoot 'skills/ci/SKILL.md'
        $destinationPath = [string]$skillEntries[0].dest
    }

    It 'validates skill frontmatter, required keys, and folder-name alignment' {
        $artifactType = Get-ArtifactType -DestinationPath $destinationPath
        $artifactType | Should -Be 'skill'

        $frontmatter = Get-PluginFrontmatter -Path $artifactPath
        Test-RequiredKeys -ArtifactType 'skill' -Frontmatter $frontmatter -Path $artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be 'ci'
    }

    It 'requires skill body headings and step procedure content' {
        Test-BodySection -ArtifactType 'skill' -Path $artifactPath | Should -BeTrue
    }

    It 'resolves markdown links from the simulated install base' {
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
