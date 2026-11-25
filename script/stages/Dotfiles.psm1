#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Common.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/WslConfig.psm1') -Force

function Invoke-DotfilesStage {
    <#
    .SYNOPSIS
        The Dotfiles stage: chezmoi owns .wslconfig.
    .DESCRIPTION
        Installs chezmoi when absent (latest stable), applies the repository's chezmoi source and
        offers to restart WSL when .wslconfig changed. Runs non-elevated.
    .PARAMETER Context
        Run context: Profiles, DistroRoot, LinuxRepoUrl, LinuxRef, Plan, Edition.
    .PARAMETER Plan
        Describe what would change; change nothing.
    .OUTPUTS
        done, reboot-required or failed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Plan
    )
    if (Test-IsElevated) {
        Write-Warn 'The dotfiles stage must run non-elevated: .wslconfig belongs to your user profile.'
        return 'failed'
    }
    if ($Plan) {
        Write-Info 'Would install the latest stable chezmoi when absent and apply .wslconfig from the chezmoi source.'
        return 'done'
    }
    try {
        Install-Chezmoi
        $distroRoot = if ($Context.ContainsKey('DistroRoot')) { [string]$Context.DistroRoot } else { '' }
        $apply = Invoke-ChezmoiApply -DistroRoot $distroRoot
        if ($apply.Changed) { Write-Ok '.wslconfig updated.' } else { Write-Ok '.wslconfig is up to date.' }
        Request-WslRestart -Changed $apply.Changed
    }
    catch {
        Write-Warn "Dotfiles stage failed: $($_.Exception.Message)"
        return 'failed'
    }
    return 'done'
}

Export-ModuleMember -Function Invoke-DotfilesStage
