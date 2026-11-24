#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

function Get-RequiredFeatures {
    <#
    .SYNOPSIS
        The Windows optional features this run needs.
    .DESCRIPTION
        Always VirtualMachinePlatform. Microsoft-Hyper-V-All only for the lab
        profile on Pro (Home cannot have it; preflight already refused that).
    .PARAMETER Profiles
        Selected profile names.
    .PARAMETER Edition
        The Get-EditionInfo result (needs IsPro).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Returns the set of features; the name is the interface the stage and tests use.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$Profiles = @(),
        [Parameter(Mandatory)][hashtable]$Edition
    )
    $features = [System.Collections.Generic.List[string]]::new()
    $features.Add('VirtualMachinePlatform')
    if ('lab' -in $Profiles -and $Edition.IsPro) { $features.Add('Microsoft-Hyper-V-All') }
    return [string[]]$features
}

function Get-FeatureState {
    <#
    .SYNOPSIS
        Returns a feature's State (Enabled, Disabled, EnablePending, ...).
    .DESCRIPTION
        Reads Get-WindowsOptionalFeature without elevation first. [verify] whether
        that works non-elevated; the real machine settles it (Task 13). On an
        elevation or access error it falls back to the elevated script's
        -CheckOnly mode, which writes JSON to a temp file (stdout cannot cross
        ShellExecute RunAs). With -NoElevate it returns 'Unknown' instead of
        elevating, so -Plan never raises a UAC prompt.
    .PARAMETER Name
        The feature name.
    .PARAMETER NoElevate
        Never fall back to the elevated read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$NoElevate
    )
    try {
        return [string](Get-WindowsOptionalFeature -Online -FeatureName $Name).State
    }
    catch {
        if ($_.Exception.Message -notmatch 'elevat|access|denied|privilege|0x800702E4') { throw }
        if ($NoElevate) { return 'Unknown' }
    }

    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ('setup-dev-win-features-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        $code = Invoke-ElevatedScript -Name 'Enable-Features' -ArgumentList @('-CheckOnly', '-Name', $Name, '-OutFile', $outFile)
        if ($code -ne 0) { throw "Reading the state of feature $Name failed (elevated script exit $code)." }
        if (-not (Test-Path -LiteralPath $outFile -PathType Leaf)) { throw "The elevated read of feature $Name produced no result." }
        $parsed = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
        return [string]$parsed.$Name
    }
    finally {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-WslVersion {
    <#
    .SYNOPSIS
        The installed WSL version as [version], or $null when wsl is missing or fails.
    .DESCRIPTION
        Parses the first dotted version in `wsl --version`. Invoke-Native sets
        WSL_UTF8=1, so the bytes are UTF-8; PowerShell decodes with the console
        encoding, but the version line is ASCII in both, so the regex is robust.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param()
    try {
        $result = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--version')
    }
    catch {
        return $null
    }
    foreach ($line in $result.Output) {
        if ($line -match '\d+\.\d+\.\d+(\.\d+)?') { return [version]$Matches[0] }
    }
    return $null
}

Export-ModuleMember -Function Get-RequiredFeatures, Get-FeatureState, Get-WslVersion
