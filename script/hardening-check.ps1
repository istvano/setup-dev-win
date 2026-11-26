#Requires -Version 7.6
<#
.SYNOPSIS
    Read-only report of this machine's Windows security and privacy settings.
.DESCRIPTION
    Reads platform security (Secure Boot, TPM, memory integrity), Defender, UAC, the
    firewall, network exposure, legacy features and privacy settings, and prints
    OK, RECOMMEND, INFO or UNKNOWN for each. It changes nothing and never elevates:
    a read that needs an elevated terminal reports UNKNOWN (needs an elevated terminal).
    Exit code: 0 always; with -Strict, 1 when any check is RECOMMEND. UNKNOWN never fails.
.PARAMETER Strict
    Exit 1 when any check is RECOMMEND.
#>
[CmdletBinding()]
param(
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'lib/PostureChecks.psm1') -Force

if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    exit (Invoke-PostureReport -Strict:$Strict)
}
