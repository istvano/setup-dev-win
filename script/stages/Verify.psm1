#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$libRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
Import-Module (Join-Path $libRoot 'Common.psm1') -Force
Import-Module (Join-Path $libRoot 'Detect.psm1') -Force
Import-Module (Join-Path $libRoot 'WindowsFeatures.psm1') -Force
Import-Module (Join-Path $libRoot 'WslConfig.psm1') -Force
Import-Module (Join-Path $libRoot 'Distro.psm1') -Force
# No -Force: share the State instance the runner (or verify.ps1) loaded.
Import-Module (Join-Path $libRoot 'State.psm1')

function Write-CheckResult {
    # Internal. Prints one OK/FAIL line and returns the result object.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Reason = ''
    )
    if ($Ok) { Write-Host "OK $Name" -ForegroundColor Green }
    else { Write-Host "FAIL ${Name}: $Reason" -ForegroundColor Red }
    [pscustomobject]@{ Name = $Name; Ok = $Ok; Reason = $Reason }
}

function Invoke-VerifyCheck {
    # Internal. Runs one check script block; a throw becomes a FAIL so the
    # remaining checks still run. The block returns '' for pass, else the reason.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Check
    )
    try { $reason = [string](& $Check) }
    catch { $reason = $_.Exception.Message }
    Write-CheckResult -Name $Name -Ok ([string]::IsNullOrEmpty($reason)) -Reason $reason
}

function Invoke-VerifyChecks {
    <#
    .SYNOPSIS
        Runs the milestone-1 verification checks and returns one result per check.
    .DESCRIPTION
        Shared by the verify stage and script/verify.ps1. Each check prints
        "OK <name>" or "FAIL <name>: <reason>"; a failure never stops the later
        checks. Check 7 (Kernel DMA Protection, systemd state) is informational and
        returns nothing. Read-only: nothing is modified.
    .PARAMETER Context
        Run context: Profiles, DistroRoot, LinuxUser (derived when empty), Edition
        (seeded from Get-EditionInfo when absent).
    .OUTPUTS
        [pscustomobject] with Name, Ok, Reason, one per check.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Runs the set of checks; the name is the interface the stage, script/verify.ps1 and tests use.')]
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][hashtable]$Context)

    $pins = Import-PowerShellDataFile -LiteralPath (Join-Path $libRoot 'pins.psd1')
    $edition = if ($Context.ContainsKey('Edition') -and $Context.Edition) { $Context.Edition } else { Get-EditionInfo }
    $profiles = @($Context.Profiles)
    $root = [string]$Context.DistroRoot
    $linuxUser = if ($Context.ContainsKey('LinuxUser')) { [string]$Context.LinuxUser } else { '' }
    $featuresHint = if ($profiles -contains 'lab') { 'pwsh -File script\setup.ps1 -Stage features -Profiles lab' } else { 'pwsh -File script\setup.ps1 -Stage features' }
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    # 1. Build and edition.
    $results.Add((Invoke-VerifyCheck -Name 'Windows build' -Check {
                $build = Get-OsBuild
                Write-Host "     edition: $($edition.Edition), build $build"
                if ($build -lt $pins.MinOsBuild) { "build $build is below the minimum $($pins.MinOsBuild); update Windows." }
            }))

    # 2. Required features Enabled; Hyper-V only with lab.
    $results.Add((Invoke-VerifyCheck -Name 'Windows features' -Check {
                $problems = [System.Collections.Generic.List[string]]::new()
                $required = @(Get-RequiredFeatures -Profiles $profiles -Edition $edition)
                foreach ($feature in $required) {
                    $state = Get-FeatureState -Name $feature
                    if ($state -ne 'Enabled') { $problems.Add("$feature is $state (expected Enabled); run $featuresHint.") }
                }
                if ('Microsoft-Hyper-V-All' -notin $required) {
                    $hyperV = Get-FeatureState -Name 'Microsoft-Hyper-V-All'
                    if ($hyperV -notin 'Disabled', 'Absent', 'Unknown') {
                        $problems.Add("Hyper-V is $hyperV but the lab profile is not selected; disable it or select lab.")
                    }
                }
                $problems -join ' '
            }))

    # 3. WSL version.
    $results.Add((Invoke-VerifyCheck -Name 'WSL version' -Check {
                $version = Get-WslVersion
                if ($null -eq $version) { return 'wsl --version failed or WSL is not installed.' }
                if ($version -lt [version]$pins.MinWslVersion) { "WSL $version is below the minimum $($pins.MinWslVersion); run wsl --update." }
            }))

    # 4. .wslconfig has no drift against the chezmoi source.
    $results.Add((Invoke-VerifyCheck -Name 'chezmoi verify (.wslconfig)' -Check {
                $verify = Invoke-ChezmoiVerify
                if (-not $verify.Ok) { "chezmoi reports drift or an error: $((@($verify.Output) | Select-Object -First 5) -join '; ')" }
            }))

    # 5. dev is registered, under the root, WSL 2, and starts as the right user.
    $record = Get-RegisteredDistro -Name 'dev'
    $results.Add((Invoke-VerifyCheck -Name 'dev distro' -Check {
                if ($null -eq $record) { return 'distro dev is not registered; run pwsh -File script\setup.ps1 -Stage wsl.' }
                Assert-DistroPlacement -Distro $record -Root $root
                $expectedUser = if ($linuxUser) { $linuxUser } else { Get-LinuxUserName }
                Assert-DefaultUser -UserName $expectedUser
                # Informational only: the registry value is unreliable for .wsl images (W16).
                Write-Host "     registry DefaultUid: $($record.DefaultUid)"
            }))

    # 6. The Linux repository's own verify, run as the default user; output streams to the host.
    $results.Add((Invoke-VerifyCheck -Name 'Linux verify' -Check {
                if ($null -eq $record) { return 'distro dev is not registered.' }
                $linuxVerify = '~/workspace/setup-dev-linux-wsl/script/verify'
                $run = Invoke-Native -FilePath 'wsl.exe' -AllowExitCode (1..255) -ArgumentList @('-d', 'dev', '--', 'bash', '-lc', $linuxVerify)
                foreach ($line in $run.Output) { Write-Host "     $line" }
                if ($run.ExitCode -ne 0) { "setup-dev-linux-wsl verify failed (exit code $($run.ExitCode)); its output is above." }
            }))

    # 7. Informational: never fails.
    Write-Host "INFO Kernel DMA Protection: $(Get-KernelDmaProtectionState)"
    try {
        if ($null -eq $record) { throw 'dev is not registered' }
        $state = Invoke-Native -FilePath 'wsl.exe' -AllowExitCode (1..255) -ArgumentList @('-d', 'dev', '--', 'systemctl', 'is-system-running')
        $text = Get-LastResultLine -Line $state.Output
        if ($text -in 'running', 'degraded') { Write-Host "INFO systemd in dev: $text" }
        else { Write-Host "INFO systemd in dev: '$text' (reported, not a failure)" }
    }
    catch { Write-Host "INFO systemd in dev: unreadable ($($_.Exception.Message))" }

    return $results.ToArray()
}

