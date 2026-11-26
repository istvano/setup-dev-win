# Version floors and fixed settings. ASCII-only: Windows PowerShell 5.1 reads this file.
# MinPowerShell is a floor with no upper bound: stage-0 installs the latest stable
# PowerShell and accepts any installed pwsh at or above it (ADR-016).
@{
    MinPowerShell = '7.6'
    MinOsBuild = 26100
    MinWslVersion = '2.4.4'
    LinuxRepoOwner = 'istvano'
}
