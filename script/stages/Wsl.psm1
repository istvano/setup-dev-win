#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Common.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Distro.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Handoff.psm1') -Force

function Invoke-WslStage {
    <#
    .SYNOPSIS
        The Wsl stage: verified distro install, then handoff to setup-dev-linux-wsl.
    .DESCRIPTION
        Install-DevDistro returns early when dev already exists, so the default user
        is asserted on every run; the password is set on a first install only. The
        handoff is interactive (the Linux bootstrap prompts for the git identity).
    .PARAMETER Context
        Run context: Profiles, DistroRoot, LinuxRepoUrl, LinuxRef, Plan, Edition.
    .PARAMETER Plan
        Describe what would change; change nothing.
    .OUTPUTS
        done or failed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Plan
    )
    if ($Plan) {
        Write-Info 'Would read the pinned distro lock and download the image to %TEMP%\setup-dev-win, verifying its SHA256.'
        Write-Info "Would install it as distro dev under $($Context.DistroRoot)\dev (skipped when dev exists) and verify placement and the default user."
        Write-Info 'Would set the Linux user password with passwd (first install only).'
        Write-Info "Would clone $($Context.LinuxRepoUrl) at $($Context.LinuxRef) inside dev and run: ./bootstrap apply --target wsl (interactive)."
        return 'done'
    }
    try {
        $lock = Get-DistroLock
        $image = Save-VerifiedImage -Lock $lock -Directory (Join-Path ([System.IO.Path]::GetTempPath()) 'setup-dev-win')
        $userName = Get-LinuxUserName
        $existed = $null -ne (Get-RegisteredDistro -Name 'dev')
        $record = Install-DevDistro -ImagePath $image -Root $Context.DistroRoot -UserName $userName
        Assert-DistroPlacement -Distro $record -Root $Context.DistroRoot
        Assert-DefaultUser -UserName $userName
        if (-not $existed) { Set-DevUserPassword -UserName $userName }
        $code = Invoke-LinuxHandoff -Url $Context.LinuxRepoUrl -Ref $Context.LinuxRef
    }
    catch {
        Write-Warn "Wsl stage failed: $($_.Exception.Message)"
        return 'failed'
    }
    if ($code -ne 0) {
        Write-Warn "The Linux bootstrap failed (exit code $code). Fix the cause and re-run script\setup.ps1; the handoff is idempotent."
        return 'failed'
    }
    return 'done'
}

Export-ModuleMember -Function Invoke-WslStage
