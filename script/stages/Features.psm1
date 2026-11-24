#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Common.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/WindowsFeatures.psm1') -Force

function Invoke-FeaturesStage {
    <#
    .SYNOPSIS
        The Features stage: Windows optional features, then the WSL package.
    .DESCRIPTION
        Missing features are enabled by the one elevated script (a single UAC
        prompt). WSL is installed or updated when absent or below MinWslVersion;
        wsl.exe raises its own UAC prompt, so it is not elevated here.
    .PARAMETER Context
        Run context: Profiles, DistroRoot, LinuxRepoUrl, LinuxRef, Plan, Edition.
    .PARAMETER Plan
        Describe what would change; change nothing and never elevate.
    .OUTPUTS
        done, reboot-required or failed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Plan
    )
    $pins = Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/pins.psd1')
    $minWsl = [version]$pins.MinWslVersion
    $required = @(Get-RequiredFeatures -Profiles @($Context.Profiles) -Edition $Context.Edition)

    $states = @{}
    foreach ($feature in $required) {
        $states[$feature] = Get-FeatureState -Name $feature -NoElevate:$Plan
    }
    $missing = @($required | Where-Object { $states[$_] -notin 'Enabled', 'EnablePending' })
    $rebootNeeded = @($required | Where-Object { $states[$_] -eq 'EnablePending' }).Count -gt 0

    $wsl = Get-WslVersion
    $wslNeeded = ($null -eq $wsl) -or ($wsl -lt $minWsl)

    if ($Plan) {
        foreach ($feature in $missing) { Write-Info "Would enable Windows feature $feature (state: $($states[$feature]))" }
        if ($missing.Count -eq 0) { Write-Info 'Windows features already enabled.' }
        if ($wslNeeded) { Write-Info "Would install and update WSL (found: $(if ($wsl) { $wsl } else { 'none' }), need >= $minWsl)" }
        else { Write-Info "WSL $wsl is current." }
        return 'done'
    }

    if ($missing.Count -gt 0) {
        Write-Info "Enabling Windows features: $($missing -join ', ') (one UAC prompt)"
        try {
            $code = Invoke-ElevatedScript -Name 'Enable-Features' -ArgumentList @('-Name', ($missing -join ','))
        }
        catch {
            Write-Warn "Could not run the elevated feature script (UAC declined?): $($_.Exception.Message)"
            return 'failed'
        }
        if ($code -eq 3010) { $rebootNeeded = $true }
        elseif ($code -ne 0) {
            Write-Warn "The elevated feature script failed with exit code $code."
            return 'failed'
        }
        else {
            foreach ($feature in $missing) {
                if ((Get-FeatureState -Name $feature) -eq 'EnablePending') { $rebootNeeded = $true }
            }
        }
    }
    else {
        Write-Ok 'Windows features already enabled.'
    }

    if ($wslNeeded) {
        Write-Info "Installing WSL (found: $(if ($wsl) { $wsl } else { 'none' }), need >= $minWsl)"
        foreach ($arguments in @(@('--install', '--no-distribution'), @('--update'))) {
            try {
                $result = Invoke-Native -FilePath 'wsl.exe' -ArgumentList $arguments -AllowExitCode 3010
            }
            catch {
                Write-Warn "wsl.exe $($arguments -join ' ') failed: $($_.Exception.Message)"
                return 'failed'
            }
            if ($result.ExitCode -eq 3010) { $rebootNeeded = $true }
        }
    }
    else {
        Write-Ok "WSL $wsl is current."
    }

    if ($rebootNeeded) { return 'reboot-required' }
    return 'done'
}

Export-ModuleMember -Function Invoke-FeaturesStage
