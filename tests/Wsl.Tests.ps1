Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/stages/Wsl.psm1') -Force
    $script:Ctx = @{ Profiles = @('core'); DistroRoot = 'D:\WSL'; LinuxRepoUrl = 'https://github.com/istvano/setup-dev-linux-wsl'
        LinuxRef = 'main'; Plan = $false; Edition = $null 
    }
    $script:Record = @{ Name = 'dev'; BasePath = 'D:\WSL\dev'; Version = 2; DefaultUid = 1000 }
}

Describe 'Invoke-WslStage' {
    BeforeEach {
        $script:Order = [System.Collections.Generic.List[string]]::new()
        $script:Infos = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Wsl Write-Info { $script:Infos.Add($Message) }
        Mock -ModuleName Wsl Write-Warn { }
        Mock -ModuleName Wsl Write-Ok { }
        Mock -ModuleName Wsl Get-DistroLock { $script:Order.Add('lock'); @{ Name = 'Ubuntu-26.04'; Source = 'https://x' } }
        $script:Image = @{ Name = 'Ubuntu-26.04'; Url = 'https://x/img.wsl'; Sha256 = ('a' * 64) }
        Mock -ModuleName Wsl Resolve-DistroImage { $script:Order.Add('resolve'); $script:Image }
        Mock -ModuleName Wsl Save-VerifiedImage { $script:Order.Add('save'); 'C:\img.wsl' }
        Mock -ModuleName Wsl Clear-ImageCache { $script:Order.Add('clean') }
        Mock -ModuleName Wsl Get-RegisteredDistro { $null }
        Mock -ModuleName Wsl Get-LinuxUserName { 'alice' }
        Mock -ModuleName Wsl Get-LinuxUserName { 'bob' } -ParameterFilter { $Override -eq 'bob' }
        Mock -ModuleName Wsl Set-SetupSetting { }
        $script:PwStatus = 'alice L 2026-11-24 0 99999 7 -1'
        Mock -ModuleName Wsl Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = @($script:PwStatus) } }
        Mock -ModuleName Wsl Install-DevDistro { $script:Order.Add("install:$UserName"); $script:Record }
        Mock -ModuleName Wsl Assert-DistroPlacement { $script:Order.Add('placement') }
        Mock -ModuleName Wsl Assert-DefaultUser { $script:Order.Add('defaultuser') }
        Mock -ModuleName Wsl Set-DevUserPassword { $script:Order.Add('passwd') }
        Mock -ModuleName Wsl Invoke-LinuxHandoff { $script:Order.Add('handoff'); 0 }
    }

    It 'runs the steps in order on a first install and returns done' {
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        ($script:Order -join ',') | Should-Be 'lock,resolve,save,clean,install:alice,placement,defaultuser,passwd,handoff'
        Should-Invoke -CommandName Invoke-LinuxHandoff -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            $Url -eq 'https://github.com/istvano/setup-dev-linux-wsl' -and $Ref -eq 'main' }
        Should-Invoke -CommandName Resolve-DistroImage -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            $Lock.Name -eq 'Ubuntu-26.04' -and $Lock.Source -eq 'https://x' }
        Should-Invoke -CommandName Save-VerifiedImage -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            $Image.Url -eq 'https://x/img.wsl' -and $Image.Sha256 -eq ('a' * 64) }
    }

    It 'cleans the cache of other images after the verified download, keeping the new one' {
        $null = Invoke-WslStage -Context $script:Ctx
        Should-Invoke -CommandName Clear-ImageCache -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            $Directory -ceq 'D:\WSL\cache' -and $Keep -ceq 'C:\img.wsl' }
    }

    It 'does not clean the cache when the download fails' {
        Mock -ModuleName Wsl Save-VerifiedImage { throw 'hash mismatch' }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-NotInvoke -CommandName Clear-ImageCache -ModuleName Wsl
    }

    It 'skips the manifest, the download and the install when dev is already registered' {
        Mock -ModuleName Wsl Get-RegisteredDistro { $script:Record }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        foreach ($c in 'Get-DistroLock', 'Resolve-DistroImage', 'Save-VerifiedImage', 'Clear-ImageCache', 'Install-DevDistro') {
            Should-NotInvoke -CommandName $c -ModuleName Wsl
        }
        ($script:Order -join ',') | Should-Be 'placement,defaultuser,passwd,handoff'
        Should-Invoke -CommandName Assert-DistroPlacement -ModuleName Wsl -Times 1 -Exactly -ParameterFilter { $Distro.Name -eq 'dev' }
    }

    It 'downloads the image into the cache directory under the distro root, not the temp directory (<Root>)' -ForEach @(
        @{ Root = 'D:\WSL' }
        @{ Root = 'D:\WSL\' }
    ) {
        $ctx = $script:Ctx.Clone(); $ctx.DistroRoot = $Root
        $null = Invoke-WslStage -Context $ctx
        Should-Invoke -CommandName Save-VerifiedImage -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            $Directory -ceq 'D:\WSL\cache' }
    }

    It 'with -Plan names the cache directory' {
        Invoke-WslStage -Context $script:Ctx -Plan | Should-Be 'done'
        @($script:Infos | Where-Object { $_ -like '*D:\WSL\cache*' }).Count | Should-Be 1
        @($script:Infos | Where-Object { $_ -like '*TEMP*' }).Count | Should-Be 0
    }

    It 'uses Context.LinuxUser when set, prints it before installing and does not re-persist it' {
        $ctx = $script:Ctx.Clone(); $ctx.LinuxUser = 'bob'
        Invoke-WslStage -Context $ctx | Should-Be 'done'
        ($script:Order -join ',') | Should-BeLikeString '*install:bob*'
        $script:Infos | Should-ContainCollection @('Linux user: bob')
        Should-Invoke -CommandName Get-LinuxUserName -ModuleName Wsl -Times 1 -Exactly -ParameterFilter { $Override -eq 'bob' }
        Should-NotInvoke -CommandName Set-SetupSetting -ModuleName Wsl
    }

    It 'derives the user when Context.LinuxUser is unset and persists the derived name' {
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        $script:Infos | Should-ContainCollection @('Linux user: alice')
        Should-Invoke -CommandName Set-SetupSetting -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'linuxUser' -and $Value -eq 'alice' }
    }

    It 'adds the recovery hint when the default user check fails on a re-run' {
        Mock -ModuleName Wsl Assert-DefaultUser { throw "dev starts as 'root', expected 'alice'." }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-Invoke -CommandName Write-Warn -ModuleName Wsl -ParameterFilter {
            $Message -like "*starts as 'root'*wsl --unregister dev*pwsh -File script\setup.ps1 -Stage wsl*" }
    }

    It 'asks for a password when dev exists but the password is still locked' {
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        Should-Invoke -CommandName Set-DevUserPassword -ModuleName Wsl -Times 1 -Exactly
        Should-Invoke -CommandName Assert-DefaultUser -ModuleName Wsl -Times 1 -Exactly
        Should-Invoke -CommandName Invoke-Native -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq '-d dev -u root -- passwd -S alice' }
    }

    It 'skips passwd when a password is already set' {
        $script:PwStatus = 'alice P 2026-11-24 0 99999 7 -1'
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        Should-NotInvoke -CommandName Set-DevUserPassword -ModuleName Wsl
        Should-Invoke -CommandName Invoke-LinuxHandoff -ModuleName Wsl -Times 1 -Exactly
    }

    It 'asks when the status is NP' {
        $script:PwStatus = 'alice NP 2026-11-24 0 99999 7 -1'
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        Should-Invoke -CommandName Set-DevUserPassword -ModuleName Wsl -Times 1 -Exactly
    }

    It 'warns and asks when the status cannot be read' {
        Mock -ModuleName Wsl Invoke-Native { throw 'boom' }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        Should-Invoke -CommandName Set-DevUserPassword -ModuleName Wsl -Times 1 -Exactly
        Should-Invoke -CommandName Write-Warn -ModuleName Wsl -ParameterFilter { $Message -like '*Could not read the password status*' }
    }

    It 'rejects an invalid url or ref before any work, even with -Plan' {
        foreach ($plan in $false, $true) {
            $bad = $script:Ctx.Clone(); $bad.LinuxRepoUrl = 'https://github.com/o/r;id'
            Invoke-WslStage -Context $bad -Plan:$plan | Should-Be 'failed'
            $bad = $script:Ctx.Clone(); $bad.LinuxRef = '--upload-pack=x'
            Invoke-WslStage -Context $bad -Plan:$plan | Should-Be 'failed'
        }
        Should-NotInvoke -CommandName Get-DistroLock -ModuleName Wsl
        Should-NotInvoke -CommandName Resolve-DistroImage -ModuleName Wsl
        Should-NotInvoke -CommandName Save-VerifiedImage -ModuleName Wsl
    }

    It 'fails when the placement assertion throws, without handing off' {
        Mock -ModuleName Wsl Assert-DistroPlacement { throw 'dev is at C:\x, not under D:\WSL.' }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-NotInvoke -CommandName Invoke-LinuxHandoff -ModuleName Wsl
        Should-NotInvoke -CommandName Set-DevUserPassword -ModuleName Wsl
        Should-Invoke -CommandName Write-Warn -ModuleName Wsl -ParameterFilter { $Message -like '*not under D:\WSL*' }
    }

    It 'fails without downloading when the manifest cannot be resolved' {
        Mock -ModuleName Wsl Resolve-DistroImage { throw 'Could not read the distro manifest https://x: offline.' }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-NotInvoke -CommandName Save-VerifiedImage -ModuleName Wsl
        Should-NotInvoke -CommandName Install-DevDistro -ModuleName Wsl
        Should-Invoke -CommandName Write-Warn -ModuleName Wsl -ParameterFilter { $Message -like '*Could not read the distro manifest*' }
    }

    It 'fails when the default user assertion throws' {
        Mock -ModuleName Wsl Assert-DefaultUser { throw 'dev starts as root' }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-NotInvoke -CommandName Invoke-LinuxHandoff -ModuleName Wsl
    }

    It 'returns failed with the exit code when the handoff fails' {
        Mock -ModuleName Wsl Invoke-LinuxHandoff { 1 }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-Invoke -CommandName Write-Warn -ModuleName Wsl -ParameterFilter { $Message -like '*exit code 1*re-run pwsh -File script\setup.ps1 -Stage wsl*' }
    }

    It 'with -Plan prints the steps and touches nothing' {
        Invoke-WslStage -Context $script:Ctx -Plan | Should-Be 'done'
        foreach ($c in 'Get-DistroLock', 'Resolve-DistroImage', 'Save-VerifiedImage', 'Install-DevDistro', 'Invoke-LinuxHandoff', 'Invoke-Native') {
            Should-NotInvoke -CommandName $c -ModuleName Wsl
        }
        Should-Invoke -CommandName Write-Info -ModuleName Wsl -Times 4 -Exactly
    }
}
