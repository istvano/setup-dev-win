#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# The read-only Windows security and privacy report (script/hardening-check.ps1).
#
# Rules this module keeps, and tests/Repo.Tests.ps1 enforces:
#   * It only reads. No registry write, no Set-/Enable-/Disable-/Remove- cmdlet in code,
#     no netsh add/set/delete, no elevation. A recommendation may NAME such a command,
#     but only inside a string literal, which the test excludes from its scan.
#   * Every check reads through one small internal function, so tests mock the reader.
#   * Cmdlets that exist only on Windows (Defender, NetSecurity, BitLocker, Hyper-V
#     firewall) are called only inside those readers. A missing cmdlet, an absent value
#     or a read that needs elevation yields UNKNOWN, never RECOMMEND and never an error.

$libRoot = $PSScriptRoot
Import-Module (Join-Path $libRoot 'Common.psm1') -Force
Import-Module (Join-Path $libRoot 'Detect.psm1') -Force
Import-Module (Join-Path $libRoot 'WindowsFeatures.psm1') -Force
Import-Module (Join-Path $libRoot 'Winget.psm1') -Force

$script:WslHyperVVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
# 'LM Studio': the owning process name still needs confirming on hardware. com.docker.backend and
# vpnkit are Docker Desktop's host-side listeners.
$script:ListenerProcesses = @('wslrelay', 'vmmem', 'vmmemWSL', 'docker-proxy', 'com.docker.backend', 'vpnkit', 'LM Studio')
$script:ElevatedMessage = 'needs an elevated terminal'

# ---------------------------------------------------------------- shared helpers

function Assert-CmdletAvailable {
    # Internal. Throws when a Windows-only cmdlet is not on this machine (module missing).
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Name)
    if ($null -eq (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is not available on this machine"
    }
}

function Invoke-PostureRead {
    # Internal. Runs a read. When the read fails for lack of rights in a non-elevated
    # terminal, the failure becomes the one stable reason, instead of a raw error.
    # NeedsAdmin: the read is known to need elevation, so any failure there means so.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [switch]$NeedsAdmin
    )
    try {
        & $Script
    }
    catch {
        $denied = $_.Exception -is [UnauthorizedAccessException] -or
        "$($_.Exception.PSObject.Properties['NativeErrorCode']?.Value)" -eq 'AccessDenied' -or
        $_.Exception.Message -match 'access (is )?denied|requires elevat|administrator privilege|0x80070005|0x80041003|permission denied'
        if (-not (Test-IsElevated) -and ($NeedsAdmin -or $denied)) { throw $script:ElevatedMessage }
        throw
    }
}

function Get-PostureRegistryValue {
    # Internal, mockable. A registry value, or $null when the key or the value is absent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $property = (Get-ItemProperty -LiteralPath $Path).PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RequiredRegistryValue {
    # Internal. Like Get-PostureRegistryValue, but an absent value is an UNKNOWN reason.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $value = Get-PostureRegistryValue -Path $Path -Name $Name
    if ($null -eq $value) { throw "$Name is not set (the Windows default applies and cannot be read here)" }
    return $value
}

function ConvertTo-OnOff {
    # Internal. 1/true -> on, 0/false -> off.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [bool]) { return $(if ($Value) { 'on' } else { 'off' }) }
    return $(if ([int]$Value -ne 0) { 'on' } else { 'off' })
}

# ---------------------------------------------------------------- Platform readers

function Get-SecureBootState {
    # Microsoft: https://learn.microsoft.com/windows-hardware/design/device-experience/oem-secure-boot
    # UEFISecureBootEnabled is the value Confirm-SecureBootUEFI reports; it needs no elevation.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = Get-RequiredRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled'
    return ConvertTo-OnOff -Value $value
}

