#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'EvalCommon.psm1') -Force

$script:EvalInputSizeCeiling = 15000

function Get-EvalSkipSignal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Reason,

        [AllowNull()]
        $Config = $null
    )

    return [pscustomobject]@{
        shouldSkip = $true
        reason = $Reason
        config = $Config
    }
}

function Get-EvalOkSignal {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Config = $null
    )

    return [pscustomobject]@{
        shouldSkip = $false
        reason = $null
        config = $Config
    }
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [int]$TimeoutSeconds = 300
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        return [pscustomobject]@{
            timedOut = $true
            exitCode = $null
            stdout = [string]$stdoutTask.Result
            stderr = [string]$stderrTask.Result
        }
    }

    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
    return [pscustomobject]@{
        timedOut = $false
        exitCode = $process.ExitCode
        stdout = [string]$stdoutTask.Result
        stderr = [string]$stderrTask.Result
    }
}

function ConvertTo-GithubHttpsRemoteUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RemoteUrl
    )

    if ($RemoteUrl -match '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
        return "https://github.com/$($Matches.owner)/$($Matches.repo)"
    }

    if ($RemoteUrl -match '^git@github\.com:(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
        return "https://github.com/$($Matches.owner)/$($Matches.repo)"
    }

    throw "Unsupported origin URL format: '$RemoteUrl'"
}

function Resolve-EvalConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $examplePath = Join-Path $RepoRoot '.eval.config.json.example'
    $configPath = Join-Path $RepoRoot '.eval.config.json'

    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) {
        throw "Eval config example file is missing: $examplePath"
    }

    $defaults = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -Depth 20
    $config = [ordered]@{
        judgeModel = [string]$defaults.judgeModel
        temperature = [double]$defaults.temperature
        passThreshold = [double]$defaults.passThreshold
        timeoutSeconds = [int]$defaults.timeoutSeconds
    }

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $userConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 20
        foreach ($property in @('judgeModel', 'temperature', 'passThreshold', 'timeoutSeconds')) {
            if ($userConfig.PSObject.Properties.Name -contains $property -and $null -ne $userConfig.$property) {
                $config[$property] = $userConfig.$property
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$config.judgeModel) -or [string]$config.judgeModel -eq '<slug>') {
        return Get-EvalSkipSignal -Reason "LLM evals skipped: set '.eval.config.json' with a real 'judgeModel' value." -Config ([pscustomobject]$config)
    }

    if ([double]$config.passThreshold -lt 0 -or [double]$config.passThreshold -gt 1) {
        throw "Invalid passThreshold '$($config.passThreshold)'. Expected number in range [0,1]."
    }
    if ([double]$config.temperature -lt 0 -or [double]$config.temperature -gt 2) {
        throw "Invalid temperature '$($config.temperature)'. Expected number in range [0,2]."
    }
    if ([int]$config.timeoutSeconds -lt 10) {
        throw "Invalid timeoutSeconds '$($config.timeoutSeconds)'. Expected integer >= 10."
    }

    return Get-EvalOkSignal -Config ([pscustomobject]$config)
}

