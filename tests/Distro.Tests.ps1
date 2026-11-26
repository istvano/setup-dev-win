Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Distro.psm1') -Force
    $script:Bytes = [System.Text.Encoding]::ASCII.GetBytes('fixture image bytes')
    $script:GoodHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData($script:Bytes)).Replace('-', '').ToLowerInvariant()
    $script:Lock = @{
        Name = 'Ubuntu-26.04'
        Url = 'https://example.invalid/images/test-image.wsl'
        Sha256 = $script:GoodHash
    }
    $script:WriteFixture = { [System.IO.File]::WriteAllBytes($OutFile, $script:Bytes) }
    function script:New-Dir { Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')) }
    function script:New-LockFile {
        param([string]$Name = 'Ubuntu-26.04', [string]$Source = 'https://example.invalid/DistributionInfo.json',
            [string]$Extra = '')
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("lock-$([guid]::NewGuid().ToString('N')).psd1")
        "@{ Name = '$Name'; Source = '$Source'; $Extra }" | Set-Content -LiteralPath $path -Encoding ascii
        $path
    }
    $script:Manifest = Join-Path $PSScriptRoot 'fixtures/distro/DistributionInfo.json'
    $script:ManifestLock = @{ Name = 'Ubuntu-26.04'; Source = 'https://example.invalid/DistributionInfo.json' }
    # The manifest object with one change applied to the Ubuntu-26.04 entry.
    function script:Get-ManifestWith {
        param([scriptblock]$Change)
        $m = Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json
        $entry = @($m.ModernDistributions.Ubuntu | Where-Object Name -EQ 'Ubuntu-26.04')[0]
        & $Change $m $entry
        $m
    }
}

Describe 'Save-VerifiedImage' {
    BeforeEach {
        $script:Dir = New-Dir
        Mock -ModuleName Distro Invoke-WebRequest { & $script:WriteFixture }
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns the path when the hash matches' {
        $path = Save-VerifiedImage -Image $script:Lock -Directory $script:Dir
        $path | Should-Be (Join-Path $script:Dir 'test-image.wsl')
        Test-Path -LiteralPath $path | Should-BeTrue
        Test-Path -LiteralPath "$path.partial" | Should-BeFalse
    }

    It 'throws and deletes the file on mismatch' {
        $bad = $script:Lock.Clone(); $bad.Sha256 = '0' * 64
        { Save-VerifiedImage -Image $bad -Directory $script:Dir } |
            Should-Throw -ExceptionMessage "*SHA256 mismatch for test-image.wsl: expected $('0' * 64), got $($script:GoodHash)*"
        @(Get-ChildItem -LiteralPath $script:Dir -Force).Count | Should-Be 0
    }

    It 'reuses a matching cached file without downloading' {
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:Dir 'test-image.wsl'), $script:Bytes)
        Save-VerifiedImage -Image $script:Lock -Directory $script:Dir | Out-Null
        Should-NotInvoke -CommandName Invoke-WebRequest -ModuleName Distro
    }

    It 're-downloads a cached file whose hash does not match' {
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $final = Join-Path $script:Dir 'test-image.wsl'
        [System.IO.File]::WriteAllBytes($final, [byte[]](1, 2, 3))
        Save-VerifiedImage -Image $script:Lock -Directory $script:Dir | Out-Null
        Should-Invoke -CommandName Invoke-WebRequest -ModuleName Distro -Exactly -Times 1
        (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant() | Should-Be $script:GoodHash
    }

    It 'compares the hash case-insensitively' {
        $upper = $script:Lock.Clone(); $upper.Sha256 = $script:GoodHash.ToUpperInvariant()
        Save-VerifiedImage -Image $upper -Directory $script:Dir | Should-Be (Join-Path $script:Dir 'test-image.wsl')
    }

    It 'creates the directory when it is missing' {
        Test-Path -LiteralPath $script:Dir | Should-BeFalse
        $null = Save-VerifiedImage -Image $script:Lock -Directory $script:Dir
        Test-Path -LiteralPath $script:Dir -PathType Container | Should-BeTrue
    }

    It 'rejects an http:// image Url without downloading' {
        $http = $script:Lock.Clone(); $http.Url = 'http://example.invalid/test-image.wsl'
        { Save-VerifiedImage -Image $http -Directory $script:Dir } | Should-Throw -ExceptionMessage '*https*'
        Should-NotInvoke -CommandName Invoke-WebRequest -ModuleName Distro
    }

    It 'restores ProgressPreference after the download' {
        $before = $ProgressPreference
        Save-VerifiedImage -Image $script:Lock -Directory $script:Dir | Out-Null
        $ProgressPreference | Should-Be $before
    }
}

