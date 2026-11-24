#Requires -Version 7.6
<#
.SYNOPSIS
    The only script in this repository that runs elevated: enables Windows optional features.
.DESCRIPTION
    Launched by Invoke-ElevatedScript in a fresh pwsh; it does not rely on the
    caller's module state and imports nothing. -Name is checked against an exact
    allowlist before anything else happens. Exit 0 = done, 3010 = restart needed,
    1 = enabling failed, 2 = refused input. It enables only; it never reads state.
.PARAMETER Name
    Feature names; a comma-separated token is split (-File passes one string per
    parameter, so the caller sends 'A,B' as a single token).
#>
[CmdletBinding()]
param(
    [string[]]$Name = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:AllowedFeatures = @('VirtualMachinePlatform', 'Microsoft-Hyper-V-All')

function Invoke-FeatureRequest {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string[]]$Name = @()
    )
    $names = @($Name | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names.Count -eq 0) {
        Write-Host '[fail] No feature name given.'
        return 2
    }
    # Exact, case-sensitive allowlist, checked before any cmdlet runs. A name that
    # is not listed (for example the Windows Sandbox feature) is refused outright.
    foreach ($n in $names) {
        if ($n -cnotin $script:AllowedFeatures) {
            Write-Host "[fail] Refusing feature '$n'. Allowed: $($script:AllowedFeatures -join ', ')."
            return 2
        }
    }

    $restart = $false
    foreach ($n in $names) {
        Write-Host "[info] Enabling $n"
        try {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart
        }
        catch {
            # Failure wins over a pending restart, but say that the restart is owed.
            if ($restart) { Write-Host '[warn] An earlier feature was enabled and needs a restart even though this run failed.' }
            throw
        }
        if ($result.RestartNeeded) { $restart = $true }
    }
    if ($restart) { return 3010 }
    return 0
}

# SETUP_DEV_WIN_NO_MAIN=1 lets tests dot-source the functions without running.
if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    try {
        $code = Invoke-FeatureRequest -Name $Name
    }
    catch {
        Write-Host "[fail] $($_.Exception.Message)"
        $code = 1
    }
    exit $code
}