function Test-CopilotAuth {
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 60
    )

    $probe = Invoke-ExternalCommand -FilePath 'copilot' `
        -ArgumentList @('-p', 'Reply with exactly AUTH_OK', '--no-ask-user', '--allow-all', '--silent') `
        -WorkingDirectory (Get-Location).Path `
        -TimeoutSeconds $TimeoutSeconds

    if ($probe.timedOut) {
        return Get-EvalSkipSignal -Reason 'LLM evals skipped: Copilot auth probe timed out.'
    }

    if ($probe.exitCode -ne 0) {
        $stderr = ($probe.stderr ?? '').Trim()
        if ([string]::IsNullOrWhiteSpace($stderr)) {
            $stderr = 'unknown auth/runtime error'
        }
        return Get-EvalSkipSignal -Reason "LLM evals skipped: Copilot auth probe failed ($stderr)."
    }

    if (-not ($probe.stdout -match 'AUTH_OK')) {
        return Get-EvalSkipSignal -Reason 'LLM evals skipped: Copilot auth probe returned unexpected output.'
    }

    return Get-EvalOkSignal
}

function New-EvalSandbox {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $originRaw = (git -C $RepoRoot remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($originRaw)) {
        throw "Unable to read origin URL from '$RepoRoot'."
    }
    $originFetchUrl = ConvertTo-GithubHttpsRemoteUrl -RemoteUrl $originRaw
    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Create eval sandbox clone')) {
        return Get-EvalSkipSignal -Reason 'LLM eval sandbox creation skipped by ShouldProcess.'
    }

    $sandboxPath = Join-Path ([System.IO.Path]::GetTempPath()) ("skalary-eval-sandbox-" + [guid]::NewGuid().ToString('N'))
    $cloneResult = Invoke-ExternalCommand -FilePath 'git' `
        -ArgumentList @('clone', '--quiet', '--no-tags', '--depth', '1', $RepoRoot, $sandboxPath) `
        -WorkingDirectory $RepoRoot `
        -TimeoutSeconds 120
    if ($cloneResult.timedOut -or $cloneResult.exitCode -ne 0) {
        throw "Failed to clone eval sandbox: $($cloneResult.stderr)"
    }

    $sandboxPluginsPath = Join-Path $sandboxPath 'plugins'
    if (Test-Path -LiteralPath $sandboxPluginsPath) {
        Remove-Item -LiteralPath $sandboxPluginsPath -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'plugins') -Destination $sandboxPluginsPath -Recurse -Force

    $syncScript = Join-Path $sandboxPath 'scripts/skalary/Sync-Dogfood.ps1'
    $buildScript = Join-Path $sandboxPath 'scripts/skalary/Build-Registry.ps1'
    $syncResult = Invoke-ExternalCommand -FilePath 'pwsh' `
        -ArgumentList @('-NoProfile', '-File', $syncScript, '-RepoRoot', $sandboxPath) `
        -WorkingDirectory $sandboxPath `
        -TimeoutSeconds 180
    if ($syncResult.timedOut -or $syncResult.exitCode -ne 0) {
        throw "Sync-Dogfood failed in eval sandbox: $($syncResult.stderr)"
    }

    $setFetch = Invoke-ExternalCommand -FilePath 'git' `
        -ArgumentList @('-C', $sandboxPath, 'remote', 'set-url', 'origin', $originFetchUrl) `
        -WorkingDirectory $sandboxPath `
        -TimeoutSeconds 30
    if ($setFetch.timedOut -or $setFetch.exitCode -ne 0) {
        throw "Failed to set sandbox origin fetch URL: $($setFetch.stderr)"
    }

    $disablePush = Invoke-ExternalCommand -FilePath 'git' `
        -ArgumentList @('-C', $sandboxPath, 'remote', 'set-url', '--push', 'origin', 'DISABLED') `
        -WorkingDirectory $sandboxPath `
        -TimeoutSeconds 30
    if ($disablePush.timedOut -or $disablePush.exitCode -ne 0) {
        throw "Failed to disable sandbox origin push URL: $($disablePush.stderr)"
    }

    $buildResult = Invoke-ExternalCommand -FilePath 'pwsh' `
        -ArgumentList @('-NoProfile', '-File', $buildScript, '-RepoRoot', $sandboxPath) `
        -WorkingDirectory $sandboxPath `
        -TimeoutSeconds 240
    if ($buildResult.timedOut -or $buildResult.exitCode -ne 0) {
        throw "Build-Registry failed in eval sandbox: $($buildResult.stderr)"
    }

    return [pscustomobject]@{
        path = $sandboxPath
        originFetchUrl = $originFetchUrl
        pushDisabled = $true
        registryBuildSucceeded = $true
    }
}

function Remove-EvalSandbox {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SandboxPath
    )

    if ((Test-Path -LiteralPath $SandboxPath) -and $PSCmdlet.ShouldProcess($SandboxPath, 'Remove eval sandbox')) {
        Remove-Item -LiteralPath $SandboxPath -Recurse -Force
    }
}

function Get-EvalArtifactPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArtifactBody,

        [Parameter(Mandatory)]
        [string]$Scenario
    )

    return @"
You are being evaluated against the embedded artifact instructions below.

Artifact content:
====
$ArtifactBody
====

Scenario:
$Scenario
"@
}

