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
        $script:TermLocalState = $true
        $script:TermReason = ''
        Mock -ModuleName Verify Test-TerminalLocalState { $script:TermLocalState }
        Mock -ModuleName Verify Test-TerminalSettings { $script:TermReason }
        $script:Optout = '1'
        Mock -ModuleName Verify Get-UserEnvironmentVariable { $script:Optout }
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
        $script:Missing = @()
        $script:FontOk = $true
        $script:VsCli = 'C:\code.cmd'
        $script:MissingExt = @()
        Mock -ModuleName Verify Get-VSCodeCli { $script:VsCli }
        Mock -ModuleName Verify Get-MissingVSCodeExtensions { $script:MissingExt }
        Mock -ModuleName Verify Test-NerdFontInstalled { $script:FontOk }
        Mock -ModuleName Verify Test-WingetPackage { $Id -notin $script:Missing }
        $script:Installed = @('Git.Git')
        $script:ExportFails = $false
        Mock -ModuleName Verify Get-WingetInstalledIds {
            if ($script:ExportFails) { throw 'winget export failed' }
            $script:Installed
        }
    }

    It 'passes every check on a healthy machine' {
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        $r.Count | Should-Be 9
        @($r | Where-Object { -not $_.Ok }).Count | Should-Be 0
        ($script:Lines | Where-Object { $_ -like 'OK *' }).Count | Should-Be 9
        (Test-Line 'OK Apps') | Should-BeTrue
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

    It 'the chezmoi check is named for the dotfiles, not just .wslconfig' {
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -EQ 'chezmoi verify (dotfiles)').Ok | Should-BeTrue
        ($r | Where-Object Name -Like '*(.wslconfig)*') | Should-BeNull
    }

    It 'Terminal settings: fails with the reason from Test-TerminalSettings' {
        $script:TermReason = 'copyOnSelect is False'
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -EQ 'Terminal settings').Ok | Should-BeFalse
        (Test-Line 'FAIL Terminal settings: copyOnSelect is False') | Should-BeTrue
    }

    It 'Terminal settings: passes with a note when Terminal has no LocalState yet' {
        $script:TermLocalState = $false
        $script:TermReason = 'settings.json not found'
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -EQ 'Terminal settings').Ok | Should-BeTrue
        (Test-Line '*Terminal*not set up*') | Should-BeTrue
        Should-NotInvoke -CommandName Test-TerminalSettings -ModuleName Verify
    }

    It 'PowerShell telemetry opt-out: fails unless the user variable is 1' {
        $script:Optout = ''
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -EQ 'PowerShell telemetry opt-out').Ok | Should-BeFalse
        (Test-Line 'FAIL PowerShell telemetry opt-out: POWERSHELL_TELEMETRY_OPTOUT is not 1 for this user; run pwsh -File script\setup.ps1 -Stage dotfiles.') | Should-BeTrue
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

    It 'Apps: two missing packages fail naming each with the fix' {
        $script:Missing = @('Git.Git', 'twpayne.chezmoi')
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -EQ 'Apps').Ok | Should-BeFalse
        (Test-Line 'FAIL Apps: missing Git (Git.Git), chezmoi (twpayne.chezmoi); run pwsh -File script\setup.ps1 -Stage apps.') | Should-BeTrue
    }

    It 'Apps: a missing font fails with JetBrains Mono Nerd Font is not installed' {
        $script:FontOk = $false
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -EQ 'Apps').Ok | Should-BeFalse
        (Test-Line 'FAIL Apps: *JetBrains Mono Nerd Font is not installed*') | Should-BeTrue
    }

    It 'Apps: a missing package and a missing font are both reported' {
        $script:FontOk = $false
        $script:Missing = @('Git.Git')
        $null = Invoke-VerifyChecks -Context (New-Ctx)
        (Test-Line 'FAIL Apps: missing Git (Git.Git)*JetBrains Mono Nerd Font is not installed*') | Should-BeTrue
    }

    It 'Apps: names missing VS Code extensions with dev and VS Code installed' {
        $script:MissingExt = @('a.one', 'b.two')
        $r = @(Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core', 'dev')))
        ($r | Where-Object Name -EQ 'Apps').Ok | Should-BeFalse
        (Test-Line 'FAIL Apps: *VS Code extension a.one*VS Code extension b.two*') | Should-BeTrue
    }

    It 'Apps: a failing extension listing keeps the package and font problems and names the reason' {
        $script:Missing = @('Git.Git')
        $script:FontOk = $false
        Mock -ModuleName Verify Get-MissingVSCodeExtensions { throw 'code exited 1' }
        $r = @(Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core', 'dev')))
        ($r | Where-Object Name -EQ 'Apps').Ok | Should-BeFalse
        (Test-Line 'FAIL Apps: missing Git*JetBrains Mono Nerd Font is not installed*could not list VS Code extensions: code exited 1*') | Should-BeTrue
    }

    It 'Apps: ignores extensions without dev or without VS Code' {
        $script:MissingExt = @('a.one')
        $r = @(Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core')))
        ($r | Where-Object Name -EQ 'Apps').Ok | Should-BeTrue
        $script:VsCli = $null
        $r = @(Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core', 'dev')))
        ($r | Where-Object Name -EQ 'Apps').Ok | Should-BeTrue
    }

    It 'Apps: checks a Microsoft Store entry against the msstore source' {
        $null = Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core', 'productivity-extra'))
        Should-Invoke -CommandName Test-WingetPackage -ModuleName Verify -ParameterFilter { $Id -eq '9PLM9XGG6VKS' -and $Source -eq 'msstore' }
        Should-Invoke -CommandName Test-WingetPackage -ModuleName Verify -ParameterFilter { $Id -eq 'Git.Git' -and $Source -eq 'winget' }
    }

    It 'Apps: checks only the selected profiles' {
        $null = Invoke-VerifyChecks -Context (New-Ctx -Profiles @('core'))
        Should-NotInvoke -CommandName Test-WingetPackage -ModuleName Verify -ParameterFilter { $Id -eq 'Google.Chrome' }
        Should-Invoke -CommandName Test-WingetPackage -ModuleName Verify -ParameterFilter { $Id -eq 'Git.Git' }
    }

    It 'Apps: a winget error in one package fails the check, not the run' {
        Mock -ModuleName Verify Test-WingetPackage { throw "winget list failed for $Id" }
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        ($r | Where-Object Name -EQ 'Apps').Ok | Should-BeFalse
        $r.Count | Should-Be 9
    }

    It 'drift: lists installed ids in no profile, minus the allowlist, case-insensitively' {
        $script:Installed = @('Git.Git', 'google.chrome', 'Foo.Bar', 'Microsoft.VCLibs.140.00.UWPDesktop', 'Microsoft.AppInstaller', 'Zed.Other')
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        @($r | Where-Object { -not $_.Ok }).Count | Should-Be 0
        (Test-Line 'INFO apps not in any profile (2): Foo.Bar, Zed.Other') | Should-BeTrue
    }

    It 'drift: a Store entry''s winget-source name (WingetId) counts as declared' {
        $script:Installed = @('Git.Git', 'OpenAI.ChatGPT')
        $null = Invoke-VerifyChecks -Context (New-Ctx)
        (Test-Line 'INFO apps not in any profile: none') | Should-BeTrue
    }

    It 'drift: none when everything is declared or allowlisted' {
        $script:Installed = @('Git.Git', 'Microsoft.Edge')
        $null = Invoke-VerifyChecks -Context (New-Ctx)
        (Test-Line 'INFO apps not in any profile: none') | Should-BeTrue
    }

    It 'drift: an export failure is informational and never fails verify' {
        $script:ExportFails = $true
        $r = @(Invoke-VerifyChecks -Context (New-Ctx))
        @($r | Where-Object { -not $_.Ok }).Count | Should-Be 0
        (Test-Line 'INFO apps not in any profile: unreadable (winget export failed)') | Should-BeTrue
    }

    It 'the drift allowlist holds the Windows and winget infrastructure patterns' {
        $allow = Import-PowerShellDataFile (Join-Path $script:Root 'profiles/drift-allowlist.psd1')
        foreach ($p in 'Microsoft.AppInstaller', 'Microsoft.UI.Xaml.*', 'Microsoft.VCLibs.*', 'Microsoft.VCRedist.*',
            'Microsoft.WindowsAppRuntime.*', 'Microsoft.DotNet.*', 'Microsoft.Edge', 'Microsoft.EdgeWebView2Runtime',
            'Microsoft.OneDrive', 'Microsoft.WSL', 'Microsoft.DSC',
            'Microsoft.365Copilot', 'Microsoft.Outlook', 'Microsoft.Teams', 'Nvidia.PhysX') {
            $allow.Patterns | Should-ContainCollection $p
        }
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
        $r.Count | Should-Be 9
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
    It 'the plan text lists the apps check' {
        $script:Plan = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Verify Write-Info { $script:Plan.Add([string]$Message) }
        Mock -ModuleName Verify Invoke-VerifyChecks { throw 'no' }
        $null = Invoke-VerifyStage -Context (New-Ctx) -Plan
        (($script:Plan -join ' ') -like '*installed apps*') | Should-BeTrue
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
