#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'ValidatePlan')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ValidatePlan')]
    [string]$PlanPath,

    [Parameter(ParameterSetName = 'ValidatePlan')]
    [Parameter(ParameterSetName = 'VerifyEvidence')]
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,

    [Parameter(ParameterSetName = 'ValidatePlan')]
    [ValidateSet('Draft', 'PhaseCrosscheck', 'PlanCrosscheck')]
    [string]$Stage = 'Draft',

    [Parameter(Mandatory, ParameterSetName = 'VerifyEvidence')]
    [string]$EvidenceMarker,

    [Parameter(ParameterSetName = 'VerifyEvidence')]
    [ValidateSet('Draft', 'PhaseCrosscheck', 'PlanCrosscheck')]
    [string]$EvidenceStage = 'PhaseCrosscheck'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PlanEvidence.psm1') -Force -DisableNameChecking

function Remove-FencedCodeBlocks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $output = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*```') {
            $inFence = -not $inFence
            $output.Add('')
            continue
        }

        if ($inFence) {
            $output.Add('')
            continue
        }

        $output.Add($line)
    }

    return , $output.ToArray()
}

function Split-MarkdownTableCells {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Row
    )

    $trimmed = $Row.Trim()
    $withoutPipes = $trimmed.Trim('|')
    $rawCells = $withoutPipes.Split('|')
    $cells = @()
    foreach ($cell in $rawCells) {
        $cells += , $cell.Trim()
    }

    return , $cells
}

function Get-PlanMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $repoRootPath = [System.IO.Path]::GetFullPath($RepoRoot)
    $content = Get-Content -LiteralPath $fullPath -Raw
    $normalized = $content -replace "`r`n", "`n"
    $allLines = $normalized.Split("`n")
    $lines = Remove-FencedCodeBlocks -Lines $allLines

    $inRequirements = $false
    $inRisks = $false
    $currentPhase = ''
    $phaseSteps = @{}
    $requirements = @{}
    $risks = @{}
    $steps = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        if ($line -match '^\s*##\s+Requirements\b') {
            $inRequirements = $true
            $inRisks = $false
            continue
        }

        if ($line -match '^\s*##\s+Risks\b') {
            $inRequirements = $false
            $inRisks = $true
            continue
        }

        if ($line -match '^\s*##\s+') {
            $inRequirements = $false
            $inRisks = $false
            $currentPhase = $line.Trim()
            if ($currentPhase -match '^##\s+Phase\s+\d+:\s+') {
                $phaseSteps[$currentPhase] = [System.Collections.Generic.List[object]]::new()
            }
            continue
        }

        if ($inRequirements -and $line.Trim().StartsWith('|')) {
            $cells = Split-MarkdownTableCells -Row $line
            if ($cells.Count -lt 4 -or $cells[0] -eq 'ID' -or $cells[0] -eq '----') {
                continue
            }

            if ($cells[0] -match '^REQ-(?<id>\d+)$') {
                $requirements[$cells[0]] = [pscustomobject]@{
                    Id = $cells[0]
                    Number = [int]$Matches.id
                    AcceptanceCriteria = $cells[2]
                }
            }
            continue
        }

        if ($inRisks -and $line.Trim().StartsWith('|')) {
            $cells = Split-MarkdownTableCells -Row $line
            if ($cells.Count -lt 2 -or $cells[0] -eq 'ID' -or $cells[0] -eq '----') {
                continue
            }

            if ($cells[0] -match '^RISK-(?<id>\d+)$') {
                $risks[$cells[0]] = [int]$Matches.id
            }
            continue
        }

        if ($line -match '^\s*-\s\[(?<status>[ x~])\]\s+(?<step>\d+\.\d+[a-z]?)\s+(?<body>.+)$') {
            $stepId = $Matches.step
            $body = $Matches.body
            $size = ''
            if ($body -match '`(?<size>[SML])`') {
                $size = [string]$Matches.size
            }

            $role = 'ai-agent'
            if ($body -match '\s@(?<role>human|ai-agent)\b') {
                $role = [string]$Matches.role
            }

            $afterIds = @()
            if ($body -match '\[after:\s*(?<after>[^\]]+)\]') {
                $afterList = $Matches.after.Split(',')
                foreach ($after in $afterList) {
                    $candidate = $after.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        $afterIds += , $candidate
                    }
                }
            }

            $refs = @()
            $parenMatches = [regex]::Matches($body, '\((?<refs>[^)]*)\)')
            foreach ($parenMatch in $parenMatches) {
                $candidateRefs = @($parenMatch.Groups['refs'].Value.Split(',') | ForEach-Object { $_.Trim() })
                if ($candidateRefs -match '^REQ-\d+$' -or $candidateRefs -match '^RISK-\d+$') {
                    $refs = @($candidateRefs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                }
            }

            $step = [pscustomobject]@{
                Id = $stepId
                Body = $body
                Role = $role
                Size = $size
                After = $afterIds
                Refs = $refs
                Phase = $currentPhase
            }
            $steps.Add($step)
            if ($phaseSteps.ContainsKey($currentPhase)) {
                $phaseSteps[$currentPhase].Add($step)
            }
            continue
        }
    }

    $sizeBytes = [System.Text.Encoding]::UTF8.GetByteCount($content)
    if ($sizeBytes -ge 20480 -or $allLines.Length -ge 400) {
        $warnings.Add("Plan size warning: ${sizeBytes} bytes / $($allLines.Length) lines (warn threshold 20KB/400).")
    }
    if ($sizeBytes -ge 35840 -or $allLines.Length -ge 700) {
        $warnings.Add("Plan size warning: ${sizeBytes} bytes / $($allLines.Length) lines (block threshold 35KB/700 is advisory in this validator).")
    }

    return [pscustomobject]@{
        PlanPath = $fullPath
        RepoRoot = $repoRootPath
        Content = $content
        Lines = $lines
        AllLines = $allLines
        Requirements = $requirements
        Risks = $risks
        Steps = @($steps)
        PhaseSteps = $phaseSteps
        Warnings = $warnings
    }
}

