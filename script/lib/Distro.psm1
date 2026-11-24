#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

function Get-DistroLock {
    <#
    .SYNOPSIS
        Reads and validates the pinned distro image lock (wsl/ubuntu.lock.psd1).
    .DESCRIPTION
        The lock is the supply-chain anchor for the Linux environment: image URL and
        SHA256 copied from Microsoft's DistributionInfo.json. Throws a message naming
        the field for every violation.
    .PARAMETER Path
        Lock file. Defaults to <repo>/wsl/ubuntu.lock.psd1; tests pass fixtures.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path = (Join-Path (Get-RepoRoot) 'wsl/ubuntu.lock.psd1'))

    if (-not (Test-Path -LiteralPath $Path)) { throw "Distro lock not found: $Path" }
    $lock = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($key in 'Name', 'Url', 'Sha256', 'CheckedOn') {
        if (-not $lock.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$lock[$key])) {
            throw "Distro lock $Path is missing '$key'."
        }
    }
    if ([string]$lock.Name -cnotmatch '^Ubuntu-\d\d\.\d\d$') {
        throw "Distro lock Name '$($lock.Name)' must match ^Ubuntu-\d\d\.\d\d$."
    }
    if (-not ([string]$lock.Url).StartsWith('https://', [System.StringComparison]::Ordinal)) {
        throw "Distro lock Url '$($lock.Url)' must start with https://."
    }
    if ([string]$lock.Sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Distro lock Sha256 must be 64 lowercase hex characters, got '$($lock.Sha256)'."
    }
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$lock.CheckedOn, 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw "Distro lock CheckedOn '$($lock.CheckedOn)' must be a yyyy-MM-dd date."
    }
    $lock
}

function Save-VerifiedImage {
    <#
    .SYNOPSIS
        Downloads the locked image into Directory and verifies its SHA256.
    .DESCRIPTION
        Downloads to <leaf>.partial and renames only after the hash matches. A cached
        file is reused only when its hash matches; otherwise it is deleted and fetched
        again. A mismatch deletes the partial file and throws. https only.
    .OUTPUTS
        The full path of the verified image.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Lock,
        [Parameter(Mandatory)][string]$Directory
    )

    $url = [string]$Lock.Url
    if (-not $url.StartsWith('https://', [System.StringComparison]::Ordinal)) {
        throw "Refusing to download '$url': only https URLs are allowed."
    }
    $expected = ([string]$Lock.Sha256).ToLowerInvariant()
    $leaf = [System.IO.Path]::GetFileName(([uri]$url).AbsolutePath)
    if ([string]::IsNullOrEmpty($leaf)) { throw "Cannot derive a file name from '$url'." }

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $final = Join-Path $Directory $leaf
    $partial = "$final.partial"

    if (Test-Path -LiteralPath $final) {
        $cached = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($cached -eq $expected) { return $final }
        Write-Warn "Cached $leaf has the wrong hash; downloading it again."
        Remove-Item -LiteralPath $final -Force
    }
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }

    Write-Info "Downloading $leaf"
    # The progress bar makes Invoke-WebRequest very slow in Windows PowerShell and 7.
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $partial }
    catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
    finally { $ProgressPreference = $savedProgress }

    $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $partial -Force
        throw "SHA256 mismatch for ${leaf}: expected $expected, got $actual"
    }
    Move-Item -LiteralPath $partial -Destination $final -Force
    $final
}

Export-ModuleMember -Function Get-DistroLock, Save-VerifiedImage
