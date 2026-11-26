#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# The runner lives in a module (not setup.ps1) so Pester can mock the stage
# functions and State/Common helpers with -ModuleName Runner.
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Detect.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Distro.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Apps.psm1') -Force
foreach ($stageModule in Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'stages') -Filter '*.psm1') {
    Import-Module $stageModule.FullName -Force
}

$script:StageOrder = @('preflight', 'features', 'apps', 'dotfiles', 'wsl', 'verify')
$script:ValidProfiles = Get-ValidProfiles
# pwsh -File: the default shell is Windows PowerShell 5.1, which cannot run setup.ps1.
$script:RebootMessage = 'Reboot, then run pwsh -File script\setup.ps1 again (or powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1).'
# bootstrap.ps1 carries the same text; keep the two identical.
$script:ElevatedRefusal = 'Run from a normal (non-elevated) terminal; elevation is requested per step.'

function ConvertTo-ProfileList {
    # Internal. Parses the csv, validates against the milestone's profiles, always includes core.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Profiles)
    $requested = @($Profiles -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $unknown = @($requested | Where-Object { $_ -notin $script:ValidProfiles })
    if ($unknown.Count -gt 0) {
        throw "Unknown or not-yet-supported profile(s): $($unknown -join ', '). Valid: $($script:ValidProfiles -join ', ')."
    }
    return [string[]]@('core') + @($requested | Where-Object { $_ -ne 'core' } | Select-Object -Unique)
}

function Invoke-SetupRun {
    <#
    .SYNOPSIS
        Runs the resumable stage pipeline and returns the process exit code.
    .DESCRIPTION
        0 = all done, 3010 = reboot required, 1 = failure. A stage recorded done is
        skipped (verify always runs); a stage recorded reboot-required re-runs only
        after a reboot. -Stage runs one stage regardless of state. -Plan passes
        Plan to every stage and records nothing.
        Profiles, DistroRoot and LinuxUser are operator choices kept in the state
        file (ADR-015): a flag given explicitly wins and is persisted; without the
        flag the persisted value is used; without either, the default (core,dev,security,productivity,
        D:\WSL, the Linux user derived by the wsl stage). -Plan reads them and
        persists nothing.
    .PARAMETER Profiles
        Comma-separated profile list; the profiles in profiles\apps.psd1 are valid; core is always included.
    .PARAMETER Stage
        Run only this stage.
    .PARAMETER Plan
        Describe, do not change, and do not record state.
    .PARAMETER LinuxRepoUrl
        The Linux bootstrap repository the wsl stage hands off to. Default:
        https://github.com/<LinuxRepoOwner from pins.psd1>/setup-dev-linux-wsl.
    .PARAMETER LinuxRef
        Branch, tag or commit of that repository.
    .PARAMETER DistroRoot
        Root directory for WSL distributions.
    .PARAMETER LinuxUser
        The Linux user the wsl stage creates (default derived from the Windows user name).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$Profiles,
        [ValidateSet('preflight', 'features', 'apps', 'dotfiles', 'wsl', 'verify')][string]$Stage,
        [switch]$Plan,
        [string]$LinuxRepoUrl,
        [string]$LinuxRef = 'main',
        [string]$DistroRoot,
        [string]$LinuxUser
    )

    if (Test-IsElevated) {
        Write-Warn $script:ElevatedRefusal
        return 1
    }
    try {
        $bound = $PSBoundParameters
        $profileText = Resolve-SetupSetting -Name 'profiles' -Value $Profiles -Explicit:($bound.ContainsKey('Profiles')) -Default (Get-DefaultProfileText)
        $profileList = ConvertTo-ProfileList -Profiles $profileText
        $root = Resolve-SetupSetting -Name 'distroRoot' -Value $DistroRoot -Explicit:($bound.ContainsKey('DistroRoot')) -Default 'D:\WSL'
        $user = Resolve-SetupSetting -Name 'linuxUser' -Value $LinuxUser -Explicit:($bound.ContainsKey('LinuxUser'))
        # Validated before it is kept: the name reaches user-data and a command line.
        if ($user) { $user = Get-LinuxUserName -Override $user }
        if (-not $Plan) {
            $chosen = [ordered]@{ profiles = ($profileList -join ','); distroRoot = $root; linuxUser = $user }
            foreach ($key in $chosen.Keys) {
                if ($chosen[$key] -and $chosen[$key] -cne (Get-SetupSetting -Name $key)) {
                    Set-SetupSetting -Name $key -Value $chosen[$key]
                }
            }
        }
    }
    catch {
        Write-Warn $_.Exception.Message
        return 1
    }

    if ([string]::IsNullOrEmpty($LinuxRepoUrl)) {
        # One definition of the default: the owner lives in pins.psd1, the repo name is fixed.
        $pins = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'pins.psd1')
        $LinuxRepoUrl = "https://github.com/$($pins.LinuxRepoOwner)/setup-dev-linux-wsl"
    }
    $context = @{
        Profiles = $profileList
        DistroRoot = $root
        LinuxUser = $user
        LinuxRepoUrl = $LinuxRepoUrl
        LinuxRef = $LinuxRef
        Plan = [bool]$Plan
        # Seeded here (a registry read) so a re-run that skips preflight still has it.
        Edition = Get-EditionInfo
    }
    $explicit = [bool]$Stage
    $stages = if ($explicit) { @($Stage) } else { $script:StageOrder }

    foreach ($name in $stages) {
        if (-not $explicit -and -not $Plan) {
            $prior = Get-StageResult -Stage $name
            if ($prior -eq 'done' -and $name -notin @('apps', 'verify')) {
                Write-Info "Stage '$name' already done; skipping."
                continue
            }
            if ($prior -eq 'reboot-required' -and -not (Test-RebootHappenedSince -Stage $name)) {
                Write-Warn $script:RebootMessage
                return 3010
            }
        }

        Write-Info "Stage '$name'..."
        $function = 'Invoke-{0}Stage' -f ((Get-Culture).TextInfo.ToTitleCase($name))
        try {
            $result = & $function -Context $context -Plan:$Plan
        }
        catch {
            Write-Warn "Stage '$name' failed: $($_.Exception.Message)"
            if (-not $Plan) { Set-StageResult -Stage $name -Result 'failed' }
            return 1
        }

        if ($result -is [array]) { $result = $result[-1] }
        switch ($result) {
            'done' {
                if (-not $Plan) { Set-StageResult -Stage $name -Result 'done' }
                Write-Ok "Stage '$name' done."
            }
            'reboot-required' {
                if (-not $Plan) { Set-StageResult -Stage $name -Result 'reboot-required' }
                Write-Warn $script:RebootMessage
                return 3010
            }
            default {
                Write-Warn "Stage '$name' failed (returned '$result')."
                if (-not $Plan) { Set-StageResult -Stage $name -Result 'failed' }
                return 1
            }
        }
    }
    return 0
}

Export-ModuleMember -Function Invoke-SetupRun
