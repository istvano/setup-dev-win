#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

# winget return codes, decimal, from winget-cli returnCodes.md.
$script:NotFoundCode = -1978335212

# Codes that mean the package is present: nothing to do.
$script:AlreadyInstalledCodes = @(-1978335189, -1978335135, -1978334963)

# Codes that mean winget finished but Windows must restart.
$script:RebootRequiredCode = -1978334967

# Every other known code -> the plain reason shown to the operator.
$script:FailureReasons = @{
    -1978334966 = 'Windows must restart before this can install. Please restart Windows, then re-run the setup.'
    -1978334964 = 'The install was cancelled, usually because the UAC prompt was declined. Re-run the setup and accept the UAC prompt.'
    -1978335215 = 'The installer hash did not match the catalogue, so winget refused it. Nothing was installed; try again later.'
    -1978335174 = 'The install is blocked by a policy on this machine.'
    -1978334961 = 'The install is blocked by a policy on this machine.'
}

function Test-WingetPackage {
    <#
    .SYNOPSIS
        True when winget lists the package as installed.
    .DESCRIPTION
        Uses the exit code only. winget truncates long Ids in its table and
        localises its text, so the printed output is never parsed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Id)

    $arguments = @(
        'list', '--id', $Id, '--exact', '--source', 'winget',
        '--accept-source-agreements', '--disable-interactivity'
    )
    $result = Invoke-Native -FilePath 'winget.exe' -ArgumentList $arguments -AllowExitCode @($script:NotFoundCode)
    return ($result.ExitCode -eq 0)
}

function Install-WingetPackage {
    <#
    .SYNOPSIS
        Installs the newest winget package and reports the outcome.
    .DESCRIPTION
        Returns installed, already-installed or reboot-required. "Already
        installed" covers an app the operator installed by hand, which winget list
        may not correlate. Any other result throws with the Id, the exit code and a
        plain reason. No --version is passed (ADR-016); --scope only when given.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Scope
    )

    $arguments = @(
        'install', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    )
    if ($Scope) { $arguments += @('--scope', $Scope) }

    $allowed = @($script:AlreadyInstalledCodes) + @($script:RebootRequiredCode) + @($script:FailureReasons.Keys)
    $result = Invoke-Native -FilePath 'winget.exe' -ArgumentList $arguments -AllowExitCode ([int[]]$allowed)
    $code = $result.ExitCode

    if ($code -eq 0) { return 'installed' }
    if ($code -in $script:AlreadyInstalledCodes) { return 'already-installed' }
    if ($code -eq $script:RebootRequiredCode) { return 'reboot-required' }
    throw "winget could not install $Id (exit code $code). $($script:FailureReasons[$code])"
}

function Get-WingetInstalledIds {
    <#
    .SYNOPSIS
        The winget package Ids installed on this machine, from winget export.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names fixed by the task interface; the value is a list.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "winget-export-$([guid]::NewGuid().ToString('N')).json")
    try {
        $arguments = @(
            'export', '--output', $path, '--source', 'winget',
            '--accept-source-agreements', '--disable-interactivity'
        )
        $null = Invoke-Native -FilePath 'winget.exe' -ArgumentList $arguments
        $export = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $ids = [System.Collections.Generic.List[string]]::new()
        foreach ($source in @($export.PSObject.Properties['Sources']?.Value).Where({ $_ })) {
            foreach ($package in @($source.PSObject.Properties['Packages']?.Value).Where({ $_ })) {
                $ids.Add([string]$package.PackageIdentifier)
            }
        }
        return [string[]]$ids.ToArray()
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Test-WingetPackage, Install-WingetPackage, Get-WingetInstalledIds
