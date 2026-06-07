#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'cip structural evals' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $script:repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $pluginRoot = Join-Path $script:repoRoot 'plugins/create-implementation-plan'
        $manifestPath = Join-Path $pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50

        $skillEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'skills/cip/SKILL.md' })
        $skillEntries.Count | Should -Be 1
        $script:skillEntry = $skillEntries[0]

        $assetEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'skills/cip/assets/plan-template.md' })
        $assetEntries.Count | Should -Be 1
        $script:assetEntry = $assetEntries[0]

        $script:artifactPath = Join-Path $pluginRoot 'skills/cip/SKILL.md'
        $script:assetPath = Join-Path $pluginRoot 'skills/cip/assets/plan-template.md'
        $script:destinationPath = [string]$script:skillEntry.dest
    }

    It 'validates skill frontmatter, required keys, and folder-name alignment' {
        $artifactType = Get-ArtifactType -DestinationPath $script:destinationPath
        $artifactType | Should -Be 'skill'

        $frontmatter = Get-PluginFrontmatter -Path $script:artifactPath
        Test-RequiredFrontmatter -ArtifactType 'skill' -Frontmatter $frontmatter -Path $script:artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be 'cip'
    }

    It 'requires skill body headings and step procedure content' {
        Test-BodySection -ArtifactType 'skill' -Path $script:artifactPath | Should -BeTrue
    }

    It 'requires known referenced asset to exist in plugin payload' {
        $resolved = Test-ReferencedFile -BasePath $pluginRoot -RelativePath ([string]$script:assetEntry.src)
        [string]$resolved.Replace('\', '/') | Should -Match '/plugins/create-implementation-plan/skills/cip/assets/plan-template.md$'
        Test-Path -LiteralPath $script:assetPath -PathType Leaf | Should -BeTrue
    }

    It 'resolves internal markdown links from simulated install path' {
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
