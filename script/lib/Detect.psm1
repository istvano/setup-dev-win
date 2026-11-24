#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Get-EditionInfo {
    <#
    .SYNOPSIS
        Returns the Windows edition and whether it is Home or Pro.
    .DESCRIPTION
        Reads EditionID from the registry (no elevation needed; Get-WindowsEdition
        is a DISM cmdlet that requires it). Core maps to Home and Professional to
        Pro; any other value is neither and the caller decides. The two strings are
        to be verified on the real machine (ADR-008).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $edition = [string](Get-ItemProperty -Path $key).EditionID
    @{
        Edition = $edition
        IsHome = ($edition -eq 'Core')
        IsPro = ($edition -eq 'Professional')
    }
}

function Get-OsBuild {
    <#
    .SYNOPSIS
        Returns the OS build number.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    [int][Environment]::OSVersion.Version.Build
}

function Test-DataVolume {
    <#
    .SYNOPSIS
        Checks that a drive letter is an existing, fixed, NTFS volume.
    .PARAMETER DriveLetter
        The drive letter to check.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][char]$DriveLetter)
    try {
        $volume = Get-Volume -DriveLetter $DriveLetter
    }
    catch {
        $volume = $null
    }
    if (-not $volume) { return @{ Ok = $false; Reason = "Volume ${DriveLetter}: not found." } }
    if ($volume.FileSystem -ne 'NTFS') {
        return @{ Ok = $false; Reason = "Volume ${DriveLetter}: is $($volume.FileSystem); NTFS is required." }
    }
    if ($volume.DriveType -ne 'Fixed') {
        return @{ Ok = $false; Reason = "Volume ${DriveLetter}: is $($volume.DriveType); a fixed drive is required." }
    }
    @{ Ok = $true; Reason = '' }
}

function Test-DocumentsRedirected {
    <#
    .SYNOPSIS
        True when the Documents folder is redirected (for example by OneDrive Known Folder Move).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $props = Get-ItemProperty -Path $key
    if (-not $props.PSObject.Properties['Personal']) { return $false }
    $actual = [Environment]::ExpandEnvironmentVariables([string]$props.Personal)
    $default = Join-Path $HOME 'Documents'
    $normalise = { param($p) ($p -replace '\\', '/').TrimEnd('/') }
    return -not [string]::Equals((& $normalise $actual), (& $normalise $default), [StringComparison]::OrdinalIgnoreCase)
}

function Test-VirtualizationAvailable {
    <#
    .SYNOPSIS
        True when a hypervisor is present or firmware virtualization is enabled.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ((Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent) { return $true }
    return @(Get-CimInstance -ClassName Win32_Processor).VirtualizationFirmwareEnabled -contains $true
}

function Get-KernelDmaProtectionState {
    <#
    .SYNOPSIS
        Reports Kernel DMA Protection as on, off or unknown. Report only.
    .DESCRIPTION
        Reads the DeviceGuard AvailableSecurityProperties (value 3 is DMA
        protection). That is availability, not proof of enforcement, which is why
        nothing acts on this result.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $guard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard
        if (-not $guard) { return 'unknown' }
        if (@($guard.AvailableSecurityProperties) -contains 3) { return 'on' }
        return 'off'
    }
    catch {
        return 'unknown'
    }
}

Export-ModuleMember -Function Get-EditionInfo, Get-OsBuild, Test-DataVolume, Test-DocumentsRedirected,
Test-VirtualizationAvailable, Get-KernelDmaProtectionState
