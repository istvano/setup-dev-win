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

    # Executable code only: block comments, comment lines and the CONTENTS of string literals
    # are dropped (each literal is kept as an empty pair of quotes). A recommendation may
    # therefore name a command such as Disable-WindowsOptionalFeature as text, but never run
    # it. Simple on purpose: it scans line by line and does not understand here-strings, so
    # the posture files do not use them.
    function script:Get-CodeLineNoString {
        param([Parameter(Mandatory)][string]$Path)
        $text = (Get-Content -LiteralPath $Path -Raw) -replace '(?s)<#.*?#>', ''
        $text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' } |
            ForEach-Object { [regex]::Replace($_, '"(?:[^"`]|`.)*"|''(?:[^'']|'''')*''', '""') }
    }

    # The files that implement the read-only posture report.
    $script:PostureFiles = @('script/lib/PostureChecks.psm1', 'script/hardening-check.ps1')
}

Describe 'Repository invariants' {
    It 'finds PowerShell files to check' {
        $script:ScriptFiles.Count | Should-BeGreaterThan 0
    }

    It 'Every script sets strict mode' {
        # The chezmoi-managed PowerShell profile is dot-sourced into the operator's interactive
        # session, where strict mode and Stop would break ad-hoc commands; it is exempt.
        $offenders = foreach ($file in $script:ScriptFiles | Where-Object { $_.FullName -notlike '*chezmoi*Microsoft.PowerShell_profile.ps1' }) {
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
    # non-ASCII byte in a file it reads can corrupt it (AGENTS.md). Skipped per file
    # while the file does not exist yet.
    It 'pins.psd1 carries the Linux repository owner' {
        (Import-PowerShellDataFile (Join-Path $script:Root 'script/lib/pins.psd1')).LinuxRepoOwner | Should-Be 'istvano'
    }

    It 'pins.psd1 has a PowerShell floor and no installed-version pins (W21, W22)' {
        $pins = Import-PowerShellDataFile (Join-Path $script:Root 'script/lib/pins.psd1')
        $pins.MinPowerShell | Should-Be '7.6'
        @($pins.Keys | Where-Object { $_ -in 'PowerShell', 'Chezmoi' }) | Should-BeCollection @()
    }

    It 'ASCII-only file <_> (read by Windows PowerShell 5.1)' -ForEach @('bootstrap.ps1', 'script/lib/pins.psd1', 'wsl/ubuntu.lock.psd1') {
        $path = Join-Path $script:Root $_
        if (-not (Test-Path -LiteralPath $path)) {
            Set-ItResult -Skipped -Because "$_ does not exist yet"
            return
        }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should-Be 0
    }
}

Describe 'Workflows' {
    BeforeAll {
        $script:WorkflowFiles = @(
            Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -File -ErrorAction SilentlyContinue |
                Where-Object Extension -In '.yml', '.yaml'
        )
        # Non-comment lines of every workflow, as @{ File; Text } records.
        $script:WorkflowLines = @(
            foreach ($file in $script:WorkflowFiles) {
                foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                    if ($line -notmatch '^\s*#') { [pscustomobject]@{ File = $file.Name; Text = $line } }
                }
            }
        )
        $script:UsesLines = @($script:WorkflowLines | Where-Object { $_.Text -match '^\s*-?\s*uses:' })
    }

    It 'has at least one workflow with uses: lines (no vacuous pass)' {
        $script:WorkflowFiles.Count | Should-BeGreaterThan 0
        $script:UsesLines.Count | Should-BeGreaterThan 0
    }

    It 'pins every uses: line to a 40-hex SHA' {
        $offenders = $script:UsesLines | Where-Object { $_.Text -notmatch '^\s*-?\s*uses:\s*\S+@[0-9a-f]{40}(\s|$)' }
        @($offenders | ForEach-Object { "$($_.File): $($_.Text.Trim())" }) | Should-BeCollection @()
    }

    It 'has no floating refs' {
        # Only uses: refs; `go install tool@v1.2.3` is an exact pin, not a floating ref.
        $offenders = $script:UsesLines | Where-Object { $_.Text -match '@(latest|main|master)\b|@v\d' }
        @($offenders | ForEach-Object { "$($_.File): $($_.Text.Trim())" }) | Should-BeCollection @()
    }

    It 'gives every Install-PSResource an exact -Version' {
        $lines = @($script:WorkflowLines | Where-Object { $_.Text -match 'Install-PSResource' })
        $offenders = $lines | Where-Object { $_.Text -notmatch '-Version\b' }
        @($offenders | ForEach-Object { "$($_.File): $($_.Text.Trim())" }) | Should-BeCollection @()
    }

    It 'has no curl or wget piped to a shell' {
        $offenders = $script:WorkflowLines | Where-Object { $_.Text -match '(curl|wget)\b.*\|\s*(sudo\s+)?(ba|z)?sh\b' }
        @($offenders | ForEach-Object { "$($_.File): $($_.Text.Trim())" }) | Should-BeCollection @()
    }

    It 'yamllint covers every YAML file in the repository, not only the workflows' {
        $runs = @($script:WorkflowLines | Where-Object { $_.Text -match '^\s*run:\s*yamllint\b' } | ForEach-Object { $_.Text.Trim() })
        $runs | Should-ContainCollection @('run: yamllint --strict .')
    }

    It 'sets persist-credentials: false on every checkout' {
        $offenders = foreach ($file in $script:WorkflowFiles) {
            $lines = @($script:WorkflowLines | Where-Object File -EQ $file.Name | ForEach-Object Text)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'uses:\s*actions/checkout@') {
                    # The step's `with:` block runs until the next step ("- ").
                    $j = $i + 1
                    $block = while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\s*-\s') { $lines[$j]; $j++ }
                    if (-not ($block -match '^\s*persist-credentials:\s*false\s*$')) { "$($file.Name): checkout without persist-credentials: false" }
                }
            }
        }
        @($offenders) | Should-BeCollection @()
    }
}

