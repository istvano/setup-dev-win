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

## Planned flow

Stage-0 (`bootstrap.ps1`, Windows PowerShell 5.1) checks the OS, winget and PowerShell
7, then hands off to `script/setup.ps1` under `pwsh`. `setup` runs named, idempotent
stages with a state file: preflight, features, apps, dotfiles, defaults, hardening,
wsl, verify (spec 6.4). Elevated work runs only from `script/elevated/`.

## What exists today

The skeleton only: `script/test.ps1` (the gate), `tests/Repo.Tests.ps1` (repository
invariants), `tests/tool-versions.psd1` (pinned gate tools), `PSScriptAnalyzerSettings.psd1`
and the documentation. `bootstrap.ps1`, `script/setup.ps1`, `script/lib/`,
`script/elevated/` and `profiles/` do not exist yet; `TASKS.md` and the milestone plan
track them.

## The gate

`script/test.ps1` runs PSScriptAnalyzer (any Error or Warning fails), a formatting
check with `Invoke-Formatter`, then Pester 6. Modules are imported by the exact
versions in `tests/tool-versions.psd1`. A missing module is a loud SKIP, or a failure
under `-RequireLinters` / `REQUIRE_LINTERS=1`.
