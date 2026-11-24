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

# The same refusal text as script\setup.ps1 (Runner.psm1).
$script:ElevatedRefusal = 'Run from a normal (non-elevated) terminal; elevation is requested per step.'

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        True when this process runs elevated (a test seam; false off Windows).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return $false
    }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
    return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

function ConvertTo-StrictJson {
    <#
    .SYNOPSIS
        Removes commas that directly precede a closing brace or bracket.
    .DESCRIPTION
        Walks the text so that a comma inside a string is never touched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $out = New-Object -TypeName System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($inString) {
            [void]$out.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') {
            $inString = $true
        }
        elseif ($c -eq ',') {
            $j = $i + 1
            while ($j -lt $Text.Length -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
            if ($j -lt $Text.Length -and ($Text[$j] -eq '}' -or $Text[$j] -eq ']')) {
                continue
            }
        }
        [void]$out.Append($c)
    }
    return $out.ToString()
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
        # What `winget settings` writes ends in a trailing comma once the comments
        # are gone, which Windows PowerShell 5.1 may reject.
        $stripped = ConvertTo-StrictJson -Text $stripped
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
    # Only a real JSON true counts: -eq $true would also accept the string "true",
    # which winget does not honour.
    if ($telemetry -is [System.Management.Automation.PSCustomObject] -and
        $telemetry.PSObject.Properties['disable'] -and
        $telemetry.disable -is [bool] -and $telemetry.disable) {
        Write-Host 'winget telemetry is already disabled.'
        return
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
    return (Get-PowerShellVersionAt -Path $pwsh.Source)
}

function Test-PowerShellVersionAccepted {
    <#
    .SYNOPSIS
        True when Version is in the floor's major.minor (the LTS line) and >= Floor.
    .DESCRIPTION
        pins.psd1 PowerShell is a floor within the LTS minor (ADR-014): a later
        7.6 patch that Windows Update or winget installed is accepted, a 7.7 or a
        preview is not. Anything that does not parse as a version is rejected.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Version,
        [Parameter(Mandatory)][string]$Floor
    )
    $have = $null
    $want = [version]$Floor
    if (-not [System.Version]::TryParse([string]$Version, [ref]$have)) {
        return $false
    }
    return [bool]($have.Major -eq $want.Major -and $have.Minor -eq $want.Minor -and $have -ge $want)
}

function Get-PowerShellVersionAt {
    <#
    .SYNOPSIS
        Returns the version string reported by the given pwsh.exe (a test seam).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $version = & $Path -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    return [string]($version | Select-Object -First 1)
}

function Sync-SessionPath {
    <#
    .SYNOPSIS
        Prepends the Machine and User PATH entries to this session's PATH.
    .DESCRIPTION
        The installer changes PATH for new processes only. Existing entries are
        kept, and duplicates are dropped (case-insensitive, first one wins).
    #>
    [CmdletBinding()]
    param()
    $parts = @()
    foreach ($scope in 'Machine', 'User') {
        $value = [System.Environment]::GetEnvironmentVariable('Path', $scope)
        if ($value) { $parts += $value.Split(';') }
    }
    if ($env:Path) { $parts += $env:Path.Split(';') }
    $seen = @{}
    $unique = @()
    foreach ($part in $parts) {
        if ($part -and -not $seen.ContainsKey($part.ToLowerInvariant())) {
            $seen[$part.ToLowerInvariant()] = $true
            $unique += $part
        }
    }
    $env:Path = $unique -join ';'
}

function Resolve-PinnedPowerShell {
    <#
    .SYNOPSIS
        Returns the path of a pwsh.exe whose version passes the floor rule, or throws.
    .PARAMETER Version
        The floor (pins.psd1 PowerShell); see Test-PowerShellVersionAccepted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Version)

    $found = $null
    $onPath = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($onPath) {
        $found = Get-PowerShellVersionAt -Path $onPath.Source
        if (Test-PowerShellVersionAccepted -Version $found -Floor $Version) { return $onPath.Source }
    }
    $default = Join-Path (Join-Path (Join-Path $env:ProgramFiles 'PowerShell') '7') 'pwsh.exe'
    $defaultVersion = $null
    if (Test-Path -LiteralPath $default) {
        $defaultVersion = Get-PowerShellVersionAt -Path $default
        if (Test-PowerShellVersionAccepted -Version $defaultVersion -Floor $Version) { return $default }
    }
    $onPathText = 'not found'
    if ($found) { $onPathText = $found }
    $defaultText = 'not found'
    if ($defaultVersion) { $defaultText = $defaultVersion }
    $line = ([version]$Version).Major.ToString() + '.' + ([version]$Version).Minor.ToString()
    throw "PowerShell $line.x at or above $Version is required but pwsh on PATH reports '$onPathText' and $default reports '$defaultText'."
}

