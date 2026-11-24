#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

# The fixed bash program. A literal: no PowerShell interpolation, no single
# quote (it is wrapped in single quotes on the command line). The repository URL
# and ref reach it only as $1 and $2 (bash -c <script> handoff <url> <ref>).
$script:HandoffScript = 'set -Eeuo pipefail; url=$1; ref=$2; ' +
'command -v git >/dev/null || { echo "git missing in the image" >&2; exit 2; }; ' +
'mkdir -p ~/workspace; ' +
'[ -d ~/workspace/setup-dev-linux-wsl/.git ] || git clone "$url" ~/workspace/setup-dev-linux-wsl; ' +
'cd ~/workspace/setup-dev-linux-wsl; ' +
'git fetch --quiet origin; git checkout --quiet "$ref"; git pull --ff-only --quiet || true; ' +
'exec ./bootstrap apply --target wsl'

function Test-LinuxRepoUrl {
    <#
    .SYNOPSIS
        True for an https GitHub repository URL with no characters a shell could use.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Url)
    return [bool]($Url -cmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?\z')
}

function Test-GitRef {
    <#
    .SYNOPSIS
        True for a branch, tag or commit name that cannot be read as an option or by a shell.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Ref)
    return [bool]($Ref -cmatch '^[A-Za-z0-9._/-]{1,200}\z' -and -not $Ref.StartsWith('-', [System.StringComparison]::Ordinal))
}

function Invoke-HandoffProcess {
    # Internal, mockable. Runs wsl.exe attached to the console (the Linux bootstrap
    # prompts for the git identity) and returns the exit code as exactly one [int].
    # Same technique as Distro's Invoke-DistroInteractive: -NoNewWindow keeps the
    # console, -Wait is avoided (it waits for descendants), Handle is read once so
    # ExitCode survives. ArgumentLine is one string built only from validated parts.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$ArgumentLine)
    $env:WSL_UTF8 = '1'
    $p = @(Start-Process -FilePath 'wsl.exe' -ArgumentList $ArgumentLine -NoNewWindow -PassThru)[-1]
    $null = $p.Handle
    $p.WaitForExit()
    return [int]$p.ExitCode
}

function Invoke-LinuxHandoff {
    <#
    .SYNOPSIS
        Runs setup-dev-linux-wsl's bootstrap inside the dev distro, interactively.
    .DESCRIPTION
        Url and ref are validated, then passed as positional arguments after the fixed
        script, never substituted into it. Exit 2 from the script means git is missing
        from the image: git is installed as root and the handoff retried once.
    .OUTPUTS
        The bootstrap's exit code (0 = success).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Ref
    )
    if (-not (Test-LinuxRepoUrl -Url $Url)) { throw "Invalid Linux repository url '$Url': expected https://github.com/<owner>/<repo>[.git]." }
    if (-not (Test-GitRef -Ref $Ref)) { throw "Invalid Linux repository ref '$Ref'." }

    $line = "-d dev --cd ~ -- bash -c '$($script:HandoffScript)' handoff `"$Url`" `"$Ref`""
    $code = Invoke-HandoffProcess -ArgumentLine $line
    if ($code -eq 2) {
        Write-Warn 'git is missing in dev; installing it as root, then retrying the handoff once.'
        Invoke-Native -FilePath 'wsl.exe' -ArgumentList @('-d', 'dev', '-u', 'root', '--', 'sh', '-c',
            'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y git') | Out-Null
        $code = Invoke-HandoffProcess -ArgumentLine $line
    }
    return [int]$code
}

Export-ModuleMember -Function Test-LinuxRepoUrl, Test-GitRef, Invoke-LinuxHandoff
