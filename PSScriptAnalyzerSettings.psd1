@{
    # PSScriptAnalyzer settings for the skillz autopilot scripts.
    # The local validation gate (scripts/autopilot/validate-local.ps1) and the
    # pre-commit hook run Invoke-ScriptAnalyzer with these settings and require
    # ZERO warnings across scripts/autopilot/**.

    # Use the full built-in rule set as the baseline.
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning')

    ExcludeRules = @(
        # Autopilot orchestrators stream live Copilot CLI output to the console;
        # Write-Host is the correct tool for human-facing progress, not data.
        'PSAvoidUsingWriteHost'
    )

    Rules = @{
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable          = $true
            Kind            = 'space'
            IndentationSize = 4
        }
        PSUseConsistentWhitespace = @{
            Enable          = $true
            CheckOpenBrace  = $true
            CheckOpenParen  = $true
            CheckOperator   = $true
            CheckSeparator  = $true
        }
    }
}
