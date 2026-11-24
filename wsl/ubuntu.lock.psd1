# Pinned WSL distro image. ASCII-only: Windows PowerShell 5.1 may read this file (AGENTS.md).
# Values copied from the Ubuntu-26.04 Amd64Url entry of Source; the SHA256 was also
# confirmed by downloading the file and hashing it.
@{
    Name = 'Ubuntu-26.04'
    Url = 'https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-wsl-amd64.wsl'
    Sha256 = '48d56724b5c8e60f24893e83e73bbb58c60b3ca22fba3da977075420acd54104'
    Source = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
    CheckedOn = '2026-11-24'
}
