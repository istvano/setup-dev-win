<#
.SYNOPSIS
    Stage-0: installs the latest stable PowerShell 7 and hands off to script\setup.ps1.
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
.PARAMETER DistroRoot
    Root directory for WSL distributions, passed to script\setup.ps1 only when
    given (setup persists it; default D:\WSL). A machine without a D: drive
    uses, for example: -DistroRoot C:\WSL
.PARAMETER LinuxUser
    The Linux user for the dev distro, passed to script\setup.ps1 only when given.
#>
[CmdletBinding()]
param(
    [string]$Profiles = '',
    [switch]$SkipPowerShellInstall,
    [string]$DistroRoot = '',
    [string]$LinuxUser = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The same refusal text as script\setup.ps1 (Runner.psm1).
$script:ElevatedRefusal = 'Run from a normal (non-elevated) terminal; elevation is requested per step.'

# What to do when winget cannot open its source (seen on a real machine: the first
# winget use failed with 0x80070005 until the source was reset and updated).
$script:WingetSourceFix = 'winget could not open its package source (0x80070005, Access is denied). ' +
'To fix it: (1) in an administrator terminal run: winget source reset --force; ' +
'(2) in a normal terminal run: winget source update; ' +
'(3) if it still fails, update App Installer from the Microsoft Store (Library > Get updates); ' +
'then re-run bootstrap.ps1.'

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
        True when Version parses as a release version at or above Minimum.
    .DESCRIPTION
        pins.psd1 MinPowerShell is a floor with no upper bound (ADR-016): any
        stable PowerShell at or above it is accepted, newer ones included. A
        preview ('7.7.0-preview.1') or anything else that does not parse as a
        version is rejected.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Version,
        [Parameter(Mandatory)][string]$Minimum
    )
    $have = $null
    if (-not [System.Version]::TryParse([string]$Version, [ref]$have)) {
        return $false
    }
    return [bool]($have -ge [version]$Minimum)
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

function Resolve-PowerShell7 {
    <#
    .SYNOPSIS
        Returns the path of a pwsh.exe at or above Minimum, or throws naming what was found.
    .DESCRIPTION
        Candidates, in order: pwsh.exe on PATH (for the MSIX package this is its
        app execution alias in %LOCALAPPDATA%\Microsoft\WindowsApps, which is on
        the user PATH), that alias by its full path, and the MSI's default path.
        A candidate that cannot be run counts as not qualifying.
    .PARAMETER Minimum
        pins.psd1 MinPowerShell; see Test-PowerShellVersionAccepted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Minimum)

    $candidates = @()
    $onPath = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($onPath) {
        $candidates += [string]$onPath.Source
    }
    else {
        $candidates += ''
    }
    $fallbacks = @()
    if ($env:LOCALAPPDATA) { $fallbacks += $env:LOCALAPPDATA + '\Microsoft\WindowsApps\pwsh.exe' }
    if ($env:ProgramFiles) { $fallbacks += $env:ProgramFiles + '\PowerShell\7\pwsh.exe' }

    $report = @()
    if (-not $candidates[0]) { $report += 'pwsh.exe on PATH not found' }
    foreach ($fallback in $fallbacks) {
        if (Test-Path -LiteralPath $fallback) { $candidates += $fallback }
        else { $report += "$fallback not found" }
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $version = $null
        try { $version = Get-PowerShellVersionAt -Path $candidate }
        catch { $version = $null }
        if (Test-PowerShellVersionAccepted -Version $version -Minimum $Minimum) {
            return $candidate
        }
        $report += "$candidate reports '$version'"
    }
    throw ("PowerShell $Minimum or later is required, but no qualifying pwsh.exe was found: " +
        ($report -join '; ') + '. Re-run bootstrap.ps1 to install it, or install it with: ' +
        'winget install --id Microsoft.PowerShell --source winget --exact')
}

function ConvertTo-QuotedArgument {
    <#
    .SYNOPSIS
        Quotes one value for a Windows command line (CommandLineToArgvW rules).
    .DESCRIPTION
        Wraps the value in double quotes, doubles backslashes that precede a quote
        or the closing quote, and escapes embedded quotes, so a path with spaces or
        a trailing backslash arrives as one intact argument. The same rules as
        ConvertTo-CommandLineArgument in script\lib\Common.psm1, which stage-0
        cannot import.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
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
        [string]$Profiles,
        [string]$DistroRoot,
        [string]$LinuxUser
    )
    # Each option is passed only when given, so values setup.ps1 persisted on an
    # earlier run still apply.
    $argumentText = '-NoProfile -File ' + (ConvertTo-QuotedArgument -Value $SetupPath)
    if ($Profiles) {
        $argumentText += ' -Profiles ' + (ConvertTo-QuotedArgument -Value $Profiles)
    }
    if ($DistroRoot) {
        $argumentText += ' -DistroRoot ' + (ConvertTo-QuotedArgument -Value $DistroRoot)
    }
    if ($LinuxUser) {
        $argumentText += ' -LinuxUser ' + (ConvertTo-QuotedArgument -Value $LinuxUser)
    }
    $process = @(Start-Process -FilePath $PwshPath -ArgumentList $argumentText -NoNewWindow -PassThru)[-1]
    $null = $process.Handle
    $process.WaitForExit()
    return [int]$process.ExitCode
}

