Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Stage-0 tests. They run under pwsh locally and under Windows PowerShell 5.1 in
# CI, so this file avoids syntax that 5.1 does not have.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Bootstrap = Join-Path $script:Root 'bootstrap.ps1'
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/winget-settings'
    $env:SETUP_DEV_WIN_NO_MAIN = '1'
    . $script:Bootstrap
}

AfterAll {
    Remove-Item -Path Env:\SETUP_DEV_WIN_NO_MAIN -ErrorAction SilentlyContinue
}

Describe 'Merge-WingetSettings' {
    BeforeEach {
        # A fresh directory per test: TestDrive is shared across a Describe.
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $script:Settings = Join-Path $script:Dir 'settings.json'
    }

    It 'adds telemetry.disable to an empty (absent) file' {
        Merge-WingetSettings -Path $script:Settings
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.telemetry.disable | Should-Be $true
    }

    It 'writes UTF-8 without a BOM' {
        Merge-WingetSettings -Path $script:Settings
        $bytes = [System.IO.File]::ReadAllBytes($script:Settings)
        $bytes[0] | Should-Be ([byte][char]'{')
    }

    It 'preserves existing keys' {
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'existing-keys.json') -Destination $script:Settings
        Merge-WingetSettings -Path $script:Settings
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.visual.progressBar | Should-Be 'rainbow'
        $json.installBehavior.preferences.scope | Should-Be 'user'
        $json.telemetry.other | Should-Be 1
        $json.telemetry.disable | Should-Be $true
    }

    It 'handles the default JSONC with comments' {
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'default-jsonc.json') -Destination $script:Settings
        Merge-WingetSettings -Path $script:Settings
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.visual.progressBar | Should-Be 'rainbow'
        $json.telemetry.disable | Should-Be $true
        # A // inside a string (the schema URL) must survive comment stripping.
        $json.'$schema' | Should-Be 'https://aka.ms/winget-settings.schema.json'
    }

    It 'handles the real winget default (trailing comma left after the comments)' {
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'real-default.json') -Destination $script:Settings
        Merge-WingetSettings -Path $script:Settings
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.'$schema' | Should-Be 'https://aka.ms/winget-settings.schema.json'
        $json.telemetry.disable | Should-Be $true
    }

    It 'does not touch a comma before a brace inside a string' {
        ConvertTo-StrictJson -Text '{ "a": "x,}", "b": [1, 2,], }' | Should-Be '{ "a": "x,}", "b": [1, 2] }'
    }

    It 'treats a zero-byte file as an empty object and backs it up' {
        New-Item -ItemType File -Path $script:Settings | Out-Null
        Merge-WingetSettings -Path $script:Settings
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.telemetry.disable | Should-Be $true
        @(Get-ChildItem -Path $script:Dir -Filter 'settings.json.backup.*').Count | Should-Be 1
    }

    It 'writes nothing and makes no backup when telemetry is already disabled' {
        [System.IO.File]::WriteAllText($script:Settings, '{ "telemetry": { "disable": true } }')
        $before = (Get-Item -LiteralPath $script:Settings).LastWriteTimeUtc
        Start-Sleep -Milliseconds 50
        Merge-WingetSettings -Path $script:Settings
        [System.IO.File]::ReadAllText($script:Settings) | Should-Be '{ "telemetry": { "disable": true } }'
        (Get-Item -LiteralPath $script:Settings).LastWriteTimeUtc | Should-Be $before
        @(Get-ChildItem -Path $script:Dir -Filter 'settings.json.backup.*').Count | Should-Be 0
    }

    It 'treats a string "true" as not disabled and writes a real boolean' {
        [System.IO.File]::WriteAllText($script:Settings, '{ "telemetry": { "disable": "true" } }')
        Merge-WingetSettings -Path $script:Settings
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.telemetry.disable | Should-HaveType ([bool])
        $json.telemetry.disable | Should-Be $true
        @(Get-ChildItem -Path $script:Dir -Filter 'settings.json.backup.*').Count | Should-Be 1
    }

    It 'refuses invalid JSON and leaves the file unchanged' {
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'invalid.json') -Destination $script:Settings
        $before = [System.IO.File]::ReadAllText($script:Settings)
        $thrown = $null
        try { Merge-WingetSettings -Path $script:Settings } catch { $thrown = $_.Exception.Message }
        $thrown | Should-Be 'winget settings.json could not be parsed; add "telemetry": { "disable": true } by hand (winget settings) and re-run.'
        [System.IO.File]::ReadAllText($script:Settings) | Should-Be $before
        @(Get-ChildItem -Path $script:Dir -Filter 'settings.json.backup.*').Count | Should-Be 0
    }

    It 'writes a backup before changing' {
        Copy-Item -LiteralPath (Join-Path $script:Fixtures 'existing-keys.json') -Destination $script:Settings
        $before = [System.IO.File]::ReadAllText($script:Settings)
        Merge-WingetSettings -Path $script:Settings
        $backups = @(Get-ChildItem -Path $script:Dir -Filter 'settings.json.backup.*')
        $backups.Count | Should-Be 1
        [System.IO.File]::ReadAllText($backups[0].FullName) | Should-Be $before
    }
}