Describe 'Get-DistroLock' {
    It 'lock file in the repo passes validation and holds only Name and Source' {
        $lock = Get-DistroLock
        $lock.Name | Should-Be 'Ubuntu-26.04'
        $lock.Source | Should-Be 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
        @($lock.Keys | Sort-Object) | Should-BeCollection @('Name', 'Source')
    }

    It 'the repo lock file is ASCII-only' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Root 'wsl/ubuntu.lock.psd1'))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should-Be 0
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an http Source'; Params = @{ Source = 'http://example.invalid/DistributionInfo.json' }; Msg = '*Source*https*' }
        @{ Case = 'an empty Source'; Params = @{ Source = '' }; Msg = "*missing 'Source'*" }
        @{ Case = 'a bad Name'; Params = @{ Name = 'Debian' }; Msg = '*Name*' }
        @{ Case = 'a frozen Url'; Params = @{ Extra = "Url = 'https://example.invalid/x.wsl'" }; Msg = "*'Url'*resolved*" }
        @{ Case = 'a frozen Sha256'; Params = @{ Extra = "Sha256 = '$('a' * 64)'" }; Msg = "*'Sha256'*resolved*" }
    ) {
        $path = New-LockFile @Params
        try { { Get-DistroLock -Path $path } | Should-Throw -ExceptionMessage $Msg }
        finally { Remove-Item -LiteralPath $path -Force }
    }

    It 'accepts a well-formed fixture lock' {
        $path = New-LockFile
        try { (Get-DistroLock -Path $path).Name | Should-Be 'Ubuntu-26.04' }
        finally { Remove-Item -LiteralPath $path -Force }
    }
}