function Get-TpmState {
    # Microsoft: https://learn.microsoft.com/windows-server/administration/windows-commands/tpmtool
    # tpmtool getdeviceinformation prints "-TPM Present: True" and "-TPM Version: 2.0".
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $result = Invoke-Native -FilePath 'tpmtool.exe' -ArgumentList @('getdeviceinformation')
    $present = $false
    $seen = $false
    $version = ''
    foreach ($line in $result.Output) {
        if ($line -match 'TPM Present:\s*(\w+)') { $present = $Matches[1] -eq 'True'; $seen = $true }
        if ($line -match 'TPM Version:\s*([\d.]+)') { $version = $Matches[1] }
    }
    if (-not $seen) { throw 'tpmtool did not report whether a TPM is present' }
    if (-not $present) { return 'absent' }
    if (-not $version) { throw 'tpmtool did not report a TPM version' }
    return "present, $version"
}

function Get-DeviceGuardInstance {
    # Internal. Microsoft: https://learn.microsoft.com/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity
    # Win32_DeviceGuard lives in root\Microsoft\Windows\DeviceGuard and is readable without elevation.
    [CmdletBinding()]
    param()
    $guard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard
    if (-not $guard) { throw 'Win32_DeviceGuard returned nothing' }
    return $guard
}

function Get-HvciState {
    # SecurityServicesRunning: 1 Credential Guard, 2 Memory integrity (HVCI).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $guard = Get-DeviceGuardInstance
    return $(if (@($guard.SecurityServicesRunning) -contains 2) { 'running' } else { 'not running' })
}

function Get-VbsState {
    # VirtualizationBasedSecurityStatus: 0 off, 1 enabled but not running, 2 running.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $guard = Get-DeviceGuardInstance
    switch ([int]$guard.VirtualizationBasedSecurityStatus) {
        2 { return 'running' }
        1 { return 'enabled, not running' }
        default { return 'off' }
    }
}

function Get-LsaProtectionState {
    # Microsoft: https://learn.microsoft.com/windows-server/security/credentials-protection-and-management/configuring-additional-lsa-protection
    # RunAsPPL 1 (with UEFI lock) or 2 (without) is on. 24H2 can enable it by default
    # without writing the value, so an absent value is UNKNOWN, not a recommendation.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = Get-RequiredRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'
    return $(if ([int]$value -in 1, 2) { 'on' } else { 'off' })
}

function Get-KernelDmaState {
    # Reuses the repository helper (Detect.psm1); 'unknown' there means this read failed.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $state = Get-KernelDmaProtectionState
    if ($state -eq 'unknown') { throw 'Kernel DMA protection could not be read' }
    return $state
}

function Get-SmartAppControlState {
    # Microsoft: https://learn.microsoft.com/windows/apps/develop/smart-app-control/overview
    # VerifiedAndReputablePolicyState: 0 off, 1 on, 2 evaluation.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = Get-RequiredRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState'
    switch ([int]$value) {
        0 { return 'off (cannot be re-enabled without a reinstall)' }
        1 { return 'on' }
        2 { return 'evaluation' }
        default { return "unrecognised value $value" }
    }
}

function Get-DeviceEncryptionState {
    # Microsoft: https://learn.microsoft.com/powershell/module/bitlocker/get-bitlockervolume
    # The BitLocker cmdlets need an elevated session.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Assert-CmdletAvailable -Name 'Get-BitLockerVolume'
    $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $volume = Invoke-PostureRead -NeedsAdmin -Script {
        $found = Get-BitLockerVolume -MountPoint $drive
        if (-not $found) { throw "no BitLocker volume returned for $drive" }
        $found
    }
    switch ("$(@($volume)[0].ProtectionStatus)") {
        { $_ -in 'On', '1' } { return 'on' }
        { $_ -in 'Off', '0' } { return 'off' }
        default { throw "BitLocker protection status is $_ (unknown)" }
    }
}

# ---------------------------------------------------------------- Defender readers

function Get-DefenderStatusProperty {
    # Microsoft: https://learn.microsoft.com/powershell/module/defender/get-mpcomputerstatus
    # A value that comes back empty is hidden (tamper protection, policy, rights): UNKNOWN.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-CmdletAvailable -Name 'Get-MpComputerStatus'
    $status = Invoke-PostureRead -Script { Get-MpComputerStatus }
    $value = $status.PSObject.Properties[$Name]?.Value
    if ($null -eq $value -or "$value" -eq '') {
        throw "Defender returned no value for $Name (tamper protection or policy can hide it)"
    }
    if ($value -is [bool]) { return ConvertTo-OnOff -Value $value }
    return "$value"
}

