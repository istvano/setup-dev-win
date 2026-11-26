Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Common.psm1') -Force
    Import-Module (Join-Path $script:Root 'script/lib/Winget.psm1') -Force
}

Describe 'Test-WingetPackage' {
    It 'asks winget list with exactly the documented arguments' {
        Mock -ModuleName Winget Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = [string[]]@() } }
        Test-WingetPackage -Id 'Git.Git' | Out-Null
        Should-Invoke -CommandName Invoke-Native -ModuleName Winget -Exactly 1 -ParameterFilter {
            $FilePath -eq 'winget.exe' -and
            ($ArgumentList -join ' ') -eq 'list --id Git.Git --exact --source winget --accept-source-agreements --disable-interactivity'
        }
    }
    It 'checks the Microsoft Store source when asked' {
        Mock -ModuleName Winget Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = [string[]]@() } }
        Test-WingetPackage -Id '9PLM9XGG6VKS' -Source msstore | Out-Null
        Should-Invoke -CommandName Invoke-Native -ModuleName Winget -Exactly 1 -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'list --id 9PLM9XGG6VKS --exact --source msstore --accept-source-agreements --disable-interactivity'
        }
    }
    It 'refuses a source other than winget and msstore' {
        { Test-WingetPackage -Id 'Git.Git' -Source 'other' } | Should-Throw
    }
    It 'is true on exit 0 even when the printed table does not contain the Id' {
        Mock -ModuleName Winget Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = [string[]]@('Name  Id', 'Some Long Pack...') } }
        Test-WingetPackage -Id 'Some.LongPackageIdentifier' | Should-BeTrue
    }
    It 'is false on exit -1978335212 (no packages found)' {
        Mock -ModuleName Winget Invoke-Native { [pscustomobject]@{ ExitCode = -1978335212; Output = [string[]]@() } }
        Test-WingetPackage -Id 'Git.Git' | Should-BeFalse
    }
    It 'allows exactly the not-found code' {
        Mock -ModuleName Winget Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = [string[]]@() } }
        Test-WingetPackage -Id 'Git.Git' | Out-Null
        Should-Invoke -CommandName Invoke-Native -ModuleName Winget -Exactly 1 -ParameterFilter {
            ($AllowExitCode -join ',') -eq '-1978335212'
        }
    }
    It 'throws on any other code, naming the Id and keeping the code' {
        Mock -ModuleName Winget Invoke-Native { throw 'winget.exe exited with code 5. some tail' }
        { Test-WingetPackage -Id 'Git.Git' } | Should-Throw -ExceptionMessage '*Git.Git*code 5*some tail*'
    }
}

