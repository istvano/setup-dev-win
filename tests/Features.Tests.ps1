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
    It 'reads the state non-elevated when that works' {
        Mock -ModuleName WindowsFeatures Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }
        Mock -ModuleName WindowsFeatures Invoke-ElevatedScript { 0 }
        Get-FeatureState -Name 'VirtualMachinePlatform' | Should-Be 'Enabled'
        Should-NotInvoke -ModuleName WindowsFeatures -CommandName Invoke-ElevatedScript
    }

    It 'falls back to the elevated -CheckOnly read and removes the temp file' {
        Mock -ModuleName WindowsFeatures Get-WindowsOptionalFeature { throw 'The requested operation requires elevation.' }
        Mock -ModuleName WindowsFeatures Invoke-ElevatedScript {
            $i = [array]::IndexOf($ArgumentList, '-OutFile')
            Set-Content -LiteralPath $ArgumentList[$i + 1] -Value '{"VirtualMachinePlatform":"Disabled"}'
            0
        }
        Get-FeatureState -Name 'VirtualMachinePlatform' | Should-Be 'Disabled'
        Should-Invoke -ModuleName WindowsFeatures -CommandName Invoke-ElevatedScript -ParameterFilter {
            $Name -eq 'Enable-Features' -and $ArgumentList -contains '-CheckOnly' -and $ArgumentList -contains 'VirtualMachinePlatform'
        }
    }

    It 'removes the temp file even when the elevated read fails' {
        Mock -ModuleName WindowsFeatures Get-WindowsOptionalFeature { throw 'Access is denied' }
        $script:seen = $null
        Mock -ModuleName WindowsFeatures Invoke-ElevatedScript {
            $i = [array]::IndexOf($ArgumentList, '-OutFile')
            Set-Content -LiteralPath $ArgumentList[$i + 1] -Value 'x'
            $env:FEATURES_TEST_OUT = $ArgumentList[$i + 1]
            1
        }
        { Get-FeatureState -Name 'VirtualMachinePlatform' } | Should-Throw
        Test-Path -LiteralPath $env:FEATURES_TEST_OUT | Should-BeFalse
    }

    It 'returns Unknown without elevating under -NoElevate' {
        Mock -ModuleName WindowsFeatures Get-WindowsOptionalFeature { throw 'requires elevation' }
        Mock -ModuleName WindowsFeatures Invoke-ElevatedScript { 0 }
        Get-FeatureState -Name 'VirtualMachinePlatform' -NoElevate | Should-Be 'Unknown'
        Should-NotInvoke -ModuleName WindowsFeatures -CommandName Invoke-ElevatedScript
    }

    It 'rethrows an error that is not about elevation' {
        Mock -ModuleName WindowsFeatures Get-WindowsOptionalFeature { throw 'disk on fire' }
        Mock -ModuleName WindowsFeatures Invoke-ElevatedScript { 0 }
        { Get-FeatureState -Name 'VirtualMachinePlatform' } | Should-Throw
        Should-NotInvoke -ModuleName WindowsFeatures -CommandName Invoke-ElevatedScript
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

    It '-CheckOnly enables nothing and writes JSON to the OutFile' {
        Mock Enable-WindowsOptionalFeature { throw 'must not be called' }
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Disabled' } }
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ('setup-dev-win-features-{0}.json' -f [guid]::NewGuid().ToString('N'))
        try {
            Invoke-FeatureRequest -Name @('VirtualMachinePlatform') -CheckOnly -OutFile $out | Should-Be 0
            (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).VirtualMachinePlatform | Should-Be 'Disabled'
            Should-NotInvoke Enable-WindowsOptionalFeature
        }
        finally { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
    }

    It '-CheckOnly refuses an OutFile outside the temp naming scheme' {
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }
        Mock Write-Host {}
        $bad = Join-Path ([System.IO.Path]::GetTempPath()) 'evil.json'
        Invoke-FeatureRequest -Name @('VirtualMachinePlatform') -CheckOnly -OutFile $bad | Should-Be 2
        Test-Path -LiteralPath $bad | Should-BeFalse
    }

    It 'run as a script, exits non-zero for a refused name' {
        $pwsh = [Environment]::ProcessPath
        # The child must run main, so the NO_MAIN guard set for dot-sourcing is cleared for it.
        Remove-Item Env:\SETUP_DEV_WIN_NO_MAIN
        $PSNativeCommandUseErrorActionPreference = $false
        try { $output = & $pwsh -NoLogo -NoProfile -File $script:ElevatedScript -Name 'Containers-DisposableClientVM' 2>&1 }
        finally { $env:SETUP_DEV_WIN_NO_MAIN = '1' }
        $LASTEXITCODE | Should-Be 2
        ($output -join ' ') | Should-BeLikeString '*Refusing feature*'
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
            Mock -ModuleName Features Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = [string[]]@() } }
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
        Should-NotInvoke -ModuleName Features -CommandName Invoke-Native
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

    It 'returns reboot-required when a feature is already EnablePending' {
        Initialize-Stage -States @('EnablePending')
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'reboot-required'
        Should-NotInvoke -ModuleName Features -CommandName Invoke-ElevatedScript
    }

    It 'fails when the elevated script fails' {
        Initialize-Stage -States @('Disabled') -ElevatedExit 1
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'failed'
        Should-NotInvoke -ModuleName Features -CommandName Invoke-Native
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
        Should-Invoke -ModuleName Features -CommandName Invoke-Native -ParameterFilter { $ArgumentList -contains '--install' -and $ArgumentList -contains '--no-distribution' }
        Should-Invoke -ModuleName Features -CommandName Invoke-Native -ParameterFilter { $ArgumentList -contains '--update' }
    }

    It 'installs WSL when it is below the minimum version' {
        Initialize-Stage -Wsl ([version]'2.0.0.0')
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'done'
        Should-Invoke -ModuleName Features -CommandName Invoke-Native -Times 2 -Exactly
    }

    It 'fails with the output when wsl --install fails' {
        Initialize-Stage -Wsl $null
        Mock -ModuleName Features Invoke-Native { throw 'wsl.exe exited with code 1. boom' }
        Invoke-FeaturesStage -Context (Get-Ctx) | Should-Be 'failed'
        Should-Invoke -ModuleName Features -CommandName Write-Warn -ParameterFilter { $Message -like '*boom*' }
    }

    It 'plan prints what it would do and neither elevates nor installs' {
        Initialize-Stage -States @('Disabled') -Wsl $null
        Invoke-FeaturesStage -Context (Get-Ctx) -Plan | Should-Be 'done'
        Should-NotInvoke -ModuleName Features -CommandName Invoke-ElevatedScript
        Should-NotInvoke -ModuleName Features -CommandName Invoke-Native
        Should-Invoke -ModuleName Features -CommandName Write-Info -ParameterFilter { $Message -like 'Would enable*VirtualMachinePlatform*' }
        Should-Invoke -ModuleName Features -CommandName Get-FeatureState -ParameterFilter { $NoElevate }
    }
}