function Invoke-Handoff {
    <#
    .SYNOPSIS
        Runs script\setup.ps1 in the given pwsh on this console; returns its exit code.
    .DESCRIPTION
        Start-Process without redirection lets the child inherit the console, so
        the interactive WSL step has a terminal. Paths are quoted for spaces.
        -Wait is not used: in Windows PowerShell 5.1 it waits for every descendant
        (a job object), so a long-lived helper the setup started (wslhost, for
        example) would hang stage-0 after a successful run. Reading Handle once
        keeps ExitCode available after the process exits.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$SetupPath,
        [string]$Profiles
    )
    $argumentText = '-NoProfile -File "' + $SetupPath + '"'
    if ($Profiles) {
        $argumentText += ' -Profiles "' + $Profiles + '"'
    }
    $process = @(Start-Process -FilePath $PwshPath -ArgumentList $argumentText -NoNewWindow -PassThru)[-1]
    $null = $process.Handle
    $process.WaitForExit()
    return [int]$process.ExitCode
}

function Invoke-Winget {
    <#
    .SYNOPSIS
        Runs winget.exe with the given arguments (a test seam).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    # Out-Host: winget's output reaches the console and never the pipeline, so a
    # caller's return value stays clean.
    & winget.exe @Arguments | Out-Host
}

function Install-PinnedPowerShell {
    <#
    .SYNOPSIS
        Installs the pinned PowerShell MSI through winget unless an accepted one is present.
    .DESCRIPTION
        An installed 7.6.x at or above the pin is kept (ADR-014). Otherwise the
        exact pinned version is installed as the machine-wide MSI (--installer-type
        wix --scope machine): it lands in Program Files, so the elevated steps can
        relaunch it by path, and it avoids the MSIX package's file virtualization.
        The MSI raises its own UAC prompt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)

    $installed = Get-InstalledPowerShellVersion
    if (Test-PowerShellVersionAccepted -Version $installed -Floor $Version) {
        Write-Host "PowerShell $installed is already installed (pin $Version or a later patch)."
        return
    }
    Write-Host "Installing PowerShell $Version (machine-wide MSI; expect a UAC prompt)..."
    $arguments = @(
        'install', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--exact',
        '--version', $Version, '--installer-type', 'wix', '--scope', 'machine',
        '--silent', '--accept-package-agreements',
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
    .OUTPUTS
        Exactly one [int], the exit code of script\setup.ps1. Nothing else is
        emitted on the pipeline.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Profiles, [switch]$SkipPowerShellInstall)

    # Up front, before anything changes: an elevated stage-0 would hand an
    # elevated pwsh to setup.ps1, which refuses it anyway (ADR-004).
    if (Test-IsAdministrator) {
        throw $script:ElevatedRefusal
    }
    $pins = Import-PowerShellDataFile -Path (Join-Path (Join-Path $PSScriptRoot 'script') 'lib\pins.psd1')
    Assert-SupportedWindows -MinBuild $pins.MinOsBuild

    $setup = Join-Path (Join-Path $PSScriptRoot 'script') 'setup.ps1'
    if (-not (Test-Path -LiteralPath $setup)) {
        throw 'script\setup.ps1 not found next to bootstrap.ps1; is the clone complete?'
    }

    Wait-Winget -TimeoutSeconds 60

    $settingsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
    Merge-WingetSettings -Path $settingsPath

    if (-not $SkipPowerShellInstall) {
        Install-PinnedPowerShell -Version $pins.PowerShell
    }
    # No execution-policy change here: under the documented -ExecutionPolicy Bypass
    # launch it fails with ExecutionPolicyOverride, and pwsh 7 keeps its own
    # policy (ADR-003).

    Sync-SessionPath
    $pwsh = Resolve-PinnedPowerShell -Version $pins.PowerShell
    return [int](Invoke-Handoff -PwshPath $pwsh -SetupPath $setup -Profiles $Profiles)
}

if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    $code = Invoke-Bootstrap -Profiles $Profiles -SkipPowerShellInstall:$SkipPowerShellInstall
    exit $code
}