function Get-TypedEvidenceMarkers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AcceptanceCriteria
    )

    $markers = [System.Collections.Generic.List[string]]::new()
    $segments = $AcceptanceCriteria.Split('·')
    foreach ($segment in $segments) {
        $trimmed = $segment.Trim().Trim('`').Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        foreach ($testMatch in [regex]::Matches($trimmed, 'test:[^\s`|·]+')) {
            $markers.Add($testMatch.Value.Trim())
        }

        foreach ($reviewMatch in [regex]::Matches($trimmed, 'review:(?:cr|dr)')) {
            $markers.Add($reviewMatch.Value.Trim())
        }

        foreach ($fileMatch in [regex]::Matches($trimmed, 'file:[^#\s`|·]+#.+$')) {
            $value = $fileMatch.Value.Trim().Trim('`').Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $markers.Add($value)
            }
        }
    }

    return , $markers.ToArray()
}

function Get-StepPoints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Size
    )

    switch ($Size) {
        'S' { return 1 }
        'M' { return 2 }
        'L' { return 3 }
        default { return 0 }
    }
}

function Test-PlanMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Metadata,

        [ValidateSet('Draft', 'PhaseCrosscheck', 'PlanCrosscheck')]
        [string]$Stage = 'Draft'
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($warning in $Metadata.Warnings) {
        $warnings.Add($warning)
    }

    $isOptedIn = $Metadata.Content -match '(?m)^\s*<!--\s*evidence:\s*required\s*-->\s*$'
    if (-not $isOptedIn) {
        $warnings.Add("Legacy plan mode: '$($Metadata.PlanPath)' has no <!-- evidence: required --> marker, so integrity findings are warn-only.")
    }

    $reqIds = @($Metadata.Requirements.Keys | Sort-Object)
    if ($reqIds.Count -eq 0) {
        $errors.Add('Requirements table is missing REQ-* rows.')
    }
    else {
        $numbers = @($Metadata.Requirements.Values | Sort-Object Number | ForEach-Object { $_.Number })
        for ($index = 0; $index -lt $numbers.Count; $index++) {
            $expected = $index + 1
            if ($numbers[$index] -ne $expected) {
                $message = "REQ numbering is not sequential from REQ-1 (missing or out-of-order near REQ-$expected)."
                if ($isOptedIn) {
                    $errors.Add($message)
                }
                else {
                    $warnings.Add($message)
                }
                break
            }
        }
    }

    $riskIds = @($Metadata.Risks.Keys | Sort-Object)
    if ($riskIds.Count -gt 0) {
        $numbers = @($Metadata.Risks.Values | Sort-Object)
        for ($index = 0; $index -lt $numbers.Count; $index++) {
            $expected = $index + 1
            if ($numbers[$index] -ne $expected) {
                $message = "RISK numbering is not sequential from RISK-1 (missing or out-of-order near RISK-$expected)."
                if ($isOptedIn) {
                    $errors.Add($message)
                }
                else {
                    $warnings.Add($message)
                }
                break
            }
        }
    }

    $stepIds = @{}
    $reqRefsByStep = @{}
    $riskRefsByStep = @{}
    foreach ($step in $Metadata.Steps) {
        if ($stepIds.ContainsKey($step.Id)) {
            $message = "Duplicate step ID '$($step.Id)'."
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
            continue
        }
        $stepIds[$step.Id] = $true

        if ($step.Role -ne 'human' -and $step.Role -ne 'ai-agent') {
            $message = "Step '$($step.Id)' has invalid role '@$($step.Role)'."
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
        }

        if ($step.Size -notin @('S', 'M', 'L')) {
            $message = "Step '$($step.Id)' is missing size marker `S`, `M`, or `L`."
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
        }

        $reqRefs = @($step.Refs | Where-Object { $_ -match '^REQ-\d+$' })
        $riskRefs = @($step.Refs | Where-Object { $_ -match '^RISK-\d+$' })
        $reqRefsByStep[$step.Id] = $reqRefs
        $riskRefsByStep[$step.Id] = $riskRefs

        if ($reqRefs.Count -eq 0) {
            $message = "Step '$($step.Id)' must reference at least one REQ-* ID."
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
        }

        foreach ($reqRef in $reqRefs) {
            if (-not $Metadata.Requirements.ContainsKey($reqRef)) {
                $message = "Step '$($step.Id)' references unknown requirement '$reqRef'."
                if ($isOptedIn) {
                    $errors.Add($message)
                }
                else {
                    $warnings.Add($message)
                }
            }
        }

        foreach ($riskRef in $riskRefs) {
            if (-not $Metadata.Risks.ContainsKey($riskRef)) {
                $message = "Step '$($step.Id)' references unknown risk '$riskRef'."
                if ($isOptedIn) {
                    $errors.Add($message)
                }
                else {
                    $warnings.Add($message)
                }
            }
        }

        foreach ($afterId in $step.After) {
            if ($afterId -notmatch '^\d+\.\d+[a-z]?$') {
                $message = "Step '$($step.Id)' has invalid [after:] target '$afterId'."
                if ($isOptedIn) {
                    $errors.Add($message)
                }
                else {
                    $warnings.Add($message)
                }
                continue
            }

            if (-not $stepIds.ContainsKey($afterId) -and -not ($Metadata.Steps | Where-Object { $_.Id -eq $afterId })) {
                $message = "Step '$($step.Id)' depends on unknown step '$afterId'."
                if ($isOptedIn) {
                    $errors.Add($message)
                }
                else {
                    $warnings.Add($message)
                }
            }
        }
    }

    $graph = @{}
    foreach ($step in $Metadata.Steps) {
        $graph[$step.Id] = @($step.After)
    }

    $states = @{}
    function Visit-Step {
        param(
            [string]$StepId,
            [string[]]$Stack
        )

        $state = if ($states.ContainsKey($StepId)) { [int]$states[$StepId] } else { 0 }
        if ($state -eq 1) {
            $cycle = ($Stack + $StepId) -join ' -> '
            $message = "Dependency cycle detected: $cycle"
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
            return
        }
        if ($state -eq 2) {
            return
        }

        $states[$StepId] = 1
        foreach ($dependency in @($graph[$StepId])) {
            if ($graph.ContainsKey($dependency)) {
                Visit-Step -StepId $dependency -Stack ($Stack + $StepId)
            }
        }
        $states[$StepId] = 2
    }

    foreach ($step in $Metadata.Steps) {
        Visit-Step -StepId $step.Id -Stack @()
    }

    $referencedReqs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $referencedRisks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($stepId in $reqRefsByStep.Keys) {
        foreach ($reqRef in @($reqRefsByStep[$stepId])) {
            [void]$referencedReqs.Add($reqRef)
        }
    }
    foreach ($stepId in $riskRefsByStep.Keys) {
        foreach ($riskRef in @($riskRefsByStep[$stepId])) {
            [void]$referencedRisks.Add($riskRef)
        }
    }

    foreach ($reqId in $Metadata.Requirements.Keys) {
        if (-not $referencedReqs.Contains($reqId)) {
            $message = "Requirement '$reqId' is not referenced by any step."
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
        }
    }

    foreach ($riskId in $Metadata.Risks.Keys) {
        if (-not $referencedRisks.Contains($riskId)) {
            $message = "Risk '$riskId' is not referenced by any step."
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
        }
    }

    foreach ($requirement in $Metadata.Requirements.Values) {
        $markers = Get-TypedEvidenceMarkers -AcceptanceCriteria $requirement.AcceptanceCriteria
        if ($markers.Count -eq 0) {
            $message = "Requirement '$($requirement.Id)' has no typed evidence marker in acceptance criteria."
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
            continue
        }

        foreach ($marker in $markers) {
            if ($marker.StartsWith('test:')) {
                continue
            }

            if ($marker -match '^review:(cr|dr)$') {
                continue
            }

            if ($marker.StartsWith('file:')) {
                try {
                    $result = Invoke-PlanFileEvidence -RepoRoot $Metadata.RepoRoot -Marker $marker -Stage $Stage
                    if (-not $result.Success) {
                        if ($result.Blocking -and $isOptedIn) {
                            $errors.Add("$($requirement.Id): $($result.Message) [$marker]")
                        }
                        else {
                            $warnings.Add("$($requirement.Id): $($result.Message) [$marker]")
                        }
                    }
                }
                catch {
                    if ($isOptedIn) {
                        $errors.Add("$($requirement.Id): $($_.Exception.Message) [$marker]")
                    }
                    else {
                        $warnings.Add("$($requirement.Id): $($_.Exception.Message) [$marker]")
                    }
                }
                continue
            }

            $message = "$($requirement.Id): unknown evidence marker '$marker'."
            if ($isOptedIn) {
                $errors.Add($message)
            }
            else {
                $warnings.Add($message)
            }
        }
    }

    foreach ($phaseName in $Metadata.PhaseSteps.Keys) {
        $total = 0
        foreach ($step in $Metadata.PhaseSteps[$phaseName]) {
            $total += Get-StepPoints -Size $step.Size
        }

        if ($total -gt 6) {
            $warnings.Add("$phaseName uses $total phase-budget points (advisory cap is 6).")
        }
    }

    return [pscustomobject]@{
        Errors = @($errors)
        Warnings = @($warnings)
        OptedIn = $isOptedIn
    }
}

