# Exact versions of the tools the gate and CI use. script/test.ps1 imports Pester
# and PSScriptAnalyzer by these versions; CI installs exactly these.
@{
    Pester = '6.2.0'
    PSScriptAnalyzer = '1.25.0'
    Chezmoi = @{
        Version = '2.74.2'
        WindowsAmd64Sha256 = '6b3a0480d0d31cc72a9ef676ae44bb6a5de1222c7bca11db8799a59e9df0e78a'
    }
}