Describe 'Assert-SupportedWindows' {
    BeforeEach {
        $script:SavedArch = $env:PROCESSOR_ARCHITECTURE
    }

    AfterEach {
        $env:PROCESSOR_ARCHITECTURE = $script:SavedArch
    }

    It 'rejects build 22631' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        Mock Get-OsBuildNumber { 22631 }
        { Assert-SupportedWindows -MinBuild 26100 } | Should-Throw -ExceptionMessage '*22631*'
    }

    It 'rejects ARM64' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'
        Mock Get-OsBuildNumber { 26100 }
        { Assert-SupportedWindows -MinBuild 26100 } | Should-Throw -ExceptionMessage '*ARM64*'
    }

    It 'accepts x64 at the minimum build' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        Mock Get-OsBuildNumber { 26100 }
        Assert-SupportedWindows -MinBuild 26100
    }
}

Describe 'Wait-Winget' {
    It 'message contains RegisterByFamilyName' {
        Mock Get-Command { $null }
        Mock Start-Sleep { }
        $thrown = $null
        try { Wait-Winget -TimeoutSeconds 1 } catch { $thrown = $_.Exception.Message }
        $thrown | Should-BeLikeString '*Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe*'
    }

    It 'returns when winget is present' {
        Mock Get-Command { [pscustomobject]@{ Name = 'winget.exe' } }
        Wait-Winget -TimeoutSeconds 1
    }
}

Describe 'Test-PowerShellVersionAccepted' {
    It 'accepts <Version> for minimum 7.6' -ForEach @(
        @{ Version = '7.6.0' }
        @{ Version = '7.6.10' }
        @{ Version = '7.7.0' }
        @{ Version = '7.10.1' }
        @{ Version = '8.0.0' }
    ) {
        Test-PowerShellVersionAccepted -Version $Version -Minimum '7.6' | Should-BeTrue
    }

    It 'rejects <Version> for minimum 7.6' -ForEach @(
        @{ Version = '7.5.13' }
        @{ Version = '7.4.0' }
        @{ Version = '5.1.26100' }
        @{ Version = '7.7.0-preview.1' }
        @{ Version = 'garbage' }
        @{ Version = '' }
    ) {
        Test-PowerShellVersionAccepted -Version $Version -Minimum '7.6' | Should-BeFalse
    }
}

