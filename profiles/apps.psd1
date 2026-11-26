# The application catalogue: winget IDs per profile (ADR-016: latest stable, never pinned).
# Import-PowerShellDataFile does not preserve [ordered], so Order is the catalogue order.
# An entry may set Scope = 'user' | 'machine'; absent means no --scope. Browsers never
# set one: an app the operator installed by hand is adopted, never duplicated.
@{
    Default = @('core', 'dev', 'security', 'productivity')
    DefaultCap = 40
    Order = @('core', 'dev', 'security', 'productivity', 'backup', 'productivity-extra', 'local-llm', 'lab')
    Profiles = @{
        core = @(
            @{ Id = 'Microsoft.WindowsTerminal'; Name = 'Windows Terminal' }
            @{ Id = 'Microsoft.PowerShell'; Name = 'PowerShell' }
            @{ Id = 'Git.Git'; Name = 'Git' }
            @{ Id = 'twpayne.chezmoi'; Name = 'chezmoi'; Scope = 'user' }
        )
        dev = @(
            @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code' }
            @{ Id = 'ZedIndustries.Zed'; Name = 'Zed' }
        )
        security = @(
            @{ Id = 'Bitwarden.Bitwarden'; Name = 'Bitwarden' }
            @{ Id = 'Henry++.simplewall'; Name = 'simplewall' }
        )
        productivity = @(
            @{ Id = 'Obsidian.Obsidian'; Name = 'Obsidian' }
        )
        backup = @(
            @{ Id = 'restic.restic'; Name = 'restic' }
            @{ Id = 'Rclone.Rclone'; Name = 'rclone' }
        )
        'productivity-extra' = @(
            @{ Id = 'Google.Chrome'; Name = 'Google Chrome' }
            @{ Id = 'Mozilla.Firefox'; Name = 'Firefox' }
            @{ Id = 'SlackTechnologies.Slack'; Name = 'Slack' }
            @{ Id = 'Anthropic.Claude'; Name = 'Claude' }
            @{ Id = 'OpenAI.ChatGPT'; Name = 'ChatGPT' }
            @{ Id = 'OBSProject.OBSStudio'; Name = 'OBS Studio' }
            @{ Id = 'mpv.net'; Name = 'mpv.net' }
            @{ Id = 'Tailscale.Tailscale'; Name = 'Tailscale' }
            @{ Id = 'OpenVPNTechnologies.OpenVPN'; Name = 'OpenVPN' }
        )
        'local-llm' = @(
            @{ Id = 'ElementLabs.LMStudio'; Name = 'LM Studio' }
        )
        # Hyper-V only, Pro only: no winget package.
        lab = @()
    }
}