function Get-DefenderRunningMode {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Get-DefenderStatusProperty -Name 'AMRunningMode'
}

function Get-DefenderRealTime {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Get-DefenderStatusProperty -Name 'RealTimeProtectionEnabled'
}

function Get-DefenderBehaviorMonitor {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Get-DefenderStatusProperty -Name 'BehaviorMonitorEnabled'
}

function Get-DefenderTamperProtection {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Get-DefenderStatusProperty -Name 'IsTamperProtected'
}

function Get-DefenderPreference {
    # Internal. Microsoft: https://learn.microsoft.com/powershell/module/defender/get-mppreference
    [CmdletBinding()]
    param()
    Assert-CmdletAvailable -Name 'Get-MpPreference'
    $preference = Invoke-PostureRead -Script { Get-MpPreference }
    if (-not $preference) { throw 'Defender returned no preferences (tamper protection or policy can hide them)' }
    return $preference
}

function Get-DefenderCloudProtection {
    # MAPSReporting: 0 off, 1 basic, 2 advanced (cloud-delivered protection).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = (Get-DefenderPreference).PSObject.Properties['MAPSReporting']?.Value
    if ($null -eq $value -or "$value" -eq '') { throw 'Defender returned no value for MAPSReporting (tamper protection or policy can hide it)' }
    switch ([int]$value) {
        0 { return 'off' }
        1 { return 'basic' }
        default { return 'advanced' }
    }
}

function Get-AsrRuleSummary {
    # Microsoft: https://learn.microsoft.com/defender-endpoint/attack-surface-reduction
    # Reported only. An empty list is a real answer (no rules), not a hidden value.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ids = @((Get-DefenderPreference).PSObject.Properties['AttackSurfaceReductionRules_Ids']?.Value | Where-Object { $_ -and "$_" -notlike 'N/A*' })
    return "$($ids.Count) rules configured (ASR is documented for Pro/Enterprise)"
}

# ---------------------------------------------------------------- UAC readers

# Microsoft: https://learn.microsoft.com/windows/security/application-security/application-control/user-account-control/settings-and-configuration
function Get-UacState {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = Get-RequiredRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
    return ConvertTo-OnOff -Value $value
}

function Get-UacSecureDesktop {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = Get-RequiredRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'PromptOnSecureDesktop'
    return ConvertTo-OnOff -Value $value
}

# ---------------------------------------------------------------- Firewall readers

function Get-FirewallProfileState {
    # Microsoft: https://learn.microsoft.com/powershell/module/netsecurity/get-netfirewallprofile
    # ActiveStore: the effective values after policy, not only the persistent store.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('Domain', 'Private', 'Public')][string]$Name)
    Assert-CmdletAvailable -Name 'Get-NetFirewallProfile'
    $firewallProfile = Invoke-PostureRead -Script { Get-NetFirewallProfile -Name $Name -PolicyStore ActiveStore }
    if (-not $firewallProfile) { throw "no $Name firewall profile returned" }
    $enabled = if ("$($firewallProfile.Enabled)" -eq 'True') { 'enabled' } else { 'disabled' }
    return "$enabled, inbound $($firewallProfile.DefaultInboundAction)"
}

function Get-WslHyperVInboundState {
    # Microsoft: https://learn.microsoft.com/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall
    # and https://learn.microsoft.com/windows/wsl/networking . The VM creator Id below is WSL's.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Assert-CmdletAvailable -Name 'Get-NetFirewallHyperVVMSetting'
    $setting = Invoke-PostureRead -Script { Get-NetFirewallHyperVVMSetting -Name $script:WslHyperVVmCreatorId -PolicyStore ActiveStore }
    if (-not $setting) { throw 'no Hyper-V firewall setting returned for WSL' }
    $enabled = if ("$($setting.PSObject.Properties['Enabled']?.Value)" -eq 'False') { 'disabled' } else { 'enabled' }
    return "$enabled, inbound $($setting.DefaultInboundAction)"
}

# ---------------------------------------------------------------- Network readers

