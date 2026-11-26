# setup-dev-win Milestone 1 (W0–W2): skeleton, bootstrap, features, WSL distro on D: — Implementation Plan

> **Superseded by implementation (milestone 1, 2026-11-24).** The body below is kept as
> written. Where it disagrees with the code, the code and `docs/DECISIONS.md` win:
>
> | Stale statement in this document | What was implemented | Decision |
> |---|---|---|
> | Edition read with `Get-WindowsEdition -Online` | `EditionID` registry value (DISM cmdlet needs elevation) | ADR-008 |
> | Feature state from `Get-WindowsOptionalFeature`; `Enable-Features.ps1 -CheckOnly`; re-read after enabling | `Win32_OptionalFeature` through CIM, non-elevated; the elevated script only enables; its exit code is the result | ADR-010 |
> | `script/lib/Features.psm1` | `script/lib/WindowsFeatures.psm1` (the name clashed with `script/stages/Features.psm1` under Pester) | ADR-010 |
> | Stage-0 calls `Set-ExecutionPolicy` | Never called; launched with `-ExecutionPolicy Bypass` | ADR-003 |
> | Exact PowerShell pin `7.6.6` | Latest stable PowerShell from winget (MSIX), any installed pwsh 7.6 or later accepted (`pins.psd1` `MinPowerShell`); ADR-014's 7.6 MSI floor is superseded | ADR-016 |
> | `Start-Process pwsh -Verb RunAs` with joined arguments | One quoted argument string; the running pwsh elevated by absolute path, or the MSIX package by its app execution alias | ADR-009, ADR-016 |
> | `Assert-DistroPlacement` checks registry `DefaultUid -ne 0` | `--set-default-user`, then the effective user (`id -un`, `id -u` >= 1000); registry value informational | ADR-011 |
> | `passwd` on first install only | Whenever `passwd -S` reports `L` or `NP` | ADR-012 |
> | Handoff `git checkout "$ref"; git pull --ff-only \|\| true`; exit-2 heuristic for missing git | git probed first; origin checked with `git config`; ref resolved, then one detached checkout; unknown ref fails | ADR-013 |
> | Defaults re-applied on every run; no `-LinuxUser` | `-Profiles`, `-DistroRoot`, `-LinuxUser` persisted in `state.json`; `bootstrap.ps1` passes `-DistroRoot` and `-LinuxUser` through when given | ADR-015 |
> | Image `Ubuntu-26.04` pinned by URL and SHA256 in the lock | The lock keeps `Name` and `Source`; URL and SHA256 are read from `DistributionInfo.json` at install time and the download is verified against them | ADR-016 |
> | Image downloaded to the temp directory | Cached in `<DistroRoot>\cache` | ADR-016 |
> | Pinned chezmoi version (`pins.psd1` `Chezmoi`) | Latest stable chezmoi from winget, any installed chezmoi kept | ADR-016 |

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a fresh Windows 11 machine (Home or Pro), the operator signs in, installs Git, clones this repo and runs `bootstrap.ps1`; after at most one reboot and re-run, a SHA256-verified Ubuntu distro named `dev` exists at `D:\WSL\dev` with a non-root default user and systemd, `.wslconfig` is in force (NAT, telemetry off), and `setup-dev-linux-wsl` has been cloned and run inside it.

**Architecture:** A stage-0 script compatible with Windows PowerShell 5.1 gets PowerShell 7 via winget and hands off to `script/setup.ps1`, a resumable stage runner (`preflight → features → dotfiles → wsl → verify`) with state in `%LOCALAPPDATA%`. Logic lives in small PowerShell modules under `script/lib/`, mocked in Pester. Only scripts under `script/elevated/` ever run elevated. `.wslconfig` is owned by a Windows-side chezmoi source. Apps, Terminal, defaults and hardening are later milestones.

**Tech Stack:** Windows PowerShell 5.1 (stage-0 only), PowerShell 7.6 LTS, winget, WSL 2.4.4+, chezmoi (Windows build), Pester 6, PSScriptAnalyzer, GitHub Actions `windows-2025` + `ubuntu-24.04`.

**Spec:** `docs/superpowers/specs/2026-11-24-setup-dev-win-linux-design.md` (§2, §5, §6.1–6.4, §6.9–6.11, §8.1, §8.5). Companion plan: `setup-dev-linux-wsl/docs/superpowers/plans/2026-11-24-linux-milestone-1-core-and-shell.md` (the handoff target).

## Global Constraints

