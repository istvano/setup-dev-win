#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-WslStage {
    <#
    .SYNOPSIS
        The Wsl stage (stub; a later task fills it).
    .PARAMETER Context
        Run context: Profiles, DistroRoot, LinuxRepoUrl, LinuxRef, Plan, Edition.
    .PARAMETER Plan
        Describe what would change; change nothing.
    .OUTPUTS
        done, reboot-required or failed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Plan
    )
    return 'done'
}

Export-ModuleMember -Function Invoke-WslStage