function Invoke-VerifyStage {
    <#
    .SYNOPSIS
        The Verify stage: read-only checks of the whole milestone-1 result.
    .PARAMETER Context
        Run context: Profiles, DistroRoot, LinuxRepoUrl, LinuxRef, Plan, Edition.
    .PARAMETER Plan
        Describe what would run; run nothing.
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
        Write-Info 'Would check: OS build, features, WSL version, chezmoi drift, the dev distro, the Linux verify (read-only).'
        return 'done'
    }
    $results = @(Invoke-VerifyChecks -Context $Context)
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        Write-Warn "$($failed.Count) of $($results.Count) verification checks failed."
        return 'failed'
    }
    return 'done'
}

function Invoke-VerifyCommand {
    <#
    .SYNOPSIS
        The body of script/verify.ps1: resolves the operator's choices, runs the checks, returns the exit code.
    .DESCRIPTION
        A flag given explicitly wins; otherwise the value persisted by setup.ps1
        is used (ADR-015); otherwise the default. Read-only: nothing is persisted.
    .PARAMETER DistroRoot
        Root directory for WSL distributions.
    .PARAMETER Profiles
        Comma-separated profiles; decides whether Hyper-V is expected.
    .PARAMETER LinuxUser
        The expected default user of dev.
    .OUTPUTS
        0 when every check passed, 1 otherwise.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$DistroRoot,
        [string]$Profiles,
        [string]$LinuxUser
    )
    $bound = $PSBoundParameters
    $profileText = Resolve-SetupSetting -Name 'profiles' -Value $Profiles -Explicit:($bound.ContainsKey('Profiles')) -Default 'core'
    $profileList = @($profileText -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ('core' -notin $profileList) { $profileList = @('core') + $profileList }
    $context = @{
        Profiles = $profileList
        DistroRoot = Resolve-SetupSetting -Name 'distroRoot' -Value $DistroRoot -Explicit:($bound.ContainsKey('DistroRoot')) -Default 'D:\WSL'
        LinuxUser = Resolve-SetupSetting -Name 'linuxUser' -Value $LinuxUser -Explicit:($bound.ContainsKey('LinuxUser'))
        Edition = Get-EditionInfo
    }
    $results = @(Invoke-VerifyChecks -Context $context)
    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        Write-Host "$($failed.Count) of $($results.Count) checks failed."
        return 1
    }
    Write-Host "All $($results.Count) checks passed."
    return 0
}

Export-ModuleMember -Function Invoke-VerifyStage, Invoke-VerifyChecks, Invoke-VerifyCommand
