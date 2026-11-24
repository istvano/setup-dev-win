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


# Name of the distro this repository owns, and the user-data file cloud-init reads.
$script:DistroName = 'dev'
$script:LinuxUserPattern = '^[a-z_][a-z0-9_-]{0,31}$'

function Get-LinuxUserName {
    <#
    .SYNOPSIS
        Returns the Linux user name: the override, else the Windows name sanitised.
    .DESCRIPTION
        The Windows name is lowercased and stripped of anything outside
        [a-z0-9_-]. The result must be a valid Linux login name, otherwise the
        operator is asked for -LinuxUser. The name is later interpolated into
        user-data and a command line, so it is validated either way.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Override)

    if (-not [string]::IsNullOrEmpty($Override)) { $name = $Override }
    else { $name = ([string]$env:USERNAME).ToLowerInvariant() -replace '[^a-z0-9_-]', '' }
    if ($name -cnotmatch $script:LinuxUserPattern) {
        throw "Cannot use '$name' as a Linux user name (must match $script:LinuxUserPattern). Pass -LinuxUser <name>."
    }
    $name
}

function New-CloudInitUserData {
    <#
    .SYNOPSIS
        Renders wsl/user-data.template.yaml for UserName and writes it to Path.
    .DESCRIPTION
        The only substitution is the validated user name. The file is ASCII with LF
        line endings and no BOM, and carries no password or key material.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Path
    )
    if ($UserName -cnotmatch $script:LinuxUserPattern) {
        throw "Cannot use '$UserName' as a Linux user name (must match $script:LinuxUserPattern). Pass -LinuxUser <name>."
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'write cloud-init user-data')) { return }
    $template = Join-Path (Get-RepoRoot) 'wsl/user-data.template.yaml'
    $text = ([System.IO.File]::ReadAllText($template) -replace "`r`n", "`n").Replace('__USER__', $UserName)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::ASCII.GetBytes($text))
}