if ($PSCmdlet.ParameterSetName -eq 'VerifyEvidence') {
    try {
        $repoRootPath = [System.IO.Path]::GetFullPath($RepoRoot)
        $result = Invoke-PlanFileEvidence -RepoRoot $repoRootPath -Marker $EvidenceMarker -Stage $EvidenceStage
        if ($result.Success) {
            Write-Host "Evidence passed: $EvidenceMarker"
            exit 0
        }

        if ($result.Blocking) {
            Write-Host "Evidence failed: $($result.Message)" -ForegroundColor Red
            exit 1
        }

        Write-Host "Evidence warning: $($result.Message)" -ForegroundColor Yellow
        exit 0
    }
    catch {
        Write-Host "Evidence failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

try {
    $metadata = Get-PlanMetadata -Path $PlanPath
    $result = Test-PlanMetadata -Metadata $metadata -Stage $Stage
}
catch {
    Write-Host "Test-Plan failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

foreach ($warning in $result.Warnings) {
    Write-Host "WARN: $warning" -ForegroundColor Yellow
}

if ($result.Errors.Count -gt 0) {
    foreach ($validationError in $result.Errors) {
        Write-Host "ERROR: $validationError" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Test-Plan passed: '$($metadata.PlanPath)' ($Stage)" -ForegroundColor Green
exit 0
