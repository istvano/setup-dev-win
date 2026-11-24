# Explicit rule list: nothing is on by default. script/test.ps1 fails on any Error
# or Warning from these rules, and runs Invoke-Formatter with the Rules below.
@{
    Severity = @('Error', 'Warning')

    IncludeRules = @(
        # Correctness and safety
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingComputerNameHardcoded'
        'PSAvoidUsingCmdletAliases'
        'PSAvoidUsingPositionalParameters'
        'PSAvoidUsingWMICmdlet'
        'PSAvoidUsingEmptyCatchBlock'
        'PSAvoidAssignmentToAutomaticVariable'
        'PSAvoidDefaultValueSwitchParameter'
        'PSAvoidGlobalVars'
        'PSAvoidOverwritingBuiltInCmdlets'
        'PSAvoidShouldContinueWithoutForce'
        'PSAvoidUsingDoubleQuotesForConstantString'
        'PSMisleadingBacktick'
        'PSPossibleIncorrectComparisonWithNull'
        'PSPossibleIncorrectUsageOfAssignmentOperator'
        'PSPossibleIncorrectUsageOfRedirectionOperator'
        'PSReservedCmdletChar'
        'PSReservedParams'
        'PSUseApprovedVerbs'
        'PSUseCmdletCorrectly'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSShouldProcess'
        'PSUseSingularNouns'
        'PSUseOutputTypeCorrectly'
        'PSUseBOMForUnicodeEncodedFile'
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
        'PSPlaceOpenBrace'
        'PSPlaceCloseBrace'
        'PSProvideCommentHelp'
    )

    # An explicit, narrow exclusion list lives here so that it is reviewable.
    ExcludeRules = @()

    Rules = @{
        PSUseConsistentIndentation = @{
            Enable = $true
            IndentationSize = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind = 'space'
        }
        PSUseConsistentWhitespace = @{
            Enable = $true
            CheckInnerBrace = $true
            CheckOpenBrace = $true
            CheckOpenParen = $true
            CheckOperator = $true
            CheckPipe = $true
            CheckPipeForRedundantWhitespace = $true
            CheckSeparator = $true
            CheckParameter = $false
        }
        PSPlaceOpenBrace = @{
            Enable = $true
            OnSameLine = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace = @{
            Enable = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore = $false
        }
        PSProvideCommentHelp = @{
            Enable = $true
            ExportedOnly = $true
            BlockComment = $true
            VSCodeSnippetCorrection = $false
            Placement = 'before'
        }
    }
}
