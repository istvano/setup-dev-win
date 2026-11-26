Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Font.psm1') -Force
    $script:Hex = ('a' * 64)
    function script:New-Release {
        param([string]$Name = 'JetBrainsMono.zip', $Digest = "sha256:$($script:Hex)", [string]$Url = 'https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.zip')
        $asset = [ordered]@{ name = $Name; browser_download_url = $Url }
        if ($null -ne $Digest) { $asset.digest = $Digest }
        [pscustomobject]@{ tag_name = 'v3.4.0'; assets = @([pscustomobject]@{ name = 'Other.zip'; browser_download_url = 'https://github.com/x/Other.zip'; digest = "sha256:$($script:Hex)" }, [pscustomobject]$asset) }
    }
    function script:New-FontZip {
        param([string]$Path, [string[]]$Entries)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try {
            foreach ($e in $Entries) {
                $entry = $zip.CreateEntry($e)
                $w = [System.IO.StreamWriter]::new($entry.Open())
                $w.Write("data:$e")
                $w.Dispose()
            }
        }
        finally { $zip.Dispose() }
    }
}

Describe 'Resolve-NerdFontRelease' {
    It 'reads the latest release API and returns Tag, Url and Sha256 of JetBrainsMono.zip' {
        $release = New-Release; Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        $r = Resolve-NerdFontRelease
        $r.Tag | Should-Be 'v3.4.0'
        $r.Url | Should-Be 'https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.zip'
        $r.Sha256 | Should-Be $script:Hex
    }

    It 'normalises an upper-case digest' {
        $release = New-Release -Digest ('SHA256:' + ('A' * 64)); Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        (Resolve-NerdFontRelease).Sha256 | Should-Be $script:Hex
    }

    It 'asks the documented API URL' {
        $release = New-Release; Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        Resolve-NerdFontRelease | Out-Null
        Should-Invoke -ModuleName Font -CommandName Get-NerdFontReleaseJson -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest' }
    }

    It 'throws when the asset is missing' {
        $release = New-Release -Name 'JetBrainsMonoX.zip'; Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        { Resolve-NerdFontRelease } | Should-Throw '*JetBrainsMono.zip*'
    }

    It 'throws when the digest is missing' {
        $release = New-Release -Digest $null; Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        { Resolve-NerdFontRelease } | Should-Throw '*digest*'
    }

    It 'throws on a malformed digest' -ForEach @('md5:abc', 'sha256:abc', "sha256:$('g' * 64)", ('a' * 64)) {
        $d = $_
        $release = New-Release -Digest $d; Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        { Resolve-NerdFontRelease } | Should-Throw '*digest*'
    }

    It 'throws on a non-https URL' {
        $release = New-Release -Url 'http://github.com/ryanoasis/nerd-fonts/releases/download/v1/JetBrainsMono.zip'; Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        { Resolve-NerdFontRelease } | Should-Throw '*https*'
    }

    It 'throws on a host outside the allowlist' {
        $release = New-Release -Url 'https://evil.example.com/JetBrainsMono.zip'; Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        { Resolve-NerdFontRelease } | Should-Throw '*not allowed*'
    }

    It 'accepts the GitHub asset hosts' -ForEach @('github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com') {
        $h = $_
        $release = New-Release -Url "https://$h/JetBrainsMono.zip"; Mock -ModuleName Font Get-NerdFontReleaseJson { $release }.GetNewClosure()
        (Resolve-NerdFontRelease).Url | Should-Be "https://$h/JetBrainsMono.zip"
    }
}

Describe 'Test-NerdFontInstalled' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) "font-test-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'JetBrainsMonoNerdFontMono-Regular.ttf') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:Dir 'arial.ttf') -Value 'x'
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'is true when a matching registry value points at an existing file' {
        Mock -ModuleName Font Get-FontRegistryMap { @{ 'JetBrainsMonoNerdFontMono-Regular (TrueType)' = (Join-Path $script:Dir 'JetBrainsMonoNerdFontMono-Regular.ttf') } }
        Test-NerdFontInstalled | Should-BeTrue
    }

    It 'is false when the file is gone' {
        Mock -ModuleName Font Get-FontRegistryMap { @{ 'JetBrainsMonoNerdFontMono-Regular (TrueType)' = (Join-Path $script:Dir 'gone.ttf') } }
        Test-NerdFontInstalled | Should-BeFalse
    }

    It 'is false when only unrelated fonts are registered' {
        Mock -ModuleName Font Get-FontRegistryMap { @{ 'Arial (TrueType)' = (Join-Path $script:Dir 'arial.ttf') } }
        Test-NerdFontInstalled | Should-BeFalse
    }
}

