Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Common.psm1') -Force
    Import-Module (Join-Path $script:Root 'script/lib/BrowserProfiles.psm1') -Force
}

Describe 'Test-BrowserProfileName' {
    It 'accepts <_>' -ForEach @('personal', 'work', 'cloud-admin', 'a.b_c-1', '9lives') {
        Test-BrowserProfileName -Name $_ | Should-BeTrue
    }
    It 'refuses <_>' -ForEach @('', 'Work', "work`n", 'con', 'CON', 'nul', 'aux', 'prn', 'com1', 'lpt9', 'a.', 'work.', '../escape', 'a/b', 'a\b', '-lead', '.hidden', 'sp ace', 'quo"te', 'a:b') {
        Test-BrowserProfileName -Name $_ | Should-BeFalse
    }
}

Describe 'Test-BrowserProfileName reserved names' {
    It 'accepts names that only contain a reserved word' -ForEach @('console', 'com10', 'null', 'my-con', 'lpt0') {
        Test-BrowserProfileName -Name $_ | Should-BeTrue
    }
}

Describe 'Get-BrowserProfileRoot' {
    It 'lives under LOCALAPPDATA\setup-dev-win\browsers' {
        $env:LOCALAPPDATA = 'L'
        InModuleScope BrowserProfiles { Get-BrowserProfileRoot } | Should-Be (Join-Path (Join-Path 'L' 'setup-dev-win') 'browsers')
    }
    It 'fails closed when LOCALAPPDATA is unset' {
        $saved = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = ''
            { InModuleScope BrowserProfiles { Get-BrowserProfileRoot } } | Should-Throw
        }
        finally { $env:LOCALAPPDATA = $saved }
    }
}

Describe 'Initialize-BrowserProfile and Get-BrowserProfile' {
    BeforeEach {
        $script:Base = Join-Path $TestDrive "browsers-$([guid]::NewGuid().ToString('N'))"
        Mock -ModuleName BrowserProfiles Get-BrowserProfileRoot { $script:Base }
    }

    It 'creates one directory per browser and profile' {
        Initialize-BrowserProfile -Name work
        Test-Path -LiteralPath (Join-Path (Join-Path $script:Base 'chrome') 'work') -PathType Container | Should-BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $script:Base 'firefox') 'work') -PathType Container | Should-BeTrue
    }
    It 'is idempotent' {
        Initialize-BrowserProfile -Name work
        { Initialize-BrowserProfile -Name work } | Should -Not -Throw
    }
    It 'refuses an invalid name and creates nothing' {
        { Initialize-BrowserProfile -Name '../escape' } | Should-Throw
        Test-Path -LiteralPath $script:Base | Should-BeFalse
    }
    It 'refuses a symlinked profile path' -Skip:(-not ($IsLinux -or $IsMacOS)) {
        $outside = Join-Path $TestDrive 'outside'
        $null = New-Item -ItemType Directory -Path $outside
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Base 'chrome')
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path (Join-Path $script:Base 'chrome') 'linked') -Target $outside
        { Initialize-BrowserProfile -Name linked } | Should-Throw
    }
    It 'refuses a link in any ancestor between LOCALAPPDATA and the profile' -Skip:(-not ($IsLinux -or $IsMacOS)) {
        $env:LOCALAPPDATA = Join-Path $TestDrive "la-$([guid]::NewGuid().ToString('N'))"
        $outside = Join-Path $TestDrive "elsewhere-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $outside, $env:LOCALAPPDATA
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $env:LOCALAPPDATA 'setup-dev-win') -Target $outside
        Mock -ModuleName BrowserProfiles Get-BrowserProfileRoot { Join-Path (Join-Path $env:LOCALAPPDATA 'setup-dev-win') 'browsers' }
        { Initialize-BrowserProfile -Name work } | Should-Throw -ExceptionMessage '*linked*'
        Test-Path -LiteralPath (Join-Path $outside 'browsers') | Should-BeFalse
    }
    It 'lists browser and name, sorted, and ignores files' {
        Initialize-BrowserProfile -Name work
        Initialize-BrowserProfile -Name personal
        Set-Content -LiteralPath (Join-Path (Join-Path $script:Base 'chrome') 'stray.txt') -Value x
        $rows = @(Get-BrowserProfile)
        ($rows | ForEach-Object { "$($_.Browser)/$($_.Name)" }) | Should-BeCollection @(
            'chrome/personal', 'chrome/work', 'firefox/personal', 'firefox/work')
    }
    It 'lists nothing when the root does not exist' {
        @(Get-BrowserProfile).Count | Should-Be 0
    }
}

