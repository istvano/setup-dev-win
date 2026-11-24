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
