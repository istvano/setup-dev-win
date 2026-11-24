Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repository-wide invariants. Later tasks append Describe blocks.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Self = Join-Path $PSScriptRoot 'Repo.Tests.ps1'

    $script:ScriptFiles = @(
        Get-ChildItem -Path $script:Root -Recurse -File -Include '*.ps1', '*.psm1' |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|\.superpowers|\.tools)[\\/]' }
    )

    # Code lines only: a line whose first non-space character is # is a comment.
    function script:Get-CodeLine {
        param([Parameter(Mandatory)][string]$Path)
        Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch '^\s*#' }
    }
}

Describe 'Repository invariants' {
    It 'finds PowerShell files to check' {
        $script:ScriptFiles.Count | Should-BeGreaterThan 0
    }

    It 'Every script sets strict mode' {
        $offenders = foreach ($file in $script:ScriptFiles) {
            $code = (Get-CodeLine -Path $file.FullName) -join "`n"
            if ($code -notmatch [regex]::Escape('Set-StrictMode -Version Latest') -or
                $code -notmatch [regex]::Escape('$ErrorActionPreference = ''Stop''')) {
                $file.FullName.Substring($script:Root.Length + 1)
            }
        }
        @($offenders) | Should-BeCollection @() -Because 'every script needs strict mode and Stop'
    }

    It 'No remote script execution' {
        $pattern = 'Invoke-Expression|\biex\b|DownloadString|Invoke-RestMethod[^\n]*\|\s*iex'
        $offenders = foreach ($file in $script:ScriptFiles | Where-Object FullName -NE $script:Self) {
            if ((Get-CodeLine -Path $file.FullName) -match $pattern) {
                $file.FullName.Substring($script:Root.Length + 1)
            }
        }
        @($offenders) | Should-BeCollection @() -Because 'ADR-003: no download-and-run'
    }

    It 'No other package managers' {
        $pattern = '\bscoop\b|\bchoco(latey)?\b'
        $offenders = foreach ($file in $script:ScriptFiles | Where-Object FullName -NE $script:Self) {
            if ((Get-CodeLine -Path $file.FullName) -match $pattern) {
                $file.FullName.Substring($script:Root.Length + 1)
            }
        }
        @($offenders) | Should-BeCollection @() -Because 'ADR-002: winget only'
    }

    # Windows PowerShell 5.1 reads a BOM-less file as the ANSI code page, so any
    # non-ASCII byte in a file it reads can corrupt it (W3). Skipped per file
    # while the file does not exist yet.
    It 'ASCII-only file <_> (read by Windows PowerShell 5.1)' -ForEach @('bootstrap.ps1', 'script/lib/pins.psd1') {
        $path = Join-Path $script:Root $_
        if (-not (Test-Path -LiteralPath $path)) {
            Set-ItResult -Skipped -Because "$_ does not exist yet"
            return
        }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should-Be 0
    }
}
