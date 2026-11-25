#Requires -Version 7.6
<#
.SYNOPSIS
    The only script in this repository that runs elevated: enables Windows optional features.
.DESCRIPTION
    Launched by Invoke-ElevatedScript in a fresh pwsh; it does not rely on the
    caller's module state and imports nothing. -Name is checked against an exact
    allowlist before anything else happens. Exit 0 = done, 3010 = restart needed,
    1 = enabling failed, 2 = refused input. It enables only; it never reads state.
    Its window closes when it exits, so every [warn] and [fail] line is also
    appended, timestamped, to %LOCALAPPDATA%\setup-dev-win\elevated.log, which
    the features stage prints after a failed run. The elevated process runs as
    the same (administrator) user, so LOCALAPPDATA is the caller's.
.PARAMETER Name
    Feature names; a comma-separated token is split (-File passes one string per
    parameter, so the caller sends 'A,B' as a single token).
#>
[CmdletBinding()]
param(
    [string[]]$Name = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:AllowedFeatures = @('VirtualMachinePlatform', 'Microsoft-Hyper-V-All')
$script:ElevatedLogPath = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA (Join-Path 'setup-dev-win' 'elevated.log') } else { $null }

function Write-ElevatedLine {
    # Prints the line; [warn] and [fail] lines are also appended to the log. A
    # log that cannot be written never changes the exit code.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('info', 'warn', 'fail')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Host "[$Level] $Message"
    if ($Level -eq 'info' -or -not $script:ElevatedLogPath) { return }
    try {
        $directory = Split-Path -Parent $script:ElevatedLogPath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        $line = '{0} [{1}] {2}' -f [datetime]::UtcNow.ToString('o'), $Level, $Message
        Add-Content -LiteralPath $script:ElevatedLogPath -Value $line -Encoding utf8NoBOM
    }
    catch {
        Write-Host "[warn] Could not write $($script:ElevatedLogPath): $($_.Exception.Message)"
    }
}

function Invoke-Dism {
    # The one place dism.exe runs. The DISM PowerShell module cannot activate its
    # COM class inside packaged (MSIX) pwsh, so the native CLI is used (ADR-017).
    # Returns @{ ExitCode; Output }; it never throws on a non-zero exit.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FeatureName)
    if (-not $env:SystemRoot) { throw 'SystemRoot is not set; cannot locate dism.exe.' }
    $dismPath = Join-Path $env:SystemRoot 'System32\dism.exe'
    if (-not (Test-Path -LiteralPath $dismPath -PathType Leaf)) { throw "dism.exe not found at $dismPath." }
    $arguments = @('/online', '/enable-feature', "/featurename:$FeatureName", '/all', '/norestart')
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $dismPath @arguments 2>&1 | Out-String
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Invoke-FeatureRequest {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string[]]$Name = @()
    )
    $names = @($Name | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names.Count -eq 0) {
        Write-ElevatedLine -Level fail -Message 'No feature name given.'
        return 2
    }
    # Exact, case-sensitive allowlist, checked before dism.exe runs. A name that
    # is not listed (for example the Windows Sandbox feature) is refused outright.
    foreach ($n in $names) {
        if ($n -cnotin $script:AllowedFeatures) {
            Write-ElevatedLine -Level fail -Message "Refusing feature '$n'. Allowed: $($script:AllowedFeatures -join ', ')."
            return 2
        }
    }

    $restart = $false
    foreach ($n in $names) {
        Write-ElevatedLine -Level info -Message "Enabling $n"
        $dism = Invoke-Dism -FeatureName $n
        $exitCode = [int]$dism.ExitCode
        if ($exitCode -eq 3010) { $restart = $true; continue }
        if ($exitCode -ne 0) {
            # Failure wins over a pending restart, but say that the restart is owed.
            if ($restart) { Write-ElevatedLine -Level warn -Message 'An earlier feature was enabled and needs a restart even though this run failed.' }
            Write-ElevatedLine -Level fail -Message "dism.exe failed for $n with exit code ${exitCode}: $(([string]$dism.Output).Trim())"
            return 1
        }
    }
    if ($restart) { return 3010 }
    return 0
}

function Invoke-ElevatedMain {
    # The script body: runs the request and turns a throw into exit code 1.
    [CmdletBinding()]
    [OutputType([int])]
    param([string[]]$Name = @())
    try {
        return [int](Invoke-FeatureRequest -Name $Name)
    }
    catch {
        Write-ElevatedLine -Level fail -Message $_.Exception.Message
        return 1
    }
}

# SETUP_DEV_WIN_NO_MAIN=1 lets tests dot-source the functions without running.
if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    exit (Invoke-ElevatedMain -Name $Name)
}