function Invoke-EvalBackend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('copilot-cli', 'container')]
        [string]$Backend,

        [Parameter(Mandatory)]
        [string]$SandboxPath,

        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Plugin,

        [Parameter(Mandatory)]
        [string]$CaseStem,

        [Parameter(Mandatory)]
        [ValidateSet('agent', 'prompt', 'skill')]
        [string]$ArtifactType,

        [Parameter(Mandatory)]
        [string]$Scenario,

        [string]$AgentName,

        [string]$ArtifactBody,

        [int]$TimeoutSeconds = 300
    )

    if ($Backend -eq 'container') {
        return Get-EvalSkipSignal -Reason 'LLM evals skipped: container backend is a reserved stub and is not implemented yet.'
    }

    $prompt = if ($ArtifactType -eq 'agent') { $Scenario } else { Get-EvalArtifactPrompt -ArtifactBody $ArtifactBody -Scenario $Scenario }
    if ($prompt.Length -gt $script:EvalInputSizeCeiling) {
        return Get-EvalSkipSignal -Reason "LLM eval case skipped: prompt payload exceeds input ceiling ($($script:EvalInputSizeCeiling) chars)."
    }

    $arguments = @('-p', $prompt, '--no-ask-user', '--allow-all', '--silent')
    if ($ArtifactType -eq 'agent') {
        if ([string]::IsNullOrWhiteSpace($AgentName)) {
            throw 'Agent artifact requires a non-empty agent name.'
        }
        $arguments += @('--agent', $AgentName)
    }

    $result = Invoke-ExternalCommand -FilePath 'copilot' `
        -ArgumentList $arguments `
        -WorkingDirectory $SandboxPath `
        -TimeoutSeconds $TimeoutSeconds

    if ($result.timedOut) {
        return Get-EvalSkipSignal -Reason "LLM eval case skipped: backend timed out after $TimeoutSeconds seconds."
    }
    if ($result.exitCode -ne 0) {
        throw "LLM backend failed (exit $($result.exitCode)): $($result.stderr)"
    }

    $artifactDir = Join-Path $RepoRoot '.eval-artifacts'
    if (-not (Test-Path -LiteralPath $artifactDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $artifactDir -Force)
    }
    $transcriptPath = Join-Path $artifactDir "$Plugin-$CaseStem.txt"
    Set-Content -LiteralPath $transcriptPath -Value ([string]$result.stdout) -Encoding utf8

    return [pscustomobject]@{
        shouldSkip = $false
        reason = $null
        stdout = [string]$result.stdout
        stderr = [string]$result.stderr
        transcriptPath = $transcriptPath
    }
}

function Invoke-EvalJudge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SandboxPath,

        [Parameter(Mandatory)]
        [string]$CapturedOutput,

        [Parameter(Mandatory)]
        [string[]]$Rubric,

        [Parameter(Mandatory)]
        [double]$PassThreshold,

        [Parameter(Mandatory)]
        [string]$JudgeModel,

        [double]$Temperature = 0,

        [int]$TimeoutSeconds = 300
    )

    if ($Temperature -ne 0) {
        throw "Judge temperature must be 0 for deterministic scoring (got '$Temperature')."
    }

    $guid = [guid]::NewGuid().ToString('N')
    $startBoundary = "<<<UNTRUSTED_OUTPUT_START:$guid>>>"
    $endBoundary = "<<<UNTRUSTED_OUTPUT_END:$guid>>>"
    $safeOutput = $CapturedOutput.Replace($startBoundary, '[BOUNDARY_TOKEN]').Replace($endBoundary, '[BOUNDARY_TOKEN]')
    $rubricText = ($Rubric | ForEach-Object { "- $_" }) -join "`n"
    $judgePrompt = @"
