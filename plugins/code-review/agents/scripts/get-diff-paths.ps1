# get-diff-paths.ps1
# Produces full file contents for one or more local files or folders (non-git scope).
# For folders, recursively includes all text files (excludes bin/obj/node_modules).
# Outputs: file list to stdout (--files) or file contents to stdout (--diff, default).
#
# Usage:
#   .\get-diff-paths.ps1 --files "src/Foo/Bar"
#   .\get-diff-paths.ps1 --diff "src/Foo/Bar/Baz.cs","src/Foo/Bar/Qux.cs"
#   .\get-diff-paths.ps1 --files "src/Foo/Bar","src/Foo/Baz/Qux.cs"

param(
    [Parameter(Mandatory, Position = 0)][string[]]$Paths,
    [switch]$Files,
    [switch]$Diff
)

$excludeDirs = @('bin', 'obj', 'node_modules', '.git', '.vs')
$textExtensions = @('.cs', '.xaml', '.json', '.xml', '.md', '.ps1', '.txt', '.yaml', '.yml', '.csproj', '.slnx', '.sln', '.props', '.targets', '.editorconfig', '.gitignore')

function Get-ResolvedFiles([string[]]$InputPaths) {
    $result = @()
    foreach ($p in $InputPaths) {
        if (Test-Path $p -PathType Container) {
            $children = Get-ChildItem -Path $p -Recurse -File | Where-Object {
                $skip = $false
                foreach ($ex in $excludeDirs) {
                    $escaped = [regex]::Escape($ex)
                    if ($_.FullName -match "(\\|/)$escaped(\\|/)") { $skip = $true; break }
                }
                (-not $skip) -and ($textExtensions -contains $_.Extension.ToLower())
            }
            $result += $children | ForEach-Object { $_.FullName }
        } elseif (Test-Path $p -PathType Leaf) {
            $result += (Resolve-Path $p).Path
        } else {
            Write-Warning "Path not found: $p"
        }
    }
    return $result | Sort-Object -Unique
}

$resolvedFiles = Get-ResolvedFiles $Paths

if ($Files) {
    # Output workspace-relative paths
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if ($repoRoot) { $repoRoot = $repoRoot.Replace('/', '\') }
    foreach ($f in $resolvedFiles) {
        if ($repoRoot -and $f.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $f.Substring($repoRoot.Length).TrimStart('\', '/')
            $rel
        } else {
            $f
        }
    }
} else {
    # Output file contents in a diff-like format
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if ($repoRoot) { $repoRoot = $repoRoot.Replace('/', '\') }
    foreach ($f in $resolvedFiles) {
        if ($repoRoot -and $f.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $f.Substring($repoRoot.Length).TrimStart('\', '/')
        } else {
            $rel = $f
        }
        Write-Output "=== $rel ==="
        Get-Content -Path $f -Raw
        Write-Output ""
    }
}
