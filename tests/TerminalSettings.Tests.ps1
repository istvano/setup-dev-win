Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/TerminalSettings.psm1') -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/terminal'
    $script:Guid = '{6f9c1a52-3d4e-4b8a-9c17-2e5d8f0b7a31}'
    function script:Read-Fixture {
        param([string]$Name)
        Get-Content -LiteralPath (Join-Path $script:Fixtures $Name) -Raw | ConvertFrom-Json -AsHashtable
    }
    function script:ConvertTo-Flat { param($Value) ($Value | ConvertTo-Json -Depth 32 -Compress) }
    function script:Get-DevProfile { param($Merged) $found = @($Merged.profiles.list | Where-Object { $_.guid -eq $script:Guid }); , $found }
}

Describe 'Merge-TerminalSettings' {
    It 'declares every top-level value on an empty object' {
        $m = Merge-TerminalSettings -Settings @{}
        $m.defaultProfile | Should-Be $script:Guid
        $m.copyOnSelect | Should-BeFalse
        # Terminal 1.21+ names (MTSMSettings.h); the legacy names are migrated by
        # Terminal on load, so writing them would rewrite the file every run.
        $m['warning.multiLinePaste'] | Should-Be 'automatic'
        $m['warning.largePaste'] | Should-BeTrue
        $m['warning.confirmOnClose'] | Should-Be 'automatic'
    }

    It 'removes the legacy warning keys Terminal would migrate, and writes none of them' {
        $m = Merge-TerminalSettings -Settings @{ multiLinePasteWarning = $false; largePasteWarning = $false; confirmCloseAllTabs = $false; 'warning.confirmCloseAllTabs' = $false }
        foreach ($legacy in 'multiLinePasteWarning', 'largePasteWarning', 'confirmCloseAllTabs', 'warning.confirmCloseAllTabs') {
            $m.ContainsKey($legacy) | Should-BeFalse
        }
        $m['warning.multiLinePaste'] | Should-Be 'automatic'
    }

    It 'a file Terminal already migrated is unchanged by a second merge' {
        $once = Merge-TerminalSettings -Settings @{}
        $twice = Merge-TerminalSettings -Settings $once
        ($twice | ConvertTo-Json -Depth 32 -Compress) | Should-Be ($once | ConvertTo-Json -Depth 32 -Compress)
    }

    It 'declares the profile defaults' {
        $d = (Merge-TerminalSettings -Settings @{}).profiles.defaults
        $d.font.face | Should-Be 'JetBrainsMono Nerd Font Mono'
        $d.font.size | Should-Be 12
        $d.colorScheme.dark | Should-Be 'Catppuccin Mocha'
        $d.colorScheme.light | Should-Be 'Catppuccin Latte'
        $d.padding | Should-Be '8, 6'
    }

    It 'adds the dev profile' {
        $p = Get-DevProfile (Merge-TerminalSettings -Settings @{})
        $p.Count | Should-Be 1
        $p[0].name | Should-Be 'dev'
        $p[0].commandline | Should-Be 'wsl.exe -d dev --cd ~'
        $p[0].hidden | Should-BeFalse
    }

    It 'adds both Catppuccin schemes with the upstream colours' {
        $s = (Merge-TerminalSettings -Settings @{}).schemes
        $mocha = @($s | Where-Object { $_.name -eq 'Catppuccin Mocha' })
        $latte = @($s | Where-Object { $_.name -eq 'Catppuccin Latte' })
        $mocha.Count | Should-Be 1
        $latte.Count | Should-Be 1
        $mocha[0].background | Should-Be '#1E1E2E'
        $mocha[0].foreground | Should-Be '#CDD6F4'
        $mocha[0].brightWhite | Should-Be '#A6ADC8'
        $latte[0].background | Should-Be '#EFF1F5'
        $latte[0].foreground | Should-Be '#4C4F69'
        $latte[0].purple | Should-Be '#EA76CB'
    }

    It 'keeps operator profiles, schemes, actions and unknown keys' {
        $in = Read-Fixture 'operator.json'
        $m = Merge-TerminalSettings -Settings $in
        $m.theme | Should-Be 'dark'
        (ConvertTo-Flat $m.actions) | Should-Be (ConvertTo-Flat $in.actions)
        (ConvertTo-Flat $m.customOperatorKey) | Should-Be (ConvertTo-Flat $in.customOperatorKey)
        $m.profiles.defaults.opacity | Should-Be 90
        $m.profiles.defaults.font.weight | Should-Be 'bold'
        $m.profiles.defaults.font.face | Should-Be 'JetBrainsMono Nerd Font Mono'
        @($m.profiles.list | Where-Object { $_.name -eq 'Operator' }).Count | Should-Be 1
        ($m.profiles.list | Where-Object { $_.name -eq 'Operator' }).commandline | Should-Be 'cmd.exe'
        @($m.schemes | Where-Object { $_.name -eq 'Operator Scheme' }).Count | Should-Be 1
        @($m.schemes | Where-Object { $_.name -eq 'Catppuccin Mocha' }).Count | Should-Be 1
        ($m.schemes | Where-Object { $_.name -eq 'Catppuccin Mocha' }).background | Should-Be '#1E1E2E'
    }

    It 'hides the dynamic dev profile from both sources and leaves other dynamic profiles' {
        $m = Merge-TerminalSettings -Settings (Read-Fixture 'operator.json')
        ($m.profiles.list | Where-Object { $_.guid -eq '{22222222-2222-2222-2222-222222222222}' }).hidden | Should-BeTrue
        ($m.profiles.list | Where-Object { $_.guid -eq '{33333333-3333-3333-3333-333333333333}' }).hidden | Should-BeTrue
        $ubuntu = $m.profiles.list | Where-Object { $_.name -eq 'Ubuntu' }
        $ubuntu.ContainsKey('hidden') | Should-BeFalse
        (Get-DevProfile $m).Count | Should-Be 1
        (Get-DevProfile $m)[0].hidden | Should-BeFalse
    }

    It 'converts a legacy profiles array to a list' {
        $m = Merge-TerminalSettings -Settings @{ profiles = @(@{ guid = '{11111111-1111-1111-1111-111111111111}'; name = 'Old' }) }
        @($m.profiles.list | Where-Object { $_.name -eq 'Old' }).Count | Should-Be 1
        (Get-DevProfile $m).Count | Should-Be 1
        $m.profiles.defaults.padding | Should-Be '8, 6'
    }

    It 'resets declared keys on an existing dev profile matched by guid, case-insensitively' {
        $in = @{ profiles = @{ list = @(@{ guid = $script:Guid.ToUpperInvariant(); name = 'wrong'; hidden = $true; icon = 'x.png' }) } }
        $m = Merge-TerminalSettings -Settings $in
        $p = @($m.profiles.list)
        $p.Count | Should-Be 1
        $p[0].name | Should-Be 'dev'
        $p[0].hidden | Should-BeFalse
        $p[0].icon | Should-Be 'x.png'
    }

    It 'does not mutate its input' {
        $in = Read-Fixture 'operator.json'
        $before = ConvertTo-Flat $in
        $null = Merge-TerminalSettings -Settings $in
        (ConvertTo-Flat $in) | Should-Be $before
    }

    It 'is idempotent' {
        $once = Merge-TerminalSettings -Settings (Read-Fixture 'operator.json')
        $twice = Merge-TerminalSettings -Settings $once
        (ConvertTo-Flat $twice) | Should-Be (ConvertTo-Flat $once)
    }

    It 'parses and merges the commented fresh-Terminal fixture' {
        $m = Merge-TerminalSettings -Settings (Read-Fixture 'fresh.json')
        $m.defaultProfile | Should-Be $script:Guid
        @($m.profiles.list | Where-Object { $_.name -eq 'Windows PowerShell' }).Count | Should-Be 1
        $m['$schema'] | Should-Be 'https://aka.ms/terminal-profiles-schema'
    }
}