You are an eval judge. Return strict JSON only with keys {\"pass\":boolean,\"score\":number,\"rationale\":string}.
No markdown and no surrounding text.

Pass threshold: $PassThreshold
Rubric:
$rubricText

Candidate output:
````text
$startBoundary
$safeOutput
$endBoundary
````
"@

    $judgeResult = Invoke-ExternalCommand -FilePath 'copilot' `
        -ArgumentList @('-p', $judgePrompt, '--model', $JudgeModel, '--no-ask-user', '--allow-all', '--silent') `
        -WorkingDirectory $SandboxPath `
        -TimeoutSeconds $TimeoutSeconds

    if ($judgeResult.timedOut) {
        throw "Eval judge timed out after $TimeoutSeconds seconds."
    }
    if ($judgeResult.exitCode -ne 0) {
        throw "Eval judge failed (exit $($judgeResult.exitCode)): $($judgeResult.stderr)"
    }

    $raw = ([string]$judgeResult.stdout).Trim()
    if (-not ($raw.StartsWith('{') -and $raw.EndsWith('}'))) {
        throw "Eval judge returned non-JSON output: '$raw'"
    }

    $parsed = $raw | ConvertFrom-Json -Depth 10
    foreach ($required in @('pass', 'score', 'rationale')) {
        if (-not ($parsed.PSObject.Properties.Name -contains $required)) {
            throw "Eval judge JSON is missing required field '$required'."
        }
    }

    if (-not ($parsed.pass -is [bool])) {
        throw "Eval judge field 'pass' must be boolean."
    }
    if (-not (($parsed.score -is [double]) -or ($parsed.score -is [float]) -or ($parsed.score -is [decimal]) -or ($parsed.score -is [int]))) {
        throw "Eval judge field 'score' must be numeric."
    }
    $score = [double]$parsed.score
    if ($score -lt 0 -or $score -gt 1) {
        throw "Eval judge field 'score' must be within [0,1]."
    }
    if ([string]::IsNullOrWhiteSpace([string]$parsed.rationale)) {
        throw "Eval judge field 'rationale' must be a non-empty string."
    }

    $expectedPass = ($score -ge $PassThreshold)
    if ([bool]$parsed.pass -ne $expectedPass) {
        throw "Eval judge returned inconsistent verdict: pass=$($parsed.pass) but score=$score with threshold=$PassThreshold."
    }

    return [pscustomobject]@{
        pass = [bool]$parsed.pass
        score = $score
        rationale = [string]$parsed.rationale
    }
}

function ConvertTo-CaseStem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $stem = ($Name.ToLowerInvariant() -replace '[^a-z0-9._-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($stem)) {
        $stem = 'case'
    }
    return $stem
}

function ConvertTo-RepoRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $repoRootPath = [System.IO.Path]::GetFullPath($RepoRoot)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $repoPrefix = $repoRootPath.TrimEnd($separator) + $separator
    if (-not $fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Replace('\', '/')
    }

    return $fullPath.Substring($repoPrefix.Length).Replace('\', '/')
}

function Read-EvalCaseFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $case = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20
    $allowedKeys = @('artifact', 'scenario', 'rubric', 'passThreshold')
    foreach ($property in $case.PSObject.Properties.Name) {
        if ($allowedKeys -notcontains [string]$property) {
            throw "Eval case '$Path' contains unsupported top-level key '$property'."
        }
    }

    foreach ($required in @('artifact', 'scenario', 'rubric')) {
        if (-not ($case.PSObject.Properties.Name -contains $required)) {
            throw "Eval case '$Path' is missing required key '$required'."
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$case.artifact)) {
        throw "Eval case '$Path' has empty 'artifact'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$case.scenario)) {
        throw "Eval case '$Path' has empty 'scenario'."
    }
    if (-not ($case.rubric -is [System.Collections.IEnumerable])) {
        throw "Eval case '$Path' has non-array 'rubric'."
    }

    $rubric = @($case.rubric | ForEach-Object { [string]$_ })
    if ($rubric.Count -lt 1) {
        throw "Eval case '$Path' has empty 'rubric' array."
    }
    if (@($rubric | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "Eval case '$Path' contains empty rubric item(s)."
    }

    $passThreshold = $null
    if ($case.PSObject.Properties.Name -contains 'passThreshold' -and $null -ne $case.passThreshold) {
        $passThreshold = [double]$case.passThreshold
        if ($passThreshold -lt 0 -or $passThreshold -gt 1) {
            throw "Eval case '$Path' has invalid 'passThreshold' ($passThreshold). Expected [0,1]."
        }
    }

    return [pscustomobject]@{
        artifact = [string]$case.artifact
        scenario = [string]$case.scenario
        rubric = $rubric
        passThreshold = $passThreshold
    }
}

function Invoke-LlmEvalSuite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [ValidateSet('copilot-cli', 'container')]
        [string]$Backend = 'copilot-cli'
    )

    $configSignal = Resolve-EvalConfig -RepoRoot $RepoRoot
    if ($configSignal.shouldSkip) {
        return [pscustomobject]@{
            entries = @()
            note = [string]$configSignal.reason
            sandbox = $null
        }
    }
    $config = $configSignal.config

    $authSignal = Test-CopilotAuth -TimeoutSeconds ([Math]::Min([int]$config.timeoutSeconds, 60))
    if ($authSignal.shouldSkip) {
        return [pscustomobject]@{
            entries = @()
            note = [string]$authSignal.reason
            sandbox = $null
        }
    }

    $caseFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'plugins') -Recurse -File -Filter '*.eval.json' |
            Where-Object { $_.FullName -match '[\\/]evals[\\/]llm[\\/]' } |
            Sort-Object FullName
    )

    if ($caseFiles.Count -eq 0) {
        return [pscustomobject]@{
            entries = @()
            note = 'No LLM eval case files found under plugins/*/evals/llm/*.eval.json.'
            sandbox = $null
        }
    }

    $sandbox = New-EvalSandbox -RepoRoot $RepoRoot
    $entries = [System.Collections.Generic.List[object]]::new()
    $stemsByPlugin = @{}

    try {
        foreach ($caseFile in $caseFiles) {
            $pluginName = [string]$caseFile.Directory.Parent.Parent.Name
            if (-not $stemsByPlugin.ContainsKey($pluginName)) {
                $stemsByPlugin[$pluginName] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }

            $rawStem = [System.IO.Path]::GetFileNameWithoutExtension([string]$caseFile.Name)
            $caseStem = ConvertTo-CaseStem -Name $rawStem
            if ($stemsByPlugin[$pluginName].Contains($caseStem)) {
                throw "Plugin '$pluginName' has duplicate sanitized case stem '$caseStem'."
            }
            [void]$stemsByPlugin[$pluginName].Add($caseStem)

            $entry = [ordered]@{
                plugin = $pluginName
                case = [string]$caseFile.Name
                artifact = $null
                tier = 'llm'
                outcome = 'error'
                score = $null
                threshold = $null
                message = $null
                transcriptPath = $null
            }

            try {
                $case = Read-EvalCaseFile -Path $caseFile.FullName
                $entry.artifact = [string]$case.artifact

                $manifestPath = Join-Path $RepoRoot "plugins/$pluginName/plugin.json"
                if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                    throw "Plugin manifest not found for '$pluginName'."
                }
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 50
                $artifactEntries = @($manifest.files | Where-Object { [string]$_.dest -eq [string]$case.artifact })
                if ($artifactEntries.Count -ne 1) {
                    throw "Eval case '$($caseFile.Name)' artifact '$($case.artifact)' does not resolve to exactly one plugin manifest file."
                }

                $artifactEntry = $artifactEntries[0]
                $artifactType = Get-ArtifactType -DestinationPath ([string]$artifactEntry.dest)
                $artifactSourcePath = Join-Path (Join-Path $sandbox.path "plugins/$pluginName") ([string]$artifactEntry.src -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $artifactSourcePath -PathType Leaf)) {
                    throw "Artifact source file not found in sandbox: $artifactSourcePath"
                }

                $threshold = if ($null -ne $case.passThreshold) { [double]$case.passThreshold } else { [double]$config.passThreshold }
                $entry.threshold = $threshold
                $backendResult = Invoke-EvalBackend `
                    -Backend $Backend `
                    -SandboxPath $sandbox.path `
                    -RepoRoot $RepoRoot `
                    -Plugin $pluginName `
                    -CaseStem $caseStem `
                    -ArtifactType $artifactType `
                    -Scenario $case.scenario `
                    -AgentName ([System.IO.Path]::GetFileName([string]$artifactEntry.src) -replace '\.agent\.md$', '') `
                    -ArtifactBody (Get-Content -LiteralPath $artifactSourcePath -Raw) `
                    -TimeoutSeconds ([int]$config.timeoutSeconds)

                if ($backendResult.shouldSkip) {
                    $entry.outcome = 'skip'
                    $entry.message = [string]$backendResult.reason
                    $entries.Add([pscustomobject]$entry)
                    continue
                }

                $entry.transcriptPath = ConvertTo-RepoRelativePath -RepoRoot $RepoRoot -Path ([string]$backendResult.transcriptPath)
                $judge = Invoke-EvalJudge `
                    -SandboxPath $sandbox.path `
                    -CapturedOutput ([string]$backendResult.stdout) `
                    -Rubric $case.rubric `
                    -PassThreshold $threshold `
                    -JudgeModel ([string]$config.judgeModel) `
                    -Temperature ([double]$config.temperature) `
                    -TimeoutSeconds ([int]$config.timeoutSeconds)

                $entry.score = [double]$judge.score
                $entry.message = [string]$judge.rationale
                $entry.outcome = if ($judge.pass) { 'pass' } else { 'fail' }
            }
            catch {
                $entry.outcome = 'error'
                $entry.message = [string]$_.Exception.Message
            }

            $entries.Add([pscustomobject]$entry)
        }
    }
    finally {
        if ($null -ne $sandbox -and -not [string]::IsNullOrWhiteSpace([string]$sandbox.path)) {
            Remove-EvalSandbox -SandboxPath ([string]$sandbox.path)
        }
    }

    return [pscustomobject]@{
        entries = @($entries)
        note = $null
        sandbox = [pscustomobject]@{
            originFetchUrl = [string]$sandbox.originFetchUrl
            pushDisabled = [bool]$sandbox.pushDisabled
            registryBuildSucceeded = [bool]$sandbox.registryBuildSucceeded
        }
    }
}

Export-ModuleMember -Function @(
    'Resolve-EvalConfig',
    'Test-CopilotAuth',
    'New-EvalSandbox',
    'Remove-EvalSandbox',
    'Invoke-EvalBackend',
    'Invoke-EvalJudge',
    'Invoke-LlmEvalSuite'
)
