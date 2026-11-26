Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'script/lib/Runner.psm1') -Force
    # No -Force: reuse the State instance Runner already loaded so mocks reach it.
    Import-Module (Join-Path $root 'script/lib/State.psm1')
}

Describe 'Invoke-SetupRun' {
    BeforeEach {
        $env:SETUP_DEV_WIN_STATE = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N')).json"
        $script:Boot = [datetime]::new(2026, 1, 1, 8, 0, 0, [DateTimeKind]::Utc)
        Mock -ModuleName State Get-CimInstance { [pscustomobject]@{ LastBootUpTime = $script:Boot } }
        Mock -ModuleName Runner Test-IsElevated { $false }
        Mock -ModuleName Runner Get-EditionInfo { @{ Edition = 'Professional'; IsHome = $false; IsPro = $true } }
        foreach ($n in 'Preflight', 'Features', 'Apps', 'Dotfiles', 'Wsl', 'Verify') {
            Mock -ModuleName Runner "Invoke-${n}Stage" { 'done' }
        }
        Mock -ModuleName Runner Write-Warn { $script:Warned += $Message }
        Mock -ModuleName Runner Write-Info { }
        Mock -ModuleName Runner Write-Ok { }
        Mock -ModuleName Runner Write-Info { }
        Mock -ModuleName Runner Write-Ok { }
        $script:Warned = @()
    }
    AfterAll {
        $env:SETUP_DEV_WIN_STATE = $null
    }

    It 'refuses to run elevated' {
        Mock -ModuleName Runner Test-IsElevated { $true }
        Invoke-SetupRun | Should-Be 1
        ($script:Warned -join ' ') | Should-Be 'Run from a normal (non-elevated) terminal; elevation is requested per step.'
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-PreflightStage
    }

    It 'runs stages in order and exits 0' {
        $log = [System.Collections.Generic.List[string]]::new()
        foreach ($n in 'Preflight', 'Features', 'Apps', 'Dotfiles', 'Wsl', 'Verify') {
            Mock -ModuleName Runner "Invoke-${n}Stage" { $log.Add($n); 'done' }.GetNewClosure()
        }
        Invoke-SetupRun | Should-Be 0
        ($log -join ',') | Should-Be 'Preflight,Features,Apps,Dotfiles,Wsl,Verify'
        Get-StageResult -Stage 'wsl' | Should-Be 'done'
    }

    It 'passes the context to stages' {
        Mock -ModuleName Runner Invoke-FeaturesStage {
            $script:Ctx = $Context
            'done'
        }
        Invoke-SetupRun -Profiles 'lab' -DistroRoot 'E:\X' -LinuxRef 'v1' | Should-Be 0
        ($script:Ctx.Profiles -join ',') | Should-Be 'core,lab'
        $script:Ctx.DistroRoot | Should-Be 'E:\X'
        $script:Ctx.LinuxRef | Should-Be 'v1'
        $script:Ctx.LinuxRepoUrl | Should-Be 'https://github.com/istvano/setup-dev-linux-wsl'
        $script:Ctx.Plan | Should-BeFalse
        $script:Ctx.ContainsKey('Edition') | Should-BeTrue
    }

    It 'seeds Edition before any stage so a re-run that skips preflight still has it' {
        Set-StageResult -Stage 'preflight' -Result 'done'
        Mock -ModuleName Runner Invoke-FeaturesStage {
            $script:Ctx = $Context
            'done'
        }
        Invoke-SetupRun -Profiles 'core,lab' | Should-Be 0
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-PreflightStage
        $script:Ctx.Edition.IsPro | Should-BeTrue
    }

    It 'stops at reboot-required, exits 3010, and later stages do not run' {
        Mock -ModuleName Runner Invoke-FeaturesStage { 'reboot-required' }
        Invoke-SetupRun | Should-Be 3010
        Get-StageResult -Stage 'features' | Should-Be 'reboot-required'
        ($script:Warned -join ' ') | Should-BeLikeString -Expected '*Reboot, then run pwsh -File script\setup.ps1 again (or powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1).*'
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-DotfilesStage
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-WslStage
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-VerifyStage
    }

    It 'after a reboot resumes at the recorded stage and skips done stages' {
        Mock -ModuleName Runner Invoke-FeaturesStage { 'reboot-required' }
        Invoke-SetupRun | Should-Be 3010
        $script:Boot = $script:Boot.AddHours(1)
        Mock -ModuleName Runner Invoke-FeaturesStage { 'done' }
        Invoke-SetupRun | Should-Be 0
        Should-Invoke -ModuleName Runner -CommandName Invoke-PreflightStage -Times 1 -Exactly
        # features ran twice in total: once returning reboot-required, once after the reboot.
        Should-Invoke -ModuleName Runner -CommandName Invoke-FeaturesStage -Times 2 -Exactly
        Should-Invoke -ModuleName Runner -CommandName Invoke-DotfilesStage -Times 1 -Exactly
        Get-StageResult -Stage 'features' | Should-Be 'done'
    }

    It 'without a reboot, a reboot-required stage exits 3010 again without re-running' {
        Mock -ModuleName Runner Invoke-FeaturesStage { 'reboot-required' }
        Invoke-SetupRun | Should-Be 3010
        Mock -ModuleName Runner Invoke-FeaturesStage { 'done' }
        Invoke-SetupRun | Should-Be 3010
        # Only the first run invoked features; the second exited before re-running it.
        Should-Invoke -ModuleName Runner -CommandName Invoke-FeaturesStage -Times 1 -Exactly
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-DotfilesStage
    }

    It 'a second complete run invokes only apps and verify' {
        Invoke-SetupRun | Should-Be 0
        Invoke-SetupRun | Should-Be 0
        Should-Invoke -ModuleName Runner -CommandName Invoke-AppsStage -Times 2 -Exactly
        Should-Invoke -ModuleName Runner -CommandName Invoke-PreflightStage -Times 1 -Exactly
        Should-Invoke -ModuleName Runner -CommandName Invoke-WslStage -Times 1 -Exactly
        Should-Invoke -ModuleName Runner -CommandName Invoke-VerifyStage -Times 2 -Exactly
    }

    It 'apps runs on every pass even when recorded done, so a newly added profile installs' {
        Set-StageResult -Stage 'apps' -Result 'done'
        Invoke-SetupRun | Should-Be 0
        Should-Invoke -ModuleName Runner -CommandName Invoke-AppsStage -Times 1 -Exactly
    }

    It '-Stage apps runs only apps' {
        Invoke-SetupRun -Stage 'apps' | Should-Be 0
        Should-Invoke -ModuleName Runner -CommandName Invoke-AppsStage -Times 1 -Exactly
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-FeaturesStage
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-VerifyStage
    }

    It '-Stage features runs only features, ignoring recorded state' {
        Set-StageResult -Stage 'features' -Result 'done'
        Invoke-SetupRun -Stage 'features' | Should-Be 0
        Should-Invoke -ModuleName Runner -CommandName Invoke-FeaturesStage -Times 1 -Exactly
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-PreflightStage
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-VerifyStage
    }

    It '-Plan passes Plan to every stage and records nothing' {
        Mock -ModuleName Runner Set-StageResult { }
        Invoke-SetupRun -Plan | Should-Be 0
        Should-NotInvoke -ModuleName Runner -CommandName Set-StageResult
        Should-Invoke -ModuleName Runner -CommandName Invoke-WslStage -Times 1 -Exactly -ParameterFilter { $Plan -and $Context.Plan }
        Should-Invoke -ModuleName Runner -CommandName Invoke-VerifyStage -Times 1 -Exactly -ParameterFilter { $Plan }
    }

    It 'records failed and exits 1 when a stage throws, with the message' {
        Mock -ModuleName Runner Invoke-DotfilesStage { throw 'boom' }
        Invoke-SetupRun | Should-Be 1
        Get-StageResult -Stage 'dotfiles' | Should-Be 'failed'
        ($script:Warned -join ' ') | Should-BeLikeString -Expected '*boom*'
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-WslStage
    }

    It 'a failed apps stage does not stop the run: later stages run, apps is recorded failed, exit 1' {
        Mock -ModuleName Runner Invoke-AppsStage { 'failed' }
        Invoke-SetupRun | Should-Be 1
        Get-StageResult -Stage 'apps' | Should-Be 'failed'
        Should-Invoke -ModuleName Runner -CommandName Invoke-DotfilesStage -Times 1 -Exactly
        Should-Invoke -ModuleName Runner -CommandName Invoke-WslStage -Times 1 -Exactly
        Should-Invoke -ModuleName Runner -CommandName Invoke-VerifyStage -Times 1 -Exactly
        ($script:Warned -join ' ') | Should-BeLikeString -Expected "*Stage 'apps' failed; continuing with the remaining stages. Fix the listed apps and re-run pwsh -File script\setup.ps1 -Stage apps.*"
    }

    It 'a throwing apps stage also continues and exits 1' {
        Mock -ModuleName Runner Invoke-AppsStage { throw 'boom' }
        Invoke-SetupRun | Should-Be 1
        Get-StageResult -Stage 'apps' | Should-Be 'failed'
        Should-Invoke -ModuleName Runner -CommandName Invoke-VerifyStage -Times 1 -Exactly
    }

    It 'a failed apps stage then a later reboot-required exits 3010' {
        Mock -ModuleName Runner Invoke-AppsStage { 'failed' }
        Mock -ModuleName Runner Invoke-WslStage { 'reboot-required' }
        Invoke-SetupRun | Should-Be 3010
        Get-StageResult -Stage 'apps' | Should-Be 'failed'
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-VerifyStage
    }

    It 'a failed apps stage in -Plan records nothing and still exits 1' {
        Mock -ModuleName Runner Set-StageResult { }
        Mock -ModuleName Runner Invoke-AppsStage { 'failed' }
        Invoke-SetupRun -Plan | Should-Be 1
        Should-NotInvoke -ModuleName Runner -CommandName Set-StageResult
        Should-Invoke -ModuleName Runner -CommandName Invoke-VerifyStage -Times 1 -Exactly
    }

    It 'counts an unexpected return value as failed' {
        Mock -ModuleName Runner Invoke-FeaturesStage { 'banana' }
        Invoke-SetupRun | Should-Be 1
        Get-StageResult -Stage 'features' | Should-Be 'failed'
    }

    It 'retries a stage recorded failed' {
        Set-StageResult -Stage 'features' -Result 'failed'
        Invoke-SetupRun | Should-Be 0
        Should-Invoke -ModuleName Runner -CommandName Invoke-FeaturesStage -Times 1 -Exactly
    }

    It 'rejects an unknown profile' {
        Invoke-SetupRun -Profiles 'nope' | Should-Be 1
        ($script:Warned -join ' ') | Should-BeLikeString -Expected '*nope*'
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-PreflightStage
    }

    It 'first run with no flags uses and persists the defaults; LinuxUser stays unset' {
        Mock -ModuleName Runner Invoke-FeaturesStage { $script:Ctx = $Context; 'done' }
        Invoke-SetupRun | Should-Be 0
        ($script:Ctx.Profiles -join ',') | Should-Be 'core,dev,security,productivity'
        $script:Ctx.DistroRoot | Should-Be 'D:\WSL'
        $script:Ctx.LinuxUser | Should-BeFalsy
        Get-SetupSetting -Name 'profiles' | Should-Be 'core,dev,security,productivity'
        Get-SetupSetting -Name 'distroRoot' | Should-Be 'D:\WSL'
        Get-SetupSetting -Name 'linuxUser' | Should-BeNull
    }

    It 'an explicit flag is persisted and used by a later run without the flag' {
        Mock -ModuleName Runner Invoke-FeaturesStage { $script:Ctx = $Context; 'done' }
        Invoke-SetupRun -Profiles 'lab' -DistroRoot 'E:\X' -LinuxUser 'alice' | Should-Be 0
        Get-SetupSetting -Name 'linuxUser' | Should-Be 'alice'
        Invoke-SetupRun -Stage 'features' | Should-Be 0
        ($script:Ctx.Profiles -join ',') | Should-Be 'core,lab'
        $script:Ctx.DistroRoot | Should-Be 'E:\X'
        $script:Ctx.LinuxUser | Should-Be 'alice'
    }

    It 'an explicit flag wins over the persisted value and replaces it' {
        Mock -ModuleName Runner Invoke-FeaturesStage { $script:Ctx = $Context; 'done' }
        Set-SetupSetting -Name 'profiles' -Value 'core,lab'
        Set-SetupSetting -Name 'linuxUser' -Value 'alice'
        Invoke-SetupRun -Stage 'features' -Profiles 'core' -LinuxUser 'bob' | Should-Be 0
        ($script:Ctx.Profiles -join ',') | Should-Be 'core'
        $script:Ctx.LinuxUser | Should-Be 'bob'
        Get-SetupSetting -Name 'profiles' | Should-Be 'core'
        Get-SetupSetting -Name 'linuxUser' | Should-Be 'bob'
    }

    It 'refuses an invalid -LinuxUser before any stage and persists nothing' {
        Invoke-SetupRun -LinuxUser 'root' | Should-Be 1
        ($script:Warned -join ' ') | Should-BeLikeString -Expected '*root*'
        Should-NotInvoke -ModuleName Runner -CommandName Invoke-PreflightStage
        Get-SetupSetting -Name 'linuxUser' | Should-BeNull
    }

    It '-Plan reads persisted choices but writes none' {
        Mock -ModuleName Runner Invoke-FeaturesStage { $script:Ctx = $Context; 'done' }
        Set-SetupSetting -Name 'distroRoot' -Value 'E:\X'
        Invoke-SetupRun -Plan -LinuxUser 'carol' | Should-Be 0
        $script:Ctx.DistroRoot | Should-Be 'E:\X'
        $script:Ctx.LinuxUser | Should-Be 'carol'
        Get-SetupSetting -Name 'linuxUser' | Should-BeNull
        Get-SetupSetting -Name 'profiles' | Should-BeNull
    }

    It 'treats an empty profile list as core' {
        Mock -ModuleName Runner Invoke-FeaturesStage { $script:Ctx = $Context; 'done' }
        Invoke-SetupRun -Profiles '' | Should-Be 0
        ($script:Ctx.Profiles -join ',') | Should-Be 'core'
    }
}

Describe 'setup.ps1 entry point' {
    It 'is a thin wrapper that does not run when SETUP_DEV_WIN_NO_MAIN=1' {
        $env:SETUP_DEV_WIN_NO_MAIN = '1'
        try {
            $setup = Join-Path (Split-Path -Parent $PSScriptRoot) 'script/setup.ps1'
            $threw = $false
            try { . $setup } catch { $threw = $true }
            $threw | Should-BeFalse
        }
        finally { $env:SETUP_DEV_WIN_NO_MAIN = $null }
    }
}