Describe 'Install-PowerShell' {
    BeforeEach {
        # Sync-SessionPath edits this session's PATH; keep it out of the test run.
        Mock Sync-SessionPath { }
        $script:Missing = [pscustomobject]@{ Path = $null; Report = @('none') }
        $script:Found = [pscustomobject]@{ Path = 'C:\x\pwsh.exe'; Report = @() }
    }

    It 'skips when a qualifying pwsh is found' {
        Mock Find-PowerShell7 { $script:Found }
        Mock Invoke-Winget { }
        Install-PowerShell -Minimum '7.6'
        Should-NotInvoke -CommandName Invoke-Winget
    }

    It 'syncs the session PATH before looking' {
        Mock Find-PowerShell7 { $script:Found }
        Install-PowerShell -Minimum '7.6'
        Should-Invoke -CommandName Sync-SessionPath -Times 1 -Exactly
    }

    It 'asks for the same minimum it was given' {
        Mock Find-PowerShell7 { $script:Found }
        Install-PowerShell -Minimum '7.6'
        Should-Invoke -CommandName Find-PowerShell7 -Times 1 -Exactly -ParameterFilter { $Minimum -eq '7.6' }
    }

    It 'uses the real candidate list: an alias-only pwsh counts as installed' {
        $savedLocal = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = 'C:\Users\a\AppData\Local'
        try {
            $alias = 'C:\Users\a\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
            Mock Get-Command { $null }
            Mock Test-Path { $LiteralPath -eq $alias }
            Mock Get-PowerShellVersionAt { '7.7.0' }
            Mock Invoke-Winget { }
            Install-PowerShell -Minimum '7.6'
            Should-NotInvoke -CommandName Invoke-Winget
        }
        finally { $env:LOCALAPPDATA = $savedLocal }
    }

    It 'installs when no qualifying pwsh is found' {
        Mock Find-PowerShell7 { $script:Missing }
        Mock Invoke-Winget { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Install-PowerShell -Minimum '7.6'
        Should-Invoke -CommandName Invoke-Winget -Times 1 -Exactly
    }

    It 'installs the latest stable package with no version, installer type or scope' {
        Mock Find-PowerShell7 { $script:Missing }
        Mock Invoke-Winget { $script:Captured = $Arguments; [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Install-PowerShell -Minimum '7.6'
        ($script:Captured -join ' ') | Should-Be ('install --id Microsoft.PowerShell --source winget --exact --silent ' +
            '--accept-package-agreements --accept-source-agreements --disable-interactivity')
    }

    It 'returns nothing on the pipeline' {
        Mock Find-PowerShell7 { $script:Missing }
        Mock Invoke-Winget { [pscustomobject]@{ ExitCode = 0; Output = @('noise') } }
        @(Install-PowerShell -Minimum '7.6').Count | Should-Be 0
    }

    It 'throws with the exit code when winget fails and still nothing qualifies' {
        Mock Find-PowerShell7 { $script:Missing }
        Mock Invoke-Winget { [pscustomobject]@{ ExitCode = 5; Output = @('some other error') } }
        { Install-PowerShell -Minimum '7.6' } | Should-Throw -ExceptionMessage '*exit code 5*'
    }

    It 'does not blame the source for an ordinary install failure' {
        Mock Find-PowerShell7 { $script:Missing }
        Mock Invoke-Winget { [pscustomobject]@{ ExitCode = -2147024891; Output = @('Access is denied to something else') } }
        $thrown = $null
        try { Install-PowerShell -Minimum '7.6' } catch { $thrown = $_.Exception.Message }
        $thrown | Should-BeLikeString '*winget failed to install PowerShell (exit code -2147024891)*'
        $thrown | Should-NotBeLikeString '*winget source reset*'
    }

    It 'resolves again after a non-zero exit and accepts the pwsh that is there' {
        $script:Looks = 0
        Mock Find-PowerShell7 { $script:Looks++; if ($script:Looks -eq 1) { $script:Missing } else { $script:Found } }
        Mock Invoke-Winget { [pscustomobject]@{ ExitCode = -1978335189; Output = @('No applicable upgrade found.') } }
        Install-PowerShell -Minimum '7.6'
        Should-Invoke -CommandName Find-PowerShell7 -Times 2 -Exactly
        Should-Invoke -CommandName Sync-SessionPath -Times 2 -Exactly
    }

    It 'throws the source reset steps when the install output names the predefined source' {
        Mock Find-PowerShell7 { $script:Missing }
        Mock Invoke-Winget { [pscustomobject]@{ ExitCode = -2147024891; Output = @('Failed to open the predefined source.') } }
        { Install-PowerShell -Minimum '7.6' } | Should-Throw -ExceptionMessage '*winget source reset --force*'
    }
}

Describe 'Invoke-WingetSourceUpdate' {
    It 'runs winget source update' {
        Mock Invoke-Winget { [pscustomobject]@{ ExitCode = 0; Output = @('Done') } }
        @(Invoke-WingetSourceUpdate).Count | Should-Be 0
        Should-Invoke -CommandName Invoke-Winget -Times 1 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq 'source update --name winget' }
    }

    It 'throws the reset steps when <Case>' -ForEach @(
        @{ Case = 'the output names the predefined source'; Code = 1; Text = 'Failed to open the predefined source.' }
        @{ Case = 'the output carries 0x80070005'; Code = 1; Text = '0x80070005 : Access is denied.' }
        @{ Case = 'the exit code is 0x80070005'; Code = -2147024891; Text = '' }
    ) {
        $result = [pscustomobject]@{ ExitCode = $Code; Output = @($Text) }
        Mock Invoke-Winget { $result }.GetNewClosure()
        $thrown = $null
        try { Invoke-WingetSourceUpdate } catch { $thrown = $_.Exception.Message }
        $thrown | Should-BeLikeString '*0x80070005*'
        $thrown | Should-BeLikeString '*administrator terminal*winget source reset --force*'
        $thrown | Should-BeLikeString '*normal terminal*winget source update*'
        $thrown | Should-BeLikeString '*App Installer*Microsoft Store*Library > Get updates*'
        $thrown | Should-BeLikeString '*re-run bootstrap.ps1*'
    }

    It 'throws with the exit code on any other failure' {
        Mock Invoke-Winget { [pscustomobject]@{ ExitCode = 7; Output = @('network down') } }
        { Invoke-WingetSourceUpdate } | Should-Throw -ExceptionMessage '*winget source update failed (exit code 7)*'
    }
}

Describe 'Resolve-PowerShell7' {
    BeforeEach {
        $script:SavedLocal = $env:LOCALAPPDATA
        $script:SavedPf = $env:ProgramFiles
        $env:LOCALAPPDATA = 'C:\Users\a\AppData\Local'
        $env:ProgramFiles = 'C:\Program Files'
        $script:Alias = 'C:\Users\a\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
        $script:Msi = 'C:\Program Files\PowerShell\7\pwsh.exe'
    }
    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocal
        $env:ProgramFiles = $script:SavedPf
    }

    It 'returns the pwsh on PATH when it is <Version>' -ForEach @(
        @{ Version = '7.6.0' }
        @{ Version = '7.7.0' }
    ) {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\x\pwsh.exe' } }
        Mock Get-PowerShellVersionAt ([scriptblock]::Create("'$Version'"))
        Resolve-PowerShell7 -Minimum '7.6' | Should-Be 'C:\x\pwsh.exe'
    }

    It 'falls back to the WindowsApps alias when PATH has no pwsh' {
        Mock Get-Command { $null }
        Mock Test-Path { $LiteralPath -eq $script:Alias }
        Mock Get-PowerShellVersionAt { '7.7.0' }
        Resolve-PowerShell7 -Minimum '7.6' | Should-Be $script:Alias
    }

    It 'falls back to Program Files when the PATH pwsh is too old and there is no alias' {
        Mock Get-Command { [pscustomobject]@{ Source = 'old-pwsh' } }
        Mock Test-Path { $LiteralPath -eq $script:Msi }
        Mock Get-PowerShellVersionAt { if ($Path -eq 'old-pwsh') { '7.4.0' } else { '7.6.1' } }
        Resolve-PowerShell7 -Minimum '7.6' | Should-Be $script:Msi
    }

    It 'throws naming every candidate and what it reported when none qualifies' {
        Mock Get-Command { [pscustomobject]@{ Source = 'old-pwsh' } }
        Mock Test-Path { $LiteralPath -eq $script:Msi }
        Mock Get-PowerShellVersionAt { if ($Path -eq 'old-pwsh') { '7.4.0' } else { '7.5.13' } }
        $thrown = $null
        try { Resolve-PowerShell7 -Minimum '7.6' } catch { $thrown = $_.Exception.Message }
        $thrown | Should-BeLikeString '*7.6 or later*'
        $thrown | Should-BeLikeString "*old-pwsh reports '7.4.0'*"
        $thrown | Should-BeLikeString "*$($script:Alias) not found*"
        $thrown | Should-BeLikeString "*$($script:Msi) reports '7.5.13'*"
    }

    It 'treats a candidate that cannot run as not qualifying' {
        Mock Get-Command { [pscustomobject]@{ Source = 'broken-pwsh' } }
        Mock Test-Path { $false }
        Mock Get-PowerShellVersionAt { throw 'cannot run' }
        { Resolve-PowerShell7 -Minimum '7.6' } | Should-Throw -ExceptionMessage "*broken-pwsh reports ''*"
    }
}

Describe 'ConvertTo-QuotedArgument' {
    It 'quotes <Name>' -ForEach @(
        @{ Name = 'a plain value'; Value = 'abc'; Expected = '"abc"' }
        @{ Name = 'a space'; Value = 'D:\My WSL'; Expected = '"D:\My WSL"' }
        @{ Name = 'an embedded quote'; Value = 'a"b'; Expected = '"a\"b"' }
        @{ Name = 'backslashes before a quote'; Value = 'a\"b'; Expected = '"a\\\"b"' }
        @{ Name = 'a trailing backslash'; Value = 'D:\My WSL\'; Expected = '"D:\My WSL\\"' }
        @{ Name = 'an empty string'; Value = ''; Expected = '""' }
    ) {
        ConvertTo-QuotedArgument -Value $Value | Should-Be $Expected
    }
}

Describe 'Invoke-Handoff' {
    BeforeEach {
        $script:Fake = New-Object -TypeName PSObject
        Add-Member -InputObject $script:Fake -NotePropertyName Handle -NotePropertyValue ([IntPtr]::Zero)
        Add-Member -InputObject $script:Fake -NotePropertyName ExitCode -NotePropertyValue 3010
        Add-Member -InputObject $script:Fake -MemberType ScriptMethod -Name WaitForExit -Value { }
        Mock Start-Process { 'stdout noise'; $script:Fake }
    }

    It 'quotes paths with spaces into one argument string and does not pass -Wait' {
        $r = Invoke-Handoff -PwshPath 'C:\Program Files\PowerShell\7\pwsh.exe' -SetupPath 'D:\My Repos\setup-dev-win\script\setup.ps1' -Profiles 'core,lab'
        @($r).Count | Should-Be 1
        $r | Should-HaveType ([int])
        $r | Should-Be 3010
        Should-Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Program Files\PowerShell\7\pwsh.exe' -and
            $ArgumentList -ceq '-NoProfile -File "D:\My Repos\setup-dev-win\script\setup.ps1" -Profiles "core,lab"' -and
            $NoNewWindow -and $PassThru -and -not $Wait
        }
    }

    It 'passes -DistroRoot and -LinuxUser as separate quoted arguments when given' {
        $null = Invoke-Handoff -PwshPath 'pwsh.exe' -SetupPath 'C:\r\script\setup.ps1' -Profiles 'core' -DistroRoot 'E:\My WSL' -LinuxUser 'alice'
        Should-Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -ceq '-NoProfile -File "C:\r\script\setup.ps1" -Profiles "core" -DistroRoot "E:\My WSL" -LinuxUser "alice"'
        }
    }

    It 'passes -DistroRoot alone, doubling a trailing backslash so the quote survives' {
        $null = Invoke-Handoff -PwshPath 'pwsh.exe' -SetupPath 'C:\r\script\setup.ps1' -DistroRoot 'C:\WSL dir\'
        Should-Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -ceq '-NoProfile -File "C:\r\script\setup.ps1" -DistroRoot "C:\WSL dir\\"'
        }
    }

    It 'passes -LinuxUser alone' {
        $null = Invoke-Handoff -PwshPath 'pwsh.exe' -SetupPath 'C:\r\script\setup.ps1' -LinuxUser 'bob'
        Should-Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -ceq '-NoProfile -File "C:\r\script\setup.ps1" -LinuxUser "bob"'
        }
    }

    It 'omits -Profiles when none is given' {
        $null = Invoke-Handoff -PwshPath 'pwsh.exe' -SetupPath 'C:\r\script\setup.ps1'
        Should-Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -ceq '-NoProfile -File "C:\r\script\setup.ps1"'
        }
    }
}