- Windows 11 x64 only; minimum OS build **26100** (24H2). Assert a build number, never a version name.
- Scripts under `script/` target PowerShell **7.6** (pinned `7.6.6`, LTS). `bootstrap.ps1` alone must run on Windows PowerShell **5.1**.
- Every `.ps1`/`.psm1` starts with `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`; PowerShell 7 files also set `$PSNativeCommandUseErrorActionPreference = $true`. Stage-0 checks `$LASTEXITCODE` by hand.
- **winget only.** No Scoop, no Chocolatey, no `Invoke-Expression`, no `iwr … | iex`, no PSGallery install outside CI (CI pins exact versions).
- `script/setup.ps1` refuses to run elevated. Elevation happens only by launching a script under `script/elevated/` via `Invoke-ElevatedScript`; admin-only cmdlets appear nowhere else.
- Never touch `Containers-DisposableClientVM` (Sandbox). `Microsoft-Hyper-V-All` only when the `lab` profile is selected **and** the edition is Pro.
- `.wslconfig`: `networkingMode=nat`, `localhostForwarding=true`, `firewall=true`, `telemetry=false`, `sparseVhd=true`, `autoMemoryReclaim=gradual`, `memory` = half of host RAM in GB, `processors` = logical processors − 2 (minimum 2), `swap=16GB`, `distributionInstallPath` = the distro root (default `D:\WSL`). Never `mirrored`.
- Distro: name `dev`, location `<root>\dev`, image `Ubuntu-26.04` amd64 `.wsl` pinned by URL + SHA256 from Microsoft's `DistributionInfo.json`. **If the Linux plan's Task 5 fell back to 24.04, use `Ubuntu-24.04` here.**
- cloud-init user-data contains no passwords or secrets and is deleted after first boot.
- Set `$env:WSL_UTF8 = '1'` before any `wsl.exe` call whose output is parsed.
- No credentials, private addresses or machine-specific absolute paths in tracked files (`D:\WSL` appears only as a prompt default).
- Every GitHub Action pinned to a 40-hex SHA; every CI tool/module pinned to an exact version.
- `.gitattributes`: `* text=auto eol=lf`.
- The repo never commits, pushes or creates remotes; the operator does.

## Review Focus

1. **Re-running `bootstrap.ps1`/`setup.ps1`** after a reboot, and again after everything is done — resumes at the first unfinished stage; a fully done run changes nothing and exits 0. (Test: Task 5 runner tests.)
2. **Launched from an elevated terminal** — `setup.ps1` refuses with `Run from a normal (non-elevated) terminal; elevation is requested per step.` (Test: Task 5.)
3. **A `dev` distro already exists** (e.g. installed by hand on C:) — never reinstalled or unregistered; `verify` fails with the exact `wsl --manage dev --move <root>\dev` instruction. (Test: Task 10 and Task 12.)
4. **D: missing, not NTFS, or removable** — preflight fails before any feature is enabled. (Test: Task 6.)
5. **winget `settings.json` containing comments (JSONC) or existing keys** — `telemetry.disable` is merged without discarding other keys; unparseable content stops stage-0 with instructions rather than overwriting. (Test: Task 4.)

---

## File structure

```
bootstrap.ps1                       stage-0 (5.1)
script/setup.ps1                    stage runner (7.6)
script/verify.ps1                   milestone-1 verification
script/test.ps1                     lint + format + Pester
script/lib/Common.psm1              logging, native calls, elevation helpers
script/lib/State.psm1               state file, stage results
script/lib/Detect.psm1              edition, build, drive, redirection, virtualization
script/lib/Features.psm1            optional features + WSL presence/version
script/lib/WslConfig.psm1           chezmoi install + apply for .wslconfig
script/lib/Distro.psm1              lock, verified download, cloud-init, install, registry read
script/lib/Handoff.psm1             setup-dev-linux-wsl clone + run inside dev
script/lib/pins.psd1                PowerShell, chezmoi, min build
script/stages/{Preflight,Features,Dotfiles,Wsl,Verify}.psm1   one Invoke-<Name>Stage each
script/elevated/Enable-Features.ps1 the only elevated script in this milestone
wsl/ubuntu.lock.psd1                image URL + SHA256
wsl/user-data.template.yaml
chezmoi/.chezmoi.toml.tmpl, chezmoi/dot_wslconfig.tmpl, .chezmoiroot
tests/*.Tests.ps1, tests/fixtures/
PSScriptAnalyzerSettings.psd1, PSScriptAnalyzerSettings.Stage0.psd1
.github/workflows/validate.yml
README.md AGENTS.md CLAUDE.md TASKS.md docs/{ARCHITECTURE,DECISIONS,OPERATIONS}.md .gitattributes .gitignore
```

---

### Task 1: Skeleton, docs seed, lint/test harness

**Files:**
- Create: `README.md`, `AGENTS.md`, `CLAUDE.md`, `TASKS.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/OPERATIONS.md`, `.gitattributes`, `.gitignore`, `.chezmoiroot`
- Create: `PSScriptAnalyzerSettings.psd1`, `script/test.ps1`, `tests/Repo.Tests.ps1`

**Interfaces:**
- Produces: `script/test.ps1 [-RequireLinters]` — imports Pester (`RequiredVersion` from `tests/tool-versions.psd1`, Pester `6.2.0`, PSScriptAnalyzer exact version looked up at implementation), runs `Invoke-ScriptAnalyzer -Recurse -Settings PSScriptAnalyzerSettings.psd1` on `bootstrap.ps1`, `script/`, `tests/` (any Error or Warning fails), runs a formatting check (`Invoke-Formatter` on each file, fail on diff), then `Invoke-Pester -Path tests -CI`. Missing modules: print and exit 1 if `-RequireLinters` or `$env:REQUIRE_LINTERS -eq '1'`, else print a loud SKIP.
- Produces: `tests/Repo.Tests.ps1` — the invariant suite; later tasks append `Describe` blocks.

