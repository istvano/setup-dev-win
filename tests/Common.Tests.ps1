Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Lib = Join-Path (Split-Path -Parent $PSScriptRoot) 'script/lib'
    Import-Module (Join-Path $script:Lib 'Common.psm1') -Force
}

Describe 'Invoke-Native' {
    BeforeAll {
        # A command that exits 3, per platform.
        if ($IsWindows) {
            $script:Exit3 = @{ FilePath = 'cmd'; ArgumentList = @('/c', 'exit 3') }
        }
        else {
            $script:Exit3 = @{ FilePath = '/bin/sh'; ArgumentList = @('-c', 'exit 3') }
        }
    }

    It 'throws on an unexpected exit code' {
        { Invoke-Native @script:Exit3 } | Should-Throw -ExceptionMessage '*exited with code 3*'
    }

    It 'allows listed exit codes and reports them' {
        $result = Invoke-Native @script:Exit3 -AllowExitCode 3
        $result.ExitCode | Should-Be 3
    }

    It 'captures output and a zero exit code' -Skip:(-not $IsLinux) {
        $result = Invoke-Native -FilePath '/bin/sh' -ArgumentList @('-c', 'echo hello; echo oops 1>&2')
        $result.ExitCode | Should-Be 0
        $result.Output | Should-BeCollection @('hello', 'oops')
    }

    It 'sets WSL_UTF8 only for wsl' -Skip:(-not $IsLinux) {
        $env:WSL_UTF8 = $null
        $null = Invoke-Native -FilePath '/bin/sh' -ArgumentList @('-c', 'exit 0')
        $env:WSL_UTF8 | Should-BeNull
        $dir = Join-Path $TestDrive 'bin'
        $null = New-Item -ItemType Directory -Path $dir
        $fake = Join-Path $dir 'wsl'
        Set-Content -LiteralPath $fake -Value "#!/bin/sh`necho `$WSL_UTF8"
        chmod +x $fake
        $result = Invoke-Native -FilePath $fake
        $result.Output | Should-BeCollection @('1')
        $env:WSL_UTF8 = $null
    }
}

Describe 'Invoke-ElevatedScript' {
    It 'refuses <Name>' -ForEach @(
        @{ Name = '..\setup' }
        @{ Name = '../setup' }
        @{ Name = '/etc/passwd' }
        @{ Name = 'C:\Windows\system32\evil' }
        @{ Name = '..' }
    ) {
        { Invoke-ElevatedScript -Name $Name } | Should-Throw -ExceptionMessage '*Refusing*'
    }

    It 'reports a missing script under script/elevated' {
        { Invoke-ElevatedScript -Name 'no-such-script' } | Should-Throw -ExceptionMessage '*not found*'
    }

    It 'resolves a script inside the elevated root' {
        InModuleScope Common -Parameters @{ Root = $TestDrive } {
            $null = New-Item -ItemType Directory -Path (Join-Path $Root 'elevated')
            $file = Join-Path (Join-Path $Root 'elevated') 'ok.ps1'
            Set-Content -LiteralPath $file -Value '# x'
            Resolve-ElevatedScriptPath -Name 'ok' -ElevatedRoot (Join-Path $Root 'elevated') |
                Should-Be ([System.IO.Path]::GetFullPath($file))
        }
    }

    It 'runs the resolved path in an elevated pwsh and returns its exit code' {
        Mock -ModuleName Common Resolve-ElevatedScriptPath { '/fake/script/elevated/x.ps1' }
        Mock -ModuleName Common Start-Process { [pscustomobject]@{ ExitCode = 7 } }
        Invoke-ElevatedScript -Name 'x' -ArgumentList @('-A') | Should-Be 7
        Should-Invoke -CommandName Start-Process -ModuleName Common -Exactly -Times 1 -ParameterFilter {
            $FilePath -eq 'pwsh' -and $Verb -eq 'RunAs' -and $Wait -and $PassThru -and
            ($ArgumentList -join '|') -eq '-NoProfile|-File|/fake/script/elevated/x.ps1|-A'
        }
    }
}

Describe 'Test-IsElevated and Get-RepoRoot' {
    It 'returns a bool without throwing' {
        Test-IsElevated | Should-HaveType ([bool])
    }

    It 'is false on non-Windows' -Skip:$IsWindows {
        Test-IsElevated | Should-BeFalse
    }

    It 'finds the repository root' {
        Test-Path -LiteralPath (Join-Path (Get-RepoRoot) 'script/lib/Common.psm1') | Should-BeTrue
    }
}

Describe 'Stop-Fatal' {
    It 'throws the message' {
        { Stop-Fatal -Message 'boom' } | Should-Throw -ExceptionMessage 'boom'
    }
}
