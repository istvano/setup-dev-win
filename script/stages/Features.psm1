#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Common.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/WindowsFeatures.psm1') -Force

function Get-ElevatedLogPath {
    # Internal, mockable. Where script/elevated/Enable-Features.ps1 appends its
    # [warn]/[fail] lines; the same expression lives in that script, which imports
    # nothing. $null when LOCALAPPDATA is not set.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:LOCALAPPDATA) { return $null }
    return (Join-Path $env:LOCALAPPDATA (Join-Path 'setup-dev-win' 'elevated.log'))
}

function Get-LogLineCount {
    # Internal. Number of lines in the file; 0 when it does not exist.
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    return @(Get-Content -LiteralPath $Path).Count
}

function Invoke-FeaturesStage {
    <#
    .SYNOPSIS
        The Features stage: Windows optional features, then the WSL package.
    .DESCRIPTION
        Missing features are enabled, and WSL is installed and updated when absent
        or below MinWslVersion, by one run of the elevated script: a single UAC
        prompt (wsl.exe no longer elevates itself, ADR-018). A restart Windows
        still reports as pending, for example from an earlier failed run, makes
        the stage return reboot-required.
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
    # Get-RequiredFeatures drops Hyper-V on Home, so without this check
    # -Stage features with lab on Home would report done.
    if (@($Context.Profiles) -contains 'lab' -and -not ($Context.Edition -and $Context.Edition.IsPro)) {
        Write-Warn 'The lab profile needs Windows 11 Pro (Hyper-V); this machine is not Pro.'
        return 'failed'
    }
    $pins = Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/pins.psd1')
    $minWsl = [version]$pins.MinWslVersion
    $required = @(Get-RequiredFeatures -Profiles @($Context.Profiles) -Edition $Context.Edition)

    $states = @{}
    foreach ($feature in $required) {
        $states[$feature] = Get-FeatureState -Name $feature
    }
    $missing = @($required | Where-Object { $states[$_] -ne 'Enabled' })
    $rebootNeeded = $false

    $wsl = Get-WslVersion
    $wslNeeded = ($null -eq $wsl) -or ($wsl -lt $minWsl)

    if ($Plan) {
        foreach ($feature in $missing) { Write-Info "Would enable Windows feature $feature (state: $($states[$feature]))" }
        if ($missing.Count -eq 0) { Write-Info 'Windows features already enabled.' }
        if ($wslNeeded) { Write-Info "Would install and update WSL (found: $(if ($wsl) { $wsl } else { 'none' }), need >= $minWsl)" }
        else { Write-Info "WSL $wsl is current." }
        return 'done'
    }

    if ($missing.Count -gt 0 -or $wslNeeded) {
        $steps = @()
        $arguments = @()
        if ($missing.Count -gt 0) {
            $steps += "enable $($missing -join ', ')"
            $arguments += @('-Name', ($missing -join ','))
        }
        if ($wslNeeded) {
            $steps += "install WSL (found: $(if ($wsl) { $wsl } else { 'none' }), need >= $minWsl)"
            $arguments += '-InstallWsl'
        }
        Write-Info "Elevated step: $($steps -join '; ') (one UAC prompt from this repo)"
        $log = Get-ElevatedLogPath
        $seen = Get-LogLineCount -Path $log
        try {
            $code = Invoke-ElevatedScript -Name 'Enable-Features' -ArgumentList $arguments
        }
        catch {
            Write-Warn "Could not run the elevated script (UAC declined?): $($_.Exception.Message)"
            return 'failed'
        }
        if ($code -ne 0 -and $log -and (Test-Path -LiteralPath $log -PathType Leaf)) {
            # The elevated window has closed; show what it reported.
            foreach ($line in @(Get-Content -LiteralPath $log | Select-Object -Skip $seen)) { Write-Warn "elevated: $line" }
        }
        switch ($code) {
            0 { }
            3010 { $rebootNeeded = $true }
            2 { Write-Warn 'The elevated script refused: a feature name is not allowlisted.'; return 'failed' }
            1 { Write-Warn "The elevated script failed (details above; log: $(if ($log) { $log } else { 'elevated.log' }))."; return 'failed' }
            default { Write-Warn "The elevated script exited with code $code."; return 'failed' }
        }
    }
    if ($missing.Count -eq 0) { Write-Ok 'Windows features already enabled.' }
    if (-not $wslNeeded) { Write-Ok "WSL $wsl is current." }

    if (-not $rebootNeeded -and (Test-RebootPending)) {
        Write-Info 'Windows reports a pending restart (for example from enabling a feature earlier).'
        $rebootNeeded = $true
    }

    if ($rebootNeeded) { return 'reboot-required' }
    return 'done'
}

Export-ModuleMember -Function Invoke-FeaturesStage