- [ ] **Step 1: Docs seed.** `AGENTS.md` mirrors setup-dev-mac's structure, rewritten for Windows with every Global Constraint. `CLAUDE.md` = `@AGENTS.md`. `docs/DECISIONS.md` ADRs (accepted, 3–10 lines, cite the spec): ADR-001 Two repos, this one Windows host only (§3, §5); ADR-002 winget only, Scoop and Chocolatey rejected, with the comparison table (§3); ADR-003 Stage-0 trust boundary: no download-and-run (§6.3); ADR-004 Elevation per step via `script/elevated/` only, daily admin account (§6.2); ADR-005 Resumable stages, manual re-run after reboot (§6.4); ADR-006 WSL NAT networking, never mirrored (§8.1); ADR-007 Distro on D:, repos on ext4 inside it (§2); ADR-008 Hyper-V only with `lab` on Pro (§6.4). `TASKS.md`: W3–W7 from spec §9. `.gitattributes`: `* text=auto eol=lf`. `.chezmoiroot`: `chezmoi`.
- [ ] **Step 2: Write the first invariants** in `tests/Repo.Tests.ps1` (each `It` greps code lines of all `*.ps1`/`*.psm1`, ignoring lines whose first non-space char is `#`):
  - `Every script sets strict mode` — each file contains `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
  - `No remote script execution` — no match for `Invoke-Expression|\biex\b|DownloadString|Invoke-RestMethod[^\n]*\|\s*iex`.
  - `No other package managers` — no match for `\bscoop\b|\bchoco(latey)?\b` outside `docs/`.
- [ ] **Step 3: Run** `pwsh -File script/test.ps1 -RequireLinters` (on Windows or in CI; the Mac has no pwsh and none is installed for this) — Expected: PASS with the three invariants.
- [ ] **Step 4: Mutation check:** add `Invoke-Expression 'x'` to a scratch `.ps1` under `script/`; the suite fails; remove it.
- [ ] **Step 5: Commit** (only when the operator has said to commit in this session) `feat: skeleton, docs seed and test harness`

---

### Task 2: CI workflow

**Files:**
- Create: `.github/workflows/validate.yml`, `tests/tool-versions.psd1`
- Modify: `tests/Repo.Tests.ps1`

**Interfaces:**
- Produces: job `windows` on `windows-2025` (install pinned Pester and PSScriptAnalyzer with `Install-PSResource -Name X -Version <exact> -TrustRepository` — CI only; install the pinned chezmoi Windows release zip, verifying its SHA256 from `tests/tool-versions.psd1`; run `pwsh -File script/test.ps1 -RequireLinters`). Job `static` on `ubuntu-24.04` (pinned `gitleaks`, `actionlint`, `yamllint`).

- [ ] **Step 1: Failing test** `Describe 'Workflows'`: every `uses:` line ends `@<40-hex>`; no `@latest`, `@main`, `@v\d` refs; every `Install-PSResource` line has `-Version`; no `curl|wget … | sh`.
- [ ] **Step 2: Run** — FAIL (no workflow). **Step 3: Write the workflow** (copy the checkout SHA setup-dev-mac uses; re-verify). **Step 4: Run** — PASS; `actionlint` clean.
- [ ] **Step 5: Commit** `ci: windows and static validation jobs with pinned actions and tools`

---

### Task 3: Common, State and Detect modules

**Files:**
- Create: `script/lib/Common.psm1`, `script/lib/State.psm1`, `script/lib/Detect.psm1`, `script/lib/pins.psd1`
- Create: `tests/Common.Tests.ps1`, `tests/State.Tests.ps1`, `tests/Detect.Tests.ps1`

**Interfaces:**
- Produces (`Common.psm1`):
  - `Write-Info [string]$Message`, `Write-Ok`, `Write-Warn`, `Stop-Fatal [string]$Message` (throws a terminating error with the message).
  - `Test-IsElevated` → `[bool]` (WindowsPrincipal check).
  - `Invoke-Native -FilePath [string] -ArgumentList [string[]] [-AllowExitCode [int[]]]` → `[pscustomobject]@{ ExitCode=[int]; Output=[string[]] }`; throws on an exit code not in `0 + AllowExitCode`; sets `$env:WSL_UTF8='1'` for `wsl.exe`.
  - `Invoke-ElevatedScript -Name [string] -ArgumentList [string[]]` → `[int]` exit code; resolves `script/elevated/<Name>.ps1`, refuses any other path, runs `Start-Process pwsh -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile','-File',<path>,…`.
  - `Get-RepoRoot` → `[string]`.
- Produces (`State.psm1`): state at `$env:LOCALAPPDATA\setup-dev-win\state.json` (overridable by `$env:SETUP_DEV_WIN_STATE` for tests).
  - `Get-StageResult -Stage [string]` → `'done' | 'reboot-required' | 'failed' | $null`.
  - `Set-StageResult -Stage [string] -Result [string]` (validated set), writes atomically (temp + `Move-Item -Force`), records UTC timestamp and boot time (`(Get-CimInstance Win32_OperatingSystem).LastBootUpTime`).
  - `Test-RebootHappenedSince -Stage [string]` → `[bool]` (current boot time > recorded).
- Produces (`Detect.psm1`):
  - `Get-EditionInfo` → `@{ Edition=[string]; IsHome=[bool]; IsPro=[bool] }` from `Get-WindowsEdition -Online` (`Core` = Home, `Professional` = Pro; any other value: `IsHome=$false; IsPro=$false` and the caller decides) **[verify the two strings on the real machine; record in ADR-008]**.
  - `Get-OsBuild` → `[int]` (`[Environment]::OSVersion.Version.Build`).
  - `Test-DataVolume -DriveLetter [char]` → `@{ Ok=[bool]; Reason=[string] }`: exists, `FileSystem -eq 'NTFS'`, `DriveType -eq 'Fixed'` (via `Get-Volume`).
  - `Test-DocumentsRedirected` → `[bool]`: the `Personal` value under `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`, expanded, is not `$HOME\Documents` (catches OneDrive Known Folder Move).
  - `Test-VirtualizationAvailable` → `[bool]`: `(Get-CimInstance Win32_ComputerSystem).HypervisorPresent` or `(Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled`.
  - `Get-KernelDmaProtectionState` → `[string]` (`'on'|'off'|'unknown'`), report only.
