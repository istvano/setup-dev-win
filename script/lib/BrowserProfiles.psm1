#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

# Isolated Chrome and Firefox contexts (ADR-027), the port of the Mac's browser-profile.
# Each profile is a separate data root under
# %LOCALAPPDATA%\setup-dev-win\browsers\<browser>\<name>; the browsers' own default
# profiles are never read, written or opened. Everything runs as the operator and
# nothing elevates. Creating a root signs in nowhere.

$script:Browsers = @('chrome', 'firefox')
$script:DefaultProfiles = @('personal', 'work')

function Test-BrowserProfileName {
    <#
    .SYNOPSIS
        True when the name is a valid profile name.
    .DESCRIPTION
        Lowercase letters, digits, dots, underscores and hyphens, starting with a letter or
        digit. The pattern is case-sensitive on purpose.
    .PARAMETER Name
        The candidate profile name.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Name)
    return [bool]($Name -cmatch '^[a-z0-9][a-z0-9._-]*$')
}

function Get-BrowserProfileRoot {
    # Internal (mockable). The directory holding every browser data root.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:LOCALAPPDATA) {
        throw 'LOCALAPPDATA is not set; cannot place the browser data roots.'
    }
    return Join-Path (Join-Path $env:LOCALAPPDATA 'setup-dev-win') 'browsers'
}

function Test-BrowserFile {
    # Internal (mockable). Whether a file exists.
    param([Parameter(Mandatory)][string]$Path)
    Test-Path -LiteralPath $Path -PathType Leaf
}

function Start-BrowserProcess {
    # Internal (mockable). Starts a browser and does not wait for it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A thin mockable wrapper around Start-Process.')]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    Start-Process -FilePath $FilePath -ArgumentList $ArgumentList
}

function Assert-BrowserName {
    # Internal. Fails closed on a name or browser that is not allowed.
    param([string]$Browser, [string]$Name)
    if ($Browser -and $Browser -cnotin $script:Browsers) { throw "Unknown browser: $Browser (chrome or firefox)." }
    if (-not (Test-BrowserProfileName -Name $Name)) {
        throw "Invalid profile name: '$Name'. Use lowercase letters, digits, dots, underscores and hyphens."
    }
}

function Get-BrowserProfilePath {
    # Internal. <root>\<browser>\<name>.
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Browser, [Parameter(Mandatory)][string]$Name)
    Join-Path (Join-Path (Get-BrowserProfileRoot) $Browser) $Name
}

function Initialize-BrowserProfile {
    <#
    .SYNOPSIS
        Creates the data roots of one profile name for every browser.
    .DESCRIPTION
        Idempotent. Refuses an invalid name and any path that is a symbolic link or other
        reparse point, so a profile can never be redirected to another directory.
    .PARAMETER Name
        The profile name.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Name)
    Assert-BrowserName -Name $Name
    foreach ($browser in $script:Browsers) {
        $path = Get-BrowserProfilePath -Browser $browser -Name $Name
        $parent = Split-Path -Parent $path
        foreach ($candidate in @($parent, $path)) {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            if ($item -and $item.LinkType) { throw "Refusing a linked browser profile path: $candidate" }
        }
        $null = New-Item -ItemType Directory -Path $path -Force
    }
}

function Get-BrowserProfile {
    <#
    .SYNOPSIS
        Lists the existing profiles as objects with Browser and Name, sorted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    $root = Get-BrowserProfileRoot
    $rows = foreach ($browser in $script:Browsers) {
        $dir = Join-Path $root $browser
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force | Sort-Object Name)) {
            if ($child.LinkType) { continue }
            [pscustomobject]@{ Browser = $browser; Name = $child.Name }
        }
    }
    return @($rows)
}

function Get-BrowserExecutable {
    <#
    .SYNOPSIS
        The path of chrome.exe or firefox.exe, or $null when the browser is not installed.
    .PARAMETER Browser
        chrome or firefox.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Browser)
    $candidates = switch ($Browser) {
        'chrome' {
            foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) {
                if ($base) { Join-Path $base 'Google/Chrome/Application/chrome.exe' }
            }
        }
        'firefox' {
            foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
                if ($base) { Join-Path $base 'Mozilla Firefox/firefox.exe' }
            }
        }
        default { throw "Unknown browser: $Browser (chrome or firefox)." }
    }
    foreach ($candidate in @($candidates)) {
        if (Test-BrowserFile -Path $candidate) { return $candidate }
    }
    return $null
}

function Open-BrowserProfile {
    <#
    .SYNOPSIS
        Starts a browser on its isolated data root, creating the root first.
    .DESCRIPTION
        Chrome gets --user-data-dir. Firefox gets -no-remote -profile, so it does not hand
        the window to a running default instance. Fails when the browser is not installed.
    .PARAMETER Browser
        chrome or firefox.
    .PARAMETER Name
        The profile name.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Browser,
        [Parameter(Mandatory)][string]$Name
    )
    Assert-BrowserName -Browser $Browser -Name $Name
    if ($Browser -cnotin $script:Browsers) { throw "Unknown browser: $Browser (chrome or firefox)." }
    $exe = Get-BrowserExecutable -Browser $Browser
    if (-not $exe) { throw "$Browser is not installed; select the productivity-extra profile." }
    Initialize-BrowserProfile -Name $Name
    $path = Get-BrowserProfilePath -Browser $Browser -Name $Name
    # Start-Process joins an array with bare spaces, so each token carries its own quotes.
    $arguments = if ($Browser -eq 'chrome') {
        @('"--user-data-dir=' + $path + '"')
    }
    else {
        @('-no-remote', '-profile', ('"' + $path + '"'))
    }
    Start-BrowserProcess -FilePath $exe -ArgumentList $arguments
}

function Invoke-BrowserProfileCommand {
    <#
    .SYNOPSIS
        Runs one browser-profile command and returns the exit code.
    .PARAMETER Command
        ensure-defaults, add, list or open (default list).
    .PARAMETER Argument
        The command's arguments: add NAME, open BROWSER NAME.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$Command = 'list',
        [string[]]$Argument = @()
    )
    if (Test-IsElevated) {
        Write-Warn 'Run from a normal (non-elevated) terminal; browser profiles are per user.'
        return 1
    }
    try {
        switch ($Command) {
            'ensure-defaults' {
                if ($Argument.Count -ne 0) { throw 'ensure-defaults takes no arguments.' }
                foreach ($name in $script:DefaultProfiles) { Initialize-BrowserProfile -Name $name }
                Write-Ok 'Browser profiles personal and work are ready.'
            }
            'add' {
                if ($Argument.Count -ne 1) { throw 'add requires one profile name.' }
                Initialize-BrowserProfile -Name $Argument[0]
                Write-Ok "Browser profile $($Argument[0]) is ready for Chrome and Firefox."
            }
            'list' {
                if ($Argument.Count -ne 0) { throw 'list takes no arguments.' }
                foreach ($row in @(Get-BrowserProfile)) { Write-Host ('{0,-8} {1}' -f $row.Browser, $row.Name) }
            }
            'open' {
                if ($Argument.Count -ne 2) { throw 'open requires a browser and a profile name.' }
                Open-BrowserProfile -Browser $Argument[0] -Name $Argument[1]
            }
            default { throw "Unknown command: $Command (ensure-defaults, add, list, open)." }
        }
        return 0
    }
    catch {
        Write-Warn $_.Exception.Message
        return 1
    }
}

Export-ModuleMember -Function Test-BrowserProfileName, Initialize-BrowserProfile, Get-BrowserProfile,
Get-BrowserExecutable, Open-BrowserProfile, Invoke-BrowserProfileCommand