Describe 'Update-TerminalSettings' {
    BeforeEach {
        $script:State = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Local = Join-Path $script:State 'LocalState'
        $script:File = Join-Path $script:Local 'settings.json'
        $file = $script:File
        Mock -ModuleName TerminalSettings Get-TerminalSettingsPath { $file }.GetNewClosure()
        Mock -ModuleName TerminalSettings Write-Info {}
    }

    It 'skips when the LocalState directory is absent and creates nothing' {
        Update-TerminalSettings | Should-Be 'skipped'
        Test-Path -LiteralPath $script:State | Should-BeFalse
    }

    It 'creates the file from an empty object when absent, without a backup' {
        New-Item -ItemType Directory -Path $script:Local -Force | Out-Null
        Update-TerminalSettings | Should-Be 'updated'
        (Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json -AsHashtable).defaultProfile | Should-Be $script:Guid
        @(Get-ChildItem -LiteralPath $script:Local -Filter 'settings.json.backup.*').Count | Should-Be 0
    }

    It 'writes UTF-8 without a BOM' {
        New-Item -ItemType Directory -Path $script:Local -Force | Out-Null
        Update-TerminalSettings | Out-Null
        $bytes = [IO.File]::ReadAllBytes($script:File)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should-BeFalse
        $bytes[0] | Should-Be ([byte][char]'{')
    }

    It 'updates a commented file, keeps operator content and writes exactly one backup' {
        New-Item -ItemType Directory -Path $script:Local -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'fresh.json') -Destination $script:File
        $original = Get-Content -LiteralPath $script:File -Raw
        Update-TerminalSettings | Should-Be 'updated'
        $backups = @(Get-ChildItem -LiteralPath $script:Local -Filter 'settings.json.backup.*')
        $backups.Count | Should-Be 1
        $backups[0].Name | Should-MatchString '^settings\.json\.backup\.\d{8}T\d{6}Z$'
        (Get-Content -LiteralPath $backups[0].FullName -Raw) | Should-Be $original
        $m = Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json -AsHashtable
        @($m.profiles.list | Where-Object { $_.name -eq 'Windows PowerShell' }).Count | Should-Be 1
        $m.copyOnSelect | Should-BeFalse
    }

    It 'is unchanged with no new backup on a second run' {
        New-Item -ItemType Directory -Path $script:Local -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'operator.json') -Destination $script:File
        Update-TerminalSettings | Should-Be 'updated'
        $written = Get-Content -LiteralPath $script:File -Raw
        Update-TerminalSettings | Should-Be 'unchanged'
        (Get-Content -LiteralPath $script:File -Raw) | Should-Be $written
        @(Get-ChildItem -LiteralPath $script:Local -Filter 'settings.json.backup.*').Count | Should-Be 1
    }

    It 'does not rewrite a commented file whose declared values are already present' {
        New-Item -ItemType Directory -Path $script:Local -Force | Out-Null
        $merged = Merge-TerminalSettings -Settings @{}
        $text = "// operator comment`n" + ($merged | ConvertTo-Json -Depth 32)
        [IO.File]::WriteAllText($script:File, $text)
        Update-TerminalSettings | Should-Be 'unchanged'
        (Get-Content -LiteralPath $script:File -Raw) | Should-Be $text
        @(Get-ChildItem -LiteralPath $script:Local -Filter 'settings.json.backup.*').Count | Should-Be 0
    }

    It 'restores a declared key the operator changed and says so, keeping undeclared changes' {
        New-Item -ItemType Directory -Path $script:Local -Force | Out-Null
        Update-TerminalSettings | Out-Null
        $m = Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json -AsHashtable
        $m.copyOnSelect = $true
        $m.theme = 'light'
        $m | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $script:File
        Update-TerminalSettings | Should-Be 'updated'
        $after = Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json -AsHashtable
        $after.copyOnSelect | Should-BeFalse
        $after.theme | Should-Be 'light'
        Should-Invoke -ModuleName TerminalSettings -CommandName Write-Info -ParameterFilter { $Message -like '*restor*' }
    }

    It 'refuses to overwrite a file that is not valid JSON' {
        New-Item -ItemType Directory -Path $script:Local -Force | Out-Null
        Set-Content -LiteralPath $script:File -Value '{ not json'
        { Update-TerminalSettings } | Should-Throw '*settings.json*'
        (Get-Content -LiteralPath $script:File -Raw).Trim() | Should-Be '{ not json'
    }
}

