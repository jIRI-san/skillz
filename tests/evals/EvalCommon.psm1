#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PluginFrontmatter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Frontmatter source file not found: $Path"
    }

    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -lt 3 -or [string]$lines[0] -ne '---') {
        throw "File '$Path' must start with a frontmatter delimiter '---'."
    }

    $closingDelimiterLine = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ([string]$lines[$index] -eq '---') {
            $closingDelimiterLine = $index
            break
        }
    }

    if ($closingDelimiterLine -lt 0) {
        throw "File '$Path' has an unterminated frontmatter block."
    }

    $frontmatter = [ordered]@{}
    for ($index = 1; $index -lt $closingDelimiterLine; $index++) {
        $line = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^\s*#') {
            continue
        }

        if ($line -match '^(?<key>[A-Za-z][\w-]*)\s*:\s*(?<value>.*)$') {
            $key = [string]$Matches.key
            $rawValue = [string]$Matches.value
            $trimmedValue = $rawValue.Trim()

            if ([string]::IsNullOrWhiteSpace($trimmedValue)) {
                $frontmatter[$key] = $null
                continue
            }

            if (($trimmedValue.StartsWith("'") -and $trimmedValue.EndsWith("'")) -or
                ($trimmedValue.StartsWith('"') -and $trimmedValue.EndsWith('"'))) {
                $frontmatter[$key] = $trimmedValue.Substring(1, $trimmedValue.Length - 2)
                continue
            }

            # Keep nested/complex YAML values opaque; only scalar presence/value is needed.
            if ($trimmedValue.StartsWith('[') -or $trimmedValue.StartsWith('{') -or
                $trimmedValue -eq '|' -or $trimmedValue -eq '>') {
                $frontmatter[$key] = $null
                continue
            }

            $frontmatter[$key] = $trimmedValue
            continue
        }

        if ($line -match '^\s+') {
            continue
        }

        throw "File '$Path' has malformed frontmatter line $($index + 1): '$line'"
    }

    if ($frontmatter.Count -eq 0) {
        throw "File '$Path' frontmatter has no top-level keys."
    }

    return $frontmatter
}

function Test-RequiredKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('agent', 'prompt', 'skill')]
        [string]$ArtifactType,

        [Parameter(Mandatory)]
        [hashtable]$Frontmatter,

        [string]$Path = '<unknown>'
    )

    $requiredKeysByType = @{
        agent = @('name', 'description')
        prompt = @('name', 'description', 'agent')
        skill = @('name', 'description', 'user-invocable', 'disable-model-invocation')
    }

    foreach ($key in $requiredKeysByType[$ArtifactType]) {
        if (-not $Frontmatter.ContainsKey($key)) {
            throw "File '$Path' ($ArtifactType) is missing required frontmatter key '$key'."
        }

        $value = [string]$Frontmatter[$key]
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "File '$Path' ($ArtifactType) has empty required frontmatter key '$key'."
        }
    }

    return $true
}

function Get-ArtifactType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $normalizedPath = ($DestinationPath -replace '\\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        throw 'Destination path is empty.'
    }

    if ($normalizedPath.EndsWith('.agent.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'agent'
    }

    if ($normalizedPath.EndsWith('.prompt.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'prompt'
    }

    if ($normalizedPath.EndsWith('/SKILL.md', [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.Equals('SKILL.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'skill'
    }

    throw "Unsupported artifact destination path '$DestinationPath'."
}

function Test-ReferencedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "Referenced path is empty (base '$BasePath')."
    }

    $normalizedBasePath = [System.IO.Path]::GetFullPath($BasePath)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $normalizedBasePath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $baseWithSeparator = $normalizedBasePath.TrimEnd($separator) + $separator

    if (-not $candidate.StartsWith($baseWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Referenced path '$RelativePath' escapes base path '$BasePath'."
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Referenced path not found: $candidate"
    }

    return $candidate
}

function Resolve-MarkdownLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$ArtifactDestinationPath,

        [Parameter(Mandatory)]
        [string]$LinkTarget
    )

    $trimmedTarget = $LinkTarget.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedTarget)) {
        return $null
    }

    if ($trimmedTarget.StartsWith('#')) {
        return $null
    }

    if ($trimmedTarget -match '^(https?://|mailto:)') {
        return $null
    }

    $targetWithoutFragment = $trimmedTarget
    $fragmentDelimiter = $trimmedTarget.IndexOf('#')
    if ($fragmentDelimiter -ge 0) {
        $targetWithoutFragment = $trimmedTarget.Substring(0, $fragmentDelimiter)
    }

    if ([string]::IsNullOrWhiteSpace($targetWithoutFragment)) {
        return $null
    }

    $repoRootPath = [System.IO.Path]::GetFullPath($RepoRoot)
    $artifactInstallPath = [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $repoRootPath '.github') ($ArtifactDestinationPath -replace '/', [System.IO.Path]::DirectorySeparatorChar))
    )
    $artifactInstallDirectory = Split-Path -Parent $artifactInstallPath

    $normalizedTarget = $targetWithoutFragment -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $candidate = if ($targetWithoutFragment.StartsWith('/')) {
        [System.IO.Path]::GetFullPath((Join-Path $repoRootPath $normalizedTarget.TrimStart('\', '/')))
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $artifactInstallDirectory $normalizedTarget))
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $repoWithSeparator = $repoRootPath.TrimEnd($separator) + $separator
    if (-not $candidate.StartsWith($repoWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Markdown link '$LinkTarget' resolves outside repo root '$RepoRoot'."
    }

    if (-not (Test-Path -LiteralPath $candidate)) {
        throw "Markdown link target not found: '$LinkTarget' -> $candidate"
    }

    return $candidate
}

function Test-BodySection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('agent', 'prompt', 'skill')]
        [string]$ArtifactType,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Artifact file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    $body = $raw -replace '(?s)^---\r?\n.*?\r?\n---\r?\n?', ''
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw "File '$Path' has an empty markdown body."
    }

    $hasHeading = [regex]::IsMatch($body, '(?m)^\s*#{1,6}\s+\S')
    if (-not $hasHeading) {
        throw "File '$Path' must contain at least one markdown heading."
    }

    if ($ArtifactType -eq 'agent') {
        $nonHeadingBody = ($body -split "`r?`n" | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^\s*#{1,6}\s+'
            })
        if (@($nonHeadingBody).Count -eq 0) {
            throw "Agent file '$Path' must contain non-heading body content."
        }

        return $true
    }

    $hasProcedure = [regex]::IsMatch($body, '(?mi)^\s*\d+\.\s+\S') -or
        [regex]::IsMatch($body, '(?mi)^\s*##\s*step\b')
    if (-not $hasProcedure) {
        throw "File '$Path' ($ArtifactType) must include a numbered or step-style procedure."
    }

    return $true
}

Export-ModuleMember -Function @(
    'Get-PluginFrontmatter',
    'Test-RequiredKeys',
    'Get-ArtifactType',
    'Test-ReferencedFile',
    'Resolve-MarkdownLink',
    'Test-BodySection'
)