Describe 'Install-NerdFont' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) "font-test-$([guid]::NewGuid())"
        $script:FontsDir = Join-Path $script:Work 'Fonts'
        New-Item -ItemType Directory -Path $script:Work | Out-Null
        $script:Registered = @{}
        $script:ZipPath = $null
        $script:Installed = $false
        $script:Entries = @('JetBrainsMonoNerdFontMono-Regular.ttf', 'JetBrainsMonoNerdFontMono-Bold.ttf', 'JetBrainsMonoNerdFont-Regular.ttf', 'JetBrainsMonoNLNerdFontMono-Regular.ttf', 'OFL.txt', '../evil/JetBrainsMonoNerdFontMono-Evil.ttf')
        Mock -ModuleName Font Test-NerdFontInstalled { $script:Installed }
        Mock -ModuleName Font Get-UserFontsDirectory { $script:FontsDir }
        Mock -ModuleName Font Register-FontFile { $script:Registered[$Name] = $Path }
        Mock -ModuleName Font Write-Info { }
        Mock -ModuleName Font Resolve-NerdFontRelease { @{ Tag = 'v3.4.0'; Url = 'https://github.com/x/JetBrainsMono.zip'; Sha256 = 'x' } }
        $script:MakeZip = ${function:New-FontZip}
        Mock -ModuleName Font Receive-FontArchive {
            $script:ZipPath = $OutFile
            & $script:MakeZip -Path $OutFile -Entries $script:Entries
        }
        Mock -ModuleName Font Get-FileHash { [pscustomobject]@{ Hash = 'X' } }
        Mock -ModuleName Font Resolve-NerdFontRelease { @{ Tag = 'v3.4.0'; Url = 'https://github.com/x/JetBrainsMono.zip'; Sha256 = 'x' } }
    }
    AfterEach { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns already-installed without any web call' {
        $script:Installed = $true
        Install-NerdFont | Should-Be 'already-installed'
        Should-NotInvoke -ModuleName Font -CommandName Resolve-NerdFontRelease
        Should-NotInvoke -ModuleName Font -CommandName Receive-FontArchive
    }

    It 'installs only JetBrainsMonoNerdFontMono-*.ttf, by leaf name, and registers them' {
        Install-NerdFont | Should-Be 'installed'
        $names = @(Get-ChildItem -LiteralPath $script:FontsDir | Select-Object -ExpandProperty Name | Sort-Object)
        ($names -join ',') | Should-Be 'JetBrainsMonoNerdFontMono-Bold.ttf,JetBrainsMonoNerdFontMono-Evil.ttf,JetBrainsMonoNerdFontMono-Regular.ttf'
        (Test-Path -LiteralPath (Join-Path $script:Work 'evil')) | Should-BeFalse
        $script:Registered.Count | Should-Be 3
        $script:Registered['JetBrainsMonoNerdFontMono-Regular (TrueType)'] | Should-Be (Join-Path $script:FontsDir 'JetBrainsMonoNerdFontMono-Regular.ttf')
    }

    It 'verifies with SHA256 and deletes the zip on success' {
        Install-NerdFont | Out-Null
        Should-Invoke -ModuleName Font -CommandName Get-FileHash -Times 1 -Exactly -ParameterFilter { $Algorithm -eq 'SHA256' }
        (Test-Path -LiteralPath $script:ZipPath) | Should-BeFalse
    }

    It 'throws on a hash mismatch, installs nothing and deletes the zip' {
        Mock -ModuleName Font Get-FileHash { [pscustomobject]@{ Hash = 'DEADBEEF' } }
        { Install-NerdFont } | Should-Throw '*SHA256 mismatch*'
        (Test-Path -LiteralPath $script:FontsDir) | Should-BeFalse
        $script:Registered.Count | Should-Be 0
        (Test-Path -LiteralPath $script:ZipPath) | Should-BeFalse
    }

    It 'throws when the archive holds no matching font' {
        $script:Entries = @('OFL.txt')
        { Install-NerdFont } | Should-Throw '*no JetBrainsMonoNerdFontMono*'
        (Test-Path -LiteralPath $script:ZipPath) | Should-BeFalse
    }

    It 'deletes the zip when the download fails' {
        Mock -ModuleName Font Receive-FontArchive { $script:ZipPath = $OutFile; Set-Content -LiteralPath $OutFile -Value 'partial'; throw 'network down' }
        { Install-NerdFont } | Should-Throw '*network down*'
        (Test-Path -LiteralPath $script:ZipPath) | Should-BeFalse
    }
}
