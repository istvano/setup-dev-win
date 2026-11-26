# Repository instructions

## Mission

Provision a secure, reproducible Windows 11 x64 host for an expert software
engineer specialising in security and AI, and hand off to the companion
`setup-dev-linux-wsl` repository, which owns everything inside the WSL distro. It
mirrors the operator's macOS repository `setup-dev-mac`, from which it is ported in
spirit. This repository covers the Windows host only (ADR-001).

This is infrastructure code. Treat changes as security-sensitive, operationally
consequential and expected to remain understandable years later.

## Current user decisions

These are deliberate defaults, not placeholders:

- Target platform: Windows 11 x64 ONLY, minimum OS build 26100 (24H2). Assert a
  build number, never a version name. Home must not break; Pro adds features.
- Never write a capability claim that is true of only one machine or edition.
  Detect it (edition, virtualization, nested virtualization) rather than remember it.
- Language: scripts under `script/` need PowerShell 7.6 or later. `pins.psd1`
  `MinPowerShell` (7.6) is a floor with no upper bound; stage-0 installs the latest
  stable PowerShell, which is MSIX (ADR-016). `bootstrap.ps1` alone runs on Windows
  PowerShell 5.1.
- Package manager: winget ONLY. Scoop and Chocolatey are rejected (ADR-002).
- Configuration engine: chezmoi (`.chezmoiroot` points at `chezmoi/`).
- Distro: name `dev`, installed at `<root>\dev` (default root `D:\WSL`; `C:\WSL` is
  an example for a machine without `D:`), image the newest `Ubuntu-26.04` amd64 `.wsl`.
  Its URL and SHA256 are resolved at install time from Microsoft's
  `DistributionInfo.json` over https; `wsl/ubuntu.lock.psd1` holds only `Name` and
  `Source`, and the URL host must be `releases.ubuntu.com` or `cdimage.ubuntu.com`
  (ADR-016). If the Linux repo falls back to 24.04, this repo uses
  `Ubuntu-24.04` with it; releases are never mixed. Repos live on ext4 inside the
  distro, never on `/mnt/c` or `/mnt/d` (ADR-007).
- WSL networking is NAT, never mirrored (ADR-006).
- Hyper-V is enabled only when the `lab` profile is selected AND the edition is Pro
  (ADR-008). `Containers-DisposableClientVM` (Sandbox) is never touched.
- Handoff repo: `https://github.com/istvano/setup-dev-linux-wsl`, default ref `main`.
- Exploit development, malware analysis and untrusted binaries belong in an isolated
  VM, not on the host and not in the daily distro.

## Non-negotiable architecture

Use the smallest appropriate execution boundary:

1. **Windows host** for GUI applications, VPNs, the outbound firewall, drivers and
   anything that needs the Windows desktop.
2. **WSL2 distro** for all engineering CLI and AI work (owned by the Linux repo).
3. **Hyper-V VM (Pro)** for hostile work and the destructive test harness.

Do not install on the host what belongs in the distro merely because a winget
package exists.

## Sources of truth

- `bootstrap.ps1`: stage-0, Windows PowerShell 5.1-compatible, ASCII only.
- `script/`: PowerShell 7 commands. `script/lib/` is the shared module and
  `script/elevated/` holds the only scripts that may run elevated (ADR-004).
- `script/lib/pins.psd1`: version floors and fixed settings read by stage-0
  (`MinPowerShell`, `MinOsBuild`, `MinWslVersion`, `LinuxRepoOwner`); no
  installed-version pins. ASCII only.
- `wsl/ubuntu.lock.psd1`: the distro `Name` and manifest `Source`. ASCII only.
- `profiles/apps.psd1`: the app catalogue: profiles, default set and cap (ADR-020,
  ADR-022). `profiles/drift-allowlist.psd1`: inbox and OEM Ids the drift line ignores.
  winget calls for apps go only through `script/lib/Winget.psm1`.
- `chezmoi/`: Windows-side user configuration (`.wslconfig`, the PowerShell profile).
- `script/lib/TerminalSettings.psm1`: the declared Windows Terminal keys and their merge
  (ADR-024). `vscode/extensions.list`: Windows-side VS Code extensions (ADR-025). The
  repository never edits VS Code's or Zed's `settings.json`. The `apps`, `dotfiles` and
  `verify` stages run on every pass.