Describe 'Get-BrowserExecutable' {
    BeforeEach {
        $env:ProgramFiles = 'P'
        ${env:ProgramFiles(x86)} = 'X'
        $env:LOCALAPPDATA = 'L'
        $script:Existing = @()
        Mock -ModuleName BrowserProfiles Test-BrowserFile { $script:Existing -contains $Path }
    }
    It 'finds Chrome in Program Files' {
        $script:Existing = @((Join-Path 'P' 'Google/Chrome/Application/chrome.exe'))
        Get-BrowserExecutable -Browser chrome | Should-Be (Join-Path 'P' 'Google/Chrome/Application/chrome.exe')
    }
    It 'finds a per-user Chrome' {
        $script:Existing = @((Join-Path 'L' 'Google/Chrome/Application/chrome.exe'))
        Get-BrowserExecutable -Browser chrome | Should-Be (Join-Path 'L' 'Google/Chrome/Application/chrome.exe')
    }
    It 'finds Firefox in Program Files' {
        $script:Existing = @((Join-Path 'P' 'Mozilla Firefox/firefox.exe'))
        Get-BrowserExecutable -Browser firefox | Should-Be (Join-Path 'P' 'Mozilla Firefox/firefox.exe')
    }
    It 'returns null when the browser is absent' {
        Get-BrowserExecutable -Browser firefox | Should-BeNull
    }
    It 'lists where it looked' {
        $places = InModuleScope BrowserProfiles { Get-BrowserSearchPath -Browser chrome }
        $places.Count | Should-Be 3
        $places | Should-ContainCollection @((Join-Path 'P' 'Google/Chrome/Application/chrome.exe'))
    }
}

Describe 'Open-BrowserProfile' {
    BeforeEach {
        $script:Base = Join-Path $TestDrive "open-$([guid]::NewGuid().ToString('N'))"
        Mock -ModuleName BrowserProfiles Get-BrowserProfileRoot { $script:Base }
        Mock -ModuleName BrowserProfiles Get-BrowserExecutable { "X:\$Browser.exe" }
        $script:Started = $null
        Mock -ModuleName BrowserProfiles Start-BrowserProcess { $script:Started = @{ Path = $FilePath; Args = @($ArgumentList) } }
    }

    It 'starts Chrome with --user-data-dir on its own data root' {
        Open-BrowserProfile -Browser chrome -Name work
        $script:Started.Path | Should-Be 'X:\chrome.exe'
        $script:Started.Args.Count | Should-Be 1
        $script:Started.Args[0] | Should-Be ('"--user-data-dir=' + (Join-Path (Join-Path $script:Base 'chrome') 'work') + '"')
        Test-Path -LiteralPath (Join-Path (Join-Path $script:Base 'chrome') 'work') -PathType Container | Should-BeTrue
    }
    It 'starts Firefox with -no-remote and -profile on its own data root' {
        Open-BrowserProfile -Browser firefox -Name work
        $script:Started.Path | Should-Be 'X:\firefox.exe'
        $script:Started.Args | Should-BeCollection @('-no-remote', '-profile', ('"' + (Join-Path (Join-Path $script:Base 'firefox') 'work') + '"'))
    }
    It 'only ever passes a data dir that is a child of the isolated root' {
        Open-BrowserProfile -Browser chrome -Name personal
        $dir = ($script:Started.Args[0] -replace '^"--user-data-dir=', '') -replace '"$', ''
        (Split-Path -Parent (Split-Path -Parent $dir)) | Should-Be $script:Base
        Open-BrowserProfile -Browser firefox -Name personal
        $dir = $script:Started.Args[2].Trim('"')
        (Split-Path -Parent (Split-Path -Parent $dir)) | Should-Be $script:Base
    }
    It 'fails with the profile hint when the browser is not installed' {
        Mock -ModuleName BrowserProfiles Get-BrowserExecutable { $null }
        { Open-BrowserProfile -Browser chrome -Name work } | Should-Throw -ExceptionMessage '*productivity-extra*'
        Should-NotInvoke -ModuleName BrowserProfiles -CommandName Start-BrowserProcess
    }
    It 'refuses an invalid name before starting anything' {
        { Open-BrowserProfile -Browser chrome -Name 'Bad Name' } | Should-Throw
        Should-NotInvoke -ModuleName BrowserProfiles -CommandName Start-BrowserProcess
    }
    It 'refuses an unknown browser' {
        { Open-BrowserProfile -Browser edge -Name work } | Should-Throw
    }
}

