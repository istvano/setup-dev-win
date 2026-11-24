Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/stages/Wsl.psm1') -Force
    $script:Ctx = @{ Profiles = @('core'); DistroRoot = 'D:\WSL'; LinuxRepoUrl = 'https://github.com/istvano/setup-dev-linux-wsl'
        LinuxRef = 'main'; Plan = $false; Edition = $null }
    $script:Record = @{ Name = 'dev'; BasePath = 'D:\WSL\dev'; Version = 2; DefaultUid = 1000 }
}

Describe 'Invoke-WslStage' {
    BeforeEach {
        $script:Order = [System.Collections.Generic.List[string]]::new()
        $script:Registered = $null
        Mock -ModuleName Wsl Write-Info { }
        Mock -ModuleName Wsl Write-Warn { }
        Mock -ModuleName Wsl Write-Ok { }
        Mock -ModuleName Wsl Get-DistroLock { $script:Order.Add('lock'); @{ Name = 'Ubuntu-26.04' } }
        Mock -ModuleName Wsl Save-VerifiedImage { $script:Order.Add('save'); 'C:\img.wsl' }
        Mock -ModuleName Wsl Get-LinuxUserName { 'alice' }
        Mock -ModuleName Wsl Get-RegisteredDistro { $script:Registered }
        Mock -ModuleName Wsl Install-DevDistro { $script:Order.Add('install'); $script:Registered = $script:Record; $script:Record }
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

    It 'does not re-run cloud-init or passwd when dev already exists, but still asserts the default user' {
        $script:Registered = $script:Record
        Mock -ModuleName Wsl Install-DevDistro { $script:Order.Add('install'); $script:Record }
        Invoke-WslStage -Context $script:Ctx | Should-Be 'done'
        Should-NotInvoke -CommandName Set-DevUserPassword -ModuleName Wsl
        Should-Invoke -CommandName Assert-DefaultUser -ModuleName Wsl -Times 1 -Exactly
        Should-Invoke -CommandName Invoke-LinuxHandoff -ModuleName Wsl -Times 1 -Exactly
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
        foreach ($c in 'Get-DistroLock', 'Save-VerifiedImage', 'Install-DevDistro', 'Invoke-LinuxHandoff', 'Get-RegisteredDistro') {
            Should-NotInvoke -CommandName $c -ModuleName Wsl
        }
        Should-Invoke -CommandName Write-Info -ModuleName Wsl -Times 4
    }
}
