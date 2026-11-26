Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WindowsStub
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Common.psm1') -Force
    Import-Module (Join-Path $script:Root 'script/lib/Runner.psm1') -Force
    Import-Module (Join-Path $script:Root 'script/lib/Apps.psm1') -Force
}

Describe 'profile list' {
    It 'Get-ValidProfiles is the eight profiles in catalogue order' {
        Get-ValidProfiles | Should-BeCollection @('core', 'dev', 'security', 'productivity', 'backup', 'productivity-extra', 'local-llm', 'lab')
    }
    It 'Get-DefaultProfileText is the default set' {
        Get-DefaultProfileText | Should-Be 'core,dev,security,productivity'
    }
    It 'the default profiles hold at most DefaultCap entries' {
        $catalog = Get-AppCatalog
        $catalog.DefaultCap | Should-Be 40
        (Get-AppPackages -Profiles @($catalog.Default)).Count -le $catalog.DefaultCap | Should-BeTrue
    }
}

Describe 'catalogue' {
    It 'every Id is a well-formed winget id' {
        # winget ids are Publisher.Package; Microsoft Store product ids are 12 upper-case letters/digits.
        $bad = @(Get-AppPackages -Profiles (Get-ValidProfiles) | Where-Object {
                if ($_.ContainsKey('Source') -and $_.Source -eq 'msstore') { $_.Id -cnotmatch '^[0-9A-Z]{12}$' }
                else { $_.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9.+_-]*\.[A-Za-z0-9.+_-]+$' }
            })
        $bad.Count | Should-Be 0
    }
    It 'no Id appears in two profiles' {
        $catalog = Get-AppCatalog
        $all = @(foreach ($p in $catalog.Order) { @($catalog.Profiles[$p]) | ForEach-Object { $_.Id } })
        @($all | Select-Object -Unique).Count | Should-Be $all.Count
    }
    It 'every entry has a Name and a profile exists for each Order name' {
        $catalog = Get-AppCatalog
        @($catalog.Profiles.Keys | Sort-Object) | Should-BeCollection @($catalog.Order | Sort-Object)
        @(Get-AppPackages -Profiles $catalog.Order | Where-Object { -not $_.Name }).Count | Should-Be 0
    }
    It '<Profile> holds exactly the expected ids' -ForEach @(
        @{ Profile = 'core'; Ids = @('Microsoft.WindowsTerminal', 'Microsoft.PowerShell', 'Git.Git', 'twpayne.chezmoi') }
        @{ Profile = 'dev'; Ids = @('Microsoft.VisualStudioCode', 'ZedIndustries.Zed') }
        @{ Profile = 'security'; Ids = @('Bitwarden.Bitwarden', 'Henry++.simplewall') }
        @{ Profile = 'productivity'; Ids = @('Obsidian.Obsidian') }
        @{ Profile = 'backup'; Ids = @('restic.restic', 'Rclone.Rclone') }
        @{ Profile = 'productivity-extra'; Ids = @('Google.Chrome', 'Mozilla.Firefox', 'SlackTechnologies.Slack', 'Anthropic.Claude', '9PLM9XGG6VKS', 'OBSProject.OBSStudio', 'mpv.net', 'Tailscale.Tailscale', 'OpenVPNTechnologies.OpenVPN') }
        @{ Profile = 'local-llm'; Ids = @('ElementLabs.LMStudio') }
        @{ Profile = 'lab'; Ids = @() }
    ) {
        @(Get-AppPackages -Profiles @($Profile) | ForEach-Object { $_.Id }) | Should-BeCollection $Ids
    }
    It 'only chezmoi carries a Scope (user, as WslConfig installs it)' {
        $scoped = @(Get-AppPackages -Profiles (Get-ValidProfiles) | Where-Object { $_.ContainsKey('Scope') })
        @($scoped | ForEach-Object { $_.Id }) | Should-BeCollection @('twpayne.chezmoi')
        $scoped[0].Scope | Should-Be 'user'
    }
    It 'Firefox is the release channel and browsers carry no Scope' {
        $ids = @(Get-AppPackages -Profiles (Get-ValidProfiles) | ForEach-Object { $_.Id })
        $ids -contains 'Mozilla.Firefox' | Should-BeTrue
        $ids -contains 'Mozilla.Firefox.DeveloperEdition' | Should-BeFalse
        $browsers = @(Get-AppPackages -Profiles @('productivity-extra') | Where-Object { $_.Id -in 'Google.Chrome', 'Mozilla.Firefox' })
        $browsers.Count | Should-Be 2
        @($browsers | Where-Object { $_.ContainsKey('Scope') }).Count | Should-Be 0
    }
}

Describe 'Get-AppPackages' {
    It 'returns the selected profiles in catalogue order, each tagged with its Profile' {
        $r = @(Get-AppPackages -Profiles @('productivity-extra', 'core'))
        $r.Count | Should-Be 13
        @($r[0..3] | ForEach-Object { $_.Profile } | Select-Object -Unique) | Should-BeCollection @('core')
        $r[0].Id | Should-Be 'Microsoft.WindowsTerminal'
        $r[4].Id | Should-Be 'Google.Chrome'
        @($r[4..12] | ForEach-Object { $_.Profile } | Select-Object -Unique) | Should-BeCollection @('productivity-extra')
    }
    It 'returns an empty array for lab' {
        $r = @(Get-AppPackages -Profiles @('lab'))
        $r.Count | Should-Be 0
    }
}

Describe 'ConvertTo-ProfileList' {
    It 'always includes core first' {
        InModuleScope Runner { ConvertTo-ProfileList 'dev,local-llm' } | Should-BeCollection @('core', 'dev', 'local-llm')
    }
    It 'rejects an unknown name and names the valid list' {
        { InModuleScope Runner { ConvertTo-ProfileList 'nope' } } | Should-Throw -ExceptionMessage '*nope*Valid: core, dev, security, productivity, backup, productivity-extra, local-llm, lab*'
    }
}