- `script/lib/PostureChecks.psm1`: the declared posture checks behind
  `script/hardening-check.ps1` (ADR-026). The report is read-only and a repository test
  enforces it: no registry write, no `Set-`/`Enable-`/`Disable-`/`Remove-`, no `netsh`
  change, no elevation. A value that cannot be read is `UNKNOWN`, never `RECOMMEND`.
- `tests/`: Pester 6 tests; `tests/tool-versions.psd1` pins the gate's own tools.
- `docs/ARCHITECTURE.md`: current boundaries. `docs/DECISIONS.md`: the ADR log.
  `docs/OPERATIONS.md`: the runbook. `TASKS.md`: unfinished work only.

Files that do not exist yet are future work; the docs say so rather than imply them.

## Change workflow

Before editing: read `README.md`, `docs/ARCHITECTURE.md` and `docs/DECISIONS.md`;
inspect the relevant source-of-truth files; check `git status`; verify package ids,
licences and product behaviour against vendor documentation when the network is
available, and say when that was impossible.

While editing:

- Prefer a small focused patch. Preserve idempotency.
- Keep logic in small scripts. There is no `justfile`: `script/` names are the
  interface (`setup`, `verify`, `hardening-check`, `test`, ...).
- One tool per job in the default profile. Explain each package's purpose and why
  its execution boundary is correct.
- Never put credentials, recovery keys, private addresses or machine-specific
  absolute paths in tracked files. `D:\WSL` appears only as a prompt default.
- No download-and-run, anywhere, including CI (ADR-003).
- Every GitHub Action is pinned to a 40-hex commit SHA and every CI tool or module
  to an exact version. No PSGallery install outside CI.
- The repository never commits, tags, pushes or creates remotes; the operator does.

After editing: run the gate, run the most specific checks for the area, and report
what was tested and what could not be (Windows-only behaviour is proven only by
mocks off Windows; CI on `windows-2025` is authoritative but cannot prove
client-only behaviour).

## Standard commands

```powershell
pwsh -File script/test.ps1                  # the gate
pwsh -File script/test.ps1 -RequireLinters  # what CI runs; no silent skips
```

On a machine without pwsh, run the gate in a throwaway PowerShell container with the
pinned modules installed inside the container only.

## PowerShell standards

- Every `.ps1` and `.psm1` begins with `Set-StrictMode -Version Latest` and
  `$ErrorActionPreference = 'Stop'`. PowerShell 7 files also set
  `$PSNativeCommandUseErrorActionPreference = $true`, scoped off around tools whose
  non-zero exit means success (robocopy). Stage-0 checks `$LASTEXITCODE` by hand.
- `bootstrap.ps1` and every file Windows PowerShell 5.1 reads are ASCII-only: 5.1
  decodes a BOM-less file with the ANSI code page. `tests/Repo.Tests.ps1` asserts it.
- No `Invoke-Expression`, no `iex`, no `DownloadString`, no `iwr | iex`.
- Set `$env:WSL_UTF8 = '1'` before any `wsl.exe` call whose output is parsed.
- Fail closed on invalid choices and ambiguous security state.
- Back up user-owned files before replacement. Use temp files with `try/finally`.

## Security invariants

Do not weaken these without explicit operator approval and a documented decision:

- `script/setup.ps1` refuses to run elevated. Elevation happens only by launching a
  script under `script/elevated/` through `Invoke-ElevatedScript`; admin-only
  cmdlets appear nowhere else (ADR-004).
- `.wslconfig` sets `networkingMode=nat`, `localhostForwarding=true`,
  `firewall=true`, `telemetry=false`, `sparseVhd=true`, `autoMemoryReclaim=gradual`,
  `memory` = half of host RAM in GB, `processors` = logical processors minus 2
  (minimum 2), `swap=16GB` and `distributionInstallPath` = the distro root. Never
  `mirrored`.
- cloud-init user-data contains no passwords or secrets and is deleted after first
  boot.
- The distro image is verified against the SHA256 in Microsoft's manifest before use;
  an unreachable or invalid manifest fails closed (ADR-016).
- No tool reports usage to its vendor where a verified opt-out exists.
- Interactive shells, firewalls and password managers remain mutually exclusive.
- Fail closed on ambiguous security state.

## Documentation contract

Update documentation in the same patch when behaviour, defaults, commands, package
placement or security assumptions change. `README.md` is the concise entry point,
`docs/ARCHITECTURE.md` the current-state design, `docs/DECISIONS.md` the durable
rationale, `docs/OPERATIONS.md` the runbook and `TASKS.md` unfinished work only.
