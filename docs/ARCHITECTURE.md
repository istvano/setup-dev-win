# Architecture

Current state. Section references are to
`docs/superpowers/specs/2026-11-24-setup-dev-win-linux-design.md`.

## Boundaries

| Boundary | What runs there |
|---|---|
| Windows host | GUI apps, VPNs, the outbound firewall, drivers, Windows Terminal |
| WSL2 distro `dev` | All engineering CLI and AI work, owned by `setup-dev-linux-wsl` |
| Hyper-V VM (Pro) | Hostile work and the destructive test harness |

This repository owns the first row and the WSL host settings (`.wslconfig`, the distro
install, cloud-init, the handoff). It never configures anything inside the distro
beyond first boot.

## Stage flow

Stage-0 (`bootstrap.ps1`, Windows PowerShell 5.1) checks the OS, winget and PowerShell 7,
installs the pinned PowerShell 7 and hands off to `script/setup.ps1` under `pwsh`. It
never calls `Set-ExecutionPolicy` (the operator launches it with a process-scope Bypass).
`setup` is a thin entry point; `script/lib/Runner.psm1` runs the stages in order, keeping
results in `%LOCALAPPDATA%\setup-dev-win\state.json`, and seeds `Context.Edition` from
`Get-EditionInfo` (a registry read) so a re-run that skips preflight still has it.

| Stage | Does | Elevation |
|---|---|---|
| preflight | edition, build, data volume, Documents not redirected, virtualization, Kernel DMA state | none |
| features | enable `VirtualMachinePlatform` (Hyper-V only with `lab` on Pro); state read via CIM | one UAC prompt, `script/elevated/` only |
| dotfiles | pinned chezmoi, apply `.wslconfig`, offer `wsl --shutdown` | refuses to run elevated |
| wsl | verified image, install `dev`, default user, password, handoff to the Linux repo | none |
| verify | read-only checks, always run (see OPERATIONS) | none |

Exit 3010 means reboot required; the operator re-runs. Elevated work lives only under
`script/elevated/` and is allowlisted by name.

`.wslconfig` is rendered from `chezmoi/dot_wslconfig.tmpl`: `[wsl2]` memory, processors,
swap, networkingMode=nat, localhostForwarding, firewall, telemetry=false; `[general]`
distributionInstallPath; `[experimental]` sparseVhd, autoMemoryReclaim. A key in the wrong
section is silently ignored by WSL, so the tests assert each key's section.

`script/verify.ps1` and the verify stage share `Invoke-VerifyChecks`
(`script/stages/Verify.psm1`); the script adds no runner and no state.

## Ownership

Each file or setting has exactly one owner; neither repository writes into the other's
territory (spec 5.1).

| Item | Owner |
|---|---|
| winget apps, fonts, Windows Terminal, PowerShell profile, Windows settings, Defender/ASR, UAC, privacy policy, firewall (Windows + Hyper-V firewall checks), simplewall | win |
| Windows optional features, WSL install/update, Hyper-V | win |
| `%UserProfile%\.wslconfig` | win |
| Downloading, verifying and installing the distro; cloud-init user-data; distro name and location | win |
| `C:\Program Files\ClaudeCode\managed-settings.json` (Windows-side policy for WSL to inherit) | win |
| VS Code user settings (host side) and the `remote-wsl` extension | win |
| Everything inside the distro: apt, Homebrew, mise, dotfiles, Docker, CUDA, agents | linux |
| `/etc/wsl.conf` | linux (WSL target only) |
| `/etc/claude-code/managed-settings.json`, `/etc/codex/requirements.toml` | linux |
| VS Code server-side extensions (installed into `~/.vscode-server` from WSL) | linux |
| Network exposure verify: Windows listeners, portproxy, Hyper-V firewall | win |
| Network exposure verify: Linux listeners, Docker binds | linux |

Milestone 1 implements the rows for features, `.wslconfig` and the distro; the other
`win` rows are planned (`TASKS.md`).

## The gate

`script/test.ps1` runs PSScriptAnalyzer (any Error or Warning fails), a formatting
check with `Invoke-Formatter`, then Pester 6. Modules are imported by the exact
versions in `tests/tool-versions.psd1`. A missing module is a loud SKIP, or a failure
under `-RequireLinters` / `REQUIRE_LINTERS=1`.
