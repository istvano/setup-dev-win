#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

# JetBrains Mono Nerd Font, per user, from the newest upstream release. winget has
# no Nerd Font package that tracks upstream and a local manifest needs an admin
# setting, so the release zip is verified (GitHub's published SHA256) and only the
# Mono TTFs are copied to the per-user fonts directory. No elevation.
$script:ReleaseApi = 'https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest'
$script:AssetName = 'JetBrainsMono.zip'
$script:AllowedHosts = @('github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com')
$script:FontPattern = 'JetBrainsMonoNerdFontMono-*.ttf'
$script:RegistryKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

function Get-NerdFontReleaseJson {
    # Internal (mockable). The latest release as a parsed object.
    param([Parameter(Mandatory)][string]$Uri)
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-RestMethod -Uri $Uri -Headers @{ 'User-Agent' = 'setup-dev-win'; Accept = 'application/vnd.github+json' } }
    finally { $ProgressPreference = $savedProgress }
}

function Receive-FontArchive {
    # Internal (mockable). Downloads Url to OutFile; redirects are followed.
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Url -UseBasicParsing -OutFile $OutFile -Headers @{ 'User-Agent' = 'setup-dev-win' } }
    finally { $ProgressPreference = $savedProgress }
}

function Get-UserFontsDirectory {
    # Internal (mockable). The per-user fonts directory.
    Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
}

function Get-FontRegistryMap {
    # Internal (mockable). Name -> value of the per-user font registry key.
    $entries = @{}
    if (-not (Test-Path -LiteralPath $script:RegistryKey)) { return $entries }
    $item = Get-ItemProperty -LiteralPath $script:RegistryKey
    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -notlike 'PS*') { $entries[$property.Name] = [string]$property.Value }
    }
    $entries
}

function Register-FontFile {
    # Internal (mockable). Registers one font for the current user.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $script:RegistryKey)) { New-Item -Path $script:RegistryKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $script:RegistryKey -Name $Name -Value $Path -PropertyType String -Force | Out-Null
}

function Get-JsonMember {
    # Internal. A property of a ConvertFrom-Json object, or $null when absent.
    param($Object, [string]$Name)
    if ($null -eq $Object -or $Object -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Resolve-NerdFontRelease {
    <#
    .SYNOPSIS
        Resolves the newest JetBrainsMono.zip release asset: Tag, Url and Sha256.
    .DESCRIPTION
        Reads the latest release from the GitHub API and takes the asset named
        exactly JetBrainsMono.zip with its published digest (sha256:<64 hex>).
        The URL must be https on github.com or GitHub's asset hosts. Fails closed
        on a missing asset, a missing or malformed digest or a foreign URL.
    .OUTPUTS
        @{ Tag; Url; Sha256 }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    try { $release = Get-NerdFontReleaseJson -Uri $script:ReleaseApi }
    catch { throw "Could not read the Nerd Fonts release from $($script:ReleaseApi): $($_.Exception.Message)" }
    $tag = [string](Get-JsonMember -Object $release -Name 'tag_name')
    $asset = @(@(Get-JsonMember -Object $release -Name 'assets') | Where-Object { [string](Get-JsonMember -Object $_ -Name 'name') -ceq $script:AssetName })
    if ($asset.Count -ne 1) { throw "The latest Nerd Fonts release '$tag' has no asset named exactly $($script:AssetName)." }
    $url = [string](Get-JsonMember -Object $asset[0] -Name 'browser_download_url')
    if (-not $url.StartsWith('https://', [System.StringComparison]::Ordinal)) {
        throw "The $($script:AssetName) URL '$url' must start with https://."
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) { throw "The $($script:AssetName) URL '$url' is not a valid URL." }
    if ($uri.Host.ToLowerInvariant() -notin $script:AllowedHosts) {
        throw "The $($script:AssetName) URL '$url' has host '$($uri.Host)', which is not allowed (expected $($script:AllowedHosts -join ', '))."
    }
    $digest = ([string](Get-JsonMember -Object $asset[0] -Name 'digest')).Trim().ToLowerInvariant()
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "The $($script:AssetName) asset has digest '$digest'; expected sha256:<64 hex characters>."
    }
    @{ Tag = $tag; Url = $url; Sha256 = $digest.Substring(7) }
}

function Test-NerdFontInstalled {
    <#
    .SYNOPSIS
        True when a JetBrainsMonoNerdFontMono-*.ttf registry value points at an existing file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $entries = Get-FontRegistryMap
    foreach ($name in $entries.Keys) {
        $path = [string]$entries[$name]
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $leaf = ($path -split '[\\/]')[-1]
        if ($leaf -like $script:FontPattern -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
    }
    $false
}

function Install-NerdFont {
    <#
    .SYNOPSIS
        Installs JetBrains Mono Nerd Font Mono for the current user.
    .DESCRIPTION
        Downloads the newest upstream JetBrainsMono.zip, verifies its SHA256,
        copies only JetBrainsMonoNerdFontMono-*.ttf (by leaf name, never the entry
        path) to the per-user fonts directory and registers each under HKCU. The
        zip is deleted afterwards either way. No elevation, no web call when the
        font is already installed.
    .OUTPUTS
        installed or already-installed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (Test-NerdFontInstalled) { return 'already-installed' }
    $release = Resolve-NerdFontRelease
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "JetBrainsMono-$([guid]::NewGuid()).zip"
    try {
        Write-Info "Downloading JetBrains Mono Nerd Font $($release.Tag)"
        Receive-FontArchive -Url $release.Url -OutFile $zipPath
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $release.Sha256) {
            throw "SHA256 mismatch for $($script:AssetName): expected $($release.Sha256), got $actual"
        }
        $fontsDir = Get-UserFontsDirectory
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $wanted = @($zip.Entries | Where-Object { (($_.FullName -split '[\\/]')[-1]) -like $script:FontPattern })
            if ($wanted.Count -eq 0) { throw "The $($script:AssetName) archive has no JetBrainsMonoNerdFontMono-*.ttf entries." }
            if (-not (Test-Path -LiteralPath $fontsDir)) { New-Item -ItemType Directory -Path $fontsDir -Force | Out-Null }
            foreach ($entry in $wanted) {
                $leaf = ($entry.FullName -split '[\\/]')[-1]
                $target = Join-Path $fontsDir $leaf
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                Register-FontFile -Name "$([System.IO.Path]::GetFileNameWithoutExtension($leaf)) (TrueType)" -Path $target
            }
        }
        finally { $zip.Dispose() }
    }
    finally { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
    'installed'
}

Export-ModuleMember -Function Resolve-NerdFontRelease, Install-NerdFont, Test-NerdFontInstalled
