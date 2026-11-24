# Decisions

Durable architectural decisions. Section references are to
`docs/superpowers/specs/2026-11-24-setup-dev-win-linux-design.md`.

## ADR-001: Two repositories, this one Windows host only

Status: accepted. Spec sections 3 and 5.

The Windows host and the Linux development environment live in separate repositories
so each follows its platform's conventions. This repository covers the Windows host
and hands off to `setup-dev-linux-wsl`, which is reusable on any Ubuntu machine. The
operator's older `istvano/setup-dev-linux` is unrelated and is never touched or
depended on.

## ADR-002: winget only

Status: accepted. Spec section 3.

| | winget | Scoop | Chocolatey |
|---|---|---|---|
| Installer origin | Publisher's site; redirectors rejected | Publisher's site | Publisher's site, via maintainer script |
| Integrity | SHA256 mandatory per manifest | SHA256, but the update bot hashes whatever it downloaded | Checksum required only for non-HTTPS |
| What executes | The vendor installer only | Installer plus optional arbitrary PowerShell hooks | Maintainer PowerShell, usually as admin |
| Review of new versions | Microsoft pipeline: multi-AV, dynamic analysis, moderators | Mostly none | Human review except trusted maintainers |

winget is Microsoft's, the closest analogue of Homebrew casks, and has the strongest
review. Scoop and Chocolatey are not installed and no script may reference them.

## ADR-003: Stage-0 trust boundary, no download-and-run

Status: accepted. Spec section 6.3.

Windows has no download-and-run script. The only network-to-execution paths are
winget (hash-pinned, Microsoft-validated), `git clone` of the operator's own
repositories and the SHA256-verified Ubuntu image. Stage-0 never downloads winget and
never installs a module from PSGallery. `Invoke-Expression`, `iex` and
`DownloadString` are banned and enforced by `tests/Repo.Tests.ps1`.

## ADR-004: Elevation per step, daily admin account

Status: accepted. Spec section 6.2.

The daily account is an administrator, so an elevated step runs as the same user after
a UAC consent. Only scripts under `script/elevated/`, launched by
`Invoke-ElevatedScript`, run elevated and each states why. `script/setup.ps1` refuses
to run elevated so nothing lands in an elevated context by accident. A standard daily
user is not supported in v1.

## ADR-005: Resumable stages, manual re-run after reboot

Status: accepted. Spec section 6.4.

`script/setup.ps1` is a sequence of named, idempotent stages with a state file under
`%LOCALAPPDATA%\setup-dev-win\`. A stage needing a reboot records it and exits with a
distinct code; the operator re-runs after the reboot. There is no RunOnce auto-resume:
that keeps the operator in control and avoids an elevated autorun entry.

## ADR-006: WSL NAT networking, never mirrored

Status: accepted. Spec section 8.1.

Mirrored mode exposes WSL services on the host's LAN address, is documented alongside
advice to set the Hyper-V firewall to inbound Allow, and breaks Docker 28+
loopback-published ports. `.wslconfig` sets `networkingMode=nat` and `firewall=true`
and `mirrored` appears nowhere.

## ADR-007: Distro on D:, repositories on ext4 inside it

Status: accepted. Spec section 2.

The `dev` distro's VHDX is installed at `<root>\dev` (default `D:\WSL`) and
`distributionInstallPath` is set to the root. Repositories live in `~/workspace` on
ext4 inside it, never on `/mnt/c` or `/mnt/d`, where 9P is far slower and exec bits and
case sensitivity break. Docker and tool caches stay at their Linux defaults, which are
physically on D: because the VHDX is.

## ADR-008: Hyper-V only with `lab`, on Pro

Status: accepted. Spec section 6.4.

`Microsoft-Hyper-V-All` is enabled only when the `lab` profile is selected AND the
edition is Pro, which keeps the default attack surface smaller and Home working.
`Containers-DisposableClientVM` (Sandbox) is never touched. Capabilities are detected,
never assumed. The edition is read from the `EditionID` registry value under
`HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` (`Core` = Home, `Professional` =
Pro): `Get-WindowsEdition` is a DISM cmdlet that needs elevation, and admin-only
cmdlets stay inside `script/elevated/`.
