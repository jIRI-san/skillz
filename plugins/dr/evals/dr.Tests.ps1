#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'dr structural evals' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $script:repoRoot 'tests/evals/EvalCommon.psm1') -Force

        $script:pluginRoot = Join-Path $script:repoRoot 'plugins/dr'
        $manifestPath = Join-Path $script:pluginRoot 'plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
        $script:entries = @($manifest.files)
    }

    It 'covers orchestrator, subagents, and prompt artifacts with expected types' {
        $artifactSrcs = @($script:entries | Where-Object { [string]$_.src -match '\.(agent|prompt)\.md$' } | ForEach-Object { [string]$_.src })
        $artifactSrcs | Should -Contain 'agents/dr.agent.md'
        $artifactSrcs | Should -Contain 'agents/dr-opus.agent.md'
        $artifactSrcs | Should -Contain 'agents/dr-codex.agent.md'
        $artifactSrcs | Should -Contain 'agents/dr-gemini.agent.md'
        $artifactSrcs | Should -Contain 'prompts/dr.prompt.md'

        foreach ($entry in @($script:entries | Where-Object { [string]$_.src -match '\.(agent|prompt)\.md$' })) {
            $src = [string]$entry.src
            $dest = [string]$entry.dest
            $path = Join-Path $script:pluginRoot ($src -replace '/', [System.IO.Path]::DirectorySeparatorChar)

            $artifactType = Get-ArtifactType -DestinationPath $dest
            if ($src.EndsWith('.agent.md', [System.StringComparison]::OrdinalIgnoreCase)) {
                $artifactType | Should -Be 'agent'
            }
            elseif ($src.EndsWith('.prompt.md', [System.StringComparison]::OrdinalIgnoreCase)) {
                $artifactType | Should -Be 'prompt'
            }

            $frontmatter = Get-PluginFrontmatter -Path $path
            Test-RequiredFrontmatter -ArtifactType $artifactType -Frontmatter $frontmatter -Path $path | Should -BeTrue

            $expectedName = if ($artifactType -eq 'agent') {
                [System.IO.Path]::GetFileName($src) -replace '\.agent\.md$', ''
            }
            else {
                [System.IO.Path]::GetFileName($src) -replace '\.prompt\.md$', ''
            }
            [string]$frontmatter.name | Should -Be $expectedName
            Test-BodySection -ArtifactType $artifactType -Path $path | Should -BeTrue
        }
    }

    It 'resolves markdown links across the bundle when link targets are real repo paths' {
        $markdownEntries = @($script:entries | Where-Object { [string]$_.src -match '\.(agent|prompt)\.md$' })
        $resolvedDesignNotePaths = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $markdownEntries) {
            $path = Join-Path $script:pluginRoot (([string]$entry.src) -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $raw = Get-Content -LiteralPath $path -Raw
            $linkMatches = [regex]::Matches($raw, '\[[^\]]+\]\((?<target>[^)]+)\)')

            foreach ($match in $linkMatches) {
                $target = [string]$match.Groups['target'].Value
                if ($target -match '^src/path/') {
                    continue
                }

                $resolved = Resolve-MarkdownLink -RepoRoot $script:repoRoot -ArtifactDestinationPath ([string]$entry.dest) -LinkTarget $target
                if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                    Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
                }
            }

            $designNoteMatches = [regex]::Matches($raw, '(?<path>docs/design-notes/[A-Za-z0-9._\-/]+\.md)')
            foreach ($designNoteMatch in $designNoteMatches) {
                $designNotePath = [string]$designNoteMatch.Groups['path'].Value
                $resolved = Resolve-MarkdownLink -RepoRoot $script:repoRoot -ArtifactDestinationPath ([string]$entry.dest) -LinkTarget ('/' + $designNotePath)
                Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
                $resolvedDesignNotePaths.Add(([string]$resolved).Replace('\', '/'))
            }
        }

        @($resolvedDesignNotePaths | Sort-Object -Unique).Count | Should -BeGreaterThan 0
    }
}
