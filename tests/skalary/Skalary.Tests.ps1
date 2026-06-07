#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'skalary plugin registry scripts' {
    BeforeAll {
        $projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $tempRepos = [System.Collections.Generic.List[string]]::new()

        function New-RepoClone {
            [CmdletBinding()]
            param()

            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("skalary-tests-" + [System.Guid]::NewGuid().ToString('N'))
            git clone --quiet $projectRoot $path | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to clone test fixture repository to '$path'."
            }

            git -C $path config user.name 'skalary-tests' | Out-Null
            git -C $path config user.email 'skalary-tests@example.com' | Out-Null
            git -C $path remote set-url origin 'https://github.com/jIRI-san/skalary.git' | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to configure git identity for '$path'."
            }

            # Keep fixture repos aligned with uncommitted local changes under test.
            Copy-Item -LiteralPath (Join-Path $projectRoot 'scripts/skalary') -Destination (Join-Path $path 'scripts') -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $projectRoot 'plugins') -Destination $path -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $projectRoot 'registry.json') -Destination $path -Force
            Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md') -Destination $path -Force
            git -C $path add scripts/skalary plugins registry.json README.md | Out-Null
            $staged = @(git -C $path diff --cached --name-only)
            if ($staged.Count -gt 0) {
                git -C $path commit -m 'test: sync fixture with local changes' | Out-Null
            }

            $tempRepos.Add($path)
            return $path
        }

        function Invoke-ScriptProcess {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$RepoRoot,

                [Parameter(Mandatory)]
                [string]$ScriptName,

                [string[]]$Arguments = @()
            )

            $scriptPath = Join-Path $RepoRoot "scripts/skalary/$ScriptName"
            if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                throw "Script not found: $scriptPath"
            }

            $argList = @('-NoProfile', '-File', $scriptPath, '-RepoRoot', $RepoRoot) + $Arguments
            Push-Location -LiteralPath $RepoRoot
            try {
                $lines = @(& pwsh @argList 2>&1)
            }
            finally {
                Pop-Location
            }

            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = ($lines | ForEach-Object { "$_" }) -join "`n"
            }
        }

        function Invoke-SkalaryScript {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$RepoRoot,

                [Parameter(Mandatory)]
                [string]$ScriptName,

                [hashtable]$Parameters = @{}
            )

            $scriptPath = Join-Path $RepoRoot "scripts/skalary/$ScriptName"
            Push-Location -LiteralPath $RepoRoot
            try {
                & $scriptPath -RepoRoot $RepoRoot @Parameters
            }
            finally {
                Pop-Location
            }
        }

        function New-PluginManifest {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [Parameter(Mandatory)]
                [string]$Name,

                [string[]]$Dependencies = @()
            )

            $pluginRoot = Join-Path $Root "plugins/$Name"
            $payloadRoot = Join-Path $pluginRoot 'files'
            [void](New-Item -ItemType Directory -Path $payloadRoot -Force)
            Set-Content -LiteralPath (Join-Path $payloadRoot "$Name.txt") -Value "payload-$Name" -NoNewline -Encoding utf8

            $manifest = [ordered]@{
                name = $Name
                version = '1.0.0'
                description = "test plugin $Name"
                author = 'skalary-tests'
                license = 'MIT'
                tags = @('test')
                dependencies = $Dependencies
                status = 'stable'
                files = @(
                    [ordered]@{
                        src = "files/$Name.txt"
                        dest = "test/$Name.txt"
                    }
                )
                evals = [ordered]@{
                    path = 'evals/'
                    status = 'none'
                    lastRun = $null
                }
            } | ConvertTo-Json -Depth 10

            Set-Content -LiteralPath (Join-Path $pluginRoot 'plugin.json') -Value "$manifest`n" -Encoding utf8
        }
    }

    AfterAll {
        foreach ($repo in $tempRepos) {
            if (Test-Path -LiteralPath $repo -PathType Container) {
                Remove-Item -LiteralPath $repo -Recurse -Force
            }
        }
    }

    It 'installs transitive dependencies and writes receipts per plugin' {
        $source = New-RepoClone
        $target = New-RepoClone

        $install = Invoke-ScriptProcess -RepoRoot $target -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'continue-implementation', '-Source', $source, '-Ref', 'HEAD')
        $install.ExitCode | Should -Be 0

        Test-Path -LiteralPath (Join-Path $target '.github/skills/ci/SKILL.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target '.github/agents/cr.agent.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target '.github/agents/autopilot.agent.md') | Should -BeTrue

        $receipts = Get-ChildItem -LiteralPath (Join-Path $target '.github/.skalary/receipts') -File -Filter '*.json' | Sort-Object Name
        @($receipts.Name) | Should -Be @('autopilot.json', 'code-review.json', 'continue-implementation.json')
    }

    It 'installs a diamond graph exactly once per unique plugin' {
        $source = New-RepoClone
        $target = New-RepoClone

        Get-ChildItem -LiteralPath (Join-Path $source 'plugins') | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }

        New-PluginManifest -Root $source -Name 'leaf' -Dependencies @()
        New-PluginManifest -Root $source -Name 'left' -Dependencies @('leaf')
        New-PluginManifest -Root $source -Name 'right' -Dependencies @('leaf')
        New-PluginManifest -Root $source -Name 'root' -Dependencies @('left', 'right')

        Invoke-SkalaryScript -RepoRoot $source -ScriptName 'Build-Registry.ps1'
        git -C $source add plugins registry.json README.md
        if ($LASTEXITCODE -ne 0) {
            throw "git add failed in '$source' (exit $LASTEXITCODE)."
        }
        git -C $source commit -m 'test: custom diamond registry' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed in '$source' (exit $LASTEXITCODE)."
        }

        $install = Invoke-ScriptProcess -RepoRoot $target -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'root', '-Source', $source, '-Ref', 'HEAD')
        $install.ExitCode | Should -Be 0

        $receipts = Get-ChildItem -LiteralPath (Join-Path $target '.github/.skalary/receipts') -File -Filter '*.json'
        $receipts.Count | Should -Be 4
        Test-Path -LiteralPath (Join-Path $target '.github/test/leaf.txt') | Should -BeTrue
    }

    It 'aborts on registry hash mismatch and rolls back all staged changes' {
        $source = New-RepoClone
        $target = New-RepoClone

        $sourceRegistryPath = Join-Path $source 'registry.json'
        $sourceRegistry = Get-Content -LiteralPath $sourceRegistryPath -Raw | ConvertFrom-Json -Depth 100
        $pluginsByName = @{}
        foreach ($plugin in @($sourceRegistry.plugins)) {
            $pluginsByName[[string]$plugin.name] = $plugin
        }

        $resolvedPlugins = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        function Add-DependencyClosure {
            param([string]$Name)
            if (-not $resolvedPlugins.Add($Name)) {
                return
            }
            foreach ($dependency in @($pluginsByName[$Name].dependencies)) {
                Add-DependencyClosure -Name ([string]$dependency)
            }
        }
        Add-DependencyClosure -Name 'continue-implementation'

        $beforeHashes = @{}
        foreach ($pluginName in $resolvedPlugins) {
            foreach ($entry in @($pluginsByName[$pluginName].files)) {
                $src = [string]$entry.src
                if ($src -match '^evals(?:/|$)') {
                    continue
                }
                $dest = [string]$entry.dest
                $targetPath = Join-Path $target ('.github/' + ($dest -replace '/', [System.IO.Path]::DirectorySeparatorChar))
                if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                    $beforeHashes[$dest] = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
                }
            }
        }

        $registryPath = Join-Path $source 'registry.json'
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -Depth 100
        $ci = @($registry.plugins | Where-Object { [string]$_.name -eq 'continue-implementation' } | Select-Object -First 1)
        $ci.Count | Should -Be 1
        $ci[0].files[0].sha256 = ('0' * 64)
        Set-Content -LiteralPath $registryPath -Value (($registry | ConvertTo-Json -Depth 100) + "`n") -Encoding utf8

        git -C $source add registry.json
        if ($LASTEXITCODE -ne 0) {
            throw "git add failed in '$source' (exit $LASTEXITCODE)."
        }
        git -C $source commit -m 'test: tamper continue-implementation hash' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed in '$source' (exit $LASTEXITCODE)."
        }

        $install = Invoke-ScriptProcess -RepoRoot $target -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'continue-implementation', '-Source', $source, '-Ref', 'HEAD')
        $install.ExitCode | Should -Not -Be 0
        $install.Output | Should -Match 'Staged hash mismatch'

        foreach ($dest in $beforeHashes.Keys) {
            $targetPath = Join-Path $target ('.github/' + ($dest -replace '/', [System.IO.Path]::DirectorySeparatorChar))
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash | Should -Be $beforeHashes[$dest]
        }

        $receiptsRoot = Join-Path $target '.github/.skalary/receipts'
        if (Test-Path -LiteralPath $receiptsRoot -PathType Container) {
            (Get-ChildItem -LiteralPath $receiptsRoot -File -Filter '*.json').Count | Should -Be 0
        }
        $tmpRoot = Join-Path $target '.github/.skalary/tmp'
        if (Test-Path -LiteralPath $tmpRoot -PathType Container) {
            @(Get-ChildItem -LiteralPath $tmpRoot -Directory -Filter 'install-*').Count | Should -Be 0
        }
    }

    It 'marks update as degraded when modified files are skipped' {
        $baseSource = New-RepoClone
        $updatedSource = New-RepoClone
        $target = New-RepoClone

        $install = Invoke-ScriptProcess -RepoRoot $target -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'code-review', '-Source', $baseSource, '-Ref', 'HEAD')
        $install.ExitCode | Should -Be 0

        Set-Content -LiteralPath (Join-Path $target '.github/prompts/cr.prompt.md') -Value "user-edited`n" -Encoding utf8

        # Write canonical LF: this file is hashed by Build-Registry then committed.
        # The eol=lf gitattribute renormalizes the working tree on commit, so a
        # platform-dependent Set-Content terminator (CRLF on Windows) would make
        # the recorded hash diverge from the post-commit content.
        [System.IO.File]::WriteAllText((Join-Path $updatedSource 'plugins/code-review/prompts/cr.prompt.md'), "upstream update`n")
        $manifestPath = Join-Path $updatedSource 'plugins/code-review/plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
        $manifest.version = '1.0.1'
        Set-Content -LiteralPath $manifestPath -Value (($manifest | ConvertTo-Json -Depth 100) + "`n") -Encoding utf8
        Invoke-SkalaryScript -RepoRoot $updatedSource -ScriptName 'Build-Registry.ps1'
        git -C $updatedSource add plugins/code-review registry.json README.md
        if ($LASTEXITCODE -ne 0) {
            throw "git add failed in '$updatedSource' (exit $LASTEXITCODE)."
        }
        git -C $updatedSource commit -m 'test: bump code-review to 1.0.1' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed in '$updatedSource' (exit $LASTEXITCODE)."
        }

        $update = Invoke-ScriptProcess -RepoRoot $target -ScriptName 'Update-Plugin.ps1' -Arguments @('-Name', 'code-review', '-Source', $updatedSource, '-Ref', 'HEAD')
        $update.ExitCode | Should -Be 0

        $receipt = Get-Content -LiteralPath (Join-Path $target '.github/.skalary/receipts/code-review.json') -Raw | ConvertFrom-Json -Depth 100
        [bool]$receipt.degraded | Should -BeTrue
        [string]$receipt.version | Should -Be '1.0.0'
        @($receipt.files | Where-Object { [string]$_.outcome -eq 'skipped-modified' }).Count | Should -BeGreaterThan 0
    }

    It 'blocks removing a plugin while installed dependents still require it' {
        $source = New-RepoClone
        $target = New-RepoClone

        $install = Invoke-ScriptProcess -RepoRoot $target -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'continue-implementation', '-Source', $source, '-Ref', 'HEAD')
        $install.ExitCode | Should -Be 0

        {
            Invoke-SkalaryScript -RepoRoot $target -ScriptName 'Remove-Plugin.ps1' -Parameters @{ Name = 'code-review' }
        } | Should -Throw -ExpectedMessage "*installed dependent plugin(s): continue-implementation*"
    }

    It 'keeps modified files during remove unless -Force is used' {
        $source = New-RepoClone
        $target = New-RepoClone

        $install = Invoke-ScriptProcess -RepoRoot $target -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'create-implementation-plan', '-Source', $source, '-Ref', 'HEAD')
        $install.ExitCode | Should -Be 0

        $installedPath = Join-Path $target '.github/skills/cip/SKILL.md'
        Set-Content -LiteralPath $installedPath -Value "changed locally`n" -Encoding utf8

        Invoke-SkalaryScript -RepoRoot $target -ScriptName 'Remove-Plugin.ps1' -Parameters @{ Name = 'create-implementation-plan' }
        Test-Path -LiteralPath $installedPath | Should -BeTrue
    }

    It 'reports installed and modified flags and finds plugins by metadata' {
        $source = New-RepoClone
        $target = New-RepoClone

        $install = Invoke-ScriptProcess -RepoRoot $target -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'create-design-notes', '-Source', $source, '-Ref', 'HEAD')
        $install.ExitCode | Should -Be 0

        $plugins = Invoke-SkalaryScript -RepoRoot $target -ScriptName 'Get-Plugin.ps1'
        $cdn = @($plugins | Where-Object { [string]$_.name -eq 'create-design-notes' } | Select-Object -First 1)
        $cdn.Count | Should -Be 1
        [bool]$cdn[0].installed | Should -BeTrue
        [bool]$cdn[0].modified | Should -BeFalse

        Set-Content -LiteralPath (Join-Path $target '.github/prompts/cdn.prompt.md') -Value "mutated`n" -Encoding utf8
        $pluginsAfter = Invoke-SkalaryScript -RepoRoot $target -ScriptName 'Get-Plugin.ps1' -Parameters @{ Installed = $true }
        $cdnAfter = @($pluginsAfter | Where-Object { [string]$_.name -eq 'create-design-notes' } | Select-Object -First 1)
        $cdnAfter.Count | Should -Be 1
        [bool]$cdnAfter[0].modified | Should -BeTrue

        $search = Invoke-SkalaryScript -RepoRoot $target -ScriptName 'Find-Plugin.ps1' -Parameters @{ Query = 'review' }
        @($search.name) | Should -Contain 'code-review'
        @($search.name) | Should -Contain 'design-review'
    }

    It 'keeps Build-Registry idempotent across repeated runs' {
        $repo = New-RepoClone
        $registryPath = Join-Path $repo 'registry.json'
        $readmePath = Join-Path $repo 'README.md'

        Invoke-SkalaryScript -RepoRoot $repo -ScriptName 'Build-Registry.ps1'
        $registryHash1 = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
        $readmeHash1 = (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash

        Invoke-SkalaryScript -RepoRoot $repo -ScriptName 'Build-Registry.ps1'
        $registryHash2 = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
        $readmeHash2 = (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash

        $registryHash2 | Should -Be $registryHash1
        $readmeHash2 | Should -Be $readmeHash1
    }

    It 'fails Test-Registry on destination collisions' {
        $repo = New-RepoClone
        $manifestPath = Join-Path $repo 'plugins/create-design-notes/plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
        $manifest.files[0].dest = 'prompts/udn.prompt.md'
        Set-Content -LiteralPath $manifestPath -Value (($manifest | ConvertTo-Json -Depth 100) + "`n") -Encoding utf8

        Invoke-SkalaryScript -RepoRoot $repo -ScriptName 'Build-Registry.ps1'
        $result = Invoke-ScriptProcess -RepoRoot $repo -ScriptName 'Test-Registry.ps1'
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Destination collision'
    }

    It 'rejects traversal and rooted destination paths in Test-Registry' -TestCases @(
        @{ Dest = '../escape.md' }
        @{ Dest = '/absolute/escape.md' }
        @{ Dest = '\\server\share\escape.md' }
        @{ Dest = 'C:\escape.md' }
        @{ Dest = 'prompts/valid.md:stream' }
    ) {
        param($Dest)

        $repo = New-RepoClone
        $manifestPath = Join-Path $repo 'plugins/create-design-notes/plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
        $manifest.files[0].dest = $Dest
        Set-Content -LiteralPath $manifestPath -Value (($manifest | ConvertTo-Json -Depth 100) + "`n") -Encoding utf8

        Invoke-SkalaryScript -RepoRoot $repo -ScriptName 'Build-Registry.ps1'
        $result = Invoke-ScriptProcess -RepoRoot $repo -ScriptName 'Test-Registry.ps1'
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match "invalid destination path '$([regex]::Escape($Dest))'"
    }

    It 'produces byte-identical installs for local and remote source modes at same commit' {
        $source = New-RepoClone
        $targetLocal = New-RepoClone
        $targetRemote = New-RepoClone

        $localInstall = Invoke-ScriptProcess -RepoRoot $targetLocal -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'code-review', '-Source', $source, '-Ref', 'HEAD')
        $remoteInstall = Invoke-ScriptProcess -RepoRoot $targetRemote -ScriptName 'Install-Plugin.ps1' -Arguments @('-Name', 'code-review', '-Repository', $source, '-Ref', 'HEAD')
        $localInstall.ExitCode | Should -Be 0
        $remoteInstall.ExitCode | Should -Be 0

        $localReceipt = Get-Content -LiteralPath (Join-Path $targetLocal '.github/.skalary/receipts/code-review.json') -Raw | ConvertFrom-Json -Depth 100
        $remoteReceipt = Get-Content -LiteralPath (Join-Path $targetRemote '.github/.skalary/receipts/code-review.json') -Raw | ConvertFrom-Json -Depth 100

        [string]$localReceipt.ref | Should -Be ([string]$remoteReceipt.ref)

        $localByDest = @{}
        foreach ($entry in @($localReceipt.files)) {
            $localByDest[[string]$entry.dest] = [string]$entry.sha256
        }
        foreach ($entry in @($remoteReceipt.files)) {
            $dest = [string]$entry.dest
            $localByDest.ContainsKey($dest) | Should -BeTrue
            [string]$entry.sha256 | Should -Be $localByDest[$dest]

            $localPath = Join-Path $targetLocal ('.github/' + ($dest -replace '/', [System.IO.Path]::DirectorySeparatorChar))
            $remotePath = Join-Path $targetRemote ('.github/' + ($dest -replace '/', [System.IO.Path]::DirectorySeparatorChar))
            (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $remotePath -Algorithm SHA256).Hash
        }
    }
}
