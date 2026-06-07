#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'design-notes structural evals' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $script:repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $script:pluginRoot = Join-Path $script:repoRoot 'plugins/design-notes'
        $manifestPath = Join-Path $script:pluginRoot 'plugin.json'
        $script:manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
    }

    It 'validates each prompt: frontmatter, name slug, body, and link resolution' -TestCases @(
        @{ Src = 'prompts/design-notes.prompt.md'; Slug = 'design-notes' }
        @{ Src = 'prompts/cdn.prompt.md'; Slug = 'cdn' }
        @{ Src = 'prompts/udn.prompt.md'; Slug = 'udn' }
    ) {
        param($Src, $Slug)

        $entries = @($script:manifest.files | Where-Object { [string]$_.src -eq $Src })
        $entries.Count | Should -Be 1
        $destinationPath = [string]$entries[0].dest
        $artifactPath = Join-Path $script:pluginRoot $Src

        Get-ArtifactType -DestinationPath $destinationPath | Should -Be 'prompt'

        $frontmatter = Get-PluginFrontmatter -Path $artifactPath
        Test-RequiredFrontmatter -ArtifactType 'prompt' -Frontmatter $frontmatter -Path $artifactPath | Should -BeTrue
        [string]$frontmatter.name | Should -Be $Slug

        Test-BodySection -ArtifactType 'prompt' -Path $artifactPath | Should -BeTrue

        $raw = Get-Content -LiteralPath $artifactPath -Raw
        $linkMatches = [regex]::Matches($raw, '\[[^\]]+\]\((?<target>[^)]+)\)')
        @($linkMatches).Count | Should -BeGreaterThan 0

        $resolvedTargets = [System.Collections.Generic.List[string]]::new()
        foreach ($match in $linkMatches) {
            $target = [string]$match.Groups['target'].Value
            $resolved = Resolve-MarkdownLink -RepoRoot $script:repoRoot -ArtifactDestinationPath $destinationPath -LinkTarget $target
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
                $resolvedTargets.Add(([string]$resolved).Replace('\', '/'))
            }
        }

        @($resolvedTargets | Where-Object { $_ -match '/docs/design-notes/' }).Count | Should -BeGreaterThan 0
    }

    It 'ships both bootstrap template assets as payload files' -TestCases @(
        @{ Src = 'prompts/design-notes/templates/design-notes-index.template.md' }
        @{ Src = 'prompts/design-notes/templates/design-note-writing-style.template.md' }
    ) {
        param($Src)

        $entries = @($script:manifest.files | Where-Object { [string]$_.src -eq $Src })
        $entries.Count | Should -Be 1

        $resolved = Test-ReferencedFile -BasePath $script:pluginRoot -RelativePath $Src
        [string]$resolved.Replace('\', '/') | Should -Match ([regex]::Escape($Src) + '$')
        Test-Path -LiteralPath (Join-Path $script:pluginRoot $Src) -PathType Leaf | Should -BeTrue
    }
}
