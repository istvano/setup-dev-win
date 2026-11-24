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
        Mock -ModuleName Wsl Write-Info { }
        Mock -ModuleName Wsl Write-Warn { }
        Mock -ModuleName Wsl Write-Ok { }
        Mock -ModuleName Wsl Get-DistroLock { $script:Order.Add('lock'); @{ Name = 'Ubuntu-26.04' } }
        Mock -ModuleName Wsl Save-VerifiedImage { $script:Order.Add('save'); 'C:\img.wsl' }
        Mock -ModuleName Wsl Get-LinuxUserName { 'alice' }
        $script:PwStatus = 'alice L 2026-11-24 0 99999 7 -1'
        Mock -ModuleName Wsl Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = @($script:PwStatus) } }
        Mock -ModuleName Wsl Install-DevDistro { $script:Order.Add('install'); $script:Record }
        Mock -ModuleName Wsl Assert-DistroPlacement { $script:Order.Add('placement') }
        Mock -ModuleName Wsl Assert-DefaultUser { $script:Order.Add('defaultuser') }
        Mock -ModuleName Wsl Set-DevUserPassword { $script:Order.Add('passwd') }
        Mock -ModuleName Wsl Invoke-LinuxHandoff { $script:Order.Add('handoff'); 0 }
    }

    It 'runs the steps in order on a first install and returns done' {
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        ($script:Order -join ',') | Should-Be 'lock,save,install,placement,defaultuser,passwd,handoff'
        Should-Invoke -CommandName Invoke-LinuxHandoff -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            $Url -eq 'https://github.com/istvano/setup-dev-linux-wsl' -and $Ref -eq 'main' }
        Should-Invoke -CommandName Save-VerifiedImage -ModuleName Wsl -Times 1 -Exactly -ParameterFilter {
            $Directory -eq (Join-Path ([System.IO.Path]::GetTempPath()) 'setup-dev-win') }
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
        Should-NotInvoke -CommandName Save-VerifiedImage -ModuleName Wsl
    }

    It 'fails when the placement assertion throws, without handing off' {
        Mock -ModuleName Wsl Assert-DistroPlacement { throw 'dev is at C:\x, not under D:\WSL.' }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-NotInvoke -CommandName Invoke-LinuxHandoff -ModuleName Wsl
        Should-NotInvoke -CommandName Set-DevUserPassword -ModuleName Wsl
        Should-Invoke -CommandName Write-Warn -ModuleName Wsl -ParameterFilter { $Message -like '*not under D:\WSL*' }
    }

    It 'fails when the default user assertion throws' {
        Mock -ModuleName Wsl Assert-DefaultUser { throw 'dev starts as root' }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-NotInvoke -CommandName Invoke-LinuxHandoff -ModuleName Wsl
    }

    It 'returns failed with the exit code when the handoff fails' {
        Mock -ModuleName Wsl Invoke-LinuxHandoff { 1 }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'failed'
        Should-Invoke -CommandName Write-Warn -ModuleName Wsl -ParameterFilter { $Message -like '*exit code 1*' }
    }

    It 'with -Plan prints the steps and touches nothing' {
        Invoke-WslStage -Context $script:Ctx -Plan | Should-Be 'done'
        foreach ($c in 'Get-DistroLock', 'Save-VerifiedImage', 'Install-DevDistro', 'Invoke-LinuxHandoff', 'Invoke-Native') {
            Should-NotInvoke -CommandName $c -ModuleName Wsl
        }
        Should-Invoke -CommandName Write-Info -ModuleName Wsl -Times 4 -Exactly
    }
}