- Produces (`pins.psd1`): `@{ PowerShell='7.6.6'; Chezmoi='<exact>'; MinOsBuild=26100; MinWslVersion='2.4.4' }`.

- [ ] **Step 1: Failing tests** (Pester 6 `Should-*` assertions; all Windows cmdlets mocked with `Mock -ModuleName`):
  - `Invoke-Native throws on unexpected exit code` (mock a `cmd /c exit 3` call); `allows listed exit codes`.
  - `Invoke-ElevatedScript refuses a path outside script/elevated` (`-Name '..\setup'` throws).
  - `State round-trips` (Set then Get in a TestDrive state path); `rejects unknown result values`; `write is atomic` (no partial file if serialisation throws — mock `ConvertTo-Json` to throw, assert the old file is unchanged).
  - `Test-RebootHappenedSince` true when mocked boot time is later than recorded, false otherwise.
  - `Get-EditionInfo maps Core to Home and Professional to Pro`; `unknown edition is neither`.
  - `Test-DataVolume` cases: missing → `Reason` contains `not found`; `FAT32` → `NTFS`; `Removable` → `fixed` (Review Focus 4).
  - `Test-DocumentsRedirected` true for `%USERPROFILE%\OneDrive\Documents`, false for `%USERPROFILE%\Documents`.
- [ ] **Step 2: Run** `Invoke-Pester tests/Common.Tests.ps1,tests/State.Tests.ps1,tests/Detect.Tests.ps1` — FAIL. **Step 3: Implement.** **Step 4: Run** `script/test.ps1` — PASS.
- [ ] **Step 5: Commit** `feat: common, state and detection modules`

---

### Task 4: Stage-0 bootstrap.ps1 (Windows PowerShell 5.1)

**Files:**
- Create: `bootstrap.ps1`, `PSScriptAnalyzerSettings.Stage0.psd1`, `tests/Bootstrap.Tests.ps1`, `tests/fixtures/winget-settings/{default-jsonc.json,existing-keys.json,invalid.json}`
- Modify: `script/test.ps1` (analyse `bootstrap.ps1` with the Stage0 settings)

**Interfaces:**
- Consumes: nothing from `script/lib` (stage-0 is self-contained and must not import 7.x modules); reads `script/lib/pins.psd1` with `Import-PowerShellDataFile`.
- Produces: `bootstrap.ps1 [-Profiles <csv>] [-SkipPowerShellInstall]`, functions defined inside it and dot-sourceable for tests when `$env:SETUP_DEV_WIN_NO_MAIN -eq '1'`:
  - `Assert-SupportedWindows -MinBuild [int]` — x64 (`$env:PROCESSOR_ARCHITECTURE -eq 'AMD64'`) and build ≥ MinBuild, else throw naming what was found.
  - `Wait-Winget -TimeoutSeconds 60` — polls `Get-Command winget.exe`; on timeout throws with the exact `Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe` instruction.
  - `Merge-WingetSettings -Path [string]` — reads the file (absent → `{}`); strips `//` line comments that are outside strings **only if** the result then parses; on parse failure throws `winget settings.json could not be parsed; add "telemetry": { "disable": true } by hand (winget settings) and re-run.`; sets `telemetry.disable = $true`, preserves all other keys, writes with `ConvertTo-Json -Depth 20`, backing the original up to `settings.json.backup.<timestamp>` first.
  - `Install-PinnedPowerShell -Version [string]` — if `pwsh` exists with that version, skip; else `winget install --id Microsoft.PowerShell --source winget --exact --version $Version --silent --accept-package-agreements --accept-source-agreements --disable-interactivity`; check `$LASTEXITCODE`.
  - Main: assert → wait → merge settings (path `$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json`) → install pwsh → `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` → `& pwsh -NoProfile -File script\setup.ps1 -Profiles $Profiles`; exit with its exit code.

- [ ] **Step 1: Failing tests** (`Bootstrap.Tests.ps1`, dot-sourcing with `SETUP_DEV_WIN_NO_MAIN=1`, run under both `pwsh` and, in CI, `powershell.exe`):
  - `Merge-WingetSettings adds telemetry.disable to an empty file`; `preserves existing keys` (fixture with `"visual": {"progressBar":"rainbow"}` keeps it); `handles the default JSONC with comments`; `refuses invalid JSON and leaves the file unchanged` (Review Focus 5); `writes a backup before changing`.
  - `Assert-SupportedWindows rejects build 22631` and `rejects ARM64`.
  - `Wait-Winget message contains RegisterByFamilyName` (mock `Get-Command` to return nothing, timeout 1).
  - PSScriptAnalyzer with `PSScriptAnalyzerSettings.Stage0.psd1` (enables `PSUseCompatibleSyntax` and `PSUseCompatibleCommands` targeting Windows PowerShell 5.1 — use the compatibility profile name for 5.1 on Windows 10/11 shipped with PSScriptAnalyzer **[verify exact profile name]**) reports nothing for `bootstrap.ps1`.
  - Invariant: `bootstrap.ps1` contains no `Invoke-WebRequest`, `Start-BitsTransfer`, `Install-Module`, `Install-PSResource`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `script/test.ps1` — PASS (CI also runs the Bootstrap tests under `powershell.exe`).
- [ ] **Step 5: Commit** `feat: stage-0 bootstrap for Windows PowerShell 5.1`

