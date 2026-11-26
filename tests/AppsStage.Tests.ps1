Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'script/lib/Common.psm1') -Force
    Import-Module (Join-Path $root 'script/lib/Apps.psm1') -Force
    Import-Module (Join-Path $root 'script/lib/Winget.psm1') -Force
    Import-Module (Join-Path $root 'script/lib/Font.psm1') -Force
    Import-Module (Join-Path $root 'script/stages/AppsStage.psm1') -Force

    function Get-TestContext {
        param([string[]]$Profiles = @('core'))
        @{ Profiles = $Profiles; DistroRoot = 'D:\WSL'; LinuxRepoUrl = 'u'; LinuxRef = 'main'; Plan = $false; Edition = $null }
    }
}

Describe 'Invoke-AppsStage' {
    BeforeEach {
        $script:Infos = [System.Collections.Generic.List[string]]::new()
        $script:Oks = [System.Collections.Generic.List[string]]::new()
        $script:Warns = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AppsStage Write-Info { $script:Infos.Add($Message) }
        Mock -ModuleName AppsStage Write-Ok { $script:Oks.Add($Message) }
        Mock -ModuleName AppsStage Write-Warn { $script:Warns.Add($Message) }
        Mock -ModuleName AppsStage Get-AppPackages {
            @(
                @{ Id = 'A.One'; Name = 'One'; Profile = 'core' }
                @{ Id = 'B.Two'; Name = 'Two'; Profile = 'core'; Scope = 'machine' }
            )
        }
        Mock -ModuleName AppsStage Test-WingetPackage { $false }
        Mock -ModuleName AppsStage Install-WingetPackage { 'installed' }
        Mock -ModuleName AppsStage Install-NerdFont { 'installed' }
    }

    It 'prints the profiles line first, with the default, the available profiles and how to change them' {
        Invoke-AppsStage -Context (Get-TestContext -Profiles @('core', 'dev')) | Out-Null
        $default = InModuleScope AppsStage { Get-DefaultProfileText }
        $available = (InModuleScope AppsStage { Get-ValidProfiles }) -join ','
        $script:Infos[0] | Should-Be "Profiles: core,dev (default $default; available $available; change with pwsh -File script\setup.ps1 -Profiles <list>)"
    }

    It 'reports an installed package and does not install it' {
        Mock -ModuleName AppsStage Test-WingetPackage { $true }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'done'
        $script:Oks | Should-ContainCollection 'One already installed'
        Should-NotInvoke -ModuleName AppsStage -CommandName Install-WingetPackage
    }

    It 'announces then installs a missing package, passing the catalogue Scope' {
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'done'
        $script:Infos | Should-ContainCollection 'Installing One (A.One)... A UAC prompt may appear; check the taskbar if nothing happens.'
        Should-Invoke -ModuleName AppsStage -CommandName Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $Id -eq 'A.One' -and -not $Scope }
        Should-Invoke -ModuleName AppsStage -CommandName Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $Id -eq 'B.Two' -and $Scope -eq 'machine' }
    }

    It 'passes a catalogue Source to the check and the install, and winget otherwise' {
        Mock -ModuleName AppsStage Get-AppPackages {
            @(
                @{ Id = 'A.One'; Name = 'One'; Profile = 'core' }
                @{ Id = '9PLM9XGG6VKS'; Name = 'Store'; Profile = 'core'; Source = 'msstore' }
            )
        }
        Invoke-AppsStage -Context (Get-TestContext) | Out-Null
        Should-Invoke -ModuleName AppsStage -CommandName Test-WingetPackage -ParameterFilter { $Id -eq '9PLM9XGG6VKS' -and $Source -eq 'msstore' }
        Should-Invoke -ModuleName AppsStage -CommandName Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $Id -eq '9PLM9XGG6VKS' -and $Source -eq 'msstore' }
        Should-Invoke -ModuleName AppsStage -CommandName Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $Id -eq 'A.One' -and $Source -eq 'winget' }
    }

    It 'reports already-installed as adopted, not failed' {
        Mock -ModuleName AppsStage Install-WingetPackage { 'already-installed' }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'done'
        $script:Warns.Count | Should-Be 0
        ($script:Oks -join '|') | Should-MatchString 'Adopted One'
    }

    It 'attempts every package when one throws, then fails naming Id and reason' {
        Mock -ModuleName AppsStage Install-WingetPackage {
            if ($Id -eq 'A.One') { throw 'A.One: installer hash mismatch' }
            'installed'
        }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-Invoke -ModuleName AppsStage -CommandName Install-WingetPackage -Times 2 -Exactly
        $text = $script:Warns -join "`n"
        $text | Should-MatchString 'A\.One'
        $text | Should-MatchString 'hash mismatch'
        $text | Should-MatchString 're-run pwsh -File script\\setup\.ps1 -Stage apps$'
    }

    It 'a detection error counts as a failure and the others still install' {
        Mock -ModuleName AppsStage Test-WingetPackage {
            if ($Id -eq 'A.One') { throw 'A.One: unexpected winget exit 5' }
            $false
        }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-Invoke -ModuleName AppsStage -CommandName Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $Id -eq 'B.Two' }
        ($script:Warns -join "`n") | Should-MatchString 'unexpected winget exit 5'
    }

    It 'returns reboot-required when a package asks for a restart and none failed' {
        Mock -ModuleName AppsStage Install-WingetPackage { if ($Id -eq 'B.Two') { 'reboot-required' } else { 'installed' } }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'reboot-required'
    }

    It 'a failure wins over a restart' {
        Mock -ModuleName AppsStage Install-WingetPackage { if ($Id -eq 'B.Two') { 'reboot-required' } else { throw 'A.One: network' } }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'failed'
    }

    It '-Plan lists missing packages, counts installed ones and installs nothing' {
        Mock -ModuleName AppsStage Test-WingetPackage { $Id -eq 'A.One' }
        Invoke-AppsStage -Context (Get-TestContext) -Plan | Should-Be 'done'
        $script:Infos | Should-ContainCollection 'Would install Two (B.Two)'
        $script:Infos | Should-ContainCollection 'Already installed: 1'
        Should-NotInvoke -ModuleName AppsStage -CommandName Install-WingetPackage
    }

    It 'warns when winget does not report a package installed right after installing it, without failing' {
        Mock -ModuleName AppsStage Test-WingetPackage { $false }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'done'
        $script:Warns | Should-ContainCollection 'One (A.One) installed but winget does not report it installed; a re-run may reinstall it.'
        Should-Invoke -ModuleName AppsStage -CommandName Test-WingetPackage -Times 4 -Exactly
    }

    It 'does not warn when the post-install check confirms the package' {
        $script:Calls = @{}
        Mock -ModuleName AppsStage Test-WingetPackage {
            $n = 1 + $(if ($script:Calls.ContainsKey($Id)) { $script:Calls[$Id] } else { 0 })
            $script:Calls[$Id] = $n
            $n -gt 1
        }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'done'
        $script:Warns.Count | Should-Be 0
    }

    It '-Plan prints detection failures as warnings and returns failed' {
        Mock -ModuleName AppsStage Test-WingetPackage { if ($Id -eq 'A.One') { throw 'unexpected winget exit 5' } else { $false } }
        Invoke-AppsStage -Context (Get-TestContext) -Plan | Should-Be 'failed'
        $script:Warns | Should-ContainCollection 'Could not check A.One: unexpected winget exit 5'
        $script:Infos | Should-ContainCollection 'Would install Two (B.Two)'
    }

    It 'asks the catalogue for the context profiles' {
        Invoke-AppsStage -Context (Get-TestContext -Profiles @('core', 'dev')) | Out-Null
        Should-Invoke -ModuleName AppsStage -CommandName Get-AppPackages -Times 1 -Exactly -ParameterFilter { ($Profiles -join ',') -eq 'core,dev' }
    }

    It 'installs the font only when core is selected, after the packages' {
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName AppsStage Install-WingetPackage { $script:Order.Add("pkg:$Id"); 'installed' }
        Mock -ModuleName AppsStage Install-NerdFont { $script:Order.Add('font'); 'installed' }
        Invoke-AppsStage -Context (Get-TestContext -Profiles @('core', 'dev')) | Should-Be 'done'
        ($script:Order -join ',') | Should-Be 'pkg:A.One,pkg:B.Two,font'
        $script:Oks | Should-ContainCollection 'Installed JetBrains Mono Nerd Font'
    }

    It 'does not install the font without core' {
        Invoke-AppsStage -Context (Get-TestContext -Profiles @('dev')) | Should-Be 'done'
        Should-NotInvoke -ModuleName AppsStage -CommandName Install-NerdFont
    }

    It 'reports an already installed font without a failure' {
        Mock -ModuleName AppsStage Install-NerdFont { 'already-installed' }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'done'
        $script:Oks | Should-ContainCollection 'JetBrains Mono Nerd Font already installed'
    }

    It 'lists a font failure like a package failure, and the packages still install' {
        Mock -ModuleName AppsStage Install-NerdFont { throw 'SHA256 mismatch' }
        Invoke-AppsStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-Invoke -ModuleName AppsStage -CommandName Install-WingetPackage -Times 2 -Exactly
        ($script:Warns -join "`n") | Should-MatchString 'JetBrains Mono Nerd Font \(SHA256 mismatch\)'
    }

    It '-Plan does not install the font' {
        Invoke-AppsStage -Context (Get-TestContext) -Plan | Should-Be 'done'
        Should-NotInvoke -ModuleName AppsStage -CommandName Install-NerdFont
        $script:Infos | Should-ContainCollection 'Would install JetBrains Mono Nerd Font'
    }
}
