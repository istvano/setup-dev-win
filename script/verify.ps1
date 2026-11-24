#Requires -Version 7.6
<#
.SYNOPSIS
    Verifies the milestone-1 result: OS, features, WSL, .wslconfig, the dev distro.
.DESCRIPTION
    Runs the same checks as the verify stage, with no runner and no state file.
    Read-only. Exit code: 0 all checks passed, 1 at least one failed.
.PARAMETER DistroRoot
    Root directory for WSL distributions.
.PARAMETER Profiles
    Comma-separated profiles (core, lab). Decides whether Hyper-V is expected.
#>
[CmdletBinding()]
param(
    [string]$DistroRoot = 'D:\WSL',
    [string]$Profiles = 'core'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'lib/Detect.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'stages/Verify.psm1') -Force

if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    $profileList = @($Profiles -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ('core' -notin $profileList) { $profileList = @('core') + $profileList }
    $context = @{
        Profiles = $profileList
        DistroRoot = $DistroRoot
        Edition = Get-EditionInfo
    }
    $results = @(Invoke-VerifyChecks -Context $context)
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        Write-Host "$($failed.Count) of $($results.Count) checks failed."
        exit 1
    }
    Write-Host "All $($results.Count) checks passed."
    exit 0
}
