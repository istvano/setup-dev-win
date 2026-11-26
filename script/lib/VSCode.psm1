#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

# Windows-side VS Code extensions (UI and remote clients; WSL-side extensions are
# the operator's and no repository manages them, ADR-025). Latest stable is installed with
# no version (ADR-016). Nothing is ever uninstalled: removing a line from
# vscode/extensions.list only stops installing it. VS Code's settings.json is
# never touched. Everything runs as the operator; nothing elevates.

function Read-VSCodeExtensionListFile {
    # Internal (mockable). The raw lines of vscode/extensions.list.
    Get-Content -LiteralPath (Join-Path (Get-RepoRoot) (Join-Path 'vscode' 'extensions.list'))
}

function Find-CommandOnPath {
    # Internal (mockable). The path of a command on this session's PATH, or $null.
    param([Parameter(Mandatory)][string]$Name)
    $found = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    return $null
}

function Test-VSCodeFile {
    # Internal (mockable). Whether a file exists.
    param([Parameter(Mandatory)][string]$Path)
    Test-Path -LiteralPath $Path -PathType Leaf
}

function Get-VSCodeExtensionList {
    <#
    .SYNOPSIS
        The declared extension ids, lower-cased, comments and blank lines dropped.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $ids = foreach ($line in @(Read-VSCodeExtensionListFile)) {
        $text = ([string]$line -replace '#.*$', '').Trim()
        if ($text) { $text.ToLowerInvariant() }
    }
    return [string[]]@($ids)
}

function Get-VSCodeCli {
    <#
    .SYNOPSIS
        The path of code.cmd, or $null when VS Code is not installed.
    .DESCRIPTION
        PATH first, then the per-user install, then the per-machine install: right
        after an install this session's PATH is stale, and either scope may be used.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $onPath = Find-CommandOnPath -Name 'code.cmd'
    if ($onPath) { return $onPath }
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA (Join-Path 'Programs' (Join-Path 'Microsoft VS Code' (Join-Path 'bin' 'code.cmd'))) }
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles (Join-Path 'Microsoft VS Code' (Join-Path 'bin' 'code.cmd')) }
    foreach ($candidate in $candidates) {
        if (Test-VSCodeFile -Path $candidate) { return $candidate }
    }
    return $null
}

function Get-MissingVSCodeExtensions {
    <#
    .SYNOPSIS
        Declared extensions that VS Code does not list as installed (case-insensitive).
        Empty when VS Code is absent.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names fixed by the task interface; the value is a list.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $cli = Get-VSCodeCli
    if (-not $cli) { return [string[]]@() }
    $run = Invoke-Native -FilePath $cli -ArgumentList @('--list-extensions')
    $have = @($run.Output | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    $missing = @(Get-VSCodeExtensionList | Where-Object { $_ -notin $have })
    return [string[]]$missing
}

function Install-VSCodeExtensions {
    <#
    .SYNOPSIS
        Installs the missing declared extensions, latest version each.
    .OUTPUTS
        @{ Installed = string[]; Failed = string[] }; a failure reads "<id> (<reason>)"
        and does not stop the others.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names fixed by the task interface; the value is a list.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $installed = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $cli = Get-VSCodeCli
    if ($cli) {
        foreach ($id in @(Get-MissingVSCodeExtensions)) {
            try {
                Invoke-Native -FilePath $cli -ArgumentList @('--install-extension', $id) | Out-Null
                $installed.Add($id)
            }
            catch { $failed.Add("$id ($($_.Exception.Message))") }
        }
    }
    return @{ Installed = [string[]]$installed.ToArray(); Failed = [string[]]$failed.ToArray() }
}

Export-ModuleMember -Function Get-VSCodeExtensionList, Get-VSCodeCli, Get-MissingVSCodeExtensions, Install-VSCodeExtensions