Describe 'Native argument invariants' {
    # PowerShell 7.5+ expands a tilde in a native argument to the Windows profile path for
    # every form except a quoted literal written at the call site (ADR-024; the W1 verify bug,
    # commit 91e3f22). So [char]126 and friends do NOT help, and the one safe spelling is
    # wsl.exe --cd '~'. Anywhere else, use $HOME inside the Linux command.
    It 'no code builds a tilde from [char]126 (it is expanded like a bare ~)' {
        $offenders = foreach ($file in $script:ScriptFiles) {
            $relative = $file.FullName.Substring($script:Root.Length + 1) -replace '\\', '/'
            if ($relative -like 'tests/*') { continue }
            if ((Get-CodeLine -Path $file.FullName) -match '\[char\]\s*126') { $relative }
        }
        @($offenders) | Should-BeCollection @()
    }
    It 'no quoted string starts with ~ except the direct argument of wsl.exe --cd' {
        $offenders = foreach ($file in $script:ScriptFiles) {
            $relative = $file.FullName.Substring($script:Root.Length + 1) -replace '\\', '/'
            if ($relative -like 'tests/*') { continue }
            foreach ($line in @(Get-CodeLine -Path $file.FullName)) {
                if ($line -match '[''"]~' -and $line -notmatch 'wsl\.exe\b.*--cd\s+[''"]~[''"]') { "${relative}: $line" }
            }
        }
        @($offenders) | Should-BeCollection @() -Because 'use $HOME inside the Linux command instead'
    }
}

