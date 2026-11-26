#Requires -Version 7.6
<#
.SYNOPSIS
    The repository gate: PSScriptAnalyzer, formatting check, Pester.
.DESCRIPTION
    Runs locally and in CI. Pester and PSScriptAnalyzer are imported by the exact
    versions in tests/tool-versions.psd1. A missing module is a loud SKIP, or a
    failure with -RequireLinters or REQUIRE_LINTERS=1 (no silent skips).
.PARAMETER RequireLinters
    Fail instead of skipping when a required module is missing.
#>
[CmdletBinding()]
param(
    [switch]$RequireLinters
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path -Parent $PSScriptRoot
$strict = $RequireLinters -or ($env:REQUIRE_LINTERS -eq '1')
$versions = Import-PowerShellDataFile -Path (Join-Path $root 'tests/tool-versions.psd1')
$failed = $false

function Import-PinnedModule {
    param([string]$Name, [string]$Version)
    $found = Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq [version]$Version }
    if (-not $found) {
        if ($strict) {
            Write-Error "$Name $Version is not installed and linters are required."
        }
        Write-Warning "SKIP: $Name $Version is not installed; its checks did not run."
        return $false
    }
    Import-Module -Name $Name -RequiredVersion $Version -Force
    return $true
}

$havePsa = Import-PinnedModule -Name 'PSScriptAnalyzer' -Version $versions.PSScriptAnalyzer
$havePester = Import-PinnedModule -Name 'Pester' -Version $versions.Pester

if ($havePsa) {
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $targets = foreach ($rel in 'bootstrap.ps1', 'script', 'tests') {
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p) { $p }
    }

    Write-Host '== PSScriptAnalyzer'
    foreach ($target in $targets) {
        $results = @(Invoke-ScriptAnalyzer -Path $target -Recurse -Settings $settings |
                Where-Object Severity -In 'Error', 'Warning')
        foreach ($r in $results) {
            Write-Host ('{0}:{1} [{2}] {3}' -f $r.ScriptName, $r.Line, $r.RuleName, $r.Message)
        }
        if ($results.Count -gt 0) { $failed = $true }
    }

    # Stage-0 also has to be valid Windows PowerShell 5.1 (compatibility rules).
    $stage0 = Join-Path $root 'bootstrap.ps1'
    if (Test-Path -LiteralPath $stage0) {
        $results = @(Invoke-ScriptAnalyzer -Path $stage0 -Settings (Join-Path $root 'PSScriptAnalyzerSettings.Stage0.psd1') |
                Where-Object Severity -In 'Error', 'Warning')
        foreach ($r in $results) {
            Write-Host ('{0}:{1} [{2}] {3}' -f $r.ScriptName, $r.Line, $r.RuleName, $r.Message)
        }
        if ($results.Count -gt 0) { $failed = $true }
    }

    Write-Host '== Formatting (Invoke-Formatter)'
    $files = foreach ($target in $targets) {
        if ((Get-Item -LiteralPath $target).PSIsContainer) {
            Get-ChildItem -LiteralPath $target -Recurse -File -Include '*.ps1', '*.psm1'
        }
        else {
            Get-Item -LiteralPath $target
        }
    }
    foreach ($file in $files) {
        $original = (Get-Content -LiteralPath $file.FullName -Raw) -replace "`r`n", "`n"
        $formatted = (Invoke-Formatter -ScriptDefinition $original -Settings $settings) -replace "`r`n", "`n"
        if ($formatted.TrimEnd() -cne $original.TrimEnd()) {
            Write-Host "Not formatted: $($file.FullName.Substring($root.Length + 1)) (run Invoke-Formatter with PSScriptAnalyzerSettings.psd1)"
            $failed = $true
        }
    }
}

if ($havePester) {
    Write-Host '== Pester'
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $root 'tests'
    $config.Run.Exit = $false
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Normal'
    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { $failed = $true }
}

if ($failed) {
    Write-Host 'FAILED'
    exit 1
}
Write-Host 'All repository tests passed'
