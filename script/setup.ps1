#Requires -Version 7.6
<#
.SYNOPSIS
    Resumable provisioner for this Windows 11 host. Called by bootstrap.ps1.
.DESCRIPTION
    Thin entry point: the logic is Invoke-SetupRun in script\lib\Runner.psm1.
    Exit code: 0 done, 3010 reboot required, 1 failure.
.PARAMETER Profiles
    Comma-separated profiles (core, lab). core is always included. Persisted:
    a later run without -Profiles uses the last value given (default core).
.PARAMETER Stage
    Run only this stage (preflight, features, dotfiles, wsl, verify).
.PARAMETER Plan
    Show what would change; change and record nothing.
.PARAMETER LinuxRepoUrl
    The Linux bootstrap repository the wsl stage hands off to (default derived
    from pins.psd1 LinuxRepoOwner).
.PARAMETER LinuxRef
    Branch, tag or commit of that repository.
.PARAMETER DistroRoot
    Root directory for WSL distributions. Persisted like -Profiles (default D:\WSL).
.PARAMETER LinuxUser
    The Linux user created in the dev distro. Persisted like -Profiles (default:
    the Windows user name, lowercased, with invalid characters removed).
#>
[CmdletBinding()]
param(
    [string]$Profiles,
    [ValidateSet('preflight', 'features', 'dotfiles', 'wsl', 'verify')][string]$Stage,
    [switch]$Plan,
    [string]$LinuxRepoUrl,
    [string]$LinuxRef = 'main',
    [string]$DistroRoot,
    [string]$LinuxUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'lib/Runner.psm1') -Force

if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    exit (Invoke-SetupRun @PSBoundParameters)
}
