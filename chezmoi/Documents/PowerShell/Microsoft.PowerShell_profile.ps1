# Owned by chezmoi (setup-dev-win). Edit the copy in the repository, not this file.
# Deliberately no strict mode and no ErrorActionPreference override: this file is
# dot-sourced into your interactive session, where either would break ad-hoc commands.

# Shell history and inline prediction from history.
if (Get-Module -ListAvailable PSReadLine) {
    Set-PSReadLineOption -HistoryNoDuplicates -MaximumHistoryCount 10000 -PredictionSource History
}

# dev: open the dev WSL distro in the Linux home directory; arguments run a command there.
# The tilde is built from its character code: PowerShell 7.5+ expands a bare ~ in a native
# argument to the Windows profile path, which is not the Linux home.
function dev { wsl.exe -d dev --cd ([string][char]126) @args }
