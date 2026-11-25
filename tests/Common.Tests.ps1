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

    It 'captures output and a zero exit code through cmd on Windows' -Skip:(-not $IsWindows) {
        $result = Invoke-Native -FilePath 'cmd' -ArgumentList @('/c', 'echo hello & echo oops 1>&2')
        $result.ExitCode | Should-Be 0
        # cmd keeps the space before & and 1>&2 in the echoed text.
        @($result.Output | ForEach-Object { $_.Trim() }) | Should-BeCollection @('hello', 'oops')
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
            $FilePath -eq [Environment]::ProcessPath -and $Verb -eq 'RunAs' -and $Wait -and $PassThru -and
            @($ArgumentList).Count -eq 1 -and
            $ArgumentList -ceq '"-NoProfile" "-File" "/fake/script/elevated/x.ps1" "-A"'
        }
    }

    It 'quotes a script path and an argument that contain spaces' {
        Mock -ModuleName Common Resolve-ElevatedScriptPath { 'C:\Users\John Smith\repo\script\elevated\x.ps1' }
        Mock -ModuleName Common Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $null = Invoke-ElevatedScript -Name 'x' -ArgumentList @('-Root', 'D:\My WSL\')
        Should-Invoke -CommandName Start-Process -ModuleName Common -Exactly -Times 1 -ParameterFilter {
            $ArgumentList -ceq '"-NoProfile" "-File" "C:\Users\John Smith\repo\script\elevated\x.ps1" "-Root" "D:\My WSL\\"'
        }
    }

    Context 'which pwsh is elevated' {
        BeforeEach {
            $script:SavedLocal = $env:LOCALAPPDATA
            $env:LOCALAPPDATA = 'C:\Users\a\AppData\Local'
            $script:Alias = 'C:\Users\a\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
            Mock -ModuleName Common Resolve-ElevatedScriptPath { 'C:\r\script\elevated\x.ps1' }
            Mock -ModuleName Common Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        }
        AfterEach { $env:LOCALAPPDATA = $script:SavedLocal }

        It 'elevates the MSI pwsh by its own path' {
            Mock -ModuleName Common Get-CurrentProcessPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
            $null = Invoke-ElevatedScript -Name 'x'
            Should-Invoke -CommandName Start-Process -ModuleName Common -Exactly -Times 1 -ParameterFilter {
                $FilePath -eq 'C:\Program Files\PowerShell\7\pwsh.exe' -and $Verb -eq 'RunAs' }
        }

        It 'elevates the app execution alias when pwsh runs from the MSIX package (<Path>)' -ForEach @(
            @{ Path = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe' }
            @{ Path = 'C:\Program Files\windowsapps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe' }
        ) {
            Mock -ModuleName Common Get-CurrentProcessPath ([scriptblock]::Create("'$Path'"))
            Mock -ModuleName Common Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:Alias }
            $null = Invoke-ElevatedScript -Name 'x' -ArgumentList @('-Root', 'D:\My WSL')
            Should-Invoke -CommandName Start-Process -ModuleName Common -Exactly -Times 1 -ParameterFilter {
                $FilePath -eq $script:Alias -and $Verb -eq 'RunAs' -and $Wait -and $PassThru -and
                $ArgumentList -ceq '"-NoProfile" "-File" "C:\r\script\elevated\x.ps1" "-Root" "D:\My WSL"' }
        }

        It 'throws naming the alias when the MSIX alias is missing, without prompting' {
            Mock -ModuleName Common Get-CurrentProcessPath { 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe' }
            Mock -ModuleName Common Test-Path { $false } -ParameterFilter { $LiteralPath -eq $script:Alias }
            { Invoke-ElevatedScript -Name 'x' } | Should-Throw -ExceptionMessage "*$($script:Alias)*"
            Should-NotInvoke -CommandName Start-Process -ModuleName Common
        }
    }

    It 'lets a declined UAC prompt surface as a terminating error' {
        Mock -ModuleName Common Resolve-ElevatedScriptPath { '/fake/x.ps1' }
        Mock -ModuleName Common Start-Process { throw 'The operation was canceled by the user.' }
        { Invoke-ElevatedScript -Name 'x' } | Should-Throw -ExceptionMessage '*canceled*'
    }
}

Describe 'ConvertTo-CommandLineArgument' {
    It 'quotes <Name>' -ForEach @(
        @{ Name = 'a plain value'; Value = 'abc'; Expected = '"abc"' }
        @{ Name = 'a space'; Value = 'D:\My WSL'; Expected = '"D:\My WSL"' }
        @{ Name = 'an embedded quote'; Value = 'a"b'; Expected = '"a\"b"' }
        @{ Name = 'backslashes before a quote'; Value = 'a\"b'; Expected = '"a\\\"b"' }
        @{ Name = 'a trailing backslash'; Value = 'D:\My WSL\'; Expected = '"D:\My WSL\\"' }
        @{ Name = 'an empty string'; Value = ''; Expected = '""' }
    ) {
        InModuleScope Common -Parameters @{ Value = $Value; Expected = $Expected } {
            ConvertTo-CommandLineArgument -Value $Value | Should-BeString $Expected
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