Describe 'Resolve-DistroImage' {
    BeforeEach {
        Mock -ModuleName Distro Invoke-RestMethod { Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json }
    }

    It 'returns the Amd64 Url and the normalised Sha256 of the entry named in the lock' {
        $image = Resolve-DistroImage -Lock $script:ManifestLock
        $image.Name | Should-Be 'Ubuntu-26.04'
        $image.Url | Should-Be 'https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-wsl-amd64.wsl'
        $image.Sha256 | Should-BeString '48d56724b5c8e60f24893e83e73bbb58c60b3ca22fba3da977075420acd54104'
        Should-Invoke -CommandName Invoke-RestMethod -ModuleName Distro -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://example.invalid/DistributionInfo.json' }
    }

    It 'parses a manifest returned as text' {
        Mock -ModuleName Distro Invoke-RestMethod { Get-Content -LiteralPath $script:Manifest -Raw }
        (Resolve-DistroImage -Lock $script:ManifestLock).Url | Should-BeLikeString '*ubuntu-26.04.1-wsl-amd64.wsl'
    }

    It 'accepts a Sha256 without the 0x prefix' {
        $m = Get-ManifestWith { param($m, $e) $e.Amd64Url.Sha256 = ('AB' * 32) }
        Mock -ModuleName Distro Invoke-RestMethod { $m }.GetNewClosure()
        (Resolve-DistroImage -Lock $script:ManifestLock).Sha256 | Should-BeString ('ab' * 32)
    }

    It 'restores ProgressPreference' {
        $before = $ProgressPreference
        $null = Resolve-DistroImage -Lock $script:ManifestLock
        $ProgressPreference | Should-Be $before
    }

    It 'refuses an http Source without fetching' {
        { Resolve-DistroImage -Lock @{ Name = 'Ubuntu-26.04'; Source = 'http://example.invalid/d.json' } } |
            Should-Throw -ExceptionMessage '*https*'
        Should-NotInvoke -CommandName Invoke-RestMethod -ModuleName Distro
    }

    It 'fails closed when the manifest is unreachable' {
        Mock -ModuleName Distro Invoke-RestMethod { throw 'No such host is known.' }
        { Resolve-DistroImage -Lock $script:ManifestLock } |
            Should-Throw -ExceptionMessage '*Could not read the distro manifest https://example.invalid/DistributionInfo.json*No such host*'
    }

    It 'fails closed when the manifest text is not JSON' {
        Mock -ModuleName Distro Invoke-RestMethod { '<html>rate limited</html>' }
        { Resolve-DistroImage -Lock $script:ManifestLock } | Should-Throw -ExceptionMessage '*not valid JSON*'
    }

    It 'fails closed when <Case>' -ForEach @(
        @{
            Case = 'ModernDistributions is missing'; Msg = '*ModernDistributions*'
            Change = { param($m, $e) $m.PSObject.Properties.Remove('ModernDistributions') }
        }
        @{
            Case = 'the entry is missing'; Msg = "*'Ubuntu-26.04'*not found*"
            Change = { param($m, $e) $e.Name = 'Ubuntu-26.10' }
        }
        @{
            Case = 'Amd64Url is missing'; Msg = '*Amd64Url*'
            Change = { param($m, $e) $e.PSObject.Properties.Remove('Amd64Url') }
        }
        @{
            Case = 'the Url is http'; Msg = '*Url*https*'
            Change = { param($m, $e) $e.Amd64Url.Url = 'http://releases.ubuntu.com/x.wsl' }
        }
        @{
            Case = 'the Url is empty'; Msg = '*Url*https*'
            Change = { param($m, $e) $e.Amd64Url.Url = '' }
        }
        @{
            Case = 'the Sha256 is short'; Msg = '*Sha256*64 hex*'
            Change = { param($m, $e) $e.Amd64Url.Sha256 = '0xabc' }
        }
        @{
            Case = 'the Sha256 is not hex'; Msg = '*Sha256*64 hex*'
            Change = { param($m, $e) $e.Amd64Url.Sha256 = ('z' * 64) }
        }
        @{
            Case = 'the Sha256 is missing'; Msg = '*Sha256*'
            Change = { param($m, $e) $e.Amd64Url.PSObject.Properties.Remove('Sha256') }
        }
        @{
            Case = 'the entry appears twice'; Msg = "*'Ubuntu-26.04'*more than once*"
            Change = { param($m, $e) $m.ModernDistributions.Debian[0].Name = 'Ubuntu-26.04' }
        }
    ) {
        $m = Get-ManifestWith -Change $Change
        Mock -ModuleName Distro Invoke-RestMethod { $m }.GetNewClosure()
        { Resolve-DistroImage -Lock $script:ManifestLock } | Should-Throw -ExceptionMessage $Msg
    }

    It 'accepts the host <HostName> in any case' -ForEach @(
        @{ HostName = 'cdimage.ubuntu.com'; Url = 'https://cdimage.ubuntu.com/x/y.wsl' }
        @{ HostName = 'RELEASES.Ubuntu.COM'; Url = 'https://RELEASES.Ubuntu.COM/x/y.WSL' }
    ) {
        $m = Get-ManifestWith { param($m, $e) $e.Amd64Url.Url = $Url }.GetNewClosure()
        Mock -ModuleName Distro Invoke-RestMethod { $m }.GetNewClosure()
        (Resolve-DistroImage -Lock $script:ManifestLock).Url | Should-Be $Url
    }

    It 'refuses the URL <Url> with <Msg>' -ForEach @(
        @{ Url = 'https://evil.example/x/y.wsl'; Msg = '*host*evil.example*not allowed*' }
        @{ Url = 'https://releases.ubuntu.com.evil.example/y.wsl'; Msg = '*host*not allowed*' }
        @{ Url = 'https://evil.example@releases.ubuntu.com.evil.example/y.wsl'; Msg = '*host*not allowed*' }
        @{ Url = 'https://sub.releases.ubuntu.com/y.wsl'; Msg = '*host*not allowed*' }
        @{ Url = 'https://releases.ubuntu.com/x/y.tar.gz'; Msg = '*must end with .wsl*' }
        @{ Url = 'https://releases.ubuntu.com/x/y.wsl/'; Msg = '*must end with .wsl*' }
        @{ Url = 'https://releases.ubuntu.com/x/y.wsl.exe'; Msg = '*must end with .wsl*' }
    ) {
        $m = Get-ManifestWith { param($m, $e) $e.Amd64Url.Url = $Url }.GetNewClosure()
        Mock -ModuleName Distro Invoke-RestMethod { $m }.GetNewClosure()
        { Resolve-DistroImage -Lock $script:ManifestLock } | Should-Throw -ExceptionMessage $Msg
    }
}

