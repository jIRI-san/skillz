#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,
    [switch]$IncludeLlm,
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

function Get-PluginNameFromEvalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($normalizedPath -match '/plugins/(?<plugin>[^/]+)/evals/') {
        return [string]$Matches.plugin
    }

    return 'unknown'
}

function Convert-TestResultToEvalOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Result
    )

    switch -Regex ($Result) {
        '^Passed$' { return 'pass' }
        '^Skipped$' { return 'skip' }
        '^NotRun$' { return 'skip' }
        '^Failed$' { return 'fail' }
        default { return 'error' }
    }
}

function Get-TestArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $TestResult,

        [Parameter(Mandatory)]
        [string]$DefaultArtifact
    )

    if ($null -ne $TestResult.Data -and $TestResult.Data -is [hashtable]) {
        if ($TestResult.Data.ContainsKey('artifact') -and -not [string]::IsNullOrWhiteSpace([string]$TestResult.Data.artifact)) {
            return [string]$TestResult.Data.artifact
        }

        if ($TestResult.Data.ContainsKey('Artifact') -and -not [string]::IsNullOrWhiteSpace([string]$TestResult.Data.Artifact)) {
            return [string]$TestResult.Data.Artifact
        }
    }

    return $DefaultArtifact
}

function Get-StructuralEvalEntryList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PesterResult
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($test in @($PesterResult.Tests)) {
        $scriptBlockFile = $null
        if ($null -ne $test.ScriptBlock -and -not [string]::IsNullOrWhiteSpace([string]$test.ScriptBlock.File)) {
            $scriptBlockFile = [string]$test.ScriptBlock.File
        }

        $scriptPath = if (-not [string]::IsNullOrWhiteSpace($scriptBlockFile)) {
            $scriptBlockFile
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$test.Path)) {
            [string]$test.Path
        }
        else {
            '<unknown>'
        }

        $caseName = if (-not [string]::IsNullOrWhiteSpace([string]$test.ExpandedPath)) {
            [string]$test.ExpandedPath
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$test.ExpandedName)) {
            [string]$test.ExpandedName
        }
        else {
            [string]$test.Name
        }

        $errorMessage = $null
        if ($null -ne $test.ErrorRecord) {
            $errorRecordHasException = $test.ErrorRecord.PSObject.Properties.Name -contains 'Exception'
            if ($errorRecordHasException -and
                $null -ne $test.ErrorRecord.Exception -and
                -not [string]::IsNullOrWhiteSpace([string]$test.ErrorRecord.Exception.Message)) {
                $errorMessage = [string]$test.ErrorRecord.Exception.Message
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$test.ErrorRecord)) {
                $errorMessage = [string]$test.ErrorRecord
            }
        }

        $entries.Add([ordered]@{
                plugin = Get-PluginNameFromEvalPath -Path $scriptPath
                case = $caseName
                artifact = Get-TestArtifact -TestResult $test -DefaultArtifact $scriptPath
                tier = 'structural'
                outcome = Convert-TestResultToEvalOutcome -Result ([string]$test.Result)
                score = $null
                threshold = $null
                message = $errorMessage
                transcriptPath = $null
            })
    }

    return @($entries)
}

function Get-OutcomeCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory)]
        [string]$Outcome
    )

    return @($Entries | Where-Object { [string]$_.outcome -eq $Outcome }).Count
}

function ConvertTo-MarkdownCell {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }

    return (($Value -replace '\r?\n', ' ') -replace '\|', '\|')
}

function ConvertTo-EvalMarkdownReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Report
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('# Eval Report')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("- Generated: $($Report.generatedAt)")
    [void]$builder.AppendLine("- Include LLM: $($Report.includeLlm)")
    [void]$builder.AppendLine()

    $summary = $Report.summary
    [void]$builder.AppendLine('## Summary')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Total | Pass | Fail | Skip | Error |')
    [void]$builder.AppendLine('|---|---|---|---|---|')
    [void]$builder.AppendLine("| $($summary.total) | $($summary.pass) | $($summary.fail) | $($summary.skip) | $($summary.error) |")
    [void]$builder.AppendLine()

    $structural = @($Report.entries | Where-Object { [string]$_.tier -eq 'structural' })
    $llm = @($Report.entries | Where-Object { [string]$_.tier -eq 'llm' })

    if ($structural.Count -gt 0) {
        [void]$builder.AppendLine('## Structural (Tier 1)')
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('| Plugin | Case | Outcome | Message |')
        [void]$builder.AppendLine('|---|---|---|---|')
        foreach ($entry in $structural) {
            [void]$builder.AppendLine("| $(ConvertTo-MarkdownCell ([string]$entry.plugin)) | $(ConvertTo-MarkdownCell ([string]$entry.case)) | $($entry.outcome) | $(ConvertTo-MarkdownCell ([string]$entry.message)) |")
        }
        [void]$builder.AppendLine()
    }

    if ($llm.Count -gt 0) {
        [void]$builder.AppendLine('## LLM (Tier 2)')
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('| Plugin | Case | Outcome | Score | Threshold | Transcript |')
        [void]$builder.AppendLine('|---|---|---|---|---|---|')
        foreach ($entry in $llm) {
            $score = if ($null -ne $entry.score) { '{0:0.00}' -f [double]$entry.score } else { '' }
            $threshold = if ($null -ne $entry.threshold) { '{0:0.00}' -f [double]$entry.threshold } else { '' }
            $transcript = if (-not [string]::IsNullOrWhiteSpace([string]$entry.transcriptPath)) { ConvertTo-MarkdownCell ([string]$entry.transcriptPath) } else { '' }
            [void]$builder.AppendLine("| $(ConvertTo-MarkdownCell ([string]$entry.plugin)) | $(ConvertTo-MarkdownCell ([string]$entry.case)) | $($entry.outcome) | $score | $threshold | $transcript |")
        }
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('### Judge Rationale')
        [void]$builder.AppendLine()
        foreach ($entry in $llm) {
            [void]$builder.AppendLine("- **$(ConvertTo-MarkdownCell ([string]$entry.plugin)) / $(ConvertTo-MarkdownCell ([string]$entry.case))** ($($entry.outcome)): $(ConvertTo-MarkdownCell ([string]$entry.message))")
        }
        [void]$builder.AppendLine()
    }

    return $builder.ToString()
}