---

### Task 5: Resumable stage runner

**Files:**
- Create: `script/setup.ps1`, `tests/Setup.Tests.ps1`
- Create (stubs filled by later tasks): `script/stages/Preflight.psm1`, `Features.psm1`, `Dotfiles.psm1`, `Wsl.psm1`, `Verify.psm1`

**Interfaces:**
- Consumes: `Test-IsElevated`, `Get-StageResult`, `Set-StageResult`, `Test-RebootHappenedSince`.
- Produces: `script/setup.ps1 [-Profiles <csv>] [-Stage <name>] [-Plan] [-LinuxRepoUrl <url>] [-LinuxRef <ref>] [-DistroRoot <path>]`.
  - Valid profiles in this milestone: `core,lab` (default `core`); others are rejected until their milestone adds them.
  - Stage order constant: `@('preflight','features','dotfiles','wsl','verify')`.
  - Each stage module exports `Invoke-<Name>Stage -Context [hashtable] [-Plan]` returning `'done' | 'reboot-required' | 'failed'`. Context keys: `Profiles [string[]]`, `DistroRoot [string]`, `LinuxRepoUrl [string]`, `LinuxRef [string]`, `Plan [bool]`, `Edition [hashtable]` (filled by preflight).
  - Runner rules: refuse if `Test-IsElevated` (Review Focus 2). Skip a stage whose result is `done` (except `verify`, always run). A stage recorded `reboot-required` is re-run only if `Test-RebootHappenedSince` is true; otherwise exit 3010 with `Reboot, then run script\setup.ps1 again.` On `reboot-required` from a stage: record, print the same message, exit **3010**. On `failed` or an exception: record `failed`, exit **1**. All done: exit **0**. `-Stage X` runs only X (ignores recorded state). `-Plan` passes `Plan` to every stage and records nothing.

- [ ] **Step 1: Failing tests** (stage functions mocked):
  - `refuses to run elevated` (mock `Test-IsElevated` true → exit 1, message contains `non-elevated`).
  - `runs stages in order and exits 0`.
  - `stops at reboot-required, exits 3010, and later stages do not run`.
  - `after a reboot resumes at the recorded stage and skips done stages` (Review Focus 1).
  - `without a reboot, a reboot-required stage exits 3010 again without re-running`.
  - `a second complete run invokes only verify` (Review Focus 1).
  - `-Stage features runs only features`; `-Plan records nothing`.
  - `rejects -Profiles productivity` (not yet valid).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** the runner and stub modules (each stub returns `'done'`). **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: resumable stage runner`

---

### Task 6: preflight stage

**Files:**
- Modify: `script/stages/Preflight.psm1`
- Create: `tests/Preflight.Tests.ps1`

**Interfaces:**
- Consumes: `Detect.psm1` functions, `pins.psd1`.
- Produces: `Invoke-PreflightStage` — fails (`'failed'` + reason) when: build < `MinOsBuild`; `Test-DataVolume` for the drive of `Context.DistroRoot` not Ok; `Test-DocumentsRedirected`; `-not Test-VirtualizationAvailable` (message: enable Intel VT-x/VT-d in firmware); `lab` selected and `-not IsPro` (message: `The lab profile needs Windows 11 Pro`). Reports (does not fail): edition, Kernel DMA Protection state. Writes `Context.Edition`.

- [ ] **Step 1: Failing tests:** one `It` per failure condition above asserting `'failed'` and the message substring; `passes on a healthy Pro machine`; `passes on Home without lab`; `fails before any feature cmdlet is called` (mock `Enable-WindowsOptionalFeature` and assert `Should-NotInvoke`). (Review Focus 4.)
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: preflight stage`

---

### Task 7: features stage and the elevated features script

**Files:**
- Create: `script/lib/Features.psm1`, `script/elevated/Enable-Features.ps1`, `tests/Features.Tests.ps1`
- Modify: `script/stages/Features.psm1`, `tests/Repo.Tests.ps1`

**Interfaces:**
- Produces (`Features.psm1`):
  - `Get-RequiredFeatures -Profiles [string[]] -Edition [hashtable]` → `[string[]]`: always `VirtualMachinePlatform`; plus `Microsoft-Hyper-V-All` iff `'lab' -in Profiles -and Edition.IsPro`.
  - `Get-FeatureState -Name [string]` → `'Enabled' | 'Disabled' | 'EnablePending' | ...` from `Get-WindowsOptionalFeature -Online` (read works non-elevated? **[verify]**; if not, read via `Invoke-ElevatedScript -Name Enable-Features -ArgumentList '-CheckOnly'` and parse its JSON output).
  - `Get-WslVersion` → `[version]` or `$null` (parse `wsl --version` first line with `WSL_UTF8=1`).
- Produces (`Enable-Features.ps1`): params `-Name [string[]]` and `-CheckOnly`; enables each with `Enable-WindowsOptionalFeature -Online -FeatureName X -All -NoRestart`; exit **3010** if any reports `RestartNeeded`, else 0. Refuses any name not in `@('VirtualMachinePlatform','Microsoft-Hyper-V-All')`.
- Produces (`Invoke-FeaturesStage`): enables missing features through the elevated script; if WSL absent or below `MinWslVersion`, runs `wsl --install --no-distribution` (non-elevated is fine; it prompts UAC itself) then `wsl --update`; returns `'reboot-required'` if the elevated script exited 3010 or any feature is `EnablePending`, else `'done'`. `-Plan` prints what it would enable.

