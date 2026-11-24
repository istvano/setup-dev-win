Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Stage-0 tests. They run under pwsh locally and under Windows PowerShell 5.1 in
# CI (W8), so this file avoids syntax that 5.1 does not have.
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

Describe 'Install-PinnedPowerShell' {
    It 'skips when the pinned version is already installed' {
        Mock Get-InstalledPowerShellVersion { '7.6.6' }
        Mock Invoke-Winget { }
        Install-PinnedPowerShell -Version '7.6.6'
        Should-NotInvoke -CommandName Invoke-Winget
    }

    It 'installs the exact version through winget when absent' {
        Mock Get-InstalledPowerShellVersion { $null }
        Mock Invoke-Winget { $script:Captured = $Arguments; $global:LASTEXITCODE = 0 }
        Install-PinnedPowerShell -Version '7.6.6'
        $joined = $script:Captured -join ' '
        $joined | Should-BeLikeString 'install --id Microsoft.PowerShell --source winget --exact --version 7.6.6 *'
        $joined | Should-BeLikeString '*--disable-interactivity'
    }

    It 'throws when winget returns a failure code' {
        Mock Get-InstalledPowerShellVersion { $null }
        Mock Invoke-Winget { $global:LASTEXITCODE = 5 }
        { Install-PinnedPowerShell -Version '7.6.6' } | Should-Throw -ExceptionMessage '*5*'
    }
}

Describe 'bootstrap.ps1 static checks' {
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
