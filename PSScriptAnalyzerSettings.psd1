@{
    # PSScriptAnalyzer settings for skillz PowerShell scripts.
    # Plan 002 extends this shared baseline to scripts/skillz/** so both
    # scripts/autopilot/** and scripts/skillz/** stay warning-free.

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
