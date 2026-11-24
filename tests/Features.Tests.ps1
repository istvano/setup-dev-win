Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Common.psm1') -Force
    Import-Module (Join-Path $script:Root 'script/lib/WindowsFeatures.psm1') -Force
    $script:ElevatedScript = Join-Path $script:Root 'script/elevated/Enable-Features.ps1'
    $script:MinWsl = (Import-PowerShellDataFile (Join-Path $script:Root 'script/lib/pins.psd1')).MinWslVersion
}

Describe 'Get-RequiredFeatures' {
    It 'Home without lab requires only VirtualMachinePlatform' {
        Get-RequiredFeatures -Profiles @('core') -Edition @{ IsHome = $true; IsPro = $false } | Should-BeCollection @('VirtualMachinePlatform')
    }
    It 'Pro with lab adds Hyper-V' {
        Get-RequiredFeatures -Profiles @('core', 'lab') -Edition @{ IsHome = $false; IsPro = $true } | Should-BeCollection @('VirtualMachinePlatform', 'Microsoft-Hyper-V-All')
    }
    It 'Pro without lab does not add Hyper-V' {
        Get-RequiredFeatures -Profiles @('core') -Edition @{ IsHome = $false; IsPro = $true } | Should-BeCollection @('VirtualMachinePlatform')
    }
    It 'Home with lab does not add Hyper-V' {
        Get-RequiredFeatures -Profiles @('lab') -Edition @{ IsHome = $true; IsPro = $false } | Should-BeCollection @('VirtualMachinePlatform')
    }
}

Describe 'Get-FeatureState' {
    It 'maps InstallState <State> to <Expected>' -ForEach @(
        @{ State = 1; Expected = 'Enabled' }
        @{ State = 2; Expected = 'Disabled' }
        @{ State = 3; Expected = 'Absent' }
        @{ State = 7; Expected = 'Unknown' }
    ) {
        $value = $State
        Mock -ModuleName WindowsFeatures Get-CimInstance ({ [pscustomobject]@{ InstallState = $value } }.GetNewClosure())
        Get-FeatureState -Name 'VirtualMachinePlatform' | Should-Be $Expected
    }

    It 'returns Unknown when there is no instance' {
        Mock -ModuleName WindowsFeatures Get-CimInstance { $null }
        Get-FeatureState -Name 'VirtualMachinePlatform' | Should-Be 'Unknown'
    }

    It 'queries Win32_OptionalFeature by name and never elevates' {
        Mock -ModuleName WindowsFeatures Get-CimInstance { [pscustomobject]@{ InstallState = 1 } }
        Mock -ModuleName WindowsFeatures Invoke-ElevatedScript { 0 }
        Get-FeatureState -Name 'VirtualMachinePlatform' | Out-Null
        Should-Invoke -ModuleName WindowsFeatures -CommandName Get-CimInstance -ParameterFilter {
            $ClassName -eq 'Win32_OptionalFeature' -and $Filter -eq "Name='VirtualMachinePlatform'"
        }
        Should-NotInvoke -ModuleName WindowsFeatures -CommandName Invoke-ElevatedScript
    }

    It 'doubles a single quote in the name' {
        Mock -ModuleName WindowsFeatures Get-CimInstance { $null }
        Get-FeatureState -Name "a'b" | Out-Null
        Should-Invoke -ModuleName WindowsFeatures -CommandName Get-CimInstance -ParameterFilter { $Filter -eq "Name='a''b'" }
    }
}

Describe 'Get-WslVersion' {
    It 'parses the first version from wsl --version' {
        Mock -ModuleName WindowsFeatures Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = [string[]]@('WSL version: 2.6.1.0', 'Kernel version: 6.6.87.2-1') } }
        Get-WslVersion | Should-Be ([version]'2.6.1.0')
    }
    It 'returns null when wsl fails or is missing' {
        Mock -ModuleName WindowsFeatures Invoke-Native { throw 'wsl.exe exited with code 1.' }
        Get-WslVersion | Should-BeNull
    }
    It 'returns null when no version is found' {
        Mock -ModuleName WindowsFeatures Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = [string[]]@('usage: wsl') } }
        Get-WslVersion | Should-BeNull
    }
}

