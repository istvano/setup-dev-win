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
        Returns a feature's state: Enabled, Disabled, Absent or Unknown.
    .DESCRIPTION
        Reads Win32_OptionalFeature through CIM, which needs no elevation
        (the DISM feature cmdlet does, and may appear only under script/elevated).
        EnablePending cannot be seen here; a pending restart is reported by the
        elevated script's exit code 3010 instead.
    .PARAMETER Name
        The feature name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $escaped = $Name.Replace("'", "''")
    $feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='$escaped'" | Select-Object -First 1
    if ($null -eq $feature) { return 'Unknown' }
    # [verify on real machine, Task 13] InstallState: 1 Enabled, 2 Disabled, 3 Absent.
    switch ([int]$feature.InstallState) {
        1 { return 'Enabled' }
        2 { return 'Disabled' }
        3 { return 'Absent' }
        default { return 'Unknown' }
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

function Test-RebootPending {
    <#
    .SYNOPSIS
        True when Windows servicing reports a pending restart.
    .DESCRIPTION
        Reads the Component Based Servicing RebootPending key, which a feature
        enable or package install sets until the next boot. Readable without
        elevation. It catches a restart owed by an earlier run that failed after
        enabling a feature, so the WSL stage never runs on a half-enabled platform.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

Export-ModuleMember -Function Get-RequiredFeatures, Get-FeatureState, Get-WslVersion, Test-RebootPending