function Invoke-Winget {
    <#
    .SYNOPSIS
        Runs winget.exe, showing its output as it arrives; returns @{ ExitCode; Output }.
    .DESCRIPTION
        Each line goes to the console with Write-Host and is also kept, so callers
        can recognise a failure by its text. The only pipeline output is the one
        result object. stderr is not redirected: under Windows PowerShell 5.1 with
        $ErrorActionPreference = 'Stop', 2>&1 turns the first stderr line of a
        native command into a terminating error. winget writes its errors to stdout.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $lines = New-Object -TypeName System.Collections.Generic.List[string]
    & winget.exe @Arguments | ForEach-Object {
        $line = [string]$_
        Write-Host $line
        $lines.Add($line)
    }
    $exitCode = [int]$LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $exitCode; Output = [string[]]$lines.ToArray() }
}

function Test-WingetSourceAccessDenied {
    <#
    .SYNOPSIS
        True when a winget result shows the source access-denied failure (0x80070005).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][psobject]$Result)
    # 0x80070005 as the signed 32-bit exit code winget returns.
    if ([int]$Result.ExitCode -eq -2147024891) { return $true }
    $text = @($Result.Output) -join "`n"
    return [bool]($text -match '0x80070005|Failed to open the predefined source')
}

function Invoke-WingetSourceUpdate {
    <#
    .SYNOPSIS
        Runs winget source update; throws the repair steps when the source is broken.
    #>
    [CmdletBinding()]
    param()
    Write-Host 'Updating winget sources...'
    $result = Invoke-Winget -Arguments @('source', 'update')
    if (Test-WingetSourceAccessDenied -Result $result) {
        throw $script:WingetSourceFix
    }
    if ($result.ExitCode -ne 0) {
        throw ("winget source update failed (exit code $($result.ExitCode)). Check the network connection " +
            'and re-run bootstrap.ps1. If it keeps failing: ' + $script:WingetSourceFix)
    }
}

function Install-PowerShell {
    <#
    .SYNOPSIS
        Installs the latest stable PowerShell 7 through winget unless an accepted one is present.
    .DESCRIPTION
        Any installed pwsh at or above Minimum is kept, newer ones included
        (ADR-016). Otherwise winget installs the newest stable Microsoft.PowerShell
        with no --version, --installer-type or --scope. That package is MSIX from
        7.7 on: a per-user install that normally raises no UAC prompt, reached
        through its app execution alias.
    .PARAMETER Minimum
        pins.psd1 MinPowerShell.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Minimum)

    $installed = Get-InstalledPowerShellVersion
    if (Test-PowerShellVersionAccepted -Version $installed -Minimum $Minimum) {
        Write-Host "PowerShell $installed is already installed ($Minimum or later is accepted)."
        return
    }
    Write-Host 'Installing the latest stable PowerShell 7 with winget (this can take a minute)...'
    $arguments = @(
        'install', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--exact',
        '--silent', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity'
    )
    $result = Invoke-Winget -Arguments $arguments
    if (Test-WingetSourceAccessDenied -Result $result) {
        throw $script:WingetSourceFix
    }
    if ($result.ExitCode -ne 0) {
        throw "winget failed to install PowerShell (exit code $($result.ExitCode))."
    }
}

function Invoke-Bootstrap {
    <#
    .SYNOPSIS
        The stage-0 sequence: assert, wait, settings, source health, install, hand off.
    .OUTPUTS
        Exactly one [int], the exit code of script\setup.ps1. Nothing else is
        emitted on the pipeline.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Profiles, [switch]$SkipPowerShellInstall, [string]$DistroRoot, [string]$LinuxUser)

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

    # Always, not only before an install: the dotfiles stage installs with winget too.
    Invoke-WingetSourceUpdate

    if (-not $SkipPowerShellInstall) {
        Install-PowerShell -Minimum $pins.MinPowerShell
    }
    # No execution-policy change here: under the documented -ExecutionPolicy Bypass
    # launch it fails with ExecutionPolicyOverride, and pwsh 7 keeps its own
    # policy (ADR-003).

    Sync-SessionPath
    $pwsh = Resolve-PowerShell7 -Minimum $pins.MinPowerShell
    return [int](Invoke-Handoff -PwshPath $pwsh -SetupPath $setup -Profiles $Profiles -DistroRoot $DistroRoot -LinuxUser $LinuxUser)
}

if ($env:SETUP_DEV_WIN_NO_MAIN -ne '1') {
    $code = Invoke-Bootstrap -Profiles $Profiles -SkipPowerShellInstall:$SkipPowerShellInstall -DistroRoot $DistroRoot -LinuxUser $LinuxUser
    exit $code
}