Describe 'Enable-Features.ps1' {
    BeforeAll {
        $env:SETUP_DEV_WIN_NO_MAIN = '1'
        . $script:ElevatedScript
    }
    AfterAll { Remove-Item Env:\SETUP_DEV_WIN_NO_MAIN -ErrorAction SilentlyContinue }
    BeforeEach {
        # The dot-sourced script reads this; point it at a fresh file per test.
        $script:ElevatedLogPath = Join-Path $TestDrive "elevated-$([guid]::NewGuid().ToString('N')).log"
    }

    It 'refuses Containers-DisposableClientVM without calling Enable-WindowsOptionalFeature' {
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
        Mock Write-Host {}
        Invoke-FeatureRequest -Name @('Containers-DisposableClientVM') | Should-Be 2
        Should-NotInvoke Enable-WindowsOptionalFeature
    }

    It 'refuses the whole request when any one name is not allowed' {
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
        Mock Write-Host {}
        Invoke-FeatureRequest -Name @('VirtualMachinePlatform,Containers-DisposableClientVM') | Should-Be 2
        Should-NotInvoke Enable-WindowsOptionalFeature
    }

    It 'refuses a name that differs only in case' {
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
        Mock Write-Host {}
        Invoke-FeatureRequest -Name @('virtualmachineplatform') | Should-Be 2
        Should-NotInvoke Enable-WindowsOptionalFeature
    }

    It 'enables an allowed feature with -All -NoRestart and exits 0' {
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
        Mock Write-Host {}
        Invoke-FeatureRequest -Name @('VirtualMachinePlatform') | Should-Be 0
        Should-Invoke Enable-WindowsOptionalFeature -Times 1 -Exactly -ParameterFilter {
            $Online -and $FeatureName -eq 'VirtualMachinePlatform' -and $All -and $NoRestart
        }
    }

    It 'exits 3010 when any feature reports RestartNeeded' {
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = ($FeatureName -eq 'Microsoft-Hyper-V-All') } }
        Mock Write-Host {}
        Invoke-FeatureRequest -Name @('VirtualMachinePlatform,Microsoft-Hyper-V-All') | Should-Be 3010
        Should-Invoke Enable-WindowsOptionalFeature -Times 2 -Exactly
    }

    It 'still exits 1 when a later feature throws after RestartNeeded, naming the pending restart' {
        Mock Enable-WindowsOptionalFeature { if ($FeatureName -eq 'VirtualMachinePlatform') { [pscustomobject]@{ RestartNeeded = $true } } else { throw 'boom' } }
        Mock Write-Host {}
        { Invoke-FeatureRequest -Name @('VirtualMachinePlatform,Microsoft-Hyper-V-All') } | Should-Throw
        Should-Invoke Write-Host -ParameterFilter { $Object -like '*needs a restart*' }
    }

    It 'writes [fail] lines to elevated.log with a timestamp, and not [info] lines' {
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
        Mock Write-Host {}
        Invoke-ElevatedMain -Name @('Containers-DisposableClientVM') | Should-Be 2
        Invoke-ElevatedMain -Name @('VirtualMachinePlatform') | Should-Be 0
        $lines = @(Get-Content -LiteralPath $script:ElevatedLogPath)
        $lines.Count | Should-Be 1
        $lines[0] | Should-MatchString '^\d{4}-\d\d-\d\dT\S+ \[fail\] Refusing feature .Containers-DisposableClientVM.'
    }

    It 'logs the pending-restart warning and the failure, appending to earlier lines' {
        Set-Content -LiteralPath $script:ElevatedLogPath -Value 'earlier line'
        Mock Enable-WindowsOptionalFeature { if ($FeatureName -eq 'VirtualMachinePlatform') { [pscustomobject]@{ RestartNeeded = $true } } else { throw 'boom' } }
        Mock Write-Host {}
        Invoke-ElevatedMain -Name @('VirtualMachinePlatform,Microsoft-Hyper-V-All') | Should-Be 1
        $lines = @(Get-Content -LiteralPath $script:ElevatedLogPath)
        $lines[0] | Should-Be 'earlier line'
        $lines[1] | Should-BeLikeString '* `[warn`] *needs a restart*'
        $lines[2] | Should-BeLikeString '* `[fail`] boom'
    }

    It 'run as a script, exits non-zero for a refused name and logs it under LOCALAPPDATA' {
        $pwsh = [Environment]::ProcessPath
        $local = Join-Path $TestDrive 'child-local'
        $savedLocal = $env:LOCALAPPDATA
        # The child must run main, so the NO_MAIN guard set for dot-sourcing is cleared for it.
        Remove-Item Env:\SETUP_DEV_WIN_NO_MAIN
        $env:LOCALAPPDATA = $local
        $PSNativeCommandUseErrorActionPreference = $false
        try { $output = & $pwsh -NoLogo -NoProfile -File $script:ElevatedScript -Name 'Containers-DisposableClientVM' 2>&1 }
        finally { $env:SETUP_DEV_WIN_NO_MAIN = '1'; $env:LOCALAPPDATA = $savedLocal }
        $LASTEXITCODE | Should-Be 2
        ($output -join ' ') | Should-BeLikeString '*Refusing feature*'
        (Get-Content -LiteralPath (Join-Path $local 'setup-dev-win/elevated.log') -Raw) | Should-BeLikeString '*`[fail`] Refusing feature*'
    }
}

