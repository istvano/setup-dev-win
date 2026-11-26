#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Common.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Apps.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Winget.psm1') -Force

function Invoke-AppsStage {
    <#
    .SYNOPSIS
        The Apps stage: install the packages of the selected profiles with winget.
    .DESCRIPTION
        Runs on every setup pass (like verify), so a profile added later installs.
        Installed packages are left alone; an app installed by hand that winget
        does not correlate is adopted when the installer says it is already there.
        One failing package does not stop the others: the stage collects every
        failure and returns failed naming each Id and reason. It never elevates;
        installers that need admin raise their own UAC prompt through winget.
    .PARAMETER Context
        Run context: Profiles (string[]) is used here.
    .PARAMETER Plan
        Describe what would be installed; install nothing.
    .OUTPUTS
        done, reboot-required or failed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Plan
    )
    $profiles = @($Context.Profiles)
    $csv = $profiles -join ','
    # First line, always: a state.json that persisted profiles from an earlier run
    # would otherwise leave the operator wondering why an app is missing.
    Write-Info "Profiles: $csv (change with pwsh -File script\setup.ps1 -Profiles $csv)"

    $packages = @(Get-AppPackages -Profiles $profiles)
    $failures = [System.Collections.Generic.List[string]]::new()
    $rebootNeeded = $false
    $already = 0

    foreach ($package in $packages) {
        $id = $package.Id
        $name = $package.Name
        try {
            $installed = Test-WingetPackage -Id $id
        }
        catch {
            $failures.Add("$id ($($_.Exception.Message))")
            continue
        }
        if ($installed) {
            $already++
            if (-not $Plan) { Write-Ok "$name already installed" }
            continue
        }
        if ($Plan) {
            Write-Info "Would install $name ($id)"
            continue
        }
        Write-Info "Installing $name ($id)..."
        try {
            $install = @{ Id = $id }
            if ($package.ContainsKey('Scope') -and $package.Scope) { $install.Scope = $package.Scope }
            $outcome = Install-WingetPackage @install
        }
        catch {
            $failures.Add("$id ($($_.Exception.Message))")
            continue
        }
        switch ($outcome) {
            'installed' { Write-Ok "Installed $name" }
            'already-installed' { Write-Ok "Adopted $name (already installed outside winget)" }
            'reboot-required' { Write-Ok "Installed $name (restart required)"; $rebootNeeded = $true }
            default { $failures.Add("$id (unexpected install outcome '$outcome')") }
        }
    }

    if ($Plan) {
        Write-Info "Already installed: $already"
        return 'done'
    }
    if ($failures.Count -gt 0) {
        Write-Warn "Failed to install: $($failures -join '; '); re-run pwsh -File script\setup.ps1 -Stage apps"
        return 'failed'
    }
    if ($rebootNeeded) { return 'reboot-required' }
    return 'done'
}

Export-ModuleMember -Function Invoke-AppsStage