- [ ] **Step 1: Failing tests:**
  - `Home without lab requires only VirtualMachinePlatform`; `Pro with lab adds Hyper-V`; `Pro without lab does not add Hyper-V`; `Home with lab does not add Hyper-V` (preflight already failed; defence in depth).
  - `Enable-Features refuses Containers-DisposableClientVM` (run the script with that name → non-zero, no `Enable-WindowsOptionalFeature` call).
  - `stage returns reboot-required when the elevated script exits 3010`; `returns done when everything is enabled and WSL >= 2.4.4`; `installs WSL when wsl --version fails`.
  - Repo invariant: `Enable-WindowsOptionalFeature|Disable-WindowsOptionalFeature|Set-ExecutionPolicy -Scope LocalMachine` appear only under `script/elevated/`; the string `Containers-DisposableClientVM` appears only in `Enable-Features.ps1`'s refusal test and docs.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: features stage with a single elevated script`

---

### Task 8: dotfiles stage — Windows chezmoi owning .wslconfig

**Files:**
- Create: `script/lib/WslConfig.psm1`, `chezmoi/.chezmoi.toml.tmpl`, `chezmoi/dot_wslconfig.tmpl`, `tests/WslConfig.Tests.ps1`, `tests/fixtures/chezmoi/ms02.toml`
- Modify: `script/stages/Dotfiles.psm1`, `tests/Repo.Tests.ps1`

**Interfaces:**
- Produces chezmoi data: `wslDistroRoot` (`promptStringOnce`, default `D:\WSL`), `hostMemoryGB` (`output "powershell.exe" "-NoProfile" "-Command" "[math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)" | trim | atoi`), `logicalProcessors` (`env "NUMBER_OF_PROCESSORS" | atoi`). `[git] autoCommit=false autoPush=false`.
- Produces `.wslconfig` rendering (values per Global Constraints; `memory={{ div .hostMemoryGB 2 }}GB`; `processors={{ max 2 (sub .logicalProcessors 2) }}`; `distributionInstallPath={{ .wslDistroRoot | replace "\\" "\\\\" }}`), sections `[wsl2]`, `[general]`, `[experimental]`, each key with a one-line comment citing why.
- Produces (`WslConfig.psm1`): `Install-PinnedChezmoi -Version [string]` (winget `twpayne.chezmoi`, `--exact --version`, user scope; skip if present at that version); `Invoke-ChezmoiApply` → `@{ Changed=[bool] }` (hash `$HOME\.wslconfig` before/after `chezmoi init --source <repo>\chezmoi --apply`); `Request-WslRestart` — if `Changed` and `wsl --list --running --quiet` is non-empty: interactive → `Read-Host` y/N then `wsl --shutdown`; non-interactive → `Write-Warn 'Run wsl --shutdown to apply .wslconfig'`.
- Produces (`Invoke-DotfilesStage`): install chezmoi → apply → restart request → `'done'`.

- [ ] **Step 1: Failing tests:**
  - Render `dot_wslconfig.tmpl` with `ms02.toml` (`hostMemoryGB=94`, `logicalProcessors=24`, `wslDistroRoot='D:\WSL'`) via `chezmoi execute-template --config` and compare to an exact expected string: `memory=47GB`, `processors=22`, `swap=16GB`, `networkingMode=nat`, `localhostForwarding=true`, `firewall=true`, `telemetry=false`, `distributionInstallPath=D:\\WSL`, `sparseVhd=true`, `autoMemoryReclaim=gradual`. (Windows reports slightly under the nominal 96 GB; the test fixes the arithmetic, not the marketing number.)
  - `processors never below 2` (fixture `logicalProcessors=2`).
  - Repo invariant: no `networkingMode\s*=\s*mirrored` anywhere; no `DefaultInboundAction\s+Allow` anywhere.
  - `Request-WslRestart does not shut down WSL non-interactively` (mock `wsl` and assert no `--shutdown`).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: dotfiles stage with chezmoi-owned .wslconfig`

---

### Task 9: Distro lock and verified image download

**Files:**
- Create: `wsl/ubuntu.lock.psd1`, `script/lib/Distro.psm1` (first part), `tests/Distro.Tests.ps1`

**Interfaces:**
- Produces `wsl/ubuntu.lock.psd1`: `@{ Name='Ubuntu-26.04'; Url='<amd64 Url>'; Sha256='<64-hex>'; Source='https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'; CheckedOn='<YYYY-MM-DD>' }` — values copied from the live manifest at implementation (the `Ubuntu-26.04` entry's `Amd64PackageUrl`/hash fields **[verify field names]**).
- Produces: `Get-DistroLock` → hashtable (validates: Url is `https://`, Sha256 is 64 hex, Name matches `^Ubuntu-\d\d\.\d\d$`); `Save-VerifiedImage -Lock [hashtable] -Directory [string]` → `[string]` path; downloads with `Invoke-WebRequest -UseBasicParsing` to a temp name, compares `Get-FileHash -Algorithm SHA256` case-insensitively, deletes and throws `SHA256 mismatch for <file>: expected X, got Y` on mismatch, then renames. Reuses an existing file only if its hash matches.