Describe 'Invoke-Bootstrap' {
    BeforeEach {
        $env:LOCALAPPDATA = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $TestDrive 'local' }
        Mock Test-IsAdministrator { $false }
        Mock Assert-SupportedWindows { }
        Mock Wait-Winget { }
        Mock Merge-WingetSettings { }
        Mock Invoke-WingetSourceUpdate { }
        Mock Install-PowerShell { }
        Mock Sync-SessionPath { }
        Mock Resolve-PowerShell7 { 'pwsh-fake' }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*setup.ps1' }
        Mock Invoke-Handoff { 0 }
    }

    It 'returns exactly one [int]' {
        $result = Invoke-Bootstrap -Profiles 'dev'
        @($result).Count | Should-Be 1
        $result | Should-HaveType ([int])
    }

    It 'passes the handoff exit code through unchanged (3010)' {
        Mock Invoke-Handoff { 3010 }
        Invoke-Bootstrap -Profiles 'dev' | Should-Be 3010
    }

    It 'stops before the handoff when winget fails' {
        Mock Install-PowerShell { throw 'winget failed' }
        { Invoke-Bootstrap } | Should-Throw -ExceptionMessage '*winget failed*'
        Should-NotInvoke -CommandName Invoke-Handoff
    }

    It 'updates the winget sources before installing' {
        $script:Calls = New-Object -TypeName System.Collections.Generic.List[string]
        Mock Invoke-WingetSourceUpdate { $script:Calls.Add('source') }
        Mock Install-PowerShell { $script:Calls.Add('install') }
        $null = Invoke-Bootstrap
        ($script:Calls -join ',') | Should-Be 'source,install'
    }

    It 'stops before installing and handing off when the winget source is broken' {
        Mock Invoke-WingetSourceUpdate { throw 'winget could not open its package source' }
        { Invoke-Bootstrap } | Should-Throw -ExceptionMessage '*package source*'
        Should-NotInvoke -CommandName Install-PowerShell
        Should-NotInvoke -CommandName Invoke-Handoff
    }

    It 'names setup.ps1 when it is missing' {
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*setup.ps1' }
        { Invoke-Bootstrap } | Should-Throw -ExceptionMessage '*setup.ps1*'
        Should-NotInvoke -CommandName Invoke-Handoff
    }

    It 'refuses an elevated launch before doing anything' {
        Mock Test-IsAdministrator { $true }
        $thrown = $null
        try { Invoke-Bootstrap } catch { $thrown = $_.Exception.Message }
        $thrown | Should-Be 'Run from a normal (non-elevated) terminal; elevation is requested per step.'
        Should-NotInvoke -CommandName Assert-SupportedWindows
        Should-NotInvoke -CommandName Install-PowerShell
        Should-NotInvoke -CommandName Invoke-Handoff
    }

    It 'installs with the MinPowerShell minimum from pins.psd1 and resolves with it' {
        $null = Invoke-Bootstrap
        Should-Invoke -CommandName Install-PowerShell -Times 1 -Exactly -ParameterFilter { $Minimum -eq '7.6' }
        Should-Invoke -CommandName Resolve-PowerShell7 -Times 1 -Exactly -ParameterFilter { $Minimum -eq '7.6' }
        Should-Invoke -CommandName Invoke-Handoff -Times 1 -Exactly -ParameterFilter { $PwshPath -eq 'pwsh-fake' }
    }

    It 'passes -DistroRoot and -LinuxUser through to the handoff' {
        $null = Invoke-Bootstrap -DistroRoot 'C:\WSL' -LinuxUser 'alice'
        Should-Invoke -CommandName Invoke-Handoff -Times 1 -Exactly -ParameterFilter {
            $DistroRoot -eq 'C:\WSL' -and $LinuxUser -eq 'alice' }
    }

    It 'passes empty -DistroRoot and -LinuxUser when they are not given' {
        $null = Invoke-Bootstrap
        Should-Invoke -CommandName Invoke-Handoff -Times 1 -Exactly -ParameterFilter {
            [string]::IsNullOrEmpty($DistroRoot) -and [string]::IsNullOrEmpty($LinuxUser) }
    }

    It 'skips the install when asked' {
        Invoke-Bootstrap -SkipPowerShellInstall | Out-Null
        Should-NotInvoke -CommandName Install-PowerShell
    }
}