function Get-PortProxyState {
    # Microsoft: https://learn.microsoft.com/windows-server/networking/technologies/netsh/netsh-interface-portproxy
    # `show all` lists "Address Port Address Port" rows; nothing is printed when there are none.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $result = Invoke-Native -FilePath 'netsh.exe' -ArgumentList @('interface', 'portproxy', 'show', 'all')
    $entries = foreach ($line in $result.Output) {
        if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$') { "$($Matches[1]):$($Matches[2]) -> $($Matches[3]):$($Matches[4])" }
    }
    if (-not $entries) { return 'none' }
    return ($entries -join '; ')
}

function Get-ExposedListenerState {
    # Microsoft: https://learn.microsoft.com/powershell/module/nettcpip/get-nettcpconnection
    # Listeners owned by the WSL, VM and local-LLM processes on a non-loopback address.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Assert-CmdletAvailable -Name 'Get-NetTCPConnection'
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($connection in @(Get-NetTCPConnection -State Listen)) {
        if ($connection.LocalAddress -match '^127\.' -or $connection.LocalAddress -eq '::1') { continue }
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -notin $script:ListenerProcesses) { continue }
        $found.Add("$($process.ProcessName) $($connection.LocalAddress):$($connection.LocalPort)")
    }
    if ($found.Count -eq 0) { return 'none' }
    return (($found | Select-Object -Unique) -join '; ')
}

# ---------------------------------------------------------------- Legacy readers

function Get-Smb1State {
    # Microsoft: https://learn.microsoft.com/windows-server/storage/file-server/troubleshoot/detect-enable-and-disable-smbv1-v2-v3
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $state = Get-FeatureState -Name 'SMB1Protocol'
    if ($state -eq 'Unknown') { throw 'SMB1Protocol feature state could not be read' }
    return $state
}

function Get-PowerShellV2State {
    # Microsoft: https://learn.microsoft.com/powershell/scripting/windows-powershell/install/installing-windows-powershell
    # The 2.0 engine ships as an optional feature; its root feature name is below.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Windows 11 24H2 removed the 2.0 engine (KB5065506, all editions), so the feature has no
    # Win32_OptionalFeature row. No row is only believed when the query itself works, which
    # is shown by another feature being found; a CIM failure throws out of Get-FeatureState.
    $state = Get-FeatureState -Name 'MicrosoftWindowsPowerShellV2Root'
    if ($state -ne 'Unknown') { return $state }
    if ((Get-FeatureState -Name 'SMB1Protocol') -eq 'Unknown') { throw 'the optional-feature list could not be read' }
    return 'Absent (removed from Windows)'
}

function Get-RemoteAssistanceState {
    # Microsoft: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-remoteassistance
    # fAllowToGetHelp is the per-machine switch the Remote tab of System Properties writes.
    # The Group Policy value, when present, overrides the local one.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $policy = Get-PostureRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fAllowToGetHelp'
    if ($null -ne $policy) { return ConvertTo-OnOff -Value $policy }
    $value = Get-RequiredRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp'
    return ConvertTo-OnOff -Value $value
}

function Get-AutoplayState {
    # Microsoft: https://learn.microsoft.com/windows/win32/shell/autoplay-reg
    # DisableAutoplay 1 means AutoPlay is off for the user; a missing value means on (the
    # Windows default). The policy NoDriveTypeAutoRun = 255 (0xFF) turns it off for every drive type.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($hive in 'HKLM', 'HKCU') {
        $policy = Get-PostureRegistryValue -Path "${hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name 'NoDriveTypeAutoRun'
        if ($null -ne $policy -and [int]$policy -eq 255) { return 'off' }
    }
    $value = Get-PostureRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers' -Name 'DisableAutoplay'
    if ($null -ne $value -and [int]$value -ne 0) { return 'off' }
    return 'on'
}

# ---------------------------------------------------------------- Privacy readers

# Microsoft: https://learn.microsoft.com/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services
function Get-AdvertisingIdState {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # The Group Policy DisabledByGroupPolicy = 1 turns it off whatever the user setting says.
    $policy = Get-PostureRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' -Name 'DisabledByGroupPolicy'
    if ($null -ne $policy -and [int]$policy -eq 1) { return 'off' }
    $value = Get-RequiredRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled'
    return ConvertTo-OnOff -Value $value
}

