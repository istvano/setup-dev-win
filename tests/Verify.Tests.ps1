Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/stages/Verify.psm1') -Force
    $script:Pins = Import-PowerShellDataFile (Join-Path $script:Root 'script/lib/pins.psd1')
    $script:Pro = @{ Edition = 'Professional'; IsHome = $false; IsPro = $true }
    function script:Test-Line {
        param([string]$Pattern)
        @($script:Lines | Where-Object { $_ -like $Pattern }).Count -gt 0
    }
    function script:New-Ctx {
        param([string[]]$Profiles = @('core'))
        @{ Profiles = $Profiles; DistroRoot = 'D:\WSL'; LinuxRepoUrl = 'x'; LinuxRef = 'main'; Plan = $false; Edition = $script:Pro }
    }
}

Describe 'Invoke-VerifyChecks' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Verify Write-Host { $script:Lines.Add([string]$Object) }
        Mock -ModuleName Verify Get-OsBuild { $script:Pins.MinOsBuild }
        $script:Features = @{ VirtualMachinePlatform = 'Enabled'; 'Microsoft-Hyper-V-All' = 'Disabled' }
        Mock -ModuleName Verify Get-FeatureState { $script:Features[$Name] }
        Mock -ModuleName Verify Get-WslVersion { [version]$script:Pins.MinWslVersion }
        $script:Chezmoi = @{ Ok = $true; Output = @() }
        Mock -ModuleName Verify Invoke-ChezmoiVerify { $script:Chezmoi }
        $script:Distro = @{ Name = 'dev'; BasePath = 'D:\WSL\dev'; Version = 2; DefaultUid = 0 }
        Mock -ModuleName Verify Get-RegisteredDistro { $script:Distro }
        Mock -ModuleName Verify Get-LinuxUserName { 'alice' }
        Mock -ModuleName Verify Assert-DefaultUser { }
        $script:LinuxExit = 0
        $script:SystemdState = 'running'
        Mock -ModuleName Verify Invoke-Native {
            if ($ArgumentList -contains 'systemctl') { return [pscustomobject]@{ ExitCode = 0; Output = @($script:SystemdState) } }
            [pscustomobject]@{ ExitCode = $script:LinuxExit; Output = @('linux verify line') }
        }
        Mock -ModuleName Verify Get-KernelDmaProtectionState { 'on' }
    }

    It 'passes every check on a healthy machine' {
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        $r.Count | Should-Be 6
        @($r | Where-Object { -not $_.Ok }).Count | Should-Be 0
        ($script:Lines | Where-Object { $_ -like 'OK *' }).Count | Should-Be 6
        (Test-Line '*linux verify line*') | Should-BeTrue
    }

    It 'check 1: fails below the minimum build and reports the edition' {
        Mock -ModuleName Verify Get-OsBuild { 22000 }
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        $r[0].Ok | Should-BeFalse
        (Test-Line 'FAIL *build*22000*') | Should-BeTrue
        (Test-Line '*Professional*') | Should-BeTrue
    }

    It 'check 2: fails when a required feature is not Enabled' {
        $script:Features.VirtualMachinePlatform = 'Disabled'
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*features*').Ok | Should-BeFalse
        (Test-Line 'FAIL *VirtualMachinePlatform*') | Should-BeTrue
    }

    It 'check 2: the hint names pwsh -File and adds -Profiles lab only with lab' {
        $script:Features.VirtualMachinePlatform = 'Disabled'
        $null = Invoke-VerifyChecks -Context (New-Ctx)
        (Test-Line 'FAIL *run pwsh -File script\setup.ps1 -Stage features.*') | Should-BeTrue
        $script:Lines.Clear()
        $script:Features['Microsoft-Hyper-V-All'] = 'Enabled'
        $null = Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core', 'lab'))
        (Test-Line 'FAIL *run pwsh -File script\setup.ps1 -Stage features -Profiles lab.*') | Should-BeTrue
    }

    It 'check 2: Hyper-V enabled without lab fails' {
        $script:Features['Microsoft-Hyper-V-All'] = 'Enabled'
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*features*').Ok | Should-BeFalse
        (Test-Line 'FAIL *Hyper-V*') | Should-BeTrue
    }

    It 'check 2: Hyper-V Absent without lab passes' {
        $script:Features['Microsoft-Hyper-V-All'] = 'Absent'
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*features*').Ok | Should-BeTrue
    }

    It 'check 2: with lab, Hyper-V must be Enabled' {
        $script:Features['Microsoft-Hyper-V-All'] = 'Disabled'
        $r = @(Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core', 'lab')))
        ($r | Where-Object Name -Like '*features*').Ok | Should-BeFalse
        $script:Features['Microsoft-Hyper-V-All'] = 'Enabled'
        $r = @(Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core', 'lab')))
        ($r | Where-Object Name -Like '*features*').Ok | Should-BeTrue
    }

    It 'check 3: fails when WSL is missing or too old' {
        Mock -ModuleName Verify Get-WslVersion { [version]'2.0.0' }
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*WSL version*').Ok | Should-BeFalse
        Mock -ModuleName Verify Get-WslVersion { $null }
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*WSL version*').Ok | Should-BeFalse
    }

    It 'check 4: fails when chezmoi verify reports drift' {
        $script:Chezmoi = @{ Ok = $false; Output = @('.wslconfig differs') }
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*chezmoi*').Ok | Should-BeFalse
        (Test-Line 'FAIL *chezmoi*.wslconfig differs*') | Should-BeTrue
    }

    It 'check 5: fails when dev is not registered, and check 6 fails too' {
        Mock -ModuleName Verify Get-RegisteredDistro { $null }
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*distro*').Ok | Should-BeFalse
        ($r | Where-Object Name -Like '*Linux verify*').Ok | Should-BeFalse
        Should-NotInvoke -CommandName Invoke-Native -ModuleName Verify
    }

    It 'check 5: a C: distro fails with the move instruction' {
        $script:Distro.BasePath = 'C:\Users\a\AppData\Local\wsl\dev'
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*distro*').Ok | Should-BeFalse
        (Test-Line 'FAIL *wsl --manage dev --move D:\WSL\dev*') | Should-BeTrue
    }

    It 'check 5: a WSL 1 distro fails' {
        $script:Distro.Version = 1
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*distro*').Ok | Should-BeFalse
    }

    It 'check 5: fails when the effective default user is wrong' {
        Mock -ModuleName Verify Assert-DefaultUser { throw "dev starts as 'root'" }
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*distro*').Ok | Should-BeFalse
        (Test-Line "FAIL *starts as 'root'*") | Should-BeTrue
    }

    It 'check 5: uses Context.LinuxUser when set instead of deriving it' {
        $ctx = New-Ctx; $ctx.LinuxUser = 'bob'
        $null = Invoke-VerifyChecks -Context $ctx
        Should-Invoke -CommandName Assert-DefaultUser -ModuleName Verify -Times 1 -Exactly -ParameterFilter { $UserName -eq 'bob' }
        Should-NotInvoke -CommandName Get-LinuxUserName -ModuleName Verify
    }

    It 'check 6: a failing Linux verify fails with its exit code, and the output is shown' {
        $script:LinuxExit = 1
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -Like '*Linux verify*').Ok | Should-BeFalse
        (Test-Line 'FAIL *Linux verify*exit code 1*') | Should-BeTrue
        (Test-Line '*linux verify line*') | Should-BeTrue
        Should-Invoke -CommandName Invoke-Native -ModuleName Verify -ParameterFilter {
            $FilePath -eq 'wsl.exe' -and ($ArgumentList -join ' ') -eq '-d dev -- bash -lc $HOME/workspace/setup-dev-linux-wsl/script/verify' }
    }

    It 'check 7 is informational: degraded or an odd state never fails' {
        foreach ($state in 'degraded', 'starting') {
            $script:SystemdState = $state
            $r = @(Invoke-VerifyChecks -Context (New-Ctx))
            @($r | Where-Object { -not $_.Ok }).Count | Should-Be 0
            (Test-Line "*$state*") | Should-BeTrue
        }
        (Test-Line '*Kernel DMA Protection*on*') | Should-BeTrue
    }

    It 'keeps going after a failure so every failure shows' {
        Mock -ModuleName Verify Get-OsBuild { 1 }
        $script:Chezmoi = @{ Ok = $false; Output = @('x') }
        $script:LinuxExit = 1
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        $r.Count | Should-Be 6
        @($r | Where-Object { -not $_.Ok }).Count | Should-Be 3
    }
}

