Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'script/lib/State.psm1') -Force
}

Describe 'State' {
    BeforeEach {
        $env:SETUP_DEV_WIN_STATE = Join-Path $TestDrive "sub/state-$([guid]::NewGuid().ToString('N')).json"
        $script:Boot = [datetime]::new(2026, 1, 1, 8, 0, 0, [DateTimeKind]::Utc)
        Mock -ModuleName State Get-CimInstance { [pscustomobject]@{ LastBootUpTime = $script:Boot } }
    }
    AfterAll {
        $env:SETUP_DEV_WIN_STATE = $null
    }

    It 'returns $null for an unknown stage and a missing file' {
        Get-StageResult -Stage 'features' | Should-BeNull
    }

    It 'round-trips a result' {
        Set-StageResult -Stage 'features' -Result 'reboot-required'
        Get-StageResult -Stage 'features' | Should-Be 'reboot-required'
        Set-StageResult -Stage 'features' -Result 'done'
        Set-StageResult -Stage 'wsl' -Result 'failed'
        Get-StageResult -Stage 'features' | Should-Be 'done'
        Get-StageResult -Stage 'wsl' | Should-Be 'failed'
    }

    It 'rejects unknown result values' {
        { Set-StageResult -Stage 'features' -Result 'banana' } | Should-Throw
        Get-StageResult -Stage 'features' | Should-BeNull
    }

    It 'write is atomic: a serialisation failure leaves the old file unchanged' {
        Set-StageResult -Stage 'features' -Result 'done'
        $path = $env:SETUP_DEV_WIN_STATE
        $before = Get-Content -LiteralPath $path -Raw
        Mock -ModuleName State ConvertTo-Json { throw 'cannot serialise' }
        { Set-StageResult -Stage 'features' -Result 'failed' } | Should-Throw -ExceptionMessage '*cannot serialise*'
        Get-Content -LiteralPath $path -Raw | Should-Be $before
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.tmp').Count | Should-Be 0
    }

    It 'records a UTC timestamp and the boot time' {
        Set-StageResult -Stage 'features' -Result 'done'
        $raw = Get-Content -LiteralPath $env:SETUP_DEV_WIN_STATE -Raw
        $raw | Should-BeLikeString '*"timestamp"*'
        $raw | Should-BeLikeString '*2026-01-01T08:00:00*'
    }

    It 'refuses a corrupt state file' {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $env:SETUP_DEV_WIN_STATE) -Force
        Set-Content -LiteralPath $env:SETUP_DEV_WIN_STATE -Value '{ not json'
        { Get-StageResult -Stage 'features' } | Should-Throw -ExceptionMessage '*not valid JSON*'
    }

    It 'Test-RebootHappenedSince is true only when the boot time is later' {
        Set-StageResult -Stage 'features' -Result 'reboot-required'
        Test-RebootHappenedSince -Stage 'features' | Should-BeFalse
        $script:Boot = $script:Boot.AddHours(-1)
        Test-RebootHappenedSince -Stage 'features' | Should-BeFalse
        $script:Boot = [datetime]::new(2026, 1, 1, 9, 0, 0, [DateTimeKind]::Utc)
        Test-RebootHappenedSince -Stage 'features' | Should-BeTrue
    }

    It 'Test-RebootHappenedSince is false for an unrecorded stage' {
        Test-RebootHappenedSince -Stage 'nothing' | Should-BeFalse
    }

    It 'throws clearly when no state location can be resolved' {
        $env:SETUP_DEV_WIN_STATE = $null
        $saved = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $null
        try {
            { Get-StageResult -Stage 'x' } | Should-Throw -ExceptionMessage '*SETUP_DEV_WIN_STATE*'
        }
        finally {
            $env:LOCALAPPDATA = $saved
        }
    }

    It 'Get-SetupSetting returns $null when nothing is recorded' {
        Get-SetupSetting -Name 'linuxUser' | Should-BeNull
    }

    It 'round-trips settings without disturbing stage results' {
        Set-StageResult -Stage 'features' -Result 'done'
        Set-SetupSetting -Name 'linuxUser' -Value 'alice'
        Set-SetupSetting -Name 'distroRoot' -Value 'E:\WSL'
        Set-StageResult -Stage 'wsl' -Result 'failed'
        Get-SetupSetting -Name 'linuxUser' | Should-Be 'alice'
        Get-SetupSetting -Name 'distroRoot' | Should-Be 'E:\WSL'
        Get-StageResult -Stage 'features' | Should-Be 'done'
        Get-StageResult -Stage 'wsl' | Should-Be 'failed'
    }

    It 'rejects an unknown setting name' {
        { Set-SetupSetting -Name 'shell' -Value 'x' } | Should-Throw
        { Get-SetupSetting -Name 'shell' } | Should-Throw
    }

    It 'setting write is atomic: a serialisation failure leaves the old file unchanged' {
        Set-SetupSetting -Name 'profiles' -Value 'core'
        $path = $env:SETUP_DEV_WIN_STATE
        $before = Get-Content -LiteralPath $path -Raw
        Mock -ModuleName State ConvertTo-Json { throw 'cannot serialise' }
        { Set-SetupSetting -Name 'profiles' -Value 'core,lab' } | Should-Throw -ExceptionMessage '*cannot serialise*'
        Get-Content -LiteralPath $path -Raw | Should-Be $before
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.tmp').Count | Should-Be 0
    }
}

Describe 'Resolve-SetupSetting' {
    BeforeEach {
        $env:SETUP_DEV_WIN_STATE = Join-Path $TestDrive "sub/state-$([guid]::NewGuid().ToString('N')).json"
        Mock -ModuleName State Get-CimInstance { [pscustomobject]@{ LastBootUpTime = [datetime]::UtcNow } }
    }
    AfterAll {
        $env:SETUP_DEV_WIN_STATE = $null
    }

    It 'with no flag and nothing persisted returns the default' {
        Resolve-SetupSetting -Name 'distroRoot' -Default 'D:\WSL' | Should-Be 'D:\WSL'
    }

    It 'a persisted value wins over the default' {
        Set-SetupSetting -Name 'distroRoot' -Value 'E:\WSL'
        Resolve-SetupSetting -Name 'distroRoot' -Default 'D:\WSL' | Should-Be 'E:\WSL'
    }

    It 'an explicit value wins over the persisted one' {
        Set-SetupSetting -Name 'distroRoot' -Value 'E:\WSL'
        Resolve-SetupSetting -Name 'distroRoot' -Value 'F:\WSL' -Explicit -Default 'D:\WSL' | Should-Be 'F:\WSL'
    }

    It 'never writes' {
        $null = Resolve-SetupSetting -Name 'distroRoot' -Value 'F:\WSL' -Explicit -Default 'D:\WSL'
        $null = Resolve-SetupSetting -Name 'profiles' -Default 'core'
        Test-Path -LiteralPath $env:SETUP_DEV_WIN_STATE | Should-BeFalse
    }
}
