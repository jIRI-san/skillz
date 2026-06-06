#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'cip structural evals' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $pluginRoot = Join-Path $repoRoot 'plugins/cip'
        $manifestPath = Join-Path $pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50

        $skillEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'skills/cip/SKILL.md' })
        $skillEntries.Count | Should -Be 1
        $skillEntry = $skillEntries[0]

        $assetEntries = @($manifest.files | Where-Object { [string]$_.src -eq 'skills/cip/assets/plan-template.md' })
        $assetEntries.Count | Should -Be 1
        $assetEntry = $assetEntries[0]

        $artifactPath = Join-Path $pluginRoot 'skills/cip/SKILL.md'
        $assetPath = Join-Path $pluginRoot 'skills/cip/assets/plan-template.md'
        $destinationPath = [string]$skillEntry.dest
    }

    It 'validates skill frontmatter, required keys, and folder-name alignment' {
        $artifactType = Get-ArtifactType -DestinationPath $destinationPath
        $artifactType | Should -Be 'skill'

        $frontmatter = Get-PluginFrontmatter -Path $artifactPath
        Test-RequiredKeys -ArtifactType 'skill' -Frontmatter $frontmatter -Path $artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be 'cip'
    }

    It 'requires skill body headings and step procedure content' {
        Test-BodySection -ArtifactType 'skill' -Path $artifactPath | Should -BeTrue
    }

    It 'requires known referenced asset to exist in plugin payload' {
        $resolved = Test-ReferencedFile -BasePath $pluginRoot -RelativePath ([string]$assetEntry.src)
        [string]$resolved.Replace('\', '/') | Should -Match '/plugins/cip/skills/cip/assets/plan-template.md$'
        Test-Path -LiteralPath $assetPath -PathType Leaf | Should -BeTrue
    }

    It 'resolves internal markdown links from simulated install path' {
        $raw = Get-Content -LiteralPath $artifactPath -Raw
        $matches = [regex]::Matches($raw, '\[[^\]]+\]\((?<target>[^)]+)\)')
        @($matches).Count | Should -BeGreaterThan 0

        foreach ($match in $matches) {
            $target = [string]$match.Groups['target'].Value
            $resolved = Resolve-MarkdownLink -RepoRoot $repoRoot -ArtifactDestinationPath $destinationPath -LinkTarget $target
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
            }
        }
    }
}
