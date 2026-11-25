# setup-dev-win

Provisions a Windows 11 x64 workstation (winget apps, Windows features, a WSL2 distro
on `D:`) and hands off to the companion Linux repository
[`setup-dev-linux-wsl`](https://github.com/istvano/setup-dev-linux-wsl), which builds
the development environment inside the distro. It mirrors the operator's macOS
repository `setup-dev-mac`.

**Status:** milestone 1 (bootstrap to a working WSL distro) is implemented: stage-0,
preflight, features, dotfiles (`.wslconfig`), wsl and verify. App profiles, Windows
defaults and hardening are listed in `TASKS.md`.

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
the WSL installer); installing PowerShell 7 (the MSIX package) normally raises none.
See `docs/OPERATIONS.md`.

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
