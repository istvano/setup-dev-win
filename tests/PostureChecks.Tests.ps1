Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'PostureCases.ps1')
    $script:Cases = (Get-PostureTestCase).Cases
    $script:InfoCases = (Get-PostureTestCase).InfoCases
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    $script:Root = Split-Path -Parent $PSScriptRoot
    # Cmdlets that exist only on Windows. Pester's Mock needs the command to exist.
    $script:Created = @()
    foreach ($name in 'Get-MpComputerStatus', 'Get-MpPreference', 'Get-NetFirewallProfile', 'Get-BitLockerVolume', 'Get-NetTCPConnection', 'Get-NetFirewallHyperVVMSetting') {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "Function:\global:$name" -Value { [CmdletBinding()] param([string]$Name, [string]$MountPoint, [string]$State) throw 'stub: mock me' }
            $script:Created += $name
        }
    }
    Import-Module (Join-Path $script:Root 'script/lib/PostureChecks.psm1') -Force

    . (Join-Path $PSScriptRoot 'PostureCases.ps1')
    $script:Cases = (Get-PostureTestCase).Cases
    $script:InfoCases = (Get-PostureTestCase).InfoCases
    $script:AllCases = $script:Cases + $script:InfoCases
    function script:Use-ReaderMock {
        # Mocks every reader with its healthy value, except the readers named in Except.
        param([string[]]$Except = @())
        $vals = @{}
        foreach ($case in $script:Cases) {
            if ($case.ContainsKey('Key')) {
                if (-not $vals.ContainsKey($case.Reader)) { $vals[$case.Reader] = @{} }
                $vals[$case.Reader][$case.Key] = $case.Ok
            }
            else { $vals[$case.Reader] = $case.Ok }
        }
        foreach ($case in $script:InfoCases) { $vals[$case.Reader] = $case.Value }
        $script:Vals = $vals
        foreach ($reader in $vals.Keys) {
            if ($reader -in $Except) { continue }
            $body = [scriptblock]::Create("`$v = `$script:Vals['$reader']; if (`$v -is [hashtable]) { return `$v[`$Name] }; return `$v")
            Mock -ModuleName PostureChecks -CommandName $reader -MockWith $body
        }
    }
    function script:Find-Line {
        param([string]$Pattern)
        @($script:Lines | Where-Object { $_ -like $Pattern })
    }
}

AfterAll {
    foreach ($name in $script:Created) { Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue }
}

Describe 'Get-PostureChecks' {
    It 'declares the exact check set with the required shape' {
        $checks = @(Get-PostureChecks)
        $checks.Count | Should-Be $script:AllCases.Count
        foreach ($check in $checks) {
            foreach ($key in 'Id', 'Group', 'Title', 'Read', 'Evaluate', 'Recommendation') { $check.ContainsKey($key) | Should-BeTrue -Because "$($check.Id) needs $key" }
            $check.Read | Should-HaveType ([scriptblock])
            $check.Evaluate | Should-HaveType ([scriptblock])
        }
        @($checks | ForEach-Object Id | Sort-Object) | Should-BeCollection @($script:AllCases | ForEach-Object { $_.Id } | Sort-Object)
        @($checks | ForEach-Object Id | Sort-Object -Unique).Count | Should-Be $checks.Count
    }

    It 'is ASCII only' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Root 'script/lib/PostureChecks.psm1'))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should-Be 0
    }
}

