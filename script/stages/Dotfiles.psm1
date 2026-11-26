#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Common.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/WslConfig.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/TerminalSettings.psm1') -Force

function Invoke-DotfilesStage {
    <#
    .SYNOPSIS
        The Dotfiles stage: chezmoi owns .wslconfig and the PowerShell profile; Terminal settings and the telemetry opt-out.
    .DESCRIPTION
        Installs chezmoi when absent (latest stable), applies the repository's chezmoi source and
        offers to restart WSL when .wslconfig changed, sets POWERSHELL_TELEMETRY_OPTOUT=1 for the user and
        merges the declared Windows Terminal settings. Runs every pass, so a declared setting changed
        in the Terminal UI is restored. Runs non-elevated.
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
        Write-Info 'Would install the latest stable chezmoi when absent and apply .wslconfig and the PowerShell profile from the chezmoi source (existing files that differ are backed up first).'
        Write-Info 'Would set the user environment variable POWERSHELL_TELEMETRY_OPTOUT to 1 when it is not already.'
        Write-Info 'Would merge the declared Windows Terminal settings into settings.json (backup first when it changes).'
        return 'done'
    }
    try {
        Install-Chezmoi
        $distroRoot = if ($Context.ContainsKey('DistroRoot')) { [string]$Context.DistroRoot } else { '' }
        $apply = Invoke-ChezmoiApply -DistroRoot $distroRoot
        if ($apply.Changed) { Write-Ok '.wslconfig updated.' } else { Write-Ok '.wslconfig is up to date.' }
        Request-WslRestart -Changed $apply.Changed
        if ((Get-UserEnvironmentVariable -Name 'POWERSHELL_TELEMETRY_OPTOUT') -ne '1') {
            Set-UserEnvironmentVariable -Name 'POWERSHELL_TELEMETRY_OPTOUT' -Value '1'
            Write-Ok 'PowerShell telemetry opt-out set for this user (POWERSHELL_TELEMETRY_OPTOUT=1).'
        }
        switch (Update-TerminalSettings) {
            'updated' { Write-Ok 'Windows Terminal settings updated.' }
            'unchanged' { Write-Ok 'Windows Terminal settings are up to date.' }
            default { Write-Info 'Windows Terminal is not set up for this user yet; skipped.' }
        }
    }
    catch {
        Write-Warn "Dotfiles stage failed: $($_.Exception.Message)"
        return 'failed'
    }
    return 'done'
}

Export-ModuleMember -Function Invoke-DotfilesStage