function Get-TailoredExperiencesState {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = Get-RequiredRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled'
    return ConvertTo-OnOff -Value $value
}

function Get-DiagnosticDataState {
    # Microsoft: https://learn.microsoft.com/windows/privacy/configure-windows-diagnostic-data-in-your-organization
    # AllowTelemetry: 0 Security, 1 Required, 2 Enhanced (legacy), 3 Optional. The Group Policy
    # value is read first, then the Settings value; with neither there is nothing to read.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = Get-PostureRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry'
    $suffix = ' (set by policy)'
    if ($null -eq $value) {
        $suffix = ''
        $value = Get-PostureRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry'
    }
    if ($null -eq $value) { return 'not set (no Group Policy or Settings value); see Settings > Privacy & security > Diagnostics & feedback' }
    switch ([int]$value) {
        0 { return "Security$suffix" }
        1 { return "Required$suffix" }
        default { return "Optional$suffix" }
    }
}

function Get-ActivityHistoryState {
    # Microsoft: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-privacy (PublishUserActivities)
    # Only the machine policy is readable; the per-user Settings switch has no reliable value.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $value = Get-PostureRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'PublishUserActivities'
    if ($null -eq $value) { return 'not set by policy; see Settings > Privacy & security > Activity history' }
    return $(if ([int]$value -eq 0) { 'off (set by policy)' } else { 'on (set by policy)' })
}

# ---------------------------------------------------------------- Apps and account readers

function Get-CopilotAppState {
    # The winget helper exports the winget source only, and Copilot is a Store package, so the
    # per-user Appx list is read too (it needs no elevation).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $appxFailure = $null
    try { if (@(Get-CopilotAppxPackage).Count -gt 0) { return 'installed' } }
    catch { $appxFailure = $_ }
    $ids = @(Get-WingetInstalledIds)
    if ($ids -contains 'Microsoft.Copilot' -or $ids -contains 'Microsoft.365Copilot') { return 'installed' }
    if ($appxFailure) { throw $appxFailure }
    return 'not installed'
}

function Get-CopilotAppxPackage {
    # Internal, mockable. Names of installed Microsoft.Copilot* Appx packages. A missing cmdlet
    # or a failed read throws, so the row is UNKNOWN rather than a false "not installed".
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    Assert-CmdletAvailable -Name 'Get-AppxPackage'
    return [string[]]@(Get-AppxPackage -Name 'Microsoft.Copilot*' | ForEach-Object { $_.Name })
}

function Get-SimplewallState {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Test-WingetPackage -Id 'Henry++.simplewall') { return 'installed; enable and configure filtering in simplewall yourself (it blocks outbound traffic until you allow apps)' }
    return 'not installed'
}

function Get-CurrentTokenClaim {
    # Internal, mockable. The claims of the current Windows identity. WindowsIdentity.Groups
    # omits deny-only groups, which is how a UAC-filtered token lists Administrators; the
    # claims include them (group SID and deny-only SID claim types).
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    if (-not $IsWindows) { throw 'the current token can be read only on Windows' }
    return @([System.Security.Principal.WindowsIdentity]::GetCurrent().Claims)
}

function Get-CurrentGroupSid {
    # Internal, mockable. The SIDs among the current token's claims, deny-only ones included.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@(Get-CurrentTokenClaim | ForEach-Object { $_.Value })
}

function Get-AdminAccountState {
    # Microsoft: https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers
    # S-1-5-32-544 is the built-in Administrators group.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $(if ('S-1-5-32-544' -in @(Get-CurrentGroupSid)) { 'yes' } else { 'no' })
}

# ---------------------------------------------------------------- the check table