Describe 'Invoke-PostureReport' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName PostureChecks Write-Host { $script:Lines.Add([string]$Object) }
    }

    It '<Id>: the recommended value is OK' -ForEach $script:Cases {
        Use-ReaderMock
        if ($_.ContainsKey('Key')) { $script:Vals[$Reader][$_.Key] = $Ok } else { $script:Vals[$Reader] = $Ok }
        $null = Invoke-PostureReport
        (@(Find-Line "OK ${Group}: ${Title} = *")).Count | Should-Be 1
        (@(Find-Line "OK ${Group}: ${Title} = $Ok")).Count | Should-Be 1
    }

    It '<Id>: another value is <BadStatus> with the exact recommendation' -ForEach $script:Cases {
        Use-ReaderMock
        if ($_.ContainsKey('Key')) { $script:Vals[$Reader][$_.Key] = $Bad } else { $script:Vals[$Reader] = $Bad }
        $null = Invoke-PostureReport
        $line = @(Find-Line "* ${Group}: ${Title} = *")
        $line.Count | Should-Be 1
        $line[0] | Should-Be "$BadStatus ${Group}: ${Title} = $Bad"
        $index = $script:Lines.IndexOf($line[0])
        if ($BadStatus -eq 'RECOMMEND') {
            $script:Lines[$index + 1] | Should-Be "     -> $Rec"
        }
        else {
            $script:Lines[$index + 1] | Should-NotBeLikeString '     -> *'
        }
    }

    It '<Id>: a reader that throws is UNKNOWN with the reason, never an error' -ForEach $script:Cases {
        Use-ReaderMock
        Mock -ModuleName PostureChecks -CommandName $Reader -MockWith { throw 'boom reason' }
        $null = Invoke-PostureReport
        (@(Find-Line "UNKNOWN ${Group}: ${Title} = (boom reason)")).Count | Should-Be 1
        (@(Find-Line '     -> *')).Count | Should-Be 0 -Because 'a failed read recommends nothing'
    }

    It '<Id>: reports without recommending' -ForEach $script:InfoCases {
        Use-ReaderMock
        $null = Invoke-PostureReport
        (@(Find-Line "INFO ${Group}: ${Title} = $Value")).Count | Should-Be 1
        (@(Find-Line '     -> *')).Count | Should-Be 0
    }

    It '<Id>: an INFO check whose reader throws is UNKNOWN' -ForEach $script:InfoCases {
        Use-ReaderMock
        Mock -ModuleName PostureChecks -CommandName $Reader -MockWith { throw 'no access' }
        $null = Invoke-PostureReport
        (@(Find-Line "UNKNOWN ${Group}: ${Title} = (no access)")).Count | Should-Be 1
    }

    It '<Id>: a setting with no policy and no readable value is INFO, not RECOMMEND' -ForEach @(
        @{ Id = 'diagnostic-data'; Reader = 'Get-DiagnosticDataState'; Line = 'INFO Privacy: Diagnostic data = not set by policy; see Settings' }
        @{ Id = 'activity-history'; Reader = 'Get-ActivityHistoryState'; Line = 'INFO Privacy: Activity history = not set by policy; see Settings' }
    ) {
        Use-ReaderMock
        $script:Vals[$Reader] = 'not set by policy; see Settings'
        $null = Invoke-PostureReport
        (@(Find-Line $Line)).Count | Should-Be 1
        (@(Find-Line 'RECOMMEND *')).Count | Should-Be 0
    }

    It 'a reader returning nothing is UNKNOWN, not RECOMMEND' {
        Use-ReaderMock
        Mock -ModuleName PostureChecks Get-SecureBootState { $null }
        $null = Invoke-PostureReport
        (@(Find-Line 'UNKNOWN Platform: Secure Boot = *')).Count | Should-Be 1
        (@(Find-Line 'RECOMMEND *')).Count | Should-Be 0
    }

    It 'prints the summary line with the four counts' {
        Use-ReaderMock
        $script:Vals['Get-SecureBootState'] = 'off'
        Mock -ModuleName PostureChecks Get-TpmState { throw 'x' }
        $null = Invoke-PostureReport
        $total = $script:AllCases.Count
        $ok = $total - 1 - 1 - $script:InfoCases.Count
        $script:Lines[$script:Lines.Count - 1] | Should-Be "Summary: $ok OK, 1 RECOMMEND, $($script:InfoCases.Count) INFO, 1 UNKNOWN"
    }

    It 'every check line has the format STATUS group: title = value' {
        Use-ReaderMock
        $null = Invoke-PostureReport
        $checkLines = @($script:Lines | Where-Object { $_ -notlike 'Summary:*' -and $_ -notlike '     -> *' })
        $checkLines.Count | Should-Be $script:AllCases.Count
        foreach ($line in $checkLines) { $line | Should-MatchString '^(OK|RECOMMEND|INFO|UNKNOWN) [^:]+: .+ = .+$' }
    }

    Context 'exit code' {
        It 'is 0 without -Strict even when something is recommended' {
            Use-ReaderMock
            $script:Vals['Get-SecureBootState'] = 'off'
            Invoke-PostureReport | Should-Be 0
        }

        It '-Strict returns 1 when any check is RECOMMEND' {
            Use-ReaderMock
            $script:Vals['Get-SecureBootState'] = 'off'
            Invoke-PostureReport -Strict | Should-Be 1
        }

        It '-Strict returns 0 when nothing is RECOMMEND' {
            Use-ReaderMock
            Invoke-PostureReport -Strict | Should-Be 0
        }

        It '-Strict ignores UNKNOWN' {
            Use-ReaderMock
            Mock -ModuleName PostureChecks Get-SecureBootState { throw 'nope' }
            Invoke-PostureReport -Strict | Should-Be 0
        }
    }

    Context 'review focus' {
        It '1: admin-only reads from a normal terminal print UNKNOWN (needs an elevated terminal)' {
            Use-ReaderMock -Except 'Get-DeviceEncryptionState'
            Mock -ModuleName PostureChecks Test-IsElevated { $false }
            Mock -ModuleName PostureChecks Get-BitLockerVolume { throw 'Access is denied' }
            $null = Invoke-PostureReport
            (@(Find-Line 'UNKNOWN Platform: Device encryption = (needs an elevated terminal)')).Count | Should-Be 1
        }

        It '1: the same failure while elevated keeps its own reason' {
            Use-ReaderMock -Except 'Get-DeviceEncryptionState'
            Mock -ModuleName PostureChecks Test-IsElevated { $true }
            Mock -ModuleName PostureChecks Get-BitLockerVolume { throw 'driver fault' }
            $null = Invoke-PostureReport
            (@(Find-Line 'UNKNOWN Platform: Device encryption = (driver fault)')).Count | Should-Be 1
        }

        It '1: BitLocker protection on is reported as on' {
            Use-ReaderMock -Except 'Get-DeviceEncryptionState'
            Mock -ModuleName PostureChecks Get-BitLockerVolume { [pscustomobject]@{ ProtectionStatus = 'On' } }
            $null = Invoke-PostureReport
            (@(Find-Line 'OK Platform: Device encryption = on')).Count | Should-Be 1
        }

        It '2: a missing NetSecurity cmdlet makes only the firewall checks UNKNOWN' {
            Use-ReaderMock -Except 'Get-FirewallProfileState'
            Mock -ModuleName PostureChecks Get-Command { $null } -ParameterFilter { $Name -eq 'Get-NetFirewallProfile' }
            $null = Invoke-PostureReport
            (@(Find-Line 'UNKNOWN Firewall: * profile = (Get-NetFirewallProfile is not available*')).Count | Should-Be 3
            (@(Find-Line 'OK Platform: Secure Boot = on')).Count | Should-Be 1
            (@(Find-Line 'Summary: *')).Count | Should-Be 1
        }

        It '2: a missing Defender cmdlet makes the Defender status checks UNKNOWN' {
            Use-ReaderMock -Except 'Get-DefenderRealTime'
            Mock -ModuleName PostureChecks Get-Command { $null } -ParameterFilter { $Name -eq 'Get-MpComputerStatus' }
            $null = Invoke-PostureReport
            (@(Find-Line 'UNKNOWN Defender: Real-time protection = (Get-MpComputerStatus is not available*')).Count | Should-Be 1
        }

        It '3: Defender values hidden by tamper protection are UNKNOWN, never RECOMMEND' {
            Use-ReaderMock -Except 'Get-DefenderRealTime', 'Get-DefenderTamperProtection', 'Get-DefenderCloudProtection'
            Mock -ModuleName PostureChecks Get-MpComputerStatus {
                [pscustomobject]@{ AMRunningMode = 'Normal'; RealTimeProtectionEnabled = $null; BehaviorMonitorEnabled = $true; IsTamperProtected = '' }
            }
            Mock -ModuleName PostureChecks Get-MpPreference { [pscustomobject]@{ MAPSReporting = $null } }
            $null = Invoke-PostureReport
            (@(Find-Line 'UNKNOWN Defender: Real-time protection = (*')).Count | Should-Be 1
            (@(Find-Line 'UNKNOWN Defender: Tamper protection = (*')).Count | Should-Be 1
            (@(Find-Line 'UNKNOWN Defender: Cloud protection = (*')).Count | Should-Be 1
            (@(Find-Line 'RECOMMEND Defender: *')).Count | Should-Be 0
        }

        It '3: Defender values that are present are read' {
            Use-ReaderMock -Except 'Get-DefenderRealTime', 'Get-DefenderCloudProtection'
            Mock -ModuleName PostureChecks Get-MpComputerStatus { [pscustomobject]@{ RealTimeProtectionEnabled = $false } }
            Mock -ModuleName PostureChecks Get-MpPreference { [pscustomobject]@{ MAPSReporting = 0 } }
            $null = Invoke-PostureReport
            (@(Find-Line 'RECOMMEND Defender: Real-time protection = off')).Count | Should-Be 1
            (@(Find-Line 'RECOMMEND Defender: Cloud protection = off')).Count | Should-Be 1
        }
    }
}

