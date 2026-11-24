#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# The runner lives in a module (not setup.ps1) so Pester can mock the stage
# functions and State/Common helpers with -ModuleName Runner.
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Detect.psm1') -Force
foreach ($stageModule in Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'stages') -Filter '*.psm1') {
    Import-Module $stageModule.FullName -Force
}

$script:StageOrder = @('preflight', 'features', 'dotfiles', 'wsl', 'verify')
$script:ValidProfiles = @('core', 'lab')
$script:RebootMessage = 'Reboot, then run script\setup.ps1 again.'
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
    .PARAMETER Profiles
        Comma-separated profile list; core,lab are valid; core is always included.
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
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$Profiles = 'core',
        [ValidateSet('preflight', 'features', 'dotfiles', 'wsl', 'verify')][string]$Stage,
        [switch]$Plan,
        [string]$LinuxRepoUrl,
        [string]$LinuxRef = 'main',
        [string]$DistroRoot = 'D:\WSL'
    )

    if (Test-IsElevated) {
        Write-Warn $script:ElevatedRefusal
        return 1
    }
    try {
        $profileList = ConvertTo-ProfileList -Profiles $Profiles
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
        DistroRoot = $DistroRoot
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
            if ($prior -eq 'done' -and $name -ne 'verify') {
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