$repoRootPath = Resolve-RepoRoot -StartPath $RepoRoot
$pluginsRoot = Join-Path $repoRootPath 'plugins'

$outputRootPath = if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot } else { Join-Path $repoRootPath 'tests/evals/output' }
$runStamp = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
$runDir = Join-Path $outputRootPath $runStamp
if (Test-Path -LiteralPath $runDir) {
    $runDir = Join-Path $outputRootPath ($runStamp + '-' + (Get-Date).ToString('fff'))
}
[void](New-Item -ItemType Directory -Path $runDir -Force)
$reportPath = Join-Path $runDir 'report.json'
$reportMdPath = Join-Path $runDir 'report.md'

$evalTestFiles = @(
    Get-ChildItem -LiteralPath $pluginsRoot -Recurse -File -Filter '*.Tests.ps1' |
        Where-Object { $_.FullName -match '[\\/]evals[\\/]' } |
        Sort-Object FullName
)

$entries = [System.Collections.Generic.List[object]]::new()
$testResult = $null

if ($evalTestFiles.Count -gt 0) {
    if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
        throw 'Pester is required to run eval tests. Install Pester and rerun.'
    }

    $testResult = Invoke-Pester -Path $evalTestFiles.FullName -PassThru
    foreach ($entry in @(Get-StructuralEvalEntryList -PesterResult $testResult)) {
        $entries.Add($entry)
    }
}
else {
    Write-Host 'No structural eval tests found under plugins/*/evals/**/*.Tests.ps1.' -ForegroundColor Yellow
}

if ($IncludeLlm) {
    $evalLlmModulePath = Join-Path $repoRootPath 'tests/evals/EvalLlm.psm1'
    if (-not (Test-Path -LiteralPath $evalLlmModulePath -PathType Leaf)) {
        throw "LLM eval module not found: $evalLlmModulePath"
    }

    Import-Module $evalLlmModulePath -Force
    $llmResult = Invoke-LlmEvalSuite -RepoRoot $repoRootPath -OutputDir $runDir -Backend 'copilot-cli'
    foreach ($llmEntry in @($llmResult.entries)) {
        $entries.Add($llmEntry)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$llmResult.note)) {
        Write-Host $llmResult.note -ForegroundColor Yellow
        if (@($llmResult.entries).Count -eq 0) {
            $entries.Add([ordered]@{
                    plugin = 'llm-tier'
                    case = 'preflight'
                    artifact = '<none>'
                    tier = 'llm'
                    outcome = 'skip'
                    score = $null
                    threshold = $null
                    message = [string]$llmResult.note
                    transcriptPath = $null
                })
        }
    }
}

$entryArray = @($entries)
$summary = [ordered]@{
    total = $entryArray.Count
    pass = Get-OutcomeCount -Entries $entryArray -Outcome 'pass'
    fail = Get-OutcomeCount -Entries $entryArray -Outcome 'fail'
    skip = Get-OutcomeCount -Entries $entryArray -Outcome 'skip'
    error = Get-OutcomeCount -Entries $entryArray -Outcome 'error'
}

$report = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    includeLlm = [bool]$IncludeLlm
    summary = $summary
    entries = $entryArray
}

$reportJson = ($report | ConvertTo-Json -Depth 20)
Set-Content -LiteralPath $reportPath -Value ($reportJson + "`n") -Encoding utf8
Set-Content -LiteralPath $reportMdPath -Value (ConvertTo-EvalMarkdownReport -Report $report) -Encoding utf8

Write-Host 'Eval summary:' -ForegroundColor Cyan
Write-Host "  total: $($summary.total)"
Write-Host "  pass:  $($summary.pass)" -ForegroundColor Green
Write-Host "  fail:  $($summary.fail)" -ForegroundColor Red
Write-Host "  skip:  $($summary.skip)" -ForegroundColor Yellow
Write-Host "  error: $($summary.error)" -ForegroundColor Red
Write-Host "  run dir: $runDir"
Write-Host "  report:  $reportPath"
Write-Host "  summary: $reportMdPath"

if ($summary.fail -gt 0 -or $summary.error -gt 0) {
    exit 1
}

exit 0