- [ ] **Step 1: Failing tests** (mock `Invoke-WebRequest` to write fixture bytes): `returns the path when the hash matches`; `throws and deletes the file on mismatch`; `reuses a matching cached file without downloading` (`Should-NotInvoke Invoke-WebRequest`); `re-downloads a cached file whose hash does not match`; `rejects an http:// lock Url`; `lock file in the repo passes validation`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** and fill the lock from the live manifest. **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: pinned Ubuntu image with SHA256 verification`

---

### Task 10: cloud-init user, distro install and registry read-back

**Files:**
- Create: `wsl/user-data.template.yaml`
- Modify: `script/lib/Distro.psm1`, `tests/Distro.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-LinuxUserName [-Override [string]]` → `[string]`: override or `$env:USERNAME` lowercased with invalid chars removed; must match `^[a-z_][a-z0-9_-]{0,31}$` else throw asking for `-LinuxUser`.
  - `New-CloudInitUserData -UserName [string] -Path [string]` — renders the template (`#cloud-config`; `users:` with `name`, `groups: [sudo]`, `shell: /bin/bash`, `lock_passwd: true`; `write_files:` appending to `/etc/wsl.conf` `[boot] systemd=true` and `[user] default=<name>`). Target path `$env:USERPROFILE\.cloud-init\dev.user-data`.
  - `Get-RegisteredDistro -Name [string]` → `$null` or `@{ Name; BasePath; Version=[int]; DefaultUid=[int] }` from `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\*` (`DistributionName`, `BasePath`, `Version`, `DefaultUid`) **[verify value names on the machine]**.
  - `Install-DevDistro -ImagePath [string] -Root [string] -UserName [string]`: if `Get-RegisteredDistro dev` exists → do **not** install; return it (Review Focus 3). Else: write user-data → `wsl --install --from-file <img> --name dev --location <Root>\dev --no-launch` → `wsl -d dev -u root -- cloud-init status --wait` (accept exit 0 and 2 = done-with-warnings **[verify]**) → `wsl --terminate dev` → delete the user-data file → return the registry record.
  - `Set-DevUserPassword -UserName [string]` — interactive only: `wsl -d dev -u root -- passwd <name>`; non-interactive → warn with the command.
  - `Assert-DistroPlacement -Distro [hashtable] -Root [string]` → throws unless `BasePath` starts with `<Root>\` (case-insensitive) and `Version -eq 2` and `DefaultUid -ne 0`; the placement message is exactly `dev is at <BasePath>, not under <Root>. Move it with: wsl --shutdown; wsl --manage dev --move <Root>\dev`.

- [ ] **Step 1: Failing tests:**
  - `user-data parses as YAML` (use `ConvertFrom-Yaml` only if a pinned module is available in CI; otherwise assert structure by line matching) and `contains no password material` (refute `passwd:|hashed_passwd|plain_text_passwd|ssh_authorized_keys`).
  - `Get-LinuxUserName` lowercases `Istvan.Orban` → `istvanorban`; throws for a name that sanitises to empty.
  - `Install-DevDistro skips install when dev is registered` (`Should-NotInvoke` on the `--install` call) (Review Focus 3); `calls wsl in order: install, cloud-init wait, terminate`; `deletes user-data after first boot`; `uses --location <Root>\dev`.
  - `Assert-DistroPlacement` throws with the exact move instruction for `C:\Users\x\AppData\Local\wsl\{guid}`; throws for `DefaultUid 0`; passes for `D:\WSL\dev`.
  - `wsl output is parsed with WSL_UTF8 set` (assert `Invoke-Native` sets `$env:WSL_UTF8='1'` for `wsl.exe`, so UTF-16 output from `wsl --list` compares correctly; Task 7's `Get-WslVersion` relies on the same).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: cloud-init user and distro install on the data drive`

---

### Task 11: Handoff to setup-dev-linux-wsl and the wsl stage

**Files:**
- Create: `script/lib/Handoff.psm1`, `tests/Handoff.Tests.ps1`
- Modify: `script/stages/Wsl.psm1`, `tests/Repo.Tests.ps1`

**Interfaces:**
- Produces:
  - `Test-LinuxRepoUrl -Url [string]` → `[bool]`: `^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$`.
  - `Test-GitRef -Ref [string]` → `[bool]`: `^[A-Za-z0-9._/-]{1,200}$` and not starting with `-`.
  - `Invoke-LinuxHandoff -Url [string] -Ref [string] [-Profiles [string]]` → `[int]` exit code. Runs `wsl.exe -d dev --cd ~ -- bash -c '<fixed script>' handoff <Url> <Ref>` with the values passed as **positional arguments**, never interpolated into the script text. The fixed script: `set -Eeuo pipefail; url=$1; ref=$2; command -v git >/dev/null || { echo "git missing in the image" >&2; exit 2; }; mkdir -p ~/workspace; [ -d ~/workspace/setup-dev-linux-wsl/.git ] || git clone "$url" ~/workspace/setup-dev-linux-wsl; cd ~/workspace/setup-dev-linux-wsl; git fetch --quiet origin; git checkout --quiet "$ref"; git pull --ff-only --quiet || true; exec ./bootstrap apply --target wsl`. On exit 2 the module installs git as root (`wsl -d dev -u root -- apt-get install -y git` after `apt-get update`) and retries once.
  - Defaults: `-LinuxRepoUrl` = `https://github.com/<owner>/setup-dev-linux-wsl` where `<owner>` is a setting in `script/lib/pins.psd1` (`LinuxRepoOwner`), not hardcoded in code; `-LinuxRef` = `main`.
- Produces (`Invoke-WslStage`): `Get-DistroLock` → `Save-VerifiedImage` (to `$env:TEMP\setup-dev-win`) → `Install-DevDistro` → `Assert-DistroPlacement` → `Set-DevUserPassword` (first install only) → `Invoke-LinuxHandoff` → `'done'` if exit 0 else `'failed'`.

