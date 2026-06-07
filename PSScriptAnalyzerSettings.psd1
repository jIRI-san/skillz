@{
    # PSScriptAnalyzer settings for skalary PowerShell scripts.
    # Plan 002 extends this shared baseline to scripts/skalary/** so both
    # plugins/autopilot/scripts/** and scripts/skalary/** stay warning-free.

    # Use the full built-in rule set as the baseline.
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning')

    ExcludeRules = @(
        # Autopilot orchestrators stream live Copilot CLI output to the console;
        # Write-Host is the correct tool for human-facing progress, not data.
        'PSAvoidUsingWriteHost',
        # Markdown-plan parsing scripts intentionally use helper names that are
        # clearer with plural nouns and traversal verbs in this codebase.
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        # Validation helpers are pure transformations despite imperative verbs.
        'PSUseShouldProcessForStateChangingFunctions',
        # Repository scripts are UTF-8 without BOM by convention.
        'PSUseBOMForUnicodeEncodedFile'
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
