Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Common.psm1') -Force
    Import-Module (Join-Path $script:Root 'script/lib/VSCode.psm1') -Force
}

Describe 'the declared extension list file' {
    It 'holds exactly the four Windows-side ids, each with a purpose comment' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Root 'vscode/extensions.list') | Where-Object { $_ -notmatch '^\s*(#|$)' })
        $lines.Count | Should-Be 4
        foreach ($line in $lines) { $line | Should -Match '^\S+ # \S' }
        $ids = @(Get-VSCodeExtensionList)
        $ids | Should-BeCollection @('ms-vscode-remote.remote-wsl', 'ms-vscode-remote.remote-ssh', 'ms-vscode-remote.remote-containers', 'vscode-icons-team.vscode-icons')
    }
}

Describe 'Get-VSCodeExtensionList' {
    It 'ignores comments and blank lines and lower-cases ids' {
        Mock -ModuleName VSCode Read-VSCodeExtensionListFile {
            @('# header', '', '   ', 'Pub.Ext-One # why', '  pub.two   ', '#pub.three')
        }
        @(Get-VSCodeExtensionList) | Should-BeCollection @('pub.ext-one', 'pub.two')
    }
}

Describe 'Get-VSCodeCli' {
    BeforeEach {
        $env:LOCALAPPDATA = 'L'
        $env:ProgramFiles = 'P'
        $script:PerUser = Join-Path 'L' 'Programs/Microsoft VS Code/bin/code.cmd'
        $script:PerMachine = Join-Path 'P' 'Microsoft VS Code/bin/code.cmd'
        $script:Existing = @()
        Mock -ModuleName VSCode Find-CommandOnPath { $script:OnPath }
        Mock -ModuleName VSCode Test-VSCodeFile { $script:Existing -contains $Path }
        $script:OnPath = $null
    }

    It 'prefers code.cmd on PATH' {
        $script:OnPath = 'X:\bin\code.cmd'
        $script:Existing = @($script:PerUser, $script:PerMachine)
        Get-VSCodeCli | Should-Be 'X:\bin\code.cmd'
    }
    It 'finds a per-user install when PATH is stale' {
        $script:Existing = @($script:PerUser)
        Get-VSCodeCli | Should-Be $script:PerUser
    }
    It 'finds a per-machine install when PATH is stale' {
        $script:Existing = @($script:PerMachine)
        Get-VSCodeCli | Should-Be $script:PerMachine
    }
    It 'prefers the per-user install over per-machine' {
        $script:Existing = @($script:PerUser, $script:PerMachine)
        Get-VSCodeCli | Should-Be $script:PerUser
    }
    It 'returns null when VS Code is absent' {
        Get-VSCodeCli | Should-BeNull
    }
}

Describe 'extension install and detection' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Installed = @('MS-VSCode-Remote.Remote-WSL', 'other.thing')
        $script:FailId = @()
        Mock -ModuleName VSCode Get-VSCodeExtensionList { @('ms-vscode-remote.remote-wsl', 'ms-vscode-remote.remote-ssh', 'vscode-icons-team.vscode-icons') }
        Mock -ModuleName VSCode Get-VSCodeCli { 'C:\code.cmd' }
        Mock -ModuleName VSCode Invoke-Native {
            $script:Calls.Add(($ArgumentList -join ' '))
            if ($ArgumentList[0] -eq '--list-extensions') { return [pscustomobject]@{ ExitCode = 0; Output = $script:Installed } }
            if ($ArgumentList[1] -in $script:FailId) { throw "exit 1 installing $($ArgumentList[1])" }
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
    }

    It 'lists only missing extensions, comparing case-insensitively' {
        @(Get-MissingVSCodeExtensions) | Should-BeCollection @('ms-vscode-remote.remote-ssh', 'vscode-icons-team.vscode-icons')
    }
    It 'returns nothing missing when VS Code is absent' {
        Mock -ModuleName VSCode Get-VSCodeCli { $null }
        @(Get-MissingVSCodeExtensions).Count | Should-Be 0
    }
    It 'installs only the missing ones, with no version' {
        $r = Install-VSCodeExtensions
        $r.Installed | Should-BeCollection @('ms-vscode-remote.remote-ssh', 'vscode-icons-team.vscode-icons')
        @($r.Failed).Count | Should-Be 0
        $script:Calls | Should-BeCollection @('--list-extensions', '--install-extension ms-vscode-remote.remote-ssh', '--install-extension vscode-icons-team.vscode-icons')
    }
    It 'reports one failure as id (reason) and still installs the others' {
        $script:FailId = @('ms-vscode-remote.remote-ssh')
        $r = Install-VSCodeExtensions
        $r.Installed | Should-BeCollection @('vscode-icons-team.vscode-icons')
        $r.Failed | Should-BeCollection @('ms-vscode-remote.remote-ssh (exit 1 installing ms-vscode-remote.remote-ssh)')
    }
    It 'never calls --uninstall-extension' {
        $script:Installed = @('other.thing')
        Install-VSCodeExtensions | Out-Null
        ($script:Calls -join "`n") | Should -Not -Match 'uninstall'
    }
}
