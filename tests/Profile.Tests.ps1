Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ProfilePath = Join-Path $script:Root 'chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1'
    $script:Text = Get-Content -LiteralPath $script:ProfilePath -Raw
}

Describe 'PowerShell profile (chezmoi source)' {
    It 'is ASCII only' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ProfilePath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should-Be 0
    }
    It 'is a plain file, not a template' {
        $script:ProfilePath | Should-NotBeLikeString -Expected '*.tmpl'
        $script:Text | Should-NotBeLikeString -Expected '*{{*'
    }
    It 'sets the PSReadLine history options, guarded by the module being available' {
        $script:Text | Should-MatchString 'Get-Module -ListAvailable PSReadLine'
        $script:Text | Should-MatchString 'Set-PSReadLineOption[^\r\n]*-HistoryNoDuplicates'
        $script:Text | Should-MatchString '-MaximumHistoryCount 10000'
        $script:Text | Should-MatchString '-PredictionSource History'
    }
    It 'defines dev as a wrapper over wsl.exe -d dev in the Linux home, passing arguments through' {
        $script:Text | Should-MatchString "(?m)^function dev \{ wsl\.exe -d dev --cd '~' @args \}\s*$"
    }
    It 'passes the tilde only as the quoted literal of wsl.exe --cd (PowerShell 7.5+ expands any other form)' {
        $code = ($script:Text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        ($code -match '\s~(\s|$)') | Should-BeFalse
        ($code -match '\[char\]\s*126') | Should-BeFalse
    }
    It 'holds no secrets and makes no network calls' {
        ($script:Text -match '(?i)invoke-webrequest|invoke-restmethod|\bcurl\b|\bwget\b|https?://|token|password|secret|apikey') | Should-BeFalse
    }
}