Describe 'Invoke-BrowserProfileCommand' {
    BeforeEach {
        Mock -ModuleName BrowserProfiles Write-Ok { }
        Mock -ModuleName BrowserProfiles Write-Warn { $script:Warned += $Message }
        Mock -ModuleName BrowserProfiles Test-IsElevated { $false }
        Mock -ModuleName BrowserProfiles Initialize-BrowserProfile { $script:Made += $Name }
        Mock -ModuleName BrowserProfiles Open-BrowserProfile { $script:Opened = "$Browser/$Name" }
        Mock -ModuleName BrowserProfiles Get-BrowserProfile { @([pscustomobject]@{ Browser = 'chrome'; Name = 'work' }) }
        $script:Made = @()
        $script:Warned = @()
        $script:Opened = $null
    }
    It 'ensure-defaults creates personal and work' {
        Invoke-BrowserProfileCommand -Command 'ensure-defaults' | Should-Be 0
        $script:Made | Should-BeCollection @('personal', 'work')
    }
    It 'add creates the named profile' {
        Invoke-BrowserProfileCommand -Command 'add' -Argument @('cloud-admin') | Should-Be 0
        $script:Made | Should-BeCollection @('cloud-admin')
    }
    It 'add without a name fails' {
        Invoke-BrowserProfileCommand -Command 'add' | Should-Be 1
    }
    It 'open passes browser and name through' {
        Invoke-BrowserProfileCommand -Command 'open' -Argument @('firefox', 'work') | Should-Be 0
        $script:Opened | Should-Be 'firefox/work'
    }
    It 'open with the wrong argument count fails' {
        Invoke-BrowserProfileCommand -Command 'open' -Argument @('firefox') | Should-Be 1
    }
    It 'an unknown command prints usage and fails' {
        $script:Hosted = @()
        Mock -ModuleName BrowserProfiles Write-Host { $script:Hosted += [string]$Object }
        Invoke-BrowserProfileCommand -Command 'nuke' | Should-Be 1
        ($script:Hosted -join "`n") | Should -Match 'Usage:'
        ($script:Warned -join ' ') | Should -Match 'Unknown command: nuke'
    }
    It '<_> prints usage and succeeds' -ForEach @('help', '-h', '--help') {
        $script:Hosted = @()
        Mock -ModuleName BrowserProfiles Write-Host { $script:Hosted += [string]$Object }
        Invoke-BrowserProfileCommand -Command $_ | Should-Be 0
        ($script:Hosted -join "`n") | Should -Match 'ensure-defaults'
        $script:Made.Count | Should-Be 0
    }
    It 'help with extra arguments is still usage' {
        Mock -ModuleName BrowserProfiles Write-Host { }
        Invoke-BrowserProfileCommand -Command 'help' -Argument @('x') | Should-Be 0
    }
    It 'list is the default and succeeds' {
        Invoke-BrowserProfileCommand | Should-Be 0
    }
    It 'refuses to run elevated' {
        Mock -ModuleName BrowserProfiles Test-IsElevated { $true }
        Invoke-BrowserProfileCommand -Command 'ensure-defaults' | Should-Be 1
        $script:Made.Count | Should-Be 0
    }
    It 'turns a thrown error into exit 1 with a warning' {
        Mock -ModuleName BrowserProfiles Initialize-BrowserProfile { throw 'boom' }
        Invoke-BrowserProfileCommand -Command 'add' -Argument @('x') | Should-Be 1
        ($script:Warned -join ' ') | Should -Match 'boom'
    }
}

Describe 'script/browser-profile.ps1' {
    It 'never elevates and never touches a default browser profile' {
        $text = (Get-Content -LiteralPath (Join-Path $script:Root 'script/browser-profile.ps1'), (Join-Path $script:Root 'script/lib/BrowserProfiles.psm1') -Raw) -join "`n"
        $text | Should -Not -Match 'RunAs|Invoke-ElevatedScript'
        $text | Should -Not -Match 'User Data\\Default|Firefox\\Profiles'
    }
}