Describe 'Clear-ImageCache' {
    BeforeEach {
        Mock -ModuleName Distro Write-Info { }
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        foreach ($n in 'new.wsl', 'old.wsl', 'old.wsl.partial', 'x.partial', 'keep.txt') {
            Set-Content -LiteralPath (Join-Path $script:Dir $n) -Value 'x'
        }
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'sub') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'sub\nested.wsl') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:Dir 'sub\nested.partial') -Value 'x'
    }

    It 'keeps the current image and unrelated files, removes other images and partials, never recurses' {
        Clear-ImageCache -Directory $script:Dir -Keep (Join-Path $script:Dir 'new.wsl')
        $left = @(Get-ChildItem -LiteralPath $script:Dir -File | ForEach-Object Name | Sort-Object)
        ($left -join ',') | Should-Be 'keep.txt,new.wsl'
        Test-Path -LiteralPath (Join-Path $script:Dir 'sub\nested.wsl') | Should-BeTrue
        Test-Path -LiteralPath (Join-Path $script:Dir 'sub\nested.partial') | Should-BeTrue
    }

    It 'does nothing when the directory does not exist' {
        Clear-ImageCache -Directory (Join-Path $script:Dir 'nope') -Keep 'C:\x\a.wsl'
    }
}

Describe 'Get-LinuxUserName' {
    It 'lowercases Istvan.Orban to istvanorban' {
        $saved = $env:USERNAME
        try { $env:USERNAME = 'Istvan.Orban'; Get-LinuxUserName | Should-Be 'istvanorban' }
        finally { $env:USERNAME = $saved }
    }
    It 'uses a valid override as given' {
        Get-LinuxUserName -Override 'dev_user-1' | Should-Be 'dev_user-1'
    }
    It 'throws asking for -LinuxUser when the name sanitises to empty' {
        $saved = $env:USERNAME
        try { $env:USERNAME = '...'; { Get-LinuxUserName } | Should-Throw -ExceptionMessage '*pwsh -File script\setup.ps1 -LinuxUser <name>*' }
        finally { $env:USERNAME = $saved }
    }
    It 'rejects root, reserved and systemd- names' -ForEach @('root', 'nobody', 'sshd', 'systemd-foo') {
        { Get-LinuxUserName -Override $_ } | Should-Throw -ExceptionMessage '*reserved*script\setup.ps1 -LinuxUser <name>*'
    }
    It 'rejects a trailing newline' {
        { Get-LinuxUserName -Override "alice`n" } | Should-Throw -ExceptionMessage '*-LinuxUser*'
    }
    It 'throws for an invalid override' {
        { Get-LinuxUserName -Override '1abc' } | Should-Throw -ExceptionMessage '*-LinuxUser*'
        { Get-LinuxUserName -Override 'a b; rm' } | Should-Throw -ExceptionMessage '*-LinuxUser*'
    }
}

Describe 'New-CloudInitUserData' {
    BeforeEach { $script:Out = Join-Path (New-Dir) 'sub/dev.user-data' }
    AfterEach { Remove-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $script:Out)) -Recurse -Force -ErrorAction SilentlyContinue }

    It 'renders the template with the user name, ASCII, LF, no BOM' {
        New-CloudInitUserData -UserName 'alice' -Path $script:Out
        $bytes = [System.IO.File]::ReadAllBytes($script:Out)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should-Be 0
        ($bytes -contains 13) | Should-BeFalse
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text.StartsWith('#cloud-config') | Should-BeTrue
        ($text -match '  - name: alice\n') | Should-BeTrue
        ($text -match 'default=alice\n') | Should-BeTrue
        ($text -match 'groups: \[sudo\]') | Should-BeTrue
        ($text -match 'shell: /bin/bash') | Should-BeTrue
        ($text -match 'lock_passwd: true') | Should-BeTrue
        ($text -match 'systemd=true') | Should-BeTrue
        ($text -match 'path: /etc/wsl.conf') | Should-BeTrue
        ($text -match '__USER__') | Should-BeFalse
    }
    It 'starts the appended wsl.conf content with an empty line' {
        New-CloudInitUserData -UserName 'alice' -Path $script:Out
        $text = Get-Content -LiteralPath $script:Out -Raw
        ($text -match "content: \|\n\n      \[boot\]\n      systemd=true\n      \[user\]\n      default=alice\n?") | Should-BeTrue
    }
    It 'has the expected structure (line matching, no YAML module in CI)' {
        New-CloudInitUserData -UserName 'alice' -Path $script:Out
        $lines = Get-Content -LiteralPath $script:Out
        $lines[0] | Should-Be '#cloud-config'
        ($lines -contains 'users:') | Should-BeTrue
        ($lines -contains 'write_files:') | Should-BeTrue
    }
    It 'contains no password material' {
        New-CloudInitUserData -UserName 'alice' -Path $script:Out
        $text = Get-Content -LiteralPath $script:Out -Raw
        ($text -match '(?<![a-z_])passwd:|hashed_passwd|plain_text_passwd|ssh_authorized_keys') | Should-BeFalse
    }
    It 'refuses an invalid user name' {
        { New-CloudInitUserData -UserName 'a: b' -Path $script:Out } | Should-Throw -ExceptionMessage '*-LinuxUser*'
        Test-Path -LiteralPath $script:Out | Should-BeFalse
    }
}

