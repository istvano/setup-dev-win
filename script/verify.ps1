#Requires -Version 7.6
<#
.SYNOPSIS
    Verifies the milestone-1 result: OS, features, WSL, .wslconfig, the dev distro.
.DESCRIPTION
    Runs the same checks as the verify stage, with no runner. It reads the
    choices setup.ps1 persisted in the state file and writes nothing.
    Exit code: 0 all checks passed, 1 at least one failed.
.PARAMETER DistroRoot
    Root directory for WSL distributions (default: the value setup.ps1 persisted, else D:\WSL).
.PARAMETER Profiles
    Comma-separated profiles (core, lab). Decides whether Hyper-V is expected
    (default: the value setup.ps1 persisted, else core).
.PARAMETER LinuxUser
    The expected default user of dev (default: the value setup.ps1 persisted,
    else derived from the Windows user name).
#>
[CmdletBinding()]
param(
    [string]$DistroRoot,
    [string]$Profiles,
    [string]$LinuxUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'lib/State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'stages/Verify.psm1') -Force

if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    exit (Invoke-VerifyCommand @PSBoundParameters)
}
