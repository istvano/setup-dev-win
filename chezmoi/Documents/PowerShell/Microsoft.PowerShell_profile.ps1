# Owned by chezmoi (setup-dev-win). Edit the copy in the repository, not this file.
# Deliberately no strict mode and no ErrorActionPreference override: this file is
# dot-sourced into your interactive session, where either would break ad-hoc commands.

# Shell history and inline prediction from history.
if (Get-Module -ListAvailable PSReadLine) {
    Set-PSReadLineOption -HistoryNoDuplicates -MaximumHistoryCount 10000 -PredictionSource History
}

# dev: open the dev WSL distro in the Linux home directory; arguments run a command there.
# The tilde is a quoted literal written at the call site because PowerShell 7.5+ expands a
# tilde in a native argument to the Windows profile path (not the Linux home) in every other
# form: bare, via a variable, via [char]126 or splatted (ADR-024). Only '~' or "~" typed
# directly there reaches wsl.exe unchanged. The same expansion applies to a ~ you pass
# through @args, so `dev ls ~` lists the Windows home: quote the whole command in one string
# (dev 'ls ~'), or open the shell with `dev` and type there.
function dev { wsl.exe -d dev --cd '~' @args }