Describe 'Get-RegisteredDistro' {
    BeforeAll { . (Join-Path $PSScriptRoot 'TestHelpers.ps1') }
    BeforeEach {
        Mock -ModuleName Distro Get-ChildItem {
            @([pscustomobject]@{ PSPath = 'k1' }, [pscustomobject]@{ PSPath = 'k2' })
        }
        Mock -ModuleName Distro Get-ItemProperty {
            if ($LiteralPath -eq 'k1') {
                [pscustomobject]@{ DistributionName = 'Ubuntu'; BasePath = 'C:\x'; Version = 2; DefaultUid = 1000 }
            }
            else {
                [pscustomobject]@{ DistributionName = 'dev'; BasePath = '\\?\D:\WSL\dev'; Version = 2; DefaultUid = 1000 }
            }
        }
    }
    It 'returns the record with the prefix stripped' {
        $d = Get-RegisteredDistro -Name 'dev'
        $d.Name | Should-Be 'dev'
        $d.BasePath | Should-Be 'D:\WSL\dev'
        $d.Version | Should-Be 2
        $d.DefaultUid | Should-Be 1000
        $d.Version.GetType().Name | Should-Be 'Int32'
    }
    It 'returns null when the name is not registered' {
        Get-RegisteredDistro -Name 'nope' | Should-BeNull
    }
    It 'returns null when the Lxss key is absent' {
        Mock -ModuleName Distro Get-ChildItem { }
        Get-RegisteredDistro -Name 'dev' | Should-BeNull
    }
}

