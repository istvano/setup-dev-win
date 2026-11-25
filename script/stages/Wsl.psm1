#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Common.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Distro.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Handoff.psm1') -Force
# No -Force: the runner has already loaded State, and reloading it would split the
# module in two (mocks and callers would see different instances).
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/State.psm1')

function Test-DevPasswordNeeded {
    # Internal. True when the user's password is locked (L), empty (NP) or cannot be
    # read: failing safe means asking. cloud-init locks it, and sudo needs it.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$UserName)
    try {
        $r = Invoke-Native -FilePath 'wsl.exe' -AllowExitCode (1..255) -ArgumentList @('-d', 'dev', '-u', 'root', '--', 'passwd', '-S', $UserName)
        $fields = @((Get-LastResultLine -Line $r.Output) -split '\s+')
        if ($r.ExitCode -eq 0 -and $fields.Count -ge 2) {
            if ($fields[1] -eq 'P') { return $false }
            if ($fields[1] -in 'L', 'NP') { return $true }
        }
    }
    catch { Write-Verbose $_.Exception.Message }
    Write-Warn "Could not read the password status of '$UserName'; asking for a password."
    return $true
}

function Invoke-WslStage {
    <#
    .SYNOPSIS
        The Wsl stage: verified distro install, then handoff to setup-dev-linux-wsl.
    .DESCRIPTION
        Install-DevDistro returns early when dev already exists, so the default user
        is asserted on every run; the password is set whenever passwd -S reports it locked. The
        handoff is interactive (the Linux bootstrap prompts for the git identity).
        The Linux user is Context.LinuxUser when set; otherwise it is derived from
        the Windows user name and persisted, so later runs and verify use the same
        name (ADR-015).
    .PARAMETER Context
        Run context: Profiles, DistroRoot, LinuxUser, LinuxRepoUrl, LinuxRef, Plan, Edition.
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
    $chosenUser = if ($Context.ContainsKey('LinuxUser')) { [string]$Context.LinuxUser } else { '' }
    if (-not (Test-LinuxRepoUrl -Url ([string]$Context.LinuxRepoUrl))) {
        Write-Warn "Invalid LinuxRepoUrl '$($Context.LinuxRepoUrl)': expected https://github.com/<owner>/<repo>[.git]."
        return 'failed'
    }
    if (-not (Test-GitRef -Ref ([string]$Context.LinuxRef))) {
        Write-Warn "Invalid LinuxRef '$($Context.LinuxRef)'."
        return 'failed'
    }
    # The image is cached on the distro drive, not in %TEMP%: it stays off C:, and
    # an MSIX pwsh's writes under AppData can be virtualised where wsl.exe cannot
    # see them (W21).
    $cache = "$(([string]$Context.DistroRoot).TrimEnd('\'))\cache"
    if ($Plan) {
        Write-Info "Would resolve the newest image of the distro in wsl\ubuntu.lock.psd1 from Microsoft's DistributionInfo.json and download it to $cache, verifying its SHA256."
        $who = if ($chosenUser) { $chosenUser } else { 'derived from the Windows user name' }
        Write-Info "Would install it as distro dev under $($Context.DistroRoot)\dev with Linux user $who (skipped when dev exists) and verify placement and the default user."
        Write-Info 'Would set the Linux user password with passwd when it is still locked.'
        Write-Info "Would clone $($Context.LinuxRepoUrl) at $($Context.LinuxRef) inside dev and run: ./bootstrap apply --target wsl (interactive)."
        return 'done'
    }
    try {
        $lock = Get-DistroLock
        $resolved = Resolve-DistroImage -Lock $lock
        Write-Info "Distro image: $($resolved.Url)"
        $image = Save-VerifiedImage -Image $resolved -Directory $cache
        if ($chosenUser) { $userName = Get-LinuxUserName -Override $chosenUser }
        else {
            $userName = Get-LinuxUserName
            Set-SetupSetting -Name 'linuxUser' -Value $userName
        }
        Write-Info "Linux user: $userName"
        $record = Install-DevDistro -ImagePath $image -Root $Context.DistroRoot -UserName $userName
        Assert-DistroPlacement -Distro $record -Root $Context.DistroRoot
        # Install-DevDistro returns early for an existing dev, so on a re-run this is
        # the first check of the user and the recovery hint is added here.
        try { Assert-DefaultUser -UserName $userName }
        catch { throw "$($_.Exception.Message) $(Get-DistroRecoveryHint)" }
        if (Test-DevPasswordNeeded -UserName $userName) { Set-DevUserPassword -UserName $userName }
        $code = Invoke-LinuxHandoff -Url $Context.LinuxRepoUrl -Ref $Context.LinuxRef
    }
    catch {
        Write-Warn "Wsl stage failed: $($_.Exception.Message)"
        return 'failed'
    }
    if ($code -ne 0) {
        Write-Warn "The Linux bootstrap failed (exit code $code). Fix the cause and re-run pwsh -File script\setup.ps1 -Stage wsl; the handoff is idempotent."
        return 'failed'
    }
    return 'done'
}

Export-ModuleMember -Function Invoke-WslStage
