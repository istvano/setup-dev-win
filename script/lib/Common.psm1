#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Write-Info {
    <#
    .SYNOPSIS
        Writes an informational progress line.
    .PARAMETER Message
        The text to show.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[info] $Message"
}

function Write-Ok {
    <#
    .SYNOPSIS
        Writes a success line.
    .PARAMETER Message
        The text to show.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[ ok ] $Message" -ForegroundColor Green
}

function Write-Warn {
    <#
    .SYNOPSIS
        Writes a warning line.
    .PARAMETER Message
        The text to show.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}

function Stop-Fatal {
    <#
    .SYNOPSIS
        Throws a terminating error carrying the message.
    .PARAMETER Message
        Why the run cannot continue.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stop- here ends the run; it changes no system state.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

function Get-RepoRoot {
    <#
    .SYNOPSIS
        Returns the repository root (the parent of script/).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Test-IsElevated {
    <#
    .SYNOPSIS
        True when the current process runs as a Windows administrator.
    .DESCRIPTION
        Returns $false on any non-Windows host rather than throwing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    $principal = [System.Security.Principal.WindowsPrincipal]::new(
        [System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
    <#
    .SYNOPSIS
        Runs a native command and returns its exit code and combined output.
    .DESCRIPTION
        Reads the exit code itself, so PSNativeCommandUseErrorActionPreference is
        switched off around the call. Throws when the exit code is not 0 and not
        in AllowExitCode. Sets WSL_UTF8=1 when the command is wsl or wsl.exe.
    .PARAMETER FilePath
        The executable to run.
    .PARAMETER ArgumentList
        Arguments, passed as separate tokens (never joined into one string).
    .PARAMETER AllowExitCode
        Exit codes other than 0 that are not errors.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$AllowExitCode = @()
    )
    $leaf = (Split-Path -Leaf $FilePath).ToLowerInvariant()
    if ($leaf -in 'wsl', 'wsl.exe') { $env:WSL_UTF8 = '1' }

    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $raw = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previous
    }
    $output = @($raw | ForEach-Object { "$_" })
    if ($exitCode -ne 0 -and $exitCode -notin $AllowExitCode) {
        $tail = ($output | Select-Object -Last 5) -join '; '
        throw "$FilePath exited with code $exitCode. $tail"
    }
    [pscustomobject]@{ ExitCode = [int]$exitCode; Output = [string[]]$output }
}

function Resolve-ElevatedScriptPath {
    # Internal. Maps a bare script name to a full path that must lie inside the
    # elevated directory, compared as normalised full paths.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ElevatedRoot = (Join-Path (Get-RepoRoot) (Join-Path 'script' 'elevated'))
    )
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Refusing elevated script name '$Name': a bare name under script/elevated is required."
    }
    $rootFull = [System.IO.Path]::GetFullPath($ElevatedRoot).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull "$Name.ps1"))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $inside = $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison)
    if (-not $inside -or -not $full.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing '$Name': it resolves outside script/elevated."
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Elevated script not found: script/elevated/$Name.ps1"
    }
    return $full
}

function ConvertTo-CommandLineArgument {
    # Internal. Quotes one token per CommandLineToArgvW rules: wrap in double
    # quotes, double backslashes that precede a quote (or the closing quote),
    # escape embedded quotes. Start-Process -ArgumentList does no quoting itself.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) $m.Groups[1].Value + $m.Groups[1].Value + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Value + $m.Value })
    return '"' + $escaped + '"'
}

function Invoke-ElevatedScript {
    <#
    .SYNOPSIS
        Runs script/elevated/<Name>.ps1 in a new elevated pwsh and returns its exit code.
    .PARAMETER Name
        Bare script name, without directory or extension.
    .PARAMETER ArgumentList
        Arguments passed to the script after -File <path>.
    .NOTES
        Every token is quoted into one argument string (Start-Process would join an
        array with bare spaces). The running pwsh is elevated by absolute path, so
        a pwsh planted on PATH is never used. A declined UAC prompt makes
        Start-Process throw; the error is not caught here and the caller must
        handle it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$ArgumentList = @()
    )
    $path = Resolve-ElevatedScriptPath -Name $Name
    $tokens = @('-NoProfile', '-File', $path) + $ArgumentList
    $arguments = ($tokens | ForEach-Object { ConvertTo-CommandLineArgument -Value $_ }) -join ' '
    $process = Start-Process -FilePath ([Environment]::ProcessPath) -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    return [int]$process.ExitCode
}

Export-ModuleMember -Function Write-Info, Write-Ok, Write-Warn, Stop-Fatal, Get-RepoRoot,
Test-IsElevated, Invoke-Native, Invoke-ElevatedScript