Describe 'Install-DevDistro' {
    BeforeEach {
        $script:HomeDir = New-Dir
        New-Item -ItemType Directory -Path $script:HomeDir | Out-Null
        $script:SavedProfile = $env:USERPROFILE
        $env:USERPROFILE = $script:HomeDir
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:UserDataSeen = $null
        $script:Registered = $null
        $script:CloudExit = 0
        $script:IdUser = 'alice'
        $script:IdUid = '1000'
        Mock -ModuleName Distro Get-RegisteredDistro {
            if ($script:Registered) { $script:Registered }
            elseif ($script:Calls.Count -gt 0) { @{ Name = 'dev'; BasePath = 'D:\WSL\dev'; Version = 2; DefaultUid = 1000 } }
        }
        Mock -ModuleName Distro Invoke-DistroInstall {
            $script:Calls.Add('install ' + ($ArgumentList -join ' '))
            $ud = Join-Path $script:HomeDir '.cloud-init\dev.user-data'
            $script:UserDataSeen = Test-Path -LiteralPath $ud
            return 0
        }
        Mock -ModuleName Distro Invoke-Native {
            $script:Calls.Add(($ArgumentList -join ' '))
            if ($ArgumentList -contains 'cloud-init') { [pscustomobject]@{ ExitCode = $script:CloudExit; Output = @('status: done') } }
            elseif ($ArgumentList -contains '-un') { [pscustomobject]@{ ExitCode = 0; Output = @($script:IdUser) } }
            elseif ($ArgumentList -contains '-u') { [pscustomobject]@{ ExitCode = 0; Output = @($script:IdUid) } }
            else { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        }
    }
    AfterEach {
        $env:USERPROFILE = $script:SavedProfile
        Remove-Item -LiteralPath $script:HomeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'skips install when dev is registered' {
        $script:Registered = @{ Name = 'dev'; BasePath = 'D:\WSL\dev'; Version = 2; DefaultUid = 1000 }
        $r = Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice'
        $r.BasePath | Should-Be 'D:\WSL\dev'
        Should-NotInvoke -CommandName Invoke-DistroInstall -ModuleName Distro
        Should-NotInvoke -CommandName Invoke-Native -ModuleName Distro
        Test-Path -LiteralPath (Join-Path $script:HomeDir '.cloud-init\dev.user-data') | Should-BeFalse
    }
    It 'calls wsl in order: install, cloud-init wait, terminate' {
        Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' | Out-Null
        $script:Calls.Count | Should-Be 6
        $script:Calls[0] | Should-Be 'install --install --from-file C:\i.wsl --name dev --location D:\WSL\dev --no-launch'
        $script:Calls[1] | Should-Be '-d dev -u root -- cloud-init status --wait'
        $script:Calls[2] | Should-Be '--terminate dev'
        $script:Calls[3] | Should-Be '--manage dev --set-default-user alice'
        $script:Calls[4] | Should-Be '-d dev -- id -un'
        $script:Calls[5] | Should-Be '-d dev -- id -u'
    }
    It 'says it is waiting for cloud-init right before the wait' {
        Mock -ModuleName Distro Write-Info { if ($Message -eq 'Waiting for cloud-init to finish (this can take a minute)...') { $script:CallsAtWait = $script:Calls.Count } }
        $script:CallsAtWait = -1
        Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' | Out-Null
        $script:CallsAtWait | Should-Be 1
    }
    It 'writes user-data before the install and deletes it after' {
        Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' | Out-Null
        $script:UserDataSeen | Should-BeTrue
        Test-Path -LiteralPath (Join-Path $script:HomeDir '.cloud-init\dev.user-data') | Should-BeFalse
    }
    It 'returns only the registry record' {
        $r = Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice'
        @($r).Count | Should-Be 1
        $r.Name | Should-Be 'dev'
    }
    It 'accepts cloud-init exit code 2 with a warning and still terminates' {
        $script:CloudExit = 2
        Mock -ModuleName Distro Write-Warn { }
        Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' | Out-Null
        Should-Invoke -CommandName Write-Warn -ModuleName Distro -Times 1 -ParameterFilter { $Message -like '*recoverable*' }
        $script:Calls -contains '--terminate dev' | Should-BeTrue
    }
    It 'warns and continues when --set-default-user is not accepted' {
        Mock -ModuleName Distro Write-Warn { }
        Mock -ModuleName Distro Invoke-Native {
            $script:Calls.Add(($ArgumentList -join ' '))
            if ($ArgumentList -contains '--set-default-user') { [pscustomobject]@{ ExitCode = 1; Output = @('usage') } }
            elseif ($ArgumentList -contains '-un') { [pscustomobject]@{ ExitCode = 0; Output = @('alice') } }
            elseif ($ArgumentList -contains '-u') { [pscustomobject]@{ ExitCode = 0; Output = @('1000') } }
            else { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        }
        Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' | Out-Null
        Should-Invoke -CommandName Write-Warn -ModuleName Distro -ParameterFilter { $Message -like '*set-default-user*' }
    }
    It 'warns and still asserts the default user when --set-default-user throws' {
        Mock -ModuleName Distro Write-Warn { }
        Mock -ModuleName Distro Invoke-Native {
            $script:Calls.Add(($ArgumentList -join ' '))
            if ($ArgumentList -contains '--set-default-user') { throw 'wsl.exe exited with code 4294967295. Invalid command line argument' }
            elseif ($ArgumentList -contains '-un') { [pscustomobject]@{ ExitCode = 0; Output = @('alice') } }
            elseif ($ArgumentList -contains '-u') { [pscustomobject]@{ ExitCode = 0; Output = @('1000') } }
            else { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        }
        Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' | Out-Null
        Should-Invoke -CommandName Write-Warn -ModuleName Distro -Times 1 -ParameterFilter { $Message -like '*set-default-user*failed*4294967295*' }
        $script:Calls -contains '-d dev -- id -un' | Should-BeTrue
    }
    It 'fails with the recovery hint when the effective user is wrong' {
        $script:IdUser = 'root'
        { Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' } |
            Should-Throw -ExceptionMessage "*starts as 'root', expected 'alice'*wsl --unregister dev*setup.ps1 -Stage wsl*"
        Test-Path -LiteralPath (Join-Path $script:HomeDir '.cloud-init\dev.user-data') | Should-BeFalse
    }
    It 'names the missing registry record after a successful install' {
        Mock -ModuleName Distro Get-RegisteredDistro { }
        { Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' } |
            Should-Throw -ExceptionMessage '*dev was installed but no registry record was found*wsl --unregister dev*'
    }
    It 'backs up an existing user-data file first' {
        $dir = Join-Path $script:HomeDir '.cloud-init'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'dev.user-data') -Value 'old'
        Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' | Out-Null
        $backups = @(Get-ChildItem -LiteralPath $dir -Filter 'dev.user-data.backup.*')
        $backups.Count | Should-Be 1
        ($backups[0].Name -match '^dev\.user-data\.backup\.\d{8}T\d{6}Z$') | Should-BeTrue
        (Get-Content -LiteralPath $backups[0].FullName -Raw).Trim() | Should-Be 'old'
        Test-Path -LiteralPath (Join-Path $dir 'dev.user-data') | Should-BeFalse
    }
    It 'throws on another cloud-init code, prints output, and still deletes user-data' {
        $script:CloudExit = 1
        $msg = try { Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice'; '' } catch { $_.Exception.Message }
        ($msg -like '*cloud-init*1*status: done*') | Should-BeTrue
        ([regex]::Matches($msg, [regex]::Escape('wsl --unregister dev'))).Count | Should-Be 1
        Test-Path -LiteralPath (Join-Path $script:HomeDir '.cloud-init\dev.user-data') | Should-BeFalse
    }
    It 'throws with the code when wsl --install fails and deletes user-data' {
        Mock -ModuleName Distro Invoke-DistroInstall { return 7 }
        { Install-DevDistro -ImagePath 'C:\i.wsl' -Root 'D:\WSL' -UserName 'alice' } |
            Should-Throw -ExceptionMessage '*7*'
        Test-Path -LiteralPath (Join-Path $script:HomeDir '.cloud-init\dev.user-data') | Should-BeFalse
        Should-NotInvoke -CommandName Invoke-Native -ModuleName Distro
    }
}

Describe 'Set-DevUserPassword' {
    It 'runs passwd interactively' {
        Mock -ModuleName Distro Test-InteractiveSession { $true }
        Mock -ModuleName Distro Invoke-DistroInteractive { 0 }
        Set-DevUserPassword -UserName 'alice'
        Should-Invoke -CommandName Invoke-DistroInteractive -ModuleName Distro -Times 1 -ParameterFilter {
            ($ArgumentList -join ' ') -eq '-d dev -u root -- passwd alice' }
    }
    It 'warns with the command when not interactive' {
        Mock -ModuleName Distro Test-InteractiveSession { $false }
        Mock -ModuleName Distro Invoke-DistroInteractive { 0 }
        Mock -ModuleName Distro Write-Warn { }
        Set-DevUserPassword -UserName 'alice'
        Should-NotInvoke -CommandName Invoke-DistroInteractive -ModuleName Distro
        Should-Invoke -CommandName Write-Warn -ModuleName Distro -Times 1 -ParameterFilter {
            $Message -like '*wsl -d dev -u root -- passwd alice*' }
    }
    It 'Invoke-DistroInteractive returns exactly one int from the process exit code' {
        $fake = [pscustomobject]@{ Handle = [IntPtr]::Zero; ExitCode = 0 }
        $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
        Mock -ModuleName Distro Start-Process { $fake }
        $r = & (Get-Module Distro) { Invoke-DistroInteractive -ArgumentList '-d', 'dev', '--', 'passwd', 'alice' }
        @($r).Count | Should-Be 1
        ($r -is [int]) | Should-BeTrue
        Should-Invoke -CommandName Start-Process -ModuleName Distro -Times 1 -ParameterFilter {
            $FilePath -eq 'wsl.exe' -and $ArgumentList -eq '-d dev -- passwd alice' -and $NoNewWindow -and $PassThru -and -not $Wait }
    }
    It 'rejects a reserved user name' {
        { Set-DevUserPassword -UserName 'root' } | Should-Throw -ExceptionMessage '*reserved*'
    }
    It 'throws when passwd fails' {
        Mock -ModuleName Distro Test-InteractiveSession { $true }
        Mock -ModuleName Distro Invoke-DistroInteractive { 10 }
        { Set-DevUserPassword -UserName 'alice' } | Should-Throw -ExceptionMessage '*10*'
    }
}

Describe 'Assert-DistroPlacement' {
    It 'passes for a distro under the root, case-insensitively' {
        & { Assert-DistroPlacement -Root 'D:\WSL\' -Distro @{ BasePath = 'd:\wsl\DEV'; Version = 2; DefaultUid = 1000 } }
        & { Assert-DistroPlacement -Root 'D:\WSL' -Distro @{ BasePath = '\\?\D:\WSL\dev\'; Version = 2; DefaultUid = 1000 } }
    }
    It 'throws the exact move instruction for a distro outside the root' {
        $d = @{ BasePath = 'C:\Users\x\AppData\Local\wsl\{guid}'; Version = 2; DefaultUid = 1000 }
        { Assert-DistroPlacement -Distro $d -Root 'D:\WSL' } | Should-Throw -ExceptionMessage `
            'dev is at C:\Users\x\AppData\Local\wsl\{guid}, not under D:\WSL. Move it with: wsl --shutdown; wsl --manage dev --move D:\WSL\dev'
    }
    It 'does not accept a sibling directory sharing the prefix' {
        { Assert-DistroPlacement -Distro @{ BasePath = 'D:\WSL2\dev'; Version = 2; DefaultUid = 1000 } -Root 'D:\WSL' } |
            Should-Throw -ExceptionMessage '*not under D:\WSL*'
    }
    It 'throws for WSL version 1' {
        { Assert-DistroPlacement -Distro @{ BasePath = 'D:\WSL\dev'; Version = 1; DefaultUid = 1000 } -Root 'D:\WSL' } |
            Should-Throw -ExceptionMessage '*WSL 2*'
    }
    It 'does not fail on registry DefaultUid 0 alone' {
        & { Assert-DistroPlacement -Distro @{ BasePath = 'D:\WSL\dev'; Version = 2; DefaultUid = 0 } -Root 'D:\WSL' }
    }
    It 'uses the normalised root in the message' {
        $d = @{ BasePath = 'C:\x'; Version = 2; DefaultUid = 1000 }
        { Assert-DistroPlacement -Distro $d -Root 'D:\WSL\' } | Should-Throw -ExceptionMessage `
            'dev is at C:\x, not under D:\WSL. Move it with: wsl --shutdown; wsl --manage dev --move D:\WSL\dev'
    }
}

Describe 'wsl output parsing' {
    It 'Invoke-Native sets WSL_UTF8 for wsl.exe' {
        $saved = $env:WSL_UTF8
        try {
            $env:WSL_UTF8 = $null
            # No such executable: the variable is set before the call, the call throws.
            { & (Get-Module Distro) { Invoke-Native -FilePath '/nonexistent/wsl.exe' } } | Should-Throw
            $env:WSL_UTF8 | Should-Be '1'
        }
        finally { $env:WSL_UTF8 = $saved }
    }
}

Describe 'Assert-DefaultUser' {
    It 'throws when the effective user differs' {
        Mock -ModuleName Distro Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = @('root') } }
        { Assert-DefaultUser -UserName 'alice' } | Should-Throw -ExceptionMessage "*'root'*'alice'*"
    }
    It 'ignores wsl: noise before the user name and uid' {
        Mock -ModuleName Distro Invoke-Native {
            $noise = 'wsl: A localhost proxy configuration was detected but not mirrored into WSL.'
            if ($ArgumentList -contains '-un') { [pscustomobject]@{ ExitCode = 0; Output = @($noise, "alice`r") } }
            else { [pscustomobject]@{ ExitCode = 0; Output = @($noise, "1000`r", '') } }
        }
        & { Assert-DefaultUser -UserName 'alice' }
    }
    It 'throws when the uid is below 1000' {
        Mock -ModuleName Distro Invoke-Native {
            if ($ArgumentList -contains '-un') { [pscustomobject]@{ ExitCode = 0; Output = @('alice') } }
            else { [pscustomobject]@{ ExitCode = 0; Output = @('999') } }
        }
        { Assert-DefaultUser -UserName 'alice' } | Should-Throw -ExceptionMessage '*>= 1000*'
    }
    It 'throws when the uid is not an integer' {
        Mock -ModuleName Distro Invoke-Native {
            if ($ArgumentList -contains '-un') { [pscustomobject]@{ ExitCode = 0; Output = @('alice') } }
            else { [pscustomobject]@{ ExitCode = 0; Output = @('abc') } }
        }
        { Assert-DefaultUser -UserName 'alice' } | Should-Throw -ExceptionMessage '*>= 1000*'
    }
}
