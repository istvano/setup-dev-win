#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Common.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Detect.psm1') -Force

function Invoke-PreflightStage {
    <#
    .SYNOPSIS
        The Preflight stage: read-only checks that must pass before any change.
    .DESCRIPTION
        Every failed check is reported (one warning each) so the operator sees all
        problems at once. Nothing is modified, so -Plan behaves identically.
    .PARAMETER Context
        Run context: Profiles, DistroRoot, LinuxRepoUrl, LinuxRef, Plan, Edition.
        Edition is set to the Get-EditionInfo result.
    .PARAMETER Plan
        Accepted for the stage contract; preflight is read-only either way.
    .OUTPUTS
        done or failed (preflight never needs a reboot).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Plan
    )
    $pins = Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/pins.psd1')
    $failures = [System.Collections.Generic.List[string]]::new()

    $edition = Get-EditionInfo
    $Context.Edition = $edition
    Write-Info "Windows edition: $($edition.Edition)"
    Write-Info "Kernel DMA Protection: $(Get-KernelDmaProtectionState)"

    $build = Get-OsBuild
    if ($build -lt $pins.MinOsBuild) {
        $failures.Add("Windows build $build is below the minimum $($pins.MinOsBuild); update Windows first.")
    }

    if ($Context.DistroRoot -match '^([A-Za-z]):\\') {
        $volume = Test-DataVolume -DriveLetter ([char]$Matches[1].ToUpperInvariant())
        if (-not $volume.Ok) {
            $message = "Distro volume check failed for $($Context.DistroRoot): $($volume.Reason)"
            # Missing, not fixed or not NTFS (W21): say how to pick another drive.
            $message += ' To use another drive, re-run with -DistroRoot <drive>:\WSL, for example: ' +
            'powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -DistroRoot C:\WSL ' +
            '(or pwsh -File script\setup.ps1 -DistroRoot C:\WSL).'
            $failures.Add($message)
        }
    }
    else {
        $failures.Add("DistroRoot '$($Context.DistroRoot)' must start with a drive letter such as D:\.")
    }

    if (Test-DocumentsRedirected) {
        $failures.Add('The Documents folder is redirected (e.g. OneDrive); the PowerShell profile and dotfiles need a local Documents folder.')
    }

    if (-not (Test-VirtualizationAvailable)) {
        $failures.Add('Hardware virtualization is unavailable; enable Intel VT-x/VT-d in firmware (BIOS/UEFI) and retry.')
    }

    if (@($Context.Profiles) -contains 'lab' -and -not $edition.IsPro) {
        $failures.Add('The lab profile needs Windows 11 Pro (Hyper-V); this machine is not Pro.')
    }

    foreach ($failure in $failures) { Write-Warn $failure }
    if ($failures.Count -gt 0) { return 'failed' }
    return 'done'
}

Export-ModuleMember -Function Invoke-PreflightStage