function New-PostureCheck {
    # Internal. One row of the table. OkValue: the value that is fine. Otherwise: the status
    # for any other value (RECOMMEND, or INFO for a report-only row). InfoPattern: a value
    # that is INFO whatever OkPattern says (a setting with no readable per-user value). OkValue omitted with
    # Otherwise INFO makes a row that always reports INFO.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory table row; changes no state.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Read,
        [string]$OkPattern,
        [string]$InfoPattern,
        [ValidateSet('RECOMMEND', 'INFO')][string]$Otherwise = 'RECOMMEND',
        [string]$Recommendation = ''
    )
    $evaluate = if ($PSBoundParameters.ContainsKey('OkPattern')) {
        {
            param($Value)
            if ("$Value" -match $OkPattern) { 'OK' }
            elseif ($InfoPattern -and "$Value" -match $InfoPattern) { 'INFO' }
            else { $Otherwise }
        }.GetNewClosure()
    }
    else {
        { param($Value) 'INFO' }
    }
    return @{
        Id = $Id; Group = $Group; Title = $Title
        Read = $Read; Evaluate = $evaluate; Recommendation = $Recommendation
    }
}

function Get-PostureChecks {
    <#
    .SYNOPSIS
        The declared posture checks, in report order.
    .DESCRIPTION
        Each row is a hashtable with Id, Group, Title, Read (a scriptblock that returns
        the value or throws the reason it cannot), Evaluate (a scriptblock taking the
        value and returning OK, RECOMMEND or INFO) and Recommendation (the text shown
        under a RECOMMEND line). Nothing here reads anything until Read is invoked.
    .OUTPUTS
        hashtable[]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Returns the table of checks; the name is the interface the report and tests use.')]
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    $firewall = 'Windows Security > Firewall & network protection.'
    $defender = 'Windows Security > Virus & threat protection settings.'
    $firewallOk = '^enabled, inbound (Block|NotConfigured)$'
    $checks = @(
        New-PostureCheck -Id 'secure-boot' -Group 'Platform' -Title 'Secure Boot' -Read { Get-SecureBootState } -OkPattern '^on$' -Recommendation 'Turn on Secure Boot in the firmware setup.'
        New-PostureCheck -Id 'tpm' -Group 'Platform' -Title 'TPM' -Read { Get-TpmState } -OkPattern '^present, 2\.0$' -Recommendation 'Enable the TPM (fTPM/PTT) in the firmware setup.'
        New-PostureCheck -Id 'hvci' -Group 'Platform' -Title 'Memory integrity (HVCI)' -Read { Get-HvciState } -OkPattern '^running$' -Recommendation 'Settings > Privacy & security > Windows Security > Device security > Core isolation > Memory integrity (restart required; check drivers first).'
        New-PostureCheck -Id 'vbs' -Group 'Platform' -Title 'Virtualization-based security' -Read { Get-VbsState } -OkPattern '^running$' -Otherwise INFO
        New-PostureCheck -Id 'lsa' -Group 'Platform' -Title 'LSA protection' -Read { Get-LsaProtectionState } -OkPattern '^on$' -Recommendation 'Core isolation > Local Security Authority protection, on (restart).'
        New-PostureCheck -Id 'kernel-dma' -Group 'Platform' -Title 'Kernel DMA protection' -Read { Get-KernelDmaState } -OkPattern '^on$' -Otherwise INFO
        New-PostureCheck -Id 'smart-app-control' -Group 'Platform' -Title 'Smart App Control' -Read { Get-SmartAppControlState } -Recommendation 'Cannot be turned back on without a reinstall; reported only.'
        New-PostureCheck -Id 'device-encryption' -Group 'Platform' -Title 'Device encryption' -Read { Get-DeviceEncryptionState } -OkPattern '^on$' -Recommendation 'Settings > Privacy & security > Device encryption.'
        New-PostureCheck -Id 'defender-mode' -Group 'Defender' -Title 'Running mode' -Read { Get-DefenderRunningMode } -OkPattern '^Normal$' -Recommendation $defender
        New-PostureCheck -Id 'defender-realtime' -Group 'Defender' -Title 'Real-time protection' -Read { Get-DefenderRealTime } -OkPattern '^on$' -Recommendation $defender
        New-PostureCheck -Id 'defender-behavior' -Group 'Defender' -Title 'Behavior monitoring' -Read { Get-DefenderBehaviorMonitor } -OkPattern '^on$' -Recommendation $defender
        New-PostureCheck -Id 'defender-tamper' -Group 'Defender' -Title 'Tamper protection' -Read { Get-DefenderTamperProtection } -OkPattern '^on$' -Recommendation $defender
        New-PostureCheck -Id 'defender-cloud' -Group 'Defender' -Title 'Cloud protection' -Read { Get-DefenderCloudProtection } -OkPattern '^(basic|advanced)$' -Recommendation 'Virus & threat protection settings > Cloud-delivered protection, on.'
        New-PostureCheck -Id 'defender-asr' -Group 'Defender' -Title 'Attack surface reduction rules' -Read { Get-AsrRuleSummary } -Recommendation 'Reported only.'
        New-PostureCheck -Id 'uac-enabled' -Group 'UAC' -Title 'UAC on' -Read { Get-UacState } -OkPattern '^on$' -Recommendation 'Never turn UAC off; restore with the UAC slider.'
        New-PostureCheck -Id 'uac-secure-desktop' -Group 'UAC' -Title 'Secure desktop prompt' -Read { Get-UacSecureDesktop } -OkPattern '^on$' -Recommendation 'Control Panel > User Accounts > Change User Account Control settings, default level.'
        New-PostureCheck -Id 'firewall-domain' -Group 'Firewall' -Title 'Domain profile' -Read { Get-FirewallProfileState -Name 'Domain' } -OkPattern $firewallOk -Recommendation $firewall
        New-PostureCheck -Id 'firewall-private' -Group 'Firewall' -Title 'Private profile' -Read { Get-FirewallProfileState -Name 'Private' } -OkPattern $firewallOk -Recommendation $firewall
        New-PostureCheck -Id 'firewall-public' -Group 'Firewall' -Title 'Public profile' -Read { Get-FirewallProfileState -Name 'Public' } -OkPattern $firewallOk -Recommendation $firewall
        New-PostureCheck -Id 'firewall-wsl' -Group 'Firewall' -Title 'WSL Hyper-V firewall inbound' -Read { Get-WslHyperVInboundState } -OkPattern $firewallOk -Recommendation "Turn the Hyper-V firewall for WSL back on and block inbound: Set-NetFirewallHyperVVMSetting -Name '$script:WslHyperVVmCreatorId' -Enabled True -DefaultInboundAction Block (elevated)."
        New-PostureCheck -Id 'port-proxy' -Group 'Network' -Title 'Port proxy' -Read { Get-PortProxyState } -OkPattern '^none$' -Recommendation 'Remove entries with netsh interface portproxy delete (elevated).'
        New-PostureCheck -Id 'exposed-listeners' -Group 'Network' -Title 'WSL/Docker listeners' -Read { Get-ExposedListenerState } -OkPattern '^none$' -Recommendation 'Bind the service to 127.0.0.1; never mirrored mode or a LAN bind (ADR-006).'
        New-PostureCheck -Id 'smb1' -Group 'Legacy' -Title 'SMBv1' -Read { Get-Smb1State } -OkPattern '^(Disabled|Absent)$' -Recommendation 'Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol (elevated).'
        New-PostureCheck -Id 'powershell-v2' -Group 'Legacy' -Title 'PowerShell 2.0 engine' -Read { Get-PowerShellV2State } -OkPattern '^(Disabled|Absent)' -Recommendation 'Disable the MicrosoftWindowsPowerShellV2Root optional feature (elevated).'
        New-PostureCheck -Id 'remote-assistance' -Group 'Legacy' -Title 'Remote Assistance' -Read { Get-RemoteAssistanceState } -OkPattern '^off$' -Recommendation 'Run SystemPropertiesRemote.exe (System Properties > Remote) and untick Allow Remote Assistance connections (asks for administrator approval).'
        New-PostureCheck -Id 'autoplay' -Group 'Legacy' -Title 'AutoPlay' -Read { Get-AutoplayState } -OkPattern '^off$' -Recommendation 'Settings > Bluetooth & devices > AutoPlay, off.'
        New-PostureCheck -Id 'advertising-id' -Group 'Privacy' -Title 'Advertising ID' -Read { Get-AdvertisingIdState } -OkPattern '^off$' -Recommendation 'Settings > Privacy & security > General.'
        New-PostureCheck -Id 'tailored-experiences' -Group 'Privacy' -Title 'Tailored experiences' -Read { Get-TailoredExperiencesState } -OkPattern '^off$' -Recommendation 'Settings > Privacy & security > Diagnostics & feedback.'
        New-PostureCheck -Id 'diagnostic-data' -Group 'Privacy' -Title 'Diagnostic data' -Read { Get-DiagnosticDataState } -OkPattern '^(Required|Security)( \(set by policy\))?$' -InfoPattern '^not set' -Recommendation 'Diagnostics & feedback > Send optional diagnostic data, off. If the value says set by policy, the Settings toggle is locked; remove the policy value first.'
        New-PostureCheck -Id 'activity-history' -Group 'Privacy' -Title 'Activity history' -Read { Get-ActivityHistoryState } -OkPattern '^off \(set by policy\)$' -InfoPattern '^not set' -Recommendation 'Settings > Privacy & security > Activity history. If the value says set by policy, the Settings toggle is locked; remove the policy value first.'
        New-PostureCheck -Id 'copilot-apps' -Group 'Apps' -Title 'Copilot apps' -Read { Get-CopilotAppState } -Recommendation 'The operator decides.'
        New-PostureCheck -Id 'simplewall' -Group 'Apps' -Title 'simplewall filtering' -Read { Get-SimplewallState } -Recommendation 'Installed; enable and configure filtering in simplewall yourself (it blocks outbound traffic until you allow apps).'
        New-PostureCheck -Id 'admin-account' -Group 'Account' -Title 'Daily account is an administrator' -Read { Get-AdminAccountState } -Recommendation 'Operator decision: the daily account is an administrator.'
    )
    return [hashtable[]]$checks
}