Describe 'Invoke-FeaturesStage' {
    BeforeAll {
        Import-Module (Join-Path $script:Root 'script/stages/Features.psm1') -Force
        function Initialize-Stage {
            param([string[]]$States = @('Enabled'), $Wsl = [version]'2.6.1.0', [int]$ElevatedExit = 0)
            $map = @{ VirtualMachinePlatform = $States[0] }
            if ($States.Count -gt 1) { $map['Microsoft-Hyper-V-All'] = $States[1] }
            # A closure cannot read the mock's own parameters, so each name gets a filtered mock.
            foreach ($key in $map.Keys) {
                $value = $map[$key]
                Mock -ModuleName Features Get-FeatureState ({ $value }.GetNewClosure()) -ParameterFilter ([scriptblock]::Create("`$Name -eq '$key'"))
            }
            Mock -ModuleName Features Get-WslVersion { $Wsl }.GetNewClosure()
            Mock -ModuleName Features Invoke-ElevatedScript { $ElevatedExit }.GetNewClosure()
            Mock -ModuleName Features Invoke-WslCommand { 0 }
            Mock -ModuleName Features Get-ElevatedLogPath { $null }
            Mock -ModuleName Features Write-Info {}
            Mock -ModuleName Features Write-Ok {}
            Mock -ModuleName Features Write-Warn {}
        }
        function Get-Ctx { @{ Profiles = @('core'); Plan = $false; Edition = @{ Edition = 'Professional'; IsHome = $false; IsPro = $true } } }
    }

    It 'returns done when everything is enabled and WSL is at least the minimum' {
        Initialize-Stage
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'done'
        Should-NotInvoke -ModuleName Features -CommandName Invoke-ElevatedScript
        Should-NotInvoke -ModuleName Features -CommandName Invoke-WslCommand
    }

    It 'enables missing features through the elevated script' {
        Initialize-Stage -States @('Disabled')
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'done'
        Should-Invoke -ModuleName Features -CommandName Invoke-ElevatedScript -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Enable-Features' -and $ArgumentList -contains 'VirtualMachinePlatform'
        }
    }

    It 'returns reboot-required when the elevated script exits 3010' {
        Initialize-Stage -States @('Disabled') -ElevatedExit 3010
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'reboot-required'
    }

    It 'fails when the elevated script fails' {
        Initialize-Stage -States @('Disabled') -ElevatedExit 1
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'failed'
        Should-NotInvoke -ModuleName Features -CommandName Invoke-WslCommand
    }

    It 'after a failed elevated run prints only the new elevated.log lines' {
        Initialize-Stage -States @('Disabled')
        $log = Join-Path $TestDrive "stage-elevated-$([guid]::NewGuid().ToString('N')).log"
        Set-Content -LiteralPath $log -Value '2026-01-01T00:00:00Z [fail] old failure'
        Mock -ModuleName Features Get-ElevatedLogPath { $log }.GetNewClosure()
        Mock -ModuleName Features Invoke-ElevatedScript { Add-Content -LiteralPath $log -Value '2026-11-24T00:00:00Z [fail] new failure'; 1 }.GetNewClosure()
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'failed'
        Should-Invoke -ModuleName Features -CommandName Write-Warn -Times 1 -Exactly -ParameterFilter { $Message -like '*new failure*' }
        Should-NotInvoke -ModuleName Features -CommandName Write-Warn -ParameterFilter { $Message -like '*old failure*' }
        Should-Invoke -ModuleName Features -CommandName Write-Warn -ParameterFilter { $Message -like "*failed while enabling*log: $log*" }
    }

    It 'fails with a warning when UAC is declined' {
        Initialize-Stage -States @('Disabled')
        Mock -ModuleName Features Invoke-ElevatedScript { throw 'The operation was canceled by the user.' }
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'failed'
        Should-Invoke -ModuleName Features -CommandName Write-Warn -ParameterFilter { $Message -like '*UAC*' }
    }

    It 'installs and updates WSL when wsl --version fails' {
        Initialize-Stage -Wsl $null
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'done'
        Should-Invoke -ModuleName Features -CommandName Invoke-WslCommand -ParameterFilter { $ArgumentList -contains '--install' -and $ArgumentList -contains '--no-distribution' }
        Should-Invoke -ModuleName Features -CommandName Invoke-WslCommand -ParameterFilter { $ArgumentList -contains '--update' }
    }

    It 'installs WSL when it is below the minimum version' {
        Initialize-Stage -Wsl ([version]'2.0.0.0')
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'done'
        Should-Invoke -ModuleName Features -CommandName Invoke-WslCommand -Times 2 -Exactly
    }

    It 'fails when wsl --install exits non-zero' {
        Initialize-Stage -Wsl $null
        Mock -ModuleName Features Invoke-WslCommand { 1 }
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'failed'
        Should-Invoke -ModuleName Features -CommandName Write-Warn -ParameterFilter { $Message -like '*exit code 1*' }
    }

    It 'elevates exactly once for several missing features' {
        Initialize-Stage -States @('Disabled', 'Disabled')
        Invoke-FeaturesStage -Context @{ Profiles = @('core', 'lab'); Plan = $false; Edition = @{ Edition = 'Professional'; IsHome = $false; IsPro = $true } } | Should-Be 'done'
        Should-Invoke -ModuleName Features -CommandName Invoke-ElevatedScript -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains 'VirtualMachinePlatform,Microsoft-Hyper-V-All'
        }
    }

    It 'maps exit code <Code> to failed with a message' -ForEach @(@{ Code = 1 }, @{ Code = 2 }, @{ Code = 5 }) {
        Initialize-Stage -States @('Disabled') -ElevatedExit $Code
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'failed'
        Should-Invoke -ModuleName Features -CommandName Write-Warn
    }

    It 'fails for lab on Home, even with -Plan, without elevating' {
        Initialize-Stage -States @('Disabled')
        $homeCtx = @{ Profiles = @('core', 'lab'); Plan = $false; Edition = @{ Edition = 'Core'; IsHome = $true; IsPro = $false } }
        Invoke-FeaturesStage -Context $homeCtx | Should-Be 'failed'
        Invoke-FeaturesStage -Context $homeCtx -Plan | Should-Be 'failed'
        Should-NotInvoke -ModuleName Features -CommandName Invoke-ElevatedScript
        Should-NotInvoke -ModuleName Features -CommandName Invoke-WslCommand
        Should-Invoke -ModuleName Features -CommandName Write-Warn -ParameterFilter { $Message -like '*lab profile needs Windows 11 Pro*' }
    }

    It 'plan prints what it would do and neither elevates nor installs' {
        Initialize-Stage -States @('Disabled') -Wsl $null
        Invoke-FeaturesStage -Context (Get-Ctx) -Plan | Should-Be 'done'
        Should-NotInvoke -ModuleName Features -CommandName Invoke-ElevatedScript
        Should-NotInvoke -ModuleName Features -CommandName Invoke-WslCommand
        Should-Invoke -ModuleName Features -CommandName Write-Info -ParameterFilter { $Message -like 'Would enable*VirtualMachinePlatform*' }
    }
}
