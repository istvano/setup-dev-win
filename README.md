# setup-dev-win

Provisions a Windows 11 x64 workstation (winget apps, Windows features, a WSL2 distro
on `D:`) and hands off to the companion Linux repository
[`setup-dev-linux-wsl`](https://github.com/istvano/setup-dev-linux-wsl), which builds
the development environment inside the distro. It mirrors the operator's macOS
repository `setup-dev-mac`.

**Status:** milestone 1 (bootstrap to a working WSL distro) is implemented: stage-0,
preflight, features, dotfiles (`.wslconfig`), wsl and verify. Phase W3 adds the apps
stage (winget profiles and the Nerd Font); its hardware acceptance is open. Windows
defaults and hardening are listed in `TASKS.md`.

## Profiles

Selected with `-Profiles` (comma-separated; `core` is always included) and remembered.
Default: `core,dev,security,productivity`.

| Profile | Default | Packages |
|---|---|---|
| core | yes | Windows Terminal, PowerShell, Git, chezmoi, JetBrains Mono Nerd Font |
| dev | yes | Visual Studio Code, Zed |
| security | yes | Bitwarden, simplewall |
| productivity | yes | Obsidian |
| backup | no | restic, rclone |
| productivity-extra | no | Chrome, Firefox, Slack, Claude, ChatGPT, OBS Studio, mpv.net, Tailscale, OpenVPN |
| local-llm | no | LM Studio |
| lab | no | none (Hyper-V, Pro only) |

A machine that already remembered `profiles` keeps it; pass `-Profiles` to change it.

## Quick start

On a fresh Windows 11 x64 machine:

1. Sign in once (winget's App Installer registers only after first interactive login).
2. `winget install --id Git.Git -e --source winget`, then open a new terminal (so `git` is on PATH).
3. `git clone` this repository to a path of your choice (`D:\src\setup-dev-win` is suggested; nothing depends on it).
4. `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1` from a normal (not elevated) terminal.
   On a machine without a `D:` drive, choose the distro root here:
   `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -DistroRoot C:\WSL`.

After a reboot or a failure, re-run `pwsh -File script\setup.ps1` (or step 4 again);
stages are idempotent and `-Profiles`, `-DistroRoot` and `-LinuxUser` are remembered.
Check the result at any time, read-only, with `pwsh -File script\verify.ps1` (exit 0 =
all good). Expect a few UAC prompts on the first run (Git, enabling Windows features,
the WSL installer, and any app installer that needs admin); installing PowerShell 7 (the MSIX package) normally raises none.
See `docs/OPERATIONS.md`.

**When the run finishes, two steps inside `wsl -d dev` are yours:** make zsh your login
shell with `chsh -s /usr/bin/zsh` (until then WSL opens in bash without the installed
tools), and enrol the printed SSH key at GitHub as both an authentication and a signing
key. See "After the first successful run" in `docs/OPERATIONS.md`.

## Principles

- Windows host only; everything engineering lives in WSL (ADR-001).
- winget is the only package manager (ADR-002).
- No download-and-run script anywhere (ADR-003).
- Elevation per step, never for the whole run (ADR-004).
- Resumable, idempotent stages; the operator re-runs after a reboot (ADR-005).
- WSL networking is NAT, never mirrored (ADR-006).
- PowerShell, chezmoi and the Ubuntu image are the latest stable releases at install
  time; the image is verified against the SHA256 in Microsoft's manifest (ADR-016).

## Test

```powershell
pwsh -File script/test.ps1 -RequireLinters
```

Pinned tool versions are in `tests/tool-versions.psd1`. See `AGENTS.md` for the rules
and `docs/` for architecture, decisions and the runbook.
