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
        param([string]$Name = 'Ubuntu-26.04', [string]$Url = 'https://example.invalid/x.wsl',
            [string]$Sha = ('a' * 64), [string]$Date = '2026-11-24')
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("lock-$([guid]::NewGuid().ToString('N')).psd1")
        "@{ Name = '$Name'; Url = '$Url'; Sha256 = '$Sha'; Source = 'x'; CheckedOn = '$Date' }" |
            Set-Content -LiteralPath $path -Encoding ascii
        $path
    }
}

Describe 'Save-VerifiedImage' {
    BeforeEach {
        $script:Dir = New-Dir
        Mock -ModuleName Distro Invoke-WebRequest { & $script:WriteFixture }
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns the path when the hash matches' {
        $path = Save-VerifiedImage -Lock $script:Lock -Directory $script:Dir
        $path | Should-Be (Join-Path $script:Dir 'test-image.wsl')
        Test-Path -LiteralPath $path | Should-BeTrue
        Test-Path -LiteralPath "$path.partial" | Should-BeFalse
    }

    It 'throws and deletes the file on mismatch' {
        $bad = $script:Lock.Clone(); $bad.Sha256 = '0' * 64
        { Save-VerifiedImage -Lock $bad -Directory $script:Dir } |
            Should-Throw -ExceptionMessage "*SHA256 mismatch for test-image.wsl: expected $('0' * 64), got $($script:GoodHash)*"
        @(Get-ChildItem -LiteralPath $script:Dir -Force).Count | Should-Be 0
    }

    It 'reuses a matching cached file without downloading' {
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:Dir 'test-image.wsl'), $script:Bytes)
        Save-VerifiedImage -Lock $script:Lock -Directory $script:Dir | Out-Null
        Should-NotInvoke -CommandName Invoke-WebRequest -ModuleName Distro
    }

    It 're-downloads a cached file whose hash does not match' {
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $final = Join-Path $script:Dir 'test-image.wsl'
        [System.IO.File]::WriteAllBytes($final, [byte[]](1, 2, 3))
        Save-VerifiedImage -Lock $script:Lock -Directory $script:Dir | Out-Null
        Should-Invoke -CommandName Invoke-WebRequest -ModuleName Distro -Exactly -Times 1
        (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant() | Should-Be $script:GoodHash
    }

    It 'compares the hash case-insensitively' {
        $upper = $script:Lock.Clone(); $upper.Sha256 = $script:GoodHash.ToUpperInvariant()
        Save-VerifiedImage -Lock $upper -Directory $script:Dir | Should-Be (Join-Path $script:Dir 'test-image.wsl')
    }

    It 'rejects an http:// lock Url without downloading' {
        $http = $script:Lock.Clone(); $http.Url = 'http://example.invalid/test-image.wsl'
        { Save-VerifiedImage -Lock $http -Directory $script:Dir } | Should-Throw -ExceptionMessage '*https*'
        Should-NotInvoke -CommandName Invoke-WebRequest -ModuleName Distro
    }

    It 'restores ProgressPreference after the download' {
        $before = $ProgressPreference
        Save-VerifiedImage -Lock $script:Lock -Directory $script:Dir | Out-Null
        $ProgressPreference | Should-Be $before
    }
}

Describe 'Get-DistroLock' {
    It 'lock file in the repo passes validation' {
        $lock = Get-DistroLock
        $lock.Name | Should-Be 'Ubuntu-26.04'
        ($lock.Url -match '^https://') | Should-BeTrue
        ($lock.Sha256 -cmatch '^[0-9a-f]{64}$') | Should-BeTrue
    }

    It 'the repo lock file is ASCII-only' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Root 'wsl/ubuntu.lock.psd1'))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should-Be 0
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an http Url'; Params = @{ Url = 'http://example.invalid/x.wsl' }; Msg = '*https*' }
        @{ Case = 'an uppercase Sha256'; Params = @{ Sha = ('A' * 64) }; Msg = '*Sha256*' }
        @{ Case = 'a short Sha256'; Params = @{ Sha = 'abc' }; Msg = '*Sha256*' }
        @{ Case = 'a bad Name'; Params = @{ Name = 'Debian' }; Msg = '*Name*' }
        @{ Case = 'a bad CheckedOn'; Params = @{ Date = '24/11/2026' }; Msg = '*CheckedOn*' }
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
        try { $env:USERNAME = '...'; { Get-LinuxUserName } | Should-Throw -ExceptionMessage '*-LinuxUser*' }
        finally { $env:USERNAME = $saved }
    }
    It 'rejects root, reserved and systemd- names' -ForEach @('root', 'nobody', 'sshd', 'systemd-foo') {
        { Get-LinuxUserName -Override $_ } | Should-Throw -ExceptionMessage '*reserved*-LinuxUser*'
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