function ConvertTo-PlainPath {
    # Internal. Strips the \\?\ prefix and trailing backslashes so paths compare.
    param([string]$Path)
    $p = $Path
    if ($p.StartsWith('\\?\', [System.StringComparison]::Ordinal)) { $p = $p.Substring(4) }
    $p.TrimEnd('\')
}

function Get-RegisteredDistro {
    <#
    .SYNOPSIS
        Reads a distro's registration from the Lxss registry key.
    .DESCRIPTION
        [verify on real machine, Task 13] The key, subkey layout and the value names
        DistributionName, BasePath, Version and DefaultUid are WSL internals; this is
        the only place that reads them. BasePath may carry a \\?\ prefix, removed here.
    .OUTPUTS
        $null, or @{ Name; BasePath; Version; DefaultUid }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Name)

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    foreach ($sub in @(Get-ChildItem -Path $key -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $p) { continue }
        $names = $p.PSObject.Properties.Name
        if ('DistributionName' -notin $names -or [string]$p.DistributionName -ne $Name) { continue }
        return @{
            Name = [string]$p.DistributionName
            BasePath = ConvertTo-PlainPath ([string]$(if ('BasePath' -in $names) { $p.BasePath } else { '' }))
            Version = [int]$(if ('Version' -in $names) { $p.Version } else { 0 })
            DefaultUid = [int]$(if ('DefaultUid' -in $names) { $p.DefaultUid } else { -1 })
        }
    }
    $null
}

function Invoke-DistroInstall {
    # Internal, mockable. Runs wsl.exe with output streaming to the host (the
    # install takes minutes and the operator should see it); returns the exit code.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $env:WSL_UTF8 = '1'
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        & wsl.exe @ArgumentList 2>&1 | Out-Host
        return [int]$LASTEXITCODE
    }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function Invoke-DistroInteractive {
    # Internal, mockable. Runs wsl.exe attached to the console (no capture) so the
    # operator can answer prompts; returns the exit code.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        & wsl.exe @ArgumentList
        return [int]$LASTEXITCODE
    }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function Test-InteractiveSession {
    # Internal, mockable. Same check as WslConfig's.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

function Install-DevDistro {
    <#
    .SYNOPSIS
        Installs the verified image as distro dev under <Root>\dev and creates the user.
    .DESCRIPTION
        Idempotent: an already registered dev is returned untouched. Otherwise the
        cloud-init user-data is written, the image is installed, cloud-init is awaited
        and the distro terminated so wsl.conf takes effect on the next start. The
        user-data is first-boot only and holds no secrets; it is deleted even when a
        step fails.
    .OUTPUTS
        The registry record (see Get-RegisteredDistro).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$UserName
    )
    $existing = Get-RegisteredDistro -Name $script:DistroName
    if ($existing) { return $existing }

    $userData = Join-Path (Join-Path $env:USERPROFILE '.cloud-init') 'dev.user-data'
    New-CloudInitUserData -UserName $UserName -Path $userData
    try {
        $location = "$($Root.TrimEnd('\'))\$script:DistroName"
        $code = Invoke-DistroInstall -ArgumentList @('--install', '--from-file', $ImagePath,
            '--name', $script:DistroName, '--location', $location, '--no-launch')
        if ($code -ne 0) { throw "wsl --install exited with code $code." }

        # Exit 2 = done with recoverable errors. [verify on real machine, Task 13]
        $wait = Invoke-Native -FilePath 'wsl.exe' -AllowExitCode (1..255) -ArgumentList @(
            '-d', $script:DistroName, '-u', 'root', '--', 'cloud-init', 'status', '--wait')
        if ($wait.ExitCode -notin 0, 2) {
            throw "cloud-init status --wait exited with code $($wait.ExitCode): $($wait.Output -join [Environment]::NewLine)"
        }
        if ($wait.ExitCode -eq 2) { Write-Warn 'cloud-init finished with recoverable errors; check /var/log/cloud-init.log in dev.' }

        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('--terminate', $script:DistroName) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $userData -Force -ErrorAction SilentlyContinue
    }
    Get-RegisteredDistro -Name $script:DistroName
}

function Set-DevUserPassword {
    <#
    .SYNOPSIS
        Sets the Linux user's password with passwd, interactively.
    .DESCRIPTION
        The password is typed into passwd and never passes through this script. The
        Linux bootstrap needs it for sudo. A non-interactive run only warns.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserName)
    if ($UserName -cnotmatch $script:LinuxUserPattern) { throw "Invalid Linux user name '$UserName'." }
    $wslArgs = @('-d', $script:DistroName, '-u', 'root', '--', 'passwd', $UserName)
    if (-not (Test-InteractiveSession)) {
        Write-Warn "Not interactive: set the password later with: wsl -d $($script:DistroName) -u root -- passwd $UserName"
        return
    }
    if (-not $PSCmdlet.ShouldProcess("dev user $UserName", 'set password')) { return }
    $code = Invoke-DistroInteractive -ArgumentList $wslArgs
    if ($code -ne 0) { throw "passwd exited with code $code." }
}

function Assert-DistroPlacement {
    <#
    .SYNOPSIS
        Throws unless the dev distro lives under Root, is WSL 2 and does not default to root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Distro,
        [Parameter(Mandatory)][string]$Root
    )
    $base = ConvertTo-PlainPath ([string]$Distro.BasePath)
    $rootPlain = ConvertTo-PlainPath $Root
    if (-not $base.StartsWith("$rootPlain\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "dev is at $($Distro.BasePath), not under $Root. Move it with: wsl --shutdown; wsl --manage dev --move $Root\dev"
    }
    if ([int]$Distro.Version -ne 2) { throw "dev is WSL version $($Distro.Version); it must be WSL 2." }
    if ([int]$Distro.DefaultUid -eq 0) { throw 'dev defaults to root (DefaultUid 0); the cloud-init user was not applied.' }
}

Export-ModuleMember -Function Get-DistroLock, Save-VerifiedImage, Get-LinuxUserName, New-CloudInitUserData,
Get-RegisteredDistro, Install-DevDistro, Set-DevUserPassword, Assert-DistroPlacement
