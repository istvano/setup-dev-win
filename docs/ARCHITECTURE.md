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

Stage-0 (`bootstrap.ps1`, Windows PowerShell 5.1) refuses an elevated launch, checks
the OS and winget, installs PowerShell 7.6 as the machine-wide MSI unless an installed
7.6.x at or above the `pins.psd1` floor is present (ADR-014), and hands off to
`script/setup.ps1` under `pwsh`, waiting for that process only (not its descendants).
It never calls `Set-ExecutionPolicy` (the operator launches it with a process-scope
Bypass). `setup` is a thin entry point; `script/lib/Runner.psm1` runs the stages in
order, keeping results in `%LOCALAPPDATA%\setup-dev-win\state.json`, and seeds
`Context.Edition` from `Get-EditionInfo` (a registry read) so a re-run that skips
preflight still has it. The same file keeps the operator's choices (`profiles`,
`distroRoot`, `linuxUser`): an explicit flag wins and is kept, else the kept value, else
the default (ADR-015).

| Stage | Does | Elevation |
|---|---|---|
| preflight | edition, build, data volume, Documents not redirected, virtualization, Kernel DMA state | none |
| features | enable `VirtualMachinePlatform` (Hyper-V only with `lab` on Pro, refused on Home); state read via CIM | one UAC prompt from this repo (`script/elevated/`); `wsl --install`/`--update` raise their own |
| dotfiles | pinned chezmoi, apply `.wslconfig`, offer `wsl --shutdown` | refuses to run elevated |
| wsl | verified image, install `dev`, default user, password, handoff to the Linux repo | none |
| verify | read-only checks, always run (see OPERATIONS) | none |

Exit 3010 means reboot required; the operator re-runs `pwsh -File script\setup.ps1`.
Elevated work lives only under `script/elevated/` and is allowlisted by name; its
`[warn]`/`[fail]` lines also go to `%LOCALAPPDATA%\setup-dev-win\elevated.log`, which the
features stage prints after a failure (ADR-010).

UAC prompts on a first run, by source: the Git installer (README step 2, before this
repository runs); the PowerShell MSI (stage-0); `Enable-Features.ps1` (the only
elevation this repository performs, through `script/elevated/`); `wsl --install
--no-distribution`, which elevates itself; possibly `wsl --update`. The repository
itself elevates only through `script/elevated/` (ADR-004). See OPERATIONS.

The handoff runs a fixed bash program inside `dev` that refuses a clone with a foreign
origin, resolves the ref before checking it out and never falls back to stale code
(ADR-013).

`.wslconfig` is rendered from `chezmoi/dot_wslconfig.tmpl`: `[wsl2]` memory, processors,
swap, networkingMode=nat, localhostForwarding, firewall, telemetry=false; `[general]`
distributionInstallPath; `[experimental]` sparseVhd, autoMemoryReclaim. A key in the wrong
section is silently ignored by WSL, so the tests assert each key's section.

`script/verify.ps1` and the verify stage share `Invoke-VerifyChecks`
(`script/stages/Verify.psm1`); the script (`Invoke-VerifyCommand`) adds no runner, reads
the kept choices when its flags are absent and writes nothing.

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