Describe 'Install-WingetPackage' {
    BeforeEach {
        $script:Code = 0
        Mock -ModuleName Winget Invoke-Native {
            [pscustomobject]@{ ExitCode = $script:Code; Output = [string[]]@() }
        }
    }
    It 'calls winget install with exactly the documented arguments and no scope by default' {
        Install-WingetPackage -Id 'Git.Git' | Out-Null
        Should-Invoke -CommandName Invoke-Native -ModuleName Winget -Exactly 1 -ParameterFilter {
            $FilePath -eq 'winget.exe' -and
            ($ArgumentList -join ' ') -eq 'install --id Git.Git --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
        }
    }
    It 'adds --scope only when given' {
        Install-WingetPackage -Id 'Git.Git' -Scope user | Out-Null
        Should-Invoke -CommandName Invoke-Native -ModuleName Winget -Exactly 1 -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'install --id Git.Git --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --scope user'
        }
    }
    It 'installs from the Microsoft Store source when asked' {
        Install-WingetPackage -Id '9PLM9XGG6VKS' -Source msstore | Out-Null
        Should-Invoke -CommandName Invoke-Native -ModuleName Winget -Exactly 1 -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'install --id 9PLM9XGG6VKS --exact --source msstore --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
        }
    }
    It 'exit 0 is installed' {
        Install-WingetPackage -Id 'Git.Git' | Should-Be 'installed'
    }
    It 'exit <Code> is already-installed' -ForEach @(
        @{ Code = -1978335189 }, @{ Code = -1978335135 }, @{ Code = -1978334963 }
    ) {
        $script:Code = $Code
        Install-WingetPackage -Id 'Git.Git' | Should-Be 'already-installed'
    }
    It 'exit -1978334967 is reboot-required' {
        $script:Code = -1978334967
        Install-WingetPackage -Id 'Git.Git' | Should-Be 'reboot-required'
    }
    It 'allows every mapped code through Invoke-Native' {
        Install-WingetPackage -Id 'Git.Git' | Out-Null
        Should-Invoke -CommandName Invoke-Native -ModuleName Winget -Exactly 1 -ParameterFilter {
            $expected = @(-1978335189, -1978335135, -1978334963, -1978334967, -1978334966, -1978334964, -2147023673, -1978335215, -1978335174, -1978334961)
            @($expected | Where-Object { $_ -notin $AllowExitCode }).Count -eq 0
        }
    }
    It 'exit -1978334964 throws naming the Id, code, cancellation and UAC' {
        $script:Code = -1978334964
        { Install-WingetPackage -Id 'Git.Git' } | Should-Throw -ExceptionMessage '*Git.Git*-1978334964*cancelled*UAC*'
    }
    It 'exit -2147023673 (ERROR_CANCELLED from an elevating exe installer) is the same UAC cancellation' {
        $script:Code = -2147023673
        { Install-WingetPackage -Id 'Git.Git' } | Should-Throw -ExceptionMessage '*Git.Git*-2147023673*cancelled*UAC*'
    }
    It 'exit -1978335212 on install says no package with this Id is in its source' {
        $script:Code = -1978335212
        { Install-WingetPackage -Id 'Git.Git' } | Should-Throw -ExceptionMessage '*Git.Git*-1978335212*no package with this Id*source*'
    }
    It 'exit -1978335215 throws mentioning the hash' {
        $script:Code = -1978335215
        { Install-WingetPackage -Id 'Git.Git' } | Should-Throw -ExceptionMessage '*hash*'
    }
    It 'exit <Code> throws mentioning policy' -ForEach @(@{ Code = -1978335174 }, @{ Code = -1978334961 }) {
        $script:Code = $Code
        { Install-WingetPackage -Id 'Git.Git' } | Should-Throw -ExceptionMessage '*policy*'
    }
    It 'exit -1978334966 throws telling the operator to restart Windows, then re-run' {
        $script:Code = -1978334966
        { Install-WingetPackage -Id 'Git.Git' } | Should-Throw -ExceptionMessage '*restart Windows, then re-run*'
    }
    It 'an unmapped failure throws naming the Id, the code and winget''s tail' {
        Mock -ModuleName Winget Invoke-Native { throw 'winget.exe exited with code 1603. some tail' }
        { Install-WingetPackage -Id 'Git.Git' } | Should-Throw -ExceptionMessage '*Git.Git*1603*some tail*'
    }
}

Describe 'Get-WingetInstalledIds' {
    BeforeEach {
        $script:Seen = $null
        $script:Json = '{"Sources":[{"Packages":[{"PackageIdentifier":"Git.Git"},{"PackageIdentifier":"Obsidian.Obsidian"}],"SourceDetails":{"Name":"winget"}}]}'
        Mock -ModuleName Winget Invoke-Native {
            $script:Seen = $ArgumentList
            $path = $ArgumentList[$ArgumentList.IndexOf('--output') + 1]
            Set-Content -LiteralPath $path -Value $script:Json -Encoding utf8
            [pscustomobject]@{ ExitCode = 0; Output = [string[]]@() }
        }
    }
    It 'exports with the documented arguments and returns the Ids' {
        $ids = Get-WingetInstalledIds
        $ids | Should-BeCollection @('Git.Git', 'Obsidian.Obsidian')
        $script:Seen[0] | Should-Be 'export'
        $script:Seen[1] | Should-Be '--output'
        ($script:Seen[3..($script:Seen.Count - 1)] -join ' ') | Should-Be '--source winget --accept-source-agreements --disable-interactivity'
    }
    It 'deletes the temp file after success' {
        Get-WingetInstalledIds | Out-Null
        Test-Path -LiteralPath $script:Seen[2] | Should-BeFalse
    }
    It 'deletes the temp file and throws when the JSON is unparseable' {
        $script:Json = '{not json'
        { Get-WingetInstalledIds } | Should-Throw
        Test-Path -LiteralPath $script:Seen[2] | Should-BeFalse
    }
    It 'returns no Ids, without error, when Sources or Packages are missing' {
        $script:Json = '{"Sources":[{"SourceDetails":{}}]}'
        @(Get-WingetInstalledIds).Count | Should-Be 0
        $script:Json = '{}'
        @(Get-WingetInstalledIds).Count | Should-Be 0
    }
    It 'returns no Ids when the export file is empty' {
        $script:Json = ''
        @(Get-WingetInstalledIds).Count | Should-Be 0
    }
}
