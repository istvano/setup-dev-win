# setup-dev-win

Provisions a Windows 11 x64 workstation (winget apps, Windows features, a WSL2 distro
on `D:`) and hands off to the companion Linux repository
[`setup-dev-linux-wsl`](https://github.com/istvano/setup-dev-linux-wsl), which builds
the development environment inside the distro. It mirrors the operator's macOS
repository `setup-dev-mac`.

**Status:** milestone 1 is in progress. Only the skeleton, documentation and the test
gate exist; the bootstrap, stages and profiles are listed in `TASKS.md`.

## Principles

- Windows host only; everything engineering lives in WSL (ADR-001).
- winget is the only package manager (ADR-002).
- No download-and-run script anywhere (ADR-003).
- Elevation per step, never for the whole run (ADR-004).
- Resumable, idempotent stages; the operator re-runs after a reboot (ADR-005).
- WSL networking is NAT, never mirrored (ADR-006).

## Test

```powershell
pwsh -File script/test.ps1 -RequireLinters
```

Pinned tool versions are in `tests/tool-versions.psd1`. See `AGENTS.md` for the rules
and `docs/` for architecture, decisions and the runbook.
