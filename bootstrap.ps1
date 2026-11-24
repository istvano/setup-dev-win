<#
.SYNOPSIS
    Stage-0: installs the pinned PowerShell 7 and hands off to script\setup.ps1.
.DESCRIPTION
    Runs on a fresh Windows 11 x64 machine under Windows PowerShell 5.1:
        powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
    It is self-contained on purpose: it imports nothing from script\lib, whose
    modules require PowerShell 7.6. The file must stay ASCII-only and use only
    5.1 syntax (no ??, no ternary, no && or ||). Tests dot-source it with
    SETUP_DEV_WIN_NO_MAIN=1, which skips the main block.
.PARAMETER Profiles
    Comma-separated profile list passed through to script\setup.ps1.
.PARAMETER SkipPowerShellInstall
    Do not install PowerShell 7 (it must already be on PATH).
#>
[CmdletBinding()]
param(
    [string]$Profiles = '',
    [switch]$SkipPowerShellInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OsBuildNumber {
    <#
    .SYNOPSIS
        Returns the Windows build number (a seam so tests can mock it).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [System.Environment]::OSVersion.Version.Build
}

function Assert-SupportedWindows {
    <#
    .SYNOPSIS
        Throws unless this is x64 Windows at or above the minimum build.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$MinBuild)

    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -ne 'AMD64') {
        throw "Unsupported architecture '$arch': this repository targets Windows 11 x64 (AMD64) only."
    }
    $build = Get-OsBuildNumber
    if ($build -lt $MinBuild) {
        throw "Unsupported Windows build ${build}: build $MinBuild (Windows 11 24H2) or newer is required."
    }
}

function Wait-Winget {
    <#
    .SYNOPSIS
        Waits for winget.exe to appear on PATH, or throws with the repair command.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if (Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue) {
            return
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 1
    }
    throw ('winget.exe was not found after {0} seconds. On a fresh machine App Installer registers lazily; run: ' -f $TimeoutSeconds) +
    'Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' +
    ' and then re-run bootstrap.ps1.'
}

function Merge-WingetSettings {
    <#
    .SYNOPSIS
        Sets telemetry.disable = true in winget's settings.json, keeping all else.
    .DESCRIPTION
        The file may be JSONC. Whole-line // comments are stripped, but only to
        parse: if the result still does not parse, the file is left untouched and
        the operator is told what to add by hand. The original is backed up first.
    #>
    # The name is the stage-0 interface; "settings.json" is a file, not a plural set.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $failure = 'winget settings.json could not be parsed; add "telemetry": { "disable": true } by hand (winget settings) and re-run.'
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $raw = ''
    if ($exists) {
        $raw = [System.IO.File]::ReadAllText($Path)
    }

    $settings = $null
    if ($raw.Trim().Length -eq 0) {
        $settings = New-Object -TypeName PSObject
    }
    else {
        # Only lines that start with // are removed, so a // inside a string
        # (for example the $schema URL) is never touched.
        $stripped = [regex]::Replace($raw, '(?m)^[ \t]*//.*$', '')
        try {
            $settings = ConvertFrom-Json -InputObject $stripped
        }
        catch {
            throw $failure
        }
        if ($null -eq $settings -or $settings -isnot [System.Management.Automation.PSCustomObject]) {
            throw $failure
        }
    }

    $telemetry = $null
    if ($settings.PSObject.Properties['telemetry']) {
        $telemetry = $settings.telemetry
    }
    if ($telemetry -isnot [System.Management.Automation.PSCustomObject]) {
        $telemetry = New-Object -TypeName PSObject
    }
    Add-Member -InputObject $telemetry -NotePropertyName 'disable' -NotePropertyValue $true -Force
    Add-Member -InputObject $settings -NotePropertyName 'telemetry' -NotePropertyValue $telemetry -Force

    $json = ConvertTo-Json -InputObject $settings -Depth 20

    if ($exists) {
        $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
        Copy-Item -LiteralPath $Path -Destination ($Path + '.backup.' + $stamp)
    }
    else {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    # UTF-8 without a BOM works the same in 5.1 and 7.
    [System.IO.File]::WriteAllText($Path, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
}

function Get-InstalledPowerShellVersion {
    <#
    .SYNOPSIS
        Returns the version string of the pwsh on PATH, or $null (a test seam).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $pwsh = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        return $null
    }
    $version = & $pwsh.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    return ($version | Select-Object -First 1)
}

function Invoke-Winget {
    <#
    .SYNOPSIS
        Runs winget.exe with the given arguments (a test seam).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    & winget.exe @Arguments
}

function Install-PinnedPowerShell {
    <#
    .SYNOPSIS
        Installs the exact PowerShell version through winget unless it is present.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)

    if ((Get-InstalledPowerShellVersion) -eq $Version) {
        Write-Host "PowerShell $Version is already installed."
        return
    }
    $arguments = @(
        'install', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--exact',
        '--version', $Version, '--silent', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity'
    )
    Invoke-Winget -Arguments $arguments
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install PowerShell $Version (exit code $LASTEXITCODE)."
    }
}

function Invoke-Bootstrap {
    <#
    .SYNOPSIS
        The stage-0 sequence: assert, wait, settings, install, hand off.
    #>
    [CmdletBinding()]
    param([string]$Profiles, [switch]$SkipPowerShellInstall)

    $pins = Import-PowerShellDataFile -Path (Join-Path (Join-Path $PSScriptRoot 'script') 'lib\pins.psd1')
    Assert-SupportedWindows -MinBuild $pins.MinOsBuild
    Wait-Winget -TimeoutSeconds 60

    $settingsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
    Merge-WingetSettings -Path $settingsPath

    if (-not $SkipPowerShellInstall) {
        Install-PinnedPowerShell -Version $pins.PowerShell
    }
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

    # The installer updates PATH for new processes; refresh this session's copy.
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = $machinePath + ';' + $userPath

    $pwsh = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw 'pwsh.exe is not on PATH after installation; open a new terminal and re-run bootstrap.ps1.'
    }
    $setup = Join-Path (Join-Path $PSScriptRoot 'script') 'setup.ps1'
    $arguments = @('-NoProfile', '-File', $setup)
    if ($Profiles) {
        $arguments += @('-Profiles', $Profiles)
    }
    & $pwsh.Source @arguments
    return $LASTEXITCODE
}

if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    $code = Invoke-Bootstrap -Profiles $Profiles -SkipPowerShellInstall:$SkipPowerShellInstall
    exit $code
}
