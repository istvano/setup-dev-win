Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-WindowsStub {
    <#
    .SYNOPSIS
        Defines global stubs for Windows-only cmdlets that this host lacks (W2).
    .DESCRIPTION
        Pester's Mock needs the command to exist. On Windows the real cmdlets are
        left alone and get mocked; on Linux pwsh a stub with the same parameter
        names the modules use is created. Dot-source this file, then call it from
        BeforeAll, then Mock -ModuleName <Module>.
    #>
    [CmdletBinding()]
    param()
    $stubs = @{
        'Get-Volume' = { [CmdletBinding()] param([char]$DriveLetter) throw 'stub: mock me' }
        'Enable-WindowsOptionalFeature' = { [CmdletBinding()] param([switch]$Online, [string]$FeatureName, [switch]$All, [switch]$NoRestart) throw 'stub: mock me' }
        'Get-WindowsOptionalFeature' = { [CmdletBinding()] param([switch]$Online, [string]$FeatureName) throw 'stub: mock me' }
        'Get-CimInstance' = { [CmdletBinding()] param([string]$ClassName, [string]$Namespace) throw 'stub: mock me' }
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "Function:\global:$name" -Value $stubs[$name]
        }
    }
}