Describe 'Posture readers' {
    It 'Get-KernelDmaState maps the shared Detect helper and refuses unknown' {
        InModuleScope PostureChecks {
            Mock Get-KernelDmaProtectionState { 'on' }
            Get-KernelDmaState | Should-Be 'on'
            Mock Get-KernelDmaProtectionState { 'unknown' }
            { Get-KernelDmaState } | Should-Throw '*could not be read*'
        }
    }

    It 'Get-Smb1State reads Get-FeatureState and refuses Unknown' {
        InModuleScope PostureChecks {
            Mock Get-FeatureState { 'Enabled' } -ParameterFilter { $Name -eq 'SMB1Protocol' }
            Get-Smb1State | Should-Be 'Enabled'
            Mock Get-FeatureState { 'Unknown' } -ParameterFilter { $Name -eq 'SMB1Protocol' }
            { Get-Smb1State } | Should-Throw '*could not be read*'
        }
    }

    It 'Get-PortProxyState parses netsh output and reports none when empty' {
        InModuleScope PostureChecks {
            Mock Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = @('') } }
            Get-PortProxyState | Should-Be 'none'
            Mock Invoke-Native {
                [pscustomobject]@{ ExitCode = 0; Output = @('', 'Listen on ipv4:             Connect to ipv4:', '', 'Address         Port        Address         Port', '--------------- ----------  --------------- ----------', '0.0.0.0         8080        127.0.0.1       80') }
            }
            Get-PortProxyState | Should-Be '0.0.0.0:8080 -> 127.0.0.1:80'
        }
    }

    It 'Get-TpmState parses tpmtool output' {
        InModuleScope PostureChecks {
            Mock Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = @('-TPM Present: True', '-TPM Version: 2.0', '-TPM Manufacturer ID: INTC') } }
            Get-TpmState | Should-Be 'present, 2.0'
            Mock Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = @('-TPM Present: False') } }
            Get-TpmState | Should-Be 'absent'
        }
    }

    It 'Get-ExposedListenerState reports only the named processes on non-loopback addresses' {
        InModuleScope PostureChecks {
            Mock Get-Command { [pscustomobject]@{ Name = 'Get-NetTCPConnection' } } -ParameterFilter { $Name -eq 'Get-NetTCPConnection' }
            Mock Get-NetTCPConnection {
                @(
                    [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 1; OwningProcess = 10 }
                    [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 2; OwningProcess = 11 }
                    [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 3; OwningProcess = 12 }
                    [pscustomobject]@{ LocalAddress = '::1'; LocalPort = 4; OwningProcess = 11 }
                )
            }
            Mock Get-Process { [pscustomobject]@{ ProcessName = $(if ($Id -eq 10) { 'vmmem' } elseif ($Id -eq 11) { 'wslrelay' } else { 'chrome' }) } }
            Get-ExposedListenerState | Should-Be 'wslrelay 0.0.0.0:2'
            Mock Get-NetTCPConnection { @() }
            Get-ExposedListenerState | Should-Be 'none'
        }
    }

    It 'Get-AdminAccountState looks for S-1-5-32-544 behind a mockable group reader' {
        InModuleScope PostureChecks {
            Mock Get-CurrentGroupSid { @('S-1-1-0', 'S-1-5-32-544') }
            Get-AdminAccountState | Should-Be 'yes'
            Mock Get-CurrentGroupSid { @('S-1-1-0') }
            Get-AdminAccountState | Should-Be 'no'
        }
    }

    It 'Get-ActivityHistoryState is INFO-shaped when no policy is set' {
        InModuleScope PostureChecks {
            Mock Get-PostureRegistryValue { $null }
            Get-ActivityHistoryState | Should-BeLikeString 'not set by policy*Activity history*'
            Mock Get-PostureRegistryValue { 0 }
            Get-ActivityHistoryState | Should-Be 'off (policy)'
        }
    }

    It 'Get-DiagnosticDataState treats an absent policy as the Settings value' {
        InModuleScope PostureChecks {
            Mock Get-PostureRegistryValue { $null }
            Get-DiagnosticDataState | Should-BeLikeString 'not set by policy*'
            Mock Get-PostureRegistryValue { 1 }
            Get-DiagnosticDataState | Should-Be 'Required'
            Mock Get-PostureRegistryValue { 3 }
            Get-DiagnosticDataState | Should-Be 'Optional'
        }
    }

    It 'Get-LsaProtectionState maps RunAsPPL 1 and 2 to on and an absent value to UNKNOWN' {
        InModuleScope PostureChecks {
            Mock Get-PostureRegistryValue { 2 }
            Get-LsaProtectionState | Should-Be 'on'
            Mock Get-PostureRegistryValue { 0 }
            Get-LsaProtectionState | Should-Be 'off'
            Mock Get-PostureRegistryValue { $null }
            { Get-LsaProtectionState } | Should-Throw '*not set*'
        }
    }

    It 'Get-FirewallProfileState reads one profile' {
        InModuleScope PostureChecks {
            Mock Get-Command { [pscustomobject]@{ Name = 'Get-NetFirewallProfile' } } -ParameterFilter { $Name -eq 'Get-NetFirewallProfile' }
            Mock Get-NetFirewallProfile { [pscustomobject]@{ Enabled = 'True'; DefaultInboundAction = 'Block' } }
            Get-FirewallProfileState -Name 'Public' | Should-Be 'enabled, inbound Block'
            Mock Get-NetFirewallProfile { [pscustomobject]@{ Enabled = 'False'; DefaultInboundAction = 'NotConfigured' } }
            Get-FirewallProfileState -Name 'Public' | Should-Be 'disabled, inbound NotConfigured'
        }
    }
}

Describe 'hardening-check.ps1' {
    It 'is a thin entry point guarded by SETUP_DEV_WIN_NO_MAIN and exposing -Strict' {
        $text = Get-Content -LiteralPath (Join-Path $script:Root 'script/hardening-check.ps1') -Raw
        $text | Should-MatchString 'SETUP_DEV_WIN_NO_MAIN'
        $text | Should-MatchString '\[switch\]\$Strict'
        $text | Should-MatchString 'Invoke-PostureReport'
    }
}