- [ ] **Step 1: Failing tests:**
  - `Test-LinuxRepoUrl` accepts `https://github.com/o/setup-dev-linux-wsl(.git)`, rejects `http://…`, `https://github.com/o/r;rm -rf ~`, `git@github.com:o/r.git`, `https://evil.example/o/r`.
  - `Test-GitRef` rejects `--upload-pack=x`, `a b`, `$(id)`.
  - `Invoke-LinuxHandoff passes url and ref as separate arguments` (capture the `Invoke-Native` ArgumentList; assert the last two elements equal the inputs and the script text contains neither).
  - `retries once after installing git when the image lacks git`.
  - Stage: `does not re-run cloud-init or passwd when dev already exists`; `fails when placement assertion throws` (Review Focus 3).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat: wsl stage with verified install and safe handoff to setup-dev-linux-wsl`

---

### Task 12: verify stage and script/verify.ps1

**Files:**
- Modify: `script/stages/Verify.psm1`
- Create: `script/verify.ps1`, `tests/Verify.Tests.ps1`
- Modify: `README.md`, `docs/OPERATIONS.md`, `docs/ARCHITECTURE.md`

**Interfaces:**
- Produces `Invoke-VerifyStage` and `script/verify.ps1` (same checks; `verify.ps1` exits 0/1), each check printing OK/FAIL with a reason; any FAIL → `'failed'`:
  1. Build ≥ MinOsBuild; edition reported.
  2. Required features `Enabled`; Hyper-V `Disabled` unless `lab`.
  3. WSL ≥ `MinWslVersion`.
  4. `chezmoi verify` for the Windows source (`.wslconfig` has no drift).
  5. `Get-RegisteredDistro dev` exists; `Assert-DistroPlacement` passes (Review Focus 3 message).
  6. `wsl -d dev -- bash -lc '~/workspace/setup-dev-linux-wsl/script/verify'` exits 0.
  7. Informational: Kernel DMA Protection state; `wsl -d dev -- systemctl is-system-running` (report `running`/`degraded`).

- [ ] **Step 1: Failing tests:** one `It` per check with mocks for pass and fail; `a C: distro fails with the move instruction`; `Hyper-V enabled without lab fails`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `script/test.ps1` — PASS.
- [ ] **Step 5: Docs:** README quick start (the four first steps from spec §6.3 verbatim); OPERATIONS: "New machine", "After a reboot", "Re-provision dev" (`wsl --export` to `<root>\backup`, `wsl --unregister dev`, `script\setup.ps1 -Stage wsl`), "dev is on C:", "winget not found"; ARCHITECTURE: stage flow and ownership table from spec §5.1.
- [ ] **Step 6: Commit** `feat: verification for milestone 1`

---

### Task 13: Real-machine acceptance run (Home edition)

**Files:**
- Modify: `docs/DECISIONS.md` (record verified facts), `TASKS.md`

This task is manual on the MS-02 and is the milestone's proof; CI cannot run it (Server 2025, no client features).

- [ ] **Step 1:** On the Windows machine (currently Home): follow README quick start exactly. Record each prompt, UAC dialog, reboot and exit code.
- [ ] **Step 2:** Expected: first run exits 3010 after `features`; after reboot the re-run finishes with `verify` all OK and exit 0.
- [ ] **Step 3:** Run `script\setup.ps1` again — expected: only `verify` runs, exit 0 (Review Focus 1).
- [ ] **Step 4:** From an elevated terminal run `script\setup.ps1` — expected: refusal (Review Focus 2).
- [ ] **Step 5:** Record every `[verify]` fact this plan raised (edition strings, Lxss value names, cloud-init exit codes, feature-state read without elevation, PSScriptAnalyzer profile name, DistributionInfo field names, whether stock Ubuntu WSL image has git and systemd on) in `docs/DECISIONS.md` with the date, and fix any code that assumed differently.
- [ ] **Step 6: Commit** `docs: record real-machine verification for milestone 1`

---

## Self-review notes

- Spec coverage for milestone 1: §6.1 layout, §6.2 standards/elevation (Tasks 1, 3, 5, 7), §6.3 stage-0 (Task 4), §6.4 stages preflight/features/dotfiles(.wslconfig only)/wsl/verify (Tasks 5–12), §6.9 WSL stage incl. cloud-init, password, login-shell note handled by the Linux repo (Tasks 8–11), §6.11 tests/CI (Tasks 1, 2, 13), §8.1 NAT (Task 8), §8.5 line endings (Task 1). Deferred to later plans: §6.5 apps + font, §6.6 Terminal, §6.7 defaults, §6.8 hardening/exposure checks, §6.11 Hyper-V harness, §6.12 lab VM, §8.2 relay, §8.6 backup.
- Cross-plan contract: the handoff calls `./bootstrap apply --target wsl` (Linux plan Task 12) and verify calls `script/verify` (Linux plan Task 12). The Ubuntu release must match the Linux plan's Task 5 outcome.
- Names consistent across tasks: `Invoke-Native`, `Invoke-ElevatedScript`, `Get-StageResult`/`Set-StageResult`, `Test-RebootHappenedSince`, `Get-EditionInfo`, `Test-DataVolume`, `Get-RequiredFeatures`, `Get-WslVersion`, `Get-DistroLock`, `Save-VerifiedImage`, `Install-DevDistro`, `Get-RegisteredDistro`, `Assert-DistroPlacement`, `Invoke-LinuxHandoff`, `Invoke-<Name>Stage`.
