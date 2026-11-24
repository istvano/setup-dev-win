#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Get-StatePath {
    # Internal. SETUP_DEV_WIN_STATE overrides the location (tests always set it).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:SETUP_DEV_WIN_STATE) { return $env:SETUP_DEV_WIN_STATE }
    if ($env:LOCALAPPDATA) { return Join-Path $env:LOCALAPPDATA (Join-Path 'setup-dev-win' 'state.json') }
    throw 'Cannot locate the state file: neither SETUP_DEV_WIN_STATE nor LOCALAPPDATA is set.'
}

function Read-State {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "State file '$path' is not valid JSON: $($_.Exception.Message)"
    }
    if ($state -isnot [hashtable]) { throw "State file '$path' does not hold a JSON object." }
    return $state
}

function ConvertTo-UtcDateTime {
    # ConvertFrom-Json turns ISO date strings into DateTime; accept both.
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    [datetime]::Parse([string]$Value, [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Get-BootTime {
    [CmdletBinding()]
    [OutputType([datetime])]
    param()
    (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
}

function Get-StageResult {
    <#
    .SYNOPSIS
        Returns the recorded result of a stage: done, reboot-required, failed, or $null.
    .PARAMETER Stage
        The stage name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Stage)
    $state = Read-State
    if (-not $state.ContainsKey($Stage)) { return $null }
    return [string]$state[$Stage].result
}

function Write-State {
    # Internal. Serialises first so a failure leaves the old file intact, then
    # writes a temp file and moves it over the state file in one step. Callers
    # own the ShouldProcess decision.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $path = Get-StatePath
    $json = $State | ConvertTo-Json -Depth 5

    $directory = Split-Path -Parent $path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Set-Content -LiteralPath $temp -Value $json -Encoding utf8NoBOM
        [System.IO.File]::Move($temp, $path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Set-StageResult {
    <#
    .SYNOPSIS
        Records a stage result with a UTC timestamp and the boot time, atomically.
    .PARAMETER Stage
        The stage name.
    .PARAMETER Result
        done, reboot-required or failed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][ValidateSet('done', 'reboot-required', 'failed')][string]$Result
    )
    $state = Read-State
    $state[$Stage] = @{
        result = $Result
        timestamp = [datetime]::UtcNow.ToString('o')
        bootTime = (Get-BootTime).ToString('o')
    }
    if (-not $PSCmdlet.ShouldProcess((Get-StatePath), "record stage '$Stage' as '$Result'")) { return }
    Write-State -State $state
}

# Operator choices kept across runs (ADR-015): linuxUser, distroRoot and profiles,
# under the "settings" key of the state file. No stage is named settings.

function Get-SetupSetting {
    <#
    .SYNOPSIS
        Returns a persisted operator choice, or $null when none is recorded.
    .PARAMETER Name
        linuxUser, distroRoot or profiles.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('linuxUser', 'distroRoot', 'profiles')][string]$Name)
    $state = Read-State
    if (-not $state.ContainsKey('settings') -or $state.settings -isnot [hashtable]) { return $null }
    if (-not $state.settings.ContainsKey($Name)) { return $null }
    $value = [string]$state.settings[$Name]
    if ([string]::IsNullOrEmpty($value)) { return $null }
    return $value
}

function Set-SetupSetting {
    <#
    .SYNOPSIS
        Persists an operator choice in the state file, atomically.
    .PARAMETER Name
        linuxUser, distroRoot or profiles.
    .PARAMETER Value
        The value to keep.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('linuxUser', 'distroRoot', 'profiles')][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $state = Read-State
    $settings = if ($state.ContainsKey('settings') -and $state.settings -is [hashtable]) { $state.settings } else { @{} }
    $settings[$Name] = $Value
    $state['settings'] = $settings
    if (-not $PSCmdlet.ShouldProcess((Get-StatePath), "persist setting '$Name' = '$Value'")) { return }
    Write-State -State $state
}

function Resolve-SetupSetting {
    <#
    .SYNOPSIS
        Applies the precedence explicit flag > persisted value > default. Read-only.
    .DESCRIPTION
        The caller persists the outcome (Set-SetupSetting) once it has validated
        it; script/verify.ps1 only reads.
    .PARAMETER Name
        linuxUser, distroRoot or profiles.
    .PARAMETER Value
        The flag's value; used only with -Explicit.
    .PARAMETER Explicit
        The operator passed the flag.
    .PARAMETER Default
        Used when there is no flag and nothing persisted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('linuxUser', 'distroRoot', 'profiles')][string]$Name,
        [AllowEmptyString()][string]$Value = '',
        [switch]$Explicit,
        [AllowEmptyString()][string]$Default = ''
    )
    if ($Explicit) { return $Value }
    $saved = Get-SetupSetting -Name $Name
    if ($null -ne $saved) { return $saved }
    return $Default
}

function Test-RebootHappenedSince {
    <#
    .SYNOPSIS
        True when the machine booted after the stage result was recorded.
    .PARAMETER Stage
        The stage name. A stage with no recorded boot time yields $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Stage)
    $state = Read-State
    if (-not $state.ContainsKey($Stage) -or -not $state[$Stage].ContainsKey('bootTime')) { return $false }
    $recorded = ConvertTo-UtcDateTime -Value $state[$Stage].bootTime
    return (Get-BootTime) -gt $recorded
}

Export-ModuleMember -Function Get-StageResult, Set-StageResult, Test-RebootHappenedSince, Get-SetupSetting,
Set-SetupSetting, Resolve-SetupSetting
