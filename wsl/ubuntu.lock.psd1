# WSL distro lock. ASCII-only: Windows PowerShell 5.1 may read this file (AGENTS.md).
# Name is the distro; Source is Microsoft's manifest. The image URL and SHA256 are
# not frozen here: Resolve-DistroImage reads them from Source over https at install
# time, so the newest point release of Name is installed and verified (ADR-016).
@{
    Name = 'Ubuntu-26.04'
    Source = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
}