Describe 'bootstrap.ps1 static checks' {
    It 'does not change the execution policy' {
        $code = Get-Content -LiteralPath $script:Bootstrap | Where-Object { $_ -notmatch '^\s*#' }
        ($code -join "`n") | Should-NotMatchString 'Set-ExecutionPolicy'
    }

    It 'accepts -DistroRoot and -LinuxUser and the main block passes them on' {
        $params = (Get-Command -Name $script:Bootstrap).Parameters.Keys
        @($params) | Should-ContainCollection @('Profiles', 'SkipPowerShellInstall', 'DistroRoot', 'LinuxUser')
        $text = Get-Content -LiteralPath $script:Bootstrap -Raw
        $text | Should-MatchString 'Invoke-Bootstrap -Profiles \$Profiles -SkipPowerShellInstall:\$SkipPowerShellInstall -DistroRoot \$DistroRoot -LinuxUser \$LinuxUser'
    }

    It 'main does not run when SETUP_DEV_WIN_NO_MAIN is 1' {
        # Reaching this point means the dot-source in BeforeAll returned.
        (Get-Command -Name Merge-WingetSettings).CommandType | Should-Be 'Function'
    }

    It 'contains no download or module-install commands' {
        $code = Get-Content -LiteralPath $script:Bootstrap | Where-Object { $_ -notmatch '^\s*#' }
        ($code -join "`n") | Should-NotMatchString 'Invoke-WebRequest|Start-BitsTransfer|Install-Module|Install-PSResource'
    }

    It 'passes PSScriptAnalyzer with the stage-0 settings' {
        if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
            Set-ItResult -Skipped -Because 'PSScriptAnalyzer is not installed'
            return
        }
        $settings = Join-Path $script:Root 'PSScriptAnalyzerSettings.Stage0.psd1'
        $results = @(Invoke-ScriptAnalyzer -Path $script:Bootstrap -Settings $settings)
        $results | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName, $_.Line, $_.RuleName, $_.Message } | Should-BeCollection @()
    }
}
