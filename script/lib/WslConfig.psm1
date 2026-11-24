#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

function Get-ChezmoiPath {
    # Internal. chezmoi on PATH, else the winget links directory (a fresh winget
    # install is not on this session's PATH yet). $null when absent.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $command = Get-Command -Name 'chezmoi' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    if ($env:LOCALAPPDATA) {
        $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\chezmoi.exe'
        if (Test-Path -LiteralPath $link) { return $link }
    }
    return $null
}

function Get-InstalledChezmoiVersion {
    # Internal. The installed chezmoi version string, or $null.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Get-ChezmoiPath
    if (-not $path) { return $null }
    try { $result = Invoke-Native -FilePath $path -ArgumentList @('--version') }
    catch { return $null }
    $text = $result.Output -join ' '
    if ($text -match 'v?(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Install-PinnedChezmoi {
    <#
    .SYNOPSIS
        Installs the exact chezmoi version through winget unless it is present.
    .PARAMETER Version
        The pinned version (pins.psd1 Chezmoi).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Version)

    if ((Get-InstalledChezmoiVersion) -eq $Version) {
        Write-Ok "chezmoi $Version is already installed."
        return
    }
    if (-not $PSCmdlet.ShouldProcess("chezmoi $Version", 'winget install')) { return }
    Write-Info "Installing chezmoi $Version"
    $arguments = @(
        'install', '--id', 'twpayne.chezmoi', '--source', 'winget', '--exact',
        '--version', $Version, '--scope', 'user', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    )
    $null = Invoke-Native -FilePath 'winget.exe' -ArgumentList $arguments
}

function Get-WslConfigPath {
    # Internal, mockable. The applied .wslconfig in the user profile.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-Path $HOME '.wslconfig')
}

function Get-WslConfigHash {
    # Internal. SHA256 of the applied .wslconfig; empty string when absent.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Get-WslConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return [string](Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Invoke-ChezmoiApply {
    <#
    .SYNOPSIS
        Applies the repository's chezmoi source and reports whether .wslconfig changed.
    .PARAMETER DistroRoot
        WSL distro root, passed to the template's one prompt so a run never asks.
    .OUTPUTS
        @{ Changed = [bool] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$DistroRoot)

    $chezmoi = Get-ChezmoiPath
    if (-not $chezmoi) { throw 'chezmoi was not found; run Install-PinnedChezmoi first.' }
    $source = Join-Path (Get-RepoRoot) 'chezmoi'
    # --force and --no-tty: never prompt, in any session (chezmoi would otherwise ask
    # about a target changed since it was last written, or fail without a TTY).
    $common = @('--source', $source, '--force', '--no-tty')
    if ($DistroRoot) {
        # promptStringOnce overrides are keyed by the prompt text, not the data key.
        $common += @('--promptString', "WSL distro root=$DistroRoot")
    }
    $target = Get-WslConfigPath
    if (Test-Path -LiteralPath $target) {
        # Write the config (data) without applying, so chezmoi can render the target.
        $null = Invoke-Native -FilePath $chezmoi -ArgumentList (@('init') + $common)
        $rendered = Invoke-Native -FilePath $chezmoi -ArgumentList @('cat', '--source', $source, $target)
        $wanted = (($rendered.Output -join "`n") -replace "`r`n", "`n").Trim()
        $existing = ((Get-Content -LiteralPath $target -Raw) -replace "`r`n", "`n").Trim()
        if ($existing -ne $wanted) {
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd\THHmmss\Z')
            $backup = "$target.backup.$stamp"
            Copy-Item -LiteralPath $target -Destination $backup
            Write-Info "Existing .wslconfig differs; backed up to $backup"
        }
    }
    $before = Get-WslConfigHash
    $result = Invoke-Native -FilePath $chezmoi -ArgumentList (@('init', '--apply') + $common)
    foreach ($line in $result.Output) { Write-Info $line }
    $after = Get-WslConfigHash
    return @{ Changed = [bool]($before -ne $after) }
}

function Test-InteractiveSession {
    # Internal, mockable. True when an operator can answer a prompt.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

function Request-WslRestart {
    <#
    .SYNOPSIS
        Asks to restart WSL so a changed .wslconfig takes effect.
    .DESCRIPTION
        Does nothing unless the file changed and a distro is running. Shuts WSL
        down only after an interactive yes; a non-interactive run only warns.
    .PARAMETER Changed
        Whether Invoke-ChezmoiApply changed .wslconfig.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([Parameter(Mandatory)][bool]$Changed)

    if (-not $Changed) { return }
    try {
        $running = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--list', '--running', '--quiet')
    }
    catch {
        # A missing wsl.exe or any non-zero exit means nothing is running; the file is already written.
        return
    }
    $names = @($running.Output | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    if ($names.Count -eq 0) { return }

    if (-not (Test-InteractiveSession)) {
        Write-Warn 'Run wsl --shutdown to apply .wslconfig'
        return
    }
    $answer = Read-Host '.wslconfig changed and WSL is running. Shut WSL down now to apply it? (y/N)'
    if ($answer -match '^(y|yes)$') {
        if ($PSCmdlet.ShouldProcess('WSL', 'wsl --shutdown')) {
            $null = Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--shutdown')
            Write-Ok 'WSL was shut down; it starts again on next use.'
        }
    }
    else {
        Write-Warn 'Run wsl --shutdown to apply .wslconfig'
    }
}

Export-ModuleMember -Function Install-PinnedChezmoi, Invoke-ChezmoiApply, Request-WslRestart
