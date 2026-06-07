#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'pprc structural evals' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $script:repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $pluginRoot = Join-Path $script:repoRoot 'plugins/process-pr-comments'
        $manifestPath = Join-Path $pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50

        $skillEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'skills/process-pr-comments/SKILL.md' })
        $skillEntries.Count | Should -Be 1
        $script:skillEntry = $skillEntries[0]

        $assetEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'skills/process-pr-comments/scripts/GitHubPr.psm1' })
        $assetEntries.Count | Should -Be 1
        $script:assetEntry = $assetEntries[0]

        $script:pluginRoot = $pluginRoot
        $script:artifactPath = Join-Path $pluginRoot 'skills/process-pr-comments/SKILL.md'
        $script:assetPath = Join-Path $pluginRoot 'skills/process-pr-comments/scripts/GitHubPr.psm1'
        $script:destinationPath = [string]$script:skillEntry.dest
    }

    It 'validates skill frontmatter, required keys, and folder-name alignment' {
        $artifactType = Get-ArtifactType -DestinationPath $script:destinationPath
        $artifactType | Should -Be 'skill'

        $frontmatter = Get-PluginFrontmatter -Path $script:artifactPath
        Test-RequiredFrontmatter -ArtifactType 'skill' -Frontmatter $frontmatter -Path $script:artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be 'process-pr-comments'
    }

    It 'requires skill body headings and step procedure content' {
        Test-BodySection -ArtifactType 'skill' -Path $script:artifactPath | Should -BeTrue
    }

    It 'requires the referenced GitHubPr module to exist in plugin payload' {
        $resolved = Test-ReferencedFile -BasePath $script:pluginRoot -RelativePath ([string]$script:assetEntry.src)
        [string]$resolved.Replace('\', '/') | Should -Match '/plugins/process-pr-comments/skills/process-pr-comments/scripts/GitHubPr.psm1$'
        Test-Path -LiteralPath $script:assetPath -PathType Leaf | Should -BeTrue
    }

    It 'resolves markdown links from the simulated install base' {
        $raw = Get-Content -LiteralPath $script:artifactPath -Raw
        $linkMatches = [regex]::Matches($raw, '\[[^\]]+\]\((?<target>[^)]+)\)')

        foreach ($match in $linkMatches) {
            $target = [string]$match.Groups['target'].Value
            $resolved = Resolve-MarkdownLink -RepoRoot $script:repoRoot -ArtifactDestinationPath $script:destinationPath -LinkTarget $target
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
            }
        }
    }
}
