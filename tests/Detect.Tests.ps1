Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'script/lib/Detect.psm1') -Force
}

Describe 'Get-EditionInfo' {
    It 'maps <Edition> to Home=<IsHome> Pro=<IsPro>' -ForEach @(
        @{ Edition = 'Core'; IsHome = $true; IsPro = $false }
        @{ Edition = 'Professional'; IsHome = $false; IsPro = $true }
        @{ Edition = 'Enterprise'; IsHome = $false; IsPro = $false }
    ) {
        Mock -ModuleName Detect Get-WindowsEdition { [pscustomobject]@{ Edition = $Edition } }
        $info = Get-EditionInfo
        $info.Edition | Should-Be $Edition
        $info.IsHome | Should-Be $IsHome
        $info.IsPro | Should-Be $IsPro
    }
}

Describe 'Get-OsBuild' {
    It 'returns the current build as an int' {
        Get-OsBuild | Should-HaveType ([int])
    }
}

Describe 'Test-DataVolume' {
    It 'reports a missing volume' {
        Mock -ModuleName Detect Get-Volume { $null }
        $r = Test-DataVolume -DriveLetter 'Q'
        $r.Ok | Should-BeFalse
        $r.Reason | Should-BeLikeString '*not found*'
    }

    It 'treats a Get-Volume error as not found' {
        Mock -ModuleName Detect Get-Volume { throw 'no such drive' }
        (Test-DataVolume -DriveLetter 'Q').Reason | Should-BeLikeString '*not found*'
    }

    It 'requires NTFS' {
        Mock -ModuleName Detect Get-Volume { [pscustomobject]@{ FileSystem = 'FAT32'; DriveType = 'Fixed' } }
        $r = Test-DataVolume -DriveLetter 'D'
        $r.Ok | Should-BeFalse
        $r.Reason | Should-BeLikeString '*NTFS*'
    }

    It 'requires a fixed drive' {
        Mock -ModuleName Detect Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS'; DriveType = 'Removable' } }
        $r = Test-DataVolume -DriveLetter 'D'
        $r.Ok | Should-BeFalse
        $r.Reason | Should-BeLikeString '*fixed*'
    }

    It 'accepts a fixed NTFS volume' {
        Mock -ModuleName Detect Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS'; DriveType = 'Fixed' } }
        (Test-DataVolume -DriveLetter 'D').Ok | Should-BeTrue
        Should-Invoke -CommandName Get-Volume -ModuleName Detect -ParameterFilter { $DriveLetter -eq 'D' }
    }
}

Describe 'Test-DocumentsRedirected' {
    BeforeAll {
        $script:SavedProfile = $env:USERPROFILE
        $env:USERPROFILE = $HOME
    }
    AfterAll {
        $env:USERPROFILE = $script:SavedProfile
    }

    It 'is true for <Value>' -ForEach @(
        @{ Value = '%USERPROFILE%\OneDrive\Documents' }
        @{ Value = '%USERPROFILE%\OneDrive - Contoso\Documents' }
    ) {
        Mock -ModuleName Detect Get-ItemProperty { [pscustomobject]@{ Personal = $Value } }
        Test-DocumentsRedirected | Should-BeTrue
    }

    It 'is false for the default location' {
        Mock -ModuleName Detect Get-ItemProperty { [pscustomobject]@{ Personal = '%USERPROFILE%\Documents' } }
        Test-DocumentsRedirected | Should-BeFalse
    }

    It 'is false when no Personal value is present' {
        Mock -ModuleName Detect Get-ItemProperty { [pscustomobject]@{ Other = 'x' } }
        Test-DocumentsRedirected | Should-BeFalse
    }
}

Describe 'Test-VirtualizationAvailable' {
    It 'is true when a hypervisor is present' {
        Mock -ModuleName Detect Get-CimInstance { [pscustomobject]@{ HypervisorPresent = $true } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        Test-VirtualizationAvailable | Should-BeTrue
    }

    It 'falls back to the firmware flag: <Firmware>' -ForEach @(
        @{ Firmware = $true }
        @{ Firmware = $false }
    ) {
        Mock -ModuleName Detect Get-CimInstance { [pscustomobject]@{ HypervisorPresent = $false } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        Mock -ModuleName Detect Get-CimInstance { [pscustomobject]@{ VirtualizationFirmwareEnabled = $Firmware } } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Test-VirtualizationAvailable | Should-Be $Firmware
    }
}

Describe 'Get-KernelDmaProtectionState' {
    It 'is on when property 3 is available' {
        Mock -ModuleName Detect Get-CimInstance { [pscustomobject]@{ AvailableSecurityProperties = @(1, 2, 3) } }
        Get-KernelDmaProtectionState | Should-Be 'on'
    }

    It 'is off when property 3 is absent' {
        Mock -ModuleName Detect Get-CimInstance { [pscustomobject]@{ AvailableSecurityProperties = @(1, 2) } }
        Get-KernelDmaProtectionState | Should-Be 'off'
    }

    It 'is unknown when the query fails' {
        Mock -ModuleName Detect Get-CimInstance { throw 'no namespace' }
        Get-KernelDmaProtectionState | Should-Be 'unknown'
    }
}
