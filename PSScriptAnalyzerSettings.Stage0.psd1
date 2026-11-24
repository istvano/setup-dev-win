# Extra analysis for bootstrap.ps1 only, on top of PSScriptAnalyzerSettings.psd1:
# stage-0 runs on Windows PowerShell 5.1, so its syntax and commands are checked
# against that edition. Profile file shipped with PSScriptAnalyzer 1.25.0:
# win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework.json
# (Windows 10/11 desktop, .NET Framework, PowerShell 5.1). Keep this file ASCII.
@{
    Severity = @('Error', 'Warning')

    IncludeRules = @(
        'PSUseCompatibleSyntax'
        'PSUseCompatibleCommands'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleCommands = @{
            Enable = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