Describe 'Elevation invariants' {
    It 'dism.exe, the DISM cmdlets and policy cmdlets appear only under script/elevated' {
        $pattern = '\bdism\.exe\b|Enable-WindowsOptionalFeature|Disable-WindowsOptionalFeature|Get-WindowsOptionalFeature|Set-ExecutionPolicy\b.*-Scope[\s:]+LocalMachine|Set-ExecutionPolicy\b.*LocalMachine.*-Scope'
        $offenders = foreach ($file in $script:ScriptFiles) {
            $relative = $file.FullName.Substring($script:Root.Length + 1) -replace '\\', '/'
            if ($relative -like 'tests/*' -or $relative -like 'script/elevated/*') { continue }
            # The posture files may name these commands in recommendation strings (text, not code).
            $lines = if ($relative -in $script:PostureFiles) { Get-CodeLineNoString -Path $file.FullName } else { Get-CodeLine -Path $file.FullName }
            if ($lines -match $pattern) { $relative }
        }
        @($offenders) | Should-BeCollection @() -Because 'only script/elevated may change machine state'
    }

    It 'the posture report is read-only: no write, no state change, no elevation in code' {
        $forbidden = @(
            '\bSet-(?!StrictMode\b)\w'
            '\bNew-ItemProperty\b|\bNew-Item\b|\bSet-ItemProperty\b'
            '\bRemove-\w'
            '\bEnable-\w'
            '\bDisable-\w'
            '\bnetsh(\.exe)?\b.*\b(add|set|delete)\b'
            'Start-Process\b.*-Verb\s+RunAs'
            'Invoke-ElevatedScript'
        )
        foreach ($relative in $script:PostureFiles) {
            $path = Join-Path $script:Root $relative
            Test-Path -LiteralPath $path | Should-BeTrue -Because "$relative must exist"
            $code = @(Get-CodeLineNoString -Path $path)
            foreach ($pattern in $forbidden) {
                @($code | Where-Object { $_ -match $pattern }) | Should-BeCollection @() -Because "$relative must not match $pattern"
            }
            # The native command's verb is a string token, so the scan above cannot see it.
            @(Get-CodeLine -Path $path | Where-Object { $_ -match '''(add|set|delete)''' }) | Should-BeCollection @() -Because "$relative passes no add/set/delete verb to a native command"
        }
    }

    It 'the posture scan itself refuses code but allows the same words in a string' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) "posture-scan-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            Set-Content -LiteralPath $temp -Value @(
                "`$rec = 'Disable-WindowsOptionalFeature -Online (elevated).'"
                '<# Remove-Item in help text #>'
                'Remove-Item -Path x'
            )
            $code = @(Get-CodeLineNoString -Path $temp)
            @($code | Where-Object { $_ -match '\bDisable-\w' }).Count | Should-Be 0
            @($code | Where-Object { $_ -match '\bRemove-\w' }).Count | Should-Be 1
        }
        finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }

    It 'Containers-DisposableClientVM appears only in Enable-Features.ps1 (code) and tests' {
        $offenders = foreach ($file in $script:ScriptFiles) {
            $relative = $file.FullName.Substring($script:Root.Length + 1) -replace '\\', '/'
            if ($relative -like 'tests/*') { continue }
            if ((Get-CodeLine -Path $file.FullName) -match 'Containers-DisposableClientVM') { $relative }
        }
        # Enable-Features.ps1 names it only in comments (allowlist is exact), so no code line may.
        @($offenders) | Should-BeCollection @() -Because 'ADR: never touch Windows Sandbox'
    }

    It 'bootstrap.ps1 and the runner refuse an elevated launch with the same text' {
        $text = 'Run from a normal (non-elevated) terminal; elevation is requested per step.'
        foreach ($rel in 'bootstrap.ps1', 'script/lib/Runner.psm1') {
            (Get-Content -LiteralPath (Join-Path $script:Root $rel) -Raw).Contains("'$text'") | Should-BeTrue -Because $rel
        }
    }

    It 'every script under script/elevated is allowlisted explicitly' {
        $elevated = @(Get-ChildItem -Path (Join-Path $script:Root 'script/elevated') -File | ForEach-Object Name)
        $elevated | Should-BeCollection @('Enable-Features.ps1')
    }
}

Describe 'WSL posture invariants (repo-wide)' {
    # Code and configuration only: prose (docs) may name what is forbidden.
    It 'no code or config file selects mirrored networking or allows default inbound' {
        $hits = Get-ChildItem -Path $script:Root -Recurse -File -Force -Include '*.ps1', '*.psm1', '*.psd1', '*.tmpl', '*.toml', '*.yml', '*.yaml', '*.json', '*.wslconfig' |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|\.superpowers|\.tools|docs)[\\/]' -and $_.FullName -ne $script:Self } |
            Select-String -Pattern 'networkingMode\s*=\s*mirrored', 'DefaultInboundAction\s+Allow' |
            ForEach-Object { $_.Path.Substring($script:Root.Length + 1) }
        @($hits) | Should-BeCollection @() -Because 'NAT with the firewall on is a global constraint'
    }
}