Describe 'Test-TerminalSettings' {
    BeforeEach {
        $script:Local = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Local | Out-Null
        $script:File = Join-Path $script:Local 'settings.json'
        $file = $script:File
        Mock -ModuleName TerminalSettings Get-TerminalSettingsPath { $file }.GetNewClosure()
        Mock -ModuleName TerminalSettings Write-Info {}
    }

    It 'returns an empty string once the settings are applied' {
        Update-TerminalSettings | Out-Null
        Test-TerminalSettings | Should-Be ''
    }

    It 'names defaultProfile when it is wrong' {
        $m = Merge-TerminalSettings -Settings @{}
        $m.defaultProfile = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'
        $m | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $script:File
        Test-TerminalSettings | Should-BeLikeString '*defaultProfile*'
    }

    It 'names a missing scheme' {
        $m = Merge-TerminalSettings -Settings @{}
        $m.schemes = @()
        $m | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $script:File
        Test-TerminalSettings | Should-BeLikeString '*Catppuccin Mocha*'
    }

    It 'reports a missing file' {
        Test-TerminalSettings | Should-BeLikeString '*settings.json*'
    }

    It 'names the multi-line paste warning when Terminal holds another value' {
        $m = Merge-TerminalSettings -Settings @{}
        $m['warning.multiLinePaste'] = 'never'
        $m | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $script:File
        Test-TerminalSettings | Should-BeLikeString '*warning.multiLinePaste*'
    }

    It 'accepts true as Terminal''s synonym for automatic' {
        $m = Merge-TerminalSettings -Settings @{}
        $m['warning.multiLinePaste'] = $true
        $m | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $script:File
        Test-TerminalSettings | Should-Be ''
    }
}