Describe 'Invoke-VerifyStage' {
    BeforeEach {
        Mock -ModuleName Verify Write-Info { }
        Mock -ModuleName Verify Write-Warn { }
    }
    It 'returns done when every check passes' {
        Mock -ModuleName Verify Invoke-VerifyChecks { @([pscustomobject]@{ Name = 'a'; Ok = $true; Reason = '' }) }
        Invoke-VerifyStage -Context (New-Ctx) | Should-Be 'done'
    }
    It 'returns failed when any check fails' {
        Mock -ModuleName Verify Invoke-VerifyChecks {
            @([pscustomobject]@{ Name = 'a'; Ok = $true; Reason = '' }, [pscustomobject]@{ Name = 'b'; Ok = $false; Reason = 'r' }) }
        Invoke-VerifyStage -Context (New-Ctx) | Should-Be 'failed'
    }
    It 'with -Plan runs no checks' {
        Mock -ModuleName Verify Invoke-VerifyChecks { throw 'no' }
        Invoke-VerifyStage -Context (New-Ctx) -Plan | Should-Be 'done'
    }
}

Describe 'Invoke-VerifyCommand (script/verify.ps1)' {
    BeforeEach {
        $env:SETUP_DEV_WIN_STATE = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N')).json"
        Mock -ModuleName Verify Get-EditionInfo { $script:Pro }
        Mock -ModuleName Verify Write-Host { }
        $script:Ok = $true
        Mock -ModuleName Verify Invoke-VerifyChecks {
            $script:VerifyCtx = $Context
            @([pscustomobject]@{ Name = 'a'; Ok = $script:Ok; Reason = '' })
        }
    }
    AfterAll { $env:SETUP_DEV_WIN_STATE = $null }

    It 'uses the defaults when nothing is persisted and no flag is given' {
        Invoke-VerifyCommand | Should-Be 0
        ($script:VerifyCtx.Profiles -join ',') | Should-Be 'core,dev,security,productivity'
        $script:VerifyCtx.DistroRoot | Should-Be 'D:\WSL'
        $script:VerifyCtx.LinuxUser | Should-BeFalsy
        Test-Path -LiteralPath $env:SETUP_DEV_WIN_STATE | Should-BeFalse
    }

    It 'reads the persisted choices when the flags are absent' {
        Set-Content -LiteralPath $env:SETUP_DEV_WIN_STATE -Value '{ "settings": { "profiles": "core,lab", "distroRoot": "E:\\X", "linuxUser": "bob" } }'
        Invoke-VerifyCommand | Should-Be 0
        ($script:VerifyCtx.Profiles -join ',') | Should-Be 'core,lab'
        $script:VerifyCtx.DistroRoot | Should-Be 'E:\X'
        $script:VerifyCtx.LinuxUser | Should-Be 'bob'
    }

    It 'a flag wins and nothing is written' {
        $json = '{ "settings": { "profiles": "core,lab", "distroRoot": "E:\\X", "linuxUser": "bob" } }'
        Set-Content -LiteralPath $env:SETUP_DEV_WIN_STATE -Value $json
        Invoke-VerifyCommand -DistroRoot 'F:\Y' -Profiles 'core' -LinuxUser 'carol' | Should-Be 0
        ($script:VerifyCtx.Profiles -join ',') | Should-Be 'core'
        $script:VerifyCtx.DistroRoot | Should-Be 'F:\Y'
        $script:VerifyCtx.LinuxUser | Should-Be 'carol'
        (Get-Content -LiteralPath $env:SETUP_DEV_WIN_STATE -Raw).Trim() | Should-Be $json
    }

    It 'returns 1 when a check fails' {
        $script:Ok = $false
        Invoke-VerifyCommand | Should-Be 1
    }

    It 'script/verify.ps1 takes -DistroRoot, -Profiles and -LinuxUser' {
        $cmd = Get-Command (Join-Path $script:Root 'script/verify.ps1')
        foreach ($p in 'DistroRoot', 'Profiles', 'LinuxUser') { $cmd.Parameters.ContainsKey($p) | Should-BeTrue -Because $p }
    }
}
