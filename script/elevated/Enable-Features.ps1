#Requires -Version 7.6
<#
.SYNOPSIS
    The only script in this repository that runs elevated: enables Windows optional features.
.DESCRIPTION
    Launched by Invoke-ElevatedScript in a fresh pwsh; it does not rely on the
    caller's module state and imports nothing. -Name is checked against an exact
    allowlist before anything else happens. Exit 0 = done, 3010 = restart needed,
    1 = enabling failed, 2 = refused input.
.PARAMETER Name
    Feature names; a comma-separated token is split (-File passes one string per
    parameter, so the caller sends 'A,B' as a single token).
.PARAMETER CheckOnly
    Enable nothing; report each feature's State as JSON {"<feature>":"<State>"}.
.PARAMETER OutFile
    With -CheckOnly: write the JSON here instead of stdout. An elevated child's
    stdout cannot cross ShellExecute RunAs, so the caller reads this file. Must be
    a setup-dev-win-features-<32 hex>.json file directly in the temp directory.
#>
[CmdletBinding()]
param(
    [string[]]$Name = @(),
    [switch]$CheckOnly,
    [string]$OutFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:AllowedFeatures = @('VirtualMachinePlatform', 'Microsoft-Hyper-V-All')

function Invoke-FeatureRequest {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string[]]$Name = @(),
        [switch]$CheckOnly,
        [string]$OutFile
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

    if ($CheckOnly) {
        $states = [ordered]@{}
        foreach ($n in $names) {
            $states[$n] = [string](Get-WindowsOptionalFeature -Online -FeatureName $n).State
        }
        $json = $states | ConvertTo-Json -Compress
        if ($OutFile) {
            $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
            $full = [System.IO.Path]::GetFullPath($OutFile)
            $leaf = [System.IO.Path]::GetFileName($full)
            $parent = [System.IO.Path]::GetDirectoryName($full)
            if ($leaf -cnotmatch '^setup-dev-win-features-[0-9a-f]{32}\.json$' -or $parent -ne $temp) {
                Write-Host '[fail] -OutFile must be setup-dev-win-features-<32 hex>.json in the temp directory.'
                return 2
            }
            [System.IO.File]::WriteAllText($full, $json)
        }
        else {
            Write-Output $json
        }
        return 0
    }

    $restart = $false
    foreach ($n in $names) {
        Write-Host "[info] Enabling $n"
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart
        if ($result.RestartNeeded) { $restart = $true }
    }
    if ($restart) { return 3010 }
    return 0
}

# SETUP_DEV_WIN_NO_MAIN=1 lets tests dot-source the functions without running.
if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    try {
        $code = Invoke-FeatureRequest -Name $Name -CheckOnly:$CheckOnly -OutFile $OutFile
    }
    catch {
        Write-Host "[fail] $($_.Exception.Message)"
        $code = 1
    }
    exit $code
}
