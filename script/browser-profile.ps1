#Requires -Version 7.6
<#
.SYNOPSIS
    Creates and opens isolated Chrome and Firefox profiles with separate data roots.
.DESCRIPTION
    Data roots live under %LOCALAPPDATA%\setup-dev-win\browsers\<browser>\<name>. Chrome is
    started with --user-data-dir and Firefox with -no-remote -profile. A browser's own
    default profile is never touched and nothing here elevates (ADR-027).
    Commands: ensure-defaults (personal and work), add NAME, list, open chrome|firefox NAME.
.PARAMETER Command
    ensure-defaults, add, list (default) or open.
.PARAMETER Argument
    add NAME, or open BROWSER NAME.
#>
[CmdletBinding()]
param(
    [string]$Command = 'list',
    [Parameter(ValueFromRemainingArguments)][string[]]$Argument = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'lib/BrowserProfiles.psm1') -Force

if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    exit (Invoke-BrowserProfileCommand -Command $Command -Argument $Argument)
}
