Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'script/lib/Common.psm1') -Force
    Import-Module (Join-Path $root 'script/lib/Detect.psm1') -Force
    Import-Module (Join-Path $root 'script/stages/Preflight.psm1') -Force

    function Initialize-Healthy {
        param([bool]$Pro = $true)
        Mock -ModuleName Preflight Get-OsBuild { 26200 }
        Mock -ModuleName Preflight Test-DataVolume { @{ Ok = $true; Reason = '' } }
        Mock -ModuleName Preflight Test-DocumentsRedirected { $false }
        Mock -ModuleName Preflight Test-VirtualizationAvailable { $true }
        Mock -ModuleName Preflight Get-KernelDmaProtectionState { 'on' }
        Mock -ModuleName Preflight Get-EditionInfo {
            @{ Edition = $(if ($Pro) { 'Professional' } else { 'Core' }); IsHome = -not $Pro; IsPro = $Pro }
        }.GetNewClosure()
        Mock -ModuleName Preflight Write-Info {}
        Mock -ModuleName Preflight Write-Warn {}
        Mock -ModuleName Preflight Enable-WindowsOptionalFeature {}
    }
    function Get-TestContext {
        param([string[]]$Profiles = @('core'), [string]$DistroRoot = 'D:\WSL')
        @{ Profiles = $Profiles; DistroRoot = $DistroRoot; LinuxRepoUrl = 'u'; LinuxRef = 'main'; Plan = $false; Edition = $null }
    }
}

Describe 'Invoke-PreflightStage' {
    It 'fails when the OS build is below MinOsBuild' {
        Initialize-Healthy
        $min = (Import-PowerShellDataFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'script/lib/pins.psd1')).MinOsBuild
        $below = $min - 1
        Mock -ModuleName Preflight Get-OsBuild ({ $below }.GetNewClosure())
        Invoke-PreflightStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-Invoke -ModuleName Preflight -CommandName Write-Warn -ParameterFilter ({ $Message -like "*$min*" }.GetNewClosure())
    }

    It 'fails when the data volume is not Ok, naming the reason' {
        Initialize-Healthy
        Mock -ModuleName Preflight Test-DataVolume { @{ Ok = $false; Reason = 'volume D is not NTFS' } }
        Invoke-PreflightStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-Invoke -ModuleName Preflight -CommandName Write-Warn -ParameterFilter { $Message -like '*volume D is not NTFS*' }
    }

    It 'checks the drive letter of DistroRoot, uppercased' {
        Initialize-Healthy
        Invoke-PreflightStage -Context (Get-TestContext -DistroRoot 'e:\WSL') | Should-Be 'done'
        Should-Invoke -ModuleName Preflight -CommandName Test-DataVolume -ParameterFilter { $DriveLetter -ceq 'E' }
    }

    It 'fails with a clear message when DistroRoot has no drive letter' {
        Initialize-Healthy
        Invoke-PreflightStage -Context (Get-TestContext -DistroRoot '\\server\share') | Should-Be 'failed'
        Should-Invoke -ModuleName Preflight -CommandName Write-Warn -ParameterFilter { $Message -like '*DistroRoot*' }
        Should-NotInvoke -ModuleName Preflight -CommandName Test-DataVolume
    }

    It 'fails when Documents is redirected' {
        Initialize-Healthy
        Mock -ModuleName Preflight Test-DocumentsRedirected { $true }
        Invoke-PreflightStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-Invoke -ModuleName Preflight -CommandName Write-Warn -ParameterFilter { $Message -like '*Documents*redirect*' }
    }

    It 'fails when virtualization is unavailable, pointing at firmware' {
        Initialize-Healthy
        Mock -ModuleName Preflight Test-VirtualizationAvailable { $false }
        Invoke-PreflightStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-Invoke -ModuleName Preflight -CommandName Write-Warn -ParameterFilter { $Message -like '*Intel VT-x/VT-d*firmware*' }
    }

    It 'fails when lab is selected on Home' {
        Initialize-Healthy -Pro $false
        Invoke-PreflightStage -Context (Get-TestContext -Profiles @('core', 'lab')) | Should-Be 'failed'
        Should-Invoke -ModuleName Preflight -CommandName Write-Warn -ParameterFilter { $Message -like '*The lab profile needs Windows 11 Pro*' }
    }

    It 'reports every failure, not just the first' {
        Initialize-Healthy
        Mock -ModuleName Preflight Get-OsBuild { 1 }
        Mock -ModuleName Preflight Test-DocumentsRedirected { $true }
        Mock -ModuleName Preflight Test-VirtualizationAvailable { $false }
        Invoke-PreflightStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-Invoke -ModuleName Preflight -CommandName Write-Warn -Times 3 -Exactly
    }

    It 'passes on a healthy Pro machine with lab and records the edition' {
        Initialize-Healthy
        $ctx = Get-TestContext -Profiles @('core', 'lab')
        Invoke-PreflightStage -Context $ctx | Should-Be 'done'
        $ctx.Edition.IsPro | Should-BeTrue
        Should-NotInvoke -ModuleName Preflight -CommandName Write-Warn
    }

    It 'passes on Home without lab' {
        Initialize-Healthy -Pro $false
        $ctx = Get-TestContext
        Invoke-PreflightStage -Context $ctx | Should-Be 'done'
        $ctx.Edition.IsHome | Should-BeTrue
    }

    It 'reports edition and Kernel DMA Protection state without failing' {
        Initialize-Healthy
        Mock -ModuleName Preflight Get-KernelDmaProtectionState { 'off' }
        Invoke-PreflightStage -Context (Get-TestContext) | Should-Be 'done'
        Should-Invoke -ModuleName Preflight -CommandName Write-Info -ParameterFilter { $Message -like '*Professional*' }
        Should-Invoke -ModuleName Preflight -CommandName Write-Info -ParameterFilter { $Message -like '*Kernel DMA Protection*off*' }
    }

    It 'returns the same result under -Plan' {
        Initialize-Healthy
        Mock -ModuleName Preflight Test-DocumentsRedirected { $true }
        Invoke-PreflightStage -Context (Get-TestContext) -Plan | Should-Be 'failed'
    }

    It 'fails before any feature cmdlet is called' {
        Initialize-Healthy
        Mock -ModuleName Preflight Test-VirtualizationAvailable { $false }
        Invoke-PreflightStage -Context (Get-TestContext) | Should-Be 'failed'
        Should-NotInvoke -ModuleName Preflight -CommandName Enable-WindowsOptionalFeature
    }
}
