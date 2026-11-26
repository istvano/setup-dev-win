Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PostureTestCase {
    <#
    .SYNOPSIS
        The posture check table as the tests see it (shared by discovery and run time).
    .OUTPUTS
        A hashtable with Cases (OK / other value) and InfoCases (report only).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test data.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    # Group and Title are pinned here on purpose: they are the operator-visible spec.
    # Key is only for a reader that takes a -Name (firewall profiles).
    $cases = @(
        @{ Id = 'secure-boot'; Group = 'Platform'; Title = 'Secure Boot'; Reader = 'Get-SecureBootState'; Ok = 'on'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Turn on Secure Boot in the firmware setup.' }
        @{ Id = 'tpm'; Group = 'Platform'; Title = 'TPM'; Reader = 'Get-TpmState'; Ok = 'present, 2.0'; Bad = 'present, 1.2'; BadStatus = 'RECOMMEND'; Rec = 'Enable the TPM (fTPM/PTT) in the firmware setup.' }
        @{ Id = 'hvci'; Group = 'Platform'; Title = 'Memory integrity (HVCI)'; Reader = 'Get-HvciState'; Ok = 'running'; Bad = 'not running'; BadStatus = 'RECOMMEND'; Rec = 'Settings > Privacy & security > Windows Security > Device security > Core isolation > Memory integrity (restart required; check drivers first).' }
        @{ Id = 'vbs'; Group = 'Platform'; Title = 'Virtualization-based security'; Reader = 'Get-VbsState'; Ok = 'running'; Bad = 'off'; BadStatus = 'INFO'; Rec = '' }
        @{ Id = 'lsa'; Group = 'Platform'; Title = 'LSA protection'; Reader = 'Get-LsaProtectionState'; Ok = 'on'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Core isolation > Local Security Authority protection, on (restart).' }
        @{ Id = 'kernel-dma'; Group = 'Platform'; Title = 'Kernel DMA protection'; Reader = 'Get-KernelDmaState'; Ok = 'on'; Bad = 'off'; BadStatus = 'INFO'; Rec = '' }
        @{ Id = 'device-encryption'; Group = 'Platform'; Title = 'Device encryption'; Reader = 'Get-DeviceEncryptionState'; Ok = 'on'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Settings > Privacy & security > Device encryption.' }
        @{ Id = 'defender-mode'; Group = 'Defender'; Title = 'Running mode'; Reader = 'Get-DefenderRunningMode'; Ok = 'Normal'; Bad = 'Passive'; BadStatus = 'RECOMMEND'; Rec = 'Windows Security > Virus & threat protection settings.' }
        @{ Id = 'defender-realtime'; Group = 'Defender'; Title = 'Real-time protection'; Reader = 'Get-DefenderRealTime'; Ok = 'on'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Windows Security > Virus & threat protection settings.' }
        @{ Id = 'defender-behavior'; Group = 'Defender'; Title = 'Behavior monitoring'; Reader = 'Get-DefenderBehaviorMonitor'; Ok = 'on'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Windows Security > Virus & threat protection settings.' }
        @{ Id = 'defender-tamper'; Group = 'Defender'; Title = 'Tamper protection'; Reader = 'Get-DefenderTamperProtection'; Ok = 'on'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Windows Security > Virus & threat protection settings.' }
        @{ Id = 'defender-cloud'; Group = 'Defender'; Title = 'Cloud protection'; Reader = 'Get-DefenderCloudProtection'; Ok = 'advanced'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Virus & threat protection settings > Cloud-delivered protection, on.' }
        @{ Id = 'uac-enabled'; Group = 'UAC'; Title = 'UAC on'; Reader = 'Get-UacState'; Ok = 'on'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Never turn UAC off; restore with the UAC slider.' }
        @{ Id = 'uac-secure-desktop'; Group = 'UAC'; Title = 'Secure desktop prompt'; Reader = 'Get-UacSecureDesktop'; Ok = 'on'; Bad = 'off'; BadStatus = 'RECOMMEND'; Rec = 'Control Panel > User Accounts > Change User Account Control settings, default level.' }
        @{ Id = 'firewall-domain'; Group = 'Firewall'; Title = 'Domain profile'; Reader = 'Get-FirewallProfileState'; Key = 'Domain'; Ok = 'enabled, inbound Block'; Bad = 'disabled, inbound Block'; BadStatus = 'RECOMMEND'; Rec = 'Windows Security > Firewall & network protection.' }
        @{ Id = 'firewall-private'; Group = 'Firewall'; Title = 'Private profile'; Reader = 'Get-FirewallProfileState'; Key = 'Private'; Ok = 'enabled, inbound NotConfigured'; Bad = 'enabled, inbound Allow'; BadStatus = 'RECOMMEND'; Rec = 'Windows Security > Firewall & network protection.' }
        @{ Id = 'firewall-public'; Group = 'Firewall'; Title = 'Public profile'; Reader = 'Get-FirewallProfileState'; Key = 'Public'; Ok = 'enabled, inbound Block'; Bad = 'disabled, inbound Allow'; BadStatus = 'RECOMMEND'; Rec = 'Windows Security > Firewall & network protection.' }
        @{ Id = 'firewall-wsl'; Group = 'Firewall'; Title = 'WSL Hyper-V firewall inbound'; Reader = 'Get-WslHyperVInboundState'; Ok = 'Block'; Bad = 'Allow'; BadStatus = 'RECOMMEND'; Rec = "Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Block (elevated)." }
        @{ Id = 'port-proxy'; Group = 'Network'; Title = 'Port proxy'; Reader = 'Get-PortProxyState'; Ok = 'none'; Bad = '0.0.0.0:8080 -> 127.0.0.1:80'; BadStatus = 'RECOMMEND'; Rec = 'Remove entries with netsh interface portproxy delete (elevated).' }
        @{ Id = 'exposed-listeners'; Group = 'Network'; Title = 'WSL/Docker listeners'; Reader = 'Get-ExposedListenerState'; Ok = 'none'; Bad = 'vmmem 0.0.0.0:8080'; BadStatus = 'RECOMMEND'; Rec = 'Bind the service to 127.0.0.1; never mirrored mode or a LAN bind (ADR-006).' }
        @{ Id = 'smb1'; Group = 'Legacy'; Title = 'SMBv1'; Reader = 'Get-Smb1State'; Ok = 'Disabled'; Bad = 'Enabled'; BadStatus = 'RECOMMEND'; Rec = 'Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol (elevated).' }
        @{ Id = 'powershell-v2'; Group = 'Legacy'; Title = 'PowerShell 2.0 engine'; Reader = 'Get-PowerShellV2State'; Ok = 'Absent'; Bad = 'Enabled'; BadStatus = 'RECOMMEND'; Rec = 'Disable the MicrosoftWindowsPowerShellV2Root optional feature (elevated).' }
        @{ Id = 'remote-assistance'; Group = 'Legacy'; Title = 'Remote Assistance'; Reader = 'Get-RemoteAssistanceState'; Ok = 'off'; Bad = 'on'; BadStatus = 'RECOMMEND'; Rec = 'System > Remote Desktop / sysdm.cpl > Remote, untick Remote Assistance.' }
        @{ Id = 'autoplay'; Group = 'Legacy'; Title = 'AutoPlay'; Reader = 'Get-AutoplayState'; Ok = 'off'; Bad = 'on'; BadStatus = 'RECOMMEND'; Rec = 'Settings > Bluetooth & devices > AutoPlay, off.' }
        @{ Id = 'advertising-id'; Group = 'Privacy'; Title = 'Advertising ID'; Reader = 'Get-AdvertisingIdState'; Ok = 'off'; Bad = 'on'; BadStatus = 'RECOMMEND'; Rec = 'Settings > Privacy & security > General.' }
        @{ Id = 'tailored-experiences'; Group = 'Privacy'; Title = 'Tailored experiences'; Reader = 'Get-TailoredExperiencesState'; Ok = 'off'; Bad = 'on'; BadStatus = 'RECOMMEND'; Rec = 'Settings > Privacy & security > Diagnostics & feedback.' }
        @{ Id = 'diagnostic-data'; Group = 'Privacy'; Title = 'Diagnostic data'; Reader = 'Get-DiagnosticDataState'; Ok = 'Required'; Bad = 'Optional'; BadStatus = 'RECOMMEND'; Rec = 'Diagnostics & feedback > Send optional diagnostic data, off.' }
        @{ Id = 'activity-history'; Group = 'Privacy'; Title = 'Activity history'; Reader = 'Get-ActivityHistoryState'; Ok = 'off (policy)'; Bad = 'on (policy)'; BadStatus = 'RECOMMEND'; Rec = 'Settings > Privacy & security > Activity history.' }
    )
    # Checks that report and never recommend: the value decides nothing.
    $infoCases = @(
        @{ Id = 'smart-app-control'; Group = 'Platform'; Title = 'Smart App Control'; Reader = 'Get-SmartAppControlState'; Value = 'off' }
        @{ Id = 'defender-asr'; Group = 'Defender'; Title = 'Attack surface reduction rules'; Reader = 'Get-AsrRuleSummary'; Value = '0 rules configured (ASR is documented for Pro/Enterprise)' }
        @{ Id = 'copilot-apps'; Group = 'Apps'; Title = 'Copilot apps'; Reader = 'Get-CopilotAppState'; Value = 'installed' }
        @{ Id = 'simplewall'; Group = 'Apps'; Title = 'simplewall filtering'; Reader = 'Get-SimplewallState'; Value = 'installed; filtering is off until you enable it in simplewall' }
        @{ Id = 'admin-account'; Group = 'Account'; Title = 'Daily account is an administrator'; Reader = 'Get-AdminAccountState'; Value = 'yes' }
    )
    @{ Cases = $cases; InfoCases = $infoCases }
}