# ---------------------------------------------------------------- the runner

function Write-PostureLine {
    # Internal. One report line, coloured by status.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Status = ''
    )
    $color = switch ($Status) {
        'OK' { 'Green' }
        'RECOMMEND' { 'Yellow' }
        'UNKNOWN' { 'DarkGray' }
        'INFO' { 'Cyan' }
        default { $null }
    }
    if ($color) { Write-Host -Object $Text -ForegroundColor $color }
    else { Write-Host -Object $Text }
}

function Invoke-PostureReport {
    <#
    .SYNOPSIS
        Prints the posture report and returns the exit code.
    .DESCRIPTION
        Runs every check's reader, evaluates the value and prints one line per check:
        STATUS group: title = value, and for RECOMMEND an indented line with the
        recommendation. A reader that throws, or returns nothing, is UNKNOWN with the
        reason. Ends with a summary line. Strictly read-only; never elevates.
    .PARAMETER Strict
        Return 1 when any check is RECOMMEND. UNKNOWN never fails. Without it the
        exit code is always 0.
    .OUTPUTS
        int. The exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([switch]$Strict)
    $counts = [ordered]@{ OK = 0; RECOMMEND = 0; INFO = 0; UNKNOWN = 0 }
    foreach ($check in Get-PostureChecks) {
        $status = 'UNKNOWN'
        $value = ''
        try {
            $read = & $check.Read
            if ($null -eq $read -or "$read" -eq '') { throw 'no value returned' }
            $evaluated = "$(& $check.Evaluate $read)"
            if ($evaluated -notin 'OK', 'RECOMMEND', 'INFO') { throw "unrecognised result '$evaluated'" }
            $status = $evaluated
            $value = "$read"
        }
        catch {
            $value = "($($_.Exception.Message))"
        }
        $counts[$status]++
        Write-PostureLine -Status $status -Text "$status $($check.Group): $($check.Title) = $value"
        if ($status -eq 'RECOMMEND') { Write-PostureLine -Text "     -> $($check.Recommendation)" }
    }
    Write-PostureLine -Text "Summary: $($counts.OK) OK, $($counts.RECOMMEND) RECOMMEND, $($counts.INFO) INFO, $($counts.UNKNOWN) UNKNOWN"
    if ($Strict -and $counts.RECOMMEND -gt 0) { return 1 }
    return 0
}

Export-ModuleMember -Function Get-PostureChecks, Invoke-PostureReport
