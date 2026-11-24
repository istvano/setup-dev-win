# setup-dev-win + setup-dev-linux-wsl: design

> **Superseded by implementation (milestone 1, 2026-11-24).** The body below is kept as
> written. Where it disagrees with the code, the code and `docs/DECISIONS.md` win:
>
> | Stale statement in this document | What was implemented | Decision |
> |---|---|---|
> | Edition read with `Get-WindowsEdition -Online` | `EditionID` registry value (DISM cmdlet needs elevation) | ADR-008 |
> | Feature state from `Get-WindowsOptionalFeature`; `Enable-Features.ps1 -CheckOnly`; re-read after enabling | `Win32_OptionalFeature` through CIM, non-elevated; the elevated script only enables; its exit code is the result | ADR-010 |
> | `script/lib/Features.psm1` | `script/lib/WindowsFeatures.psm1` (the name clashed with `script/stages/Features.psm1` under Pester) | ADR-010 |
> | Stage-0 calls `Set-ExecutionPolicy` | Never called; launched with `-ExecutionPolicy Bypass` | ADR-003 |
> | Exact PowerShell pin `7.6.6` | A floor within 7.6 (now `7.6.10`), installed as the machine-wide MSI | ADR-014 |
> | `Start-Process pwsh -Verb RunAs` with joined arguments | One quoted argument string; the running pwsh elevated by absolute path | ADR-009 |
> | `Assert-DistroPlacement` checks registry `DefaultUid -ne 0` | `--set-default-user`, then the effective user (`id -un`, `id -u` >= 1000); registry value informational | ADR-011 |
> | `passwd` on first install only | Whenever `passwd -S` reports `L` or `NP` | ADR-012 |
> | Handoff `git checkout "$ref"; git pull --ff-only \|\| true`; exit-2 heuristic for missing git | git probed first; origin checked with `git config`; ref resolved, then one detached checkout; unknown ref fails | ADR-013 |
> | Defaults re-applied on every run; no `-LinuxUser` | `-Profiles`, `-DistroRoot`, `-LinuxUser` persisted in `state.json` | ADR-015 |

Date: 2026-11-24
Status: draft for approval
Lives in: `setup-dev-win/docs/superpowers/specs/` once approved, with a copy in `setup-dev-linux-wsl`.

Markers used below:
- **[user]** — decided by the operator in conversation.
- **[call]** — the designer's decision; reversible; flagged so it can be checked.
- **[verify]** — a fact the research could not confirm from a primary source; the builder must check it before relying on it.

---

## 1. Intent

The operator has an Apple Silicon Mac set up reproducibly by `setup-dev-mac`: security-first, opinionated, test-gated, every package justified. They now have a Windows workstation and want it **as close as practical to the Mac**: the same apps, the same shell and CLI tools, the same security posture, the same "declare it, verify it, detect drift" discipline.

They will move between the two machines by `git push` on one and `git pull` on the other. No sync tooling. So the goal is not file sync but **environment parity**: a repo cloned on either machine should build, test and feel the same.

### Success looks like

- A fresh Windows 11 machine goes from first login to a working workstation by running one documented bootstrap, with a small number of stated manual steps (NVIDIA driver, sign-ins, a reboot or two).
- Inside WSL, the operator's shell, prompt, aliases, git signing, `conn`, Docker, kubectl and AI agents behave as they do on the Mac.
- A `verify` command on each side reports declared-but-missing and installed-but-undeclared state, as `setup-dev-mac` does.
- Nothing the repos install phones home where a verified opt-out exists, and nothing listens beyond loopback.

### Goals

1. Reproducible Windows host: apps, fonts, terminal, Windows settings, hardening, virtualization features.
2. Reproducible Linux dev environment, usable in WSL2 and on a plain Ubuntu machine or VM.
3. Parity with `setup-dev-mac` in tool choice, configuration and invariants, diverging only where the platform forces it, with each divergence written down.
4. The same engineering standards: ADRs, tests, strict scripts, verification by read-back, no silent skips.

### Non-goals

- File or workspace sync between machines (git only) **[user]**.
- BitLocker or Windows Sandbox **[user]**.
- BetterDisplay or any DDC/monitor-switching tool **[user]**.
- Docker Desktop, Colima or Rancher on Windows **[user]**: Docker Engine in WSL2 replaces them.
- Linux desktop GUI apps in v1 **[call]**: the Linux repo provisions a headless dev environment. GUI apps live on the Windows host (or on the Mac).
- ARM64 Windows **[call]**: the target is x64. Do not add ARM64 branches speculatively.
- Supporting distros other than Ubuntu LTS in v1 **[call]**.
- Intune, MDM, domain join, or anything that assumes a managed fleet.

### Anti-goals (would be failure even if it "works")

- Any download-and-run script outside the single documented exception (§6.3).
- A container or WSL service reachable from the LAN by default.
- A hardening change that can lock the operator out (UEFI-locked VBS/LSA, `Mandatory` HVCI, scripted Smart App Control).
- A second package manager doing the job of the first (one tool per job, as in the Mac's ADR-022).
- A verify step that reports success on an exit code instead of reading the state back.
- Shipping a telemetry variable or policy that nothing reads (the Mac's ADR-046 rule).

---

## 2. Constraints

### Hardware **[user]**

- Minisforum MS-02 Ultra, Intel Core Ultra 9 285HX (x64), 96 GB RAM.
- `C:` system drive; `D:` data drive (workspace, VMs, model caches). D: must be NTFS and internal.
- RTX 4090 in a Razer Core X V2 over Thunderbolt/USB4 (use a front 80 Gbps port). The eGPU may be absent at any time.
- Currently Windows 11 **Home**; will be upgraded to **Pro**. The repo must install Pro virtualization features when Pro is present and must not break on Home.

### Placement **[user]**

| Boundary | What runs there |
|---|---|
| Windows host | GUI apps (Slack, Chrome, Firefox Dev, Bitwarden, Obsidian, OBS, Claude, ChatGPT, LM Studio, VS Code, Zed, Windows Terminal), VPNs, Tailscale, outbound firewall, NVIDIA driver |
| WSL2 distro | All engineering CLI and AI work: shell, git, `conn`, curl, Docker Engine + compose, kubectl and friends, Claude Code / Codex / opencode, runtimes, CUDA toolkit |
| Hyper-V VM (Pro) | Untrusted or hostile work (the Mac's `lab` boundary), and the destructive test harness |

### Storage (Option A) **[user]**

- The WSL distro's VHDX is installed directly at `D:\WSL\dev` (`wsl --install … --location`), and `.wslconfig` sets `distributionInstallPath=D:\\WSL` for any future distro.
- Repos live at `~/workspace` on ext4 **inside** that VHDX. Never on `/mnt/c` or `/mnt/d` (9P is roughly 7x slower for sequential I/O and orders of magnitude slower for metadata; exec bits and case sensitivity break).
- Docker data (`/var/lib/docker`), Hugging Face, uv and mise caches stay at their Linux defaults, which are physically on D: because the VHDX is.
- Hyper-V VMs and disks on `D:\Hyper-V`.
- LM Studio's model folder on D: (Windows-native data).

### Inherited invariants (ported from `setup-dev-mac`)

- Every published container port binds `127.0.0.1`.
- No unreviewed remote-script execution.
- No tool reports usage to its vendor where a verified opt-out exists; ship only opt-outs something actually reads.
- One tool per job in the default profile, with a cap on default-profile entries.
- Stateful services belong to projects, not to the repo substrate.
- Never put credentials, recovery keys, private addresses or machine-specific absolute paths in tracked files. (`D:\WSL` is a documented default in a config template, not a tracked machine path; it is a template variable with that default.)
- Never commit, tag or push automatically. The repos never create branches or remotes on their own.
- Fail closed on ambiguous security state. Detect capabilities; never remember them.
- Interactive shell, firewall and password manager are mutually exclusive choices.
- The login shell is not reassigned automatically.

---

## 3. Approaches considered

| | Structure | Trade-off | Outcome |
|---|---|---|---|
| A | One repo, two layers (PowerShell host + bash/chezmoi Linux inside WSL) | One place; but the Linux half can only ever be "the WSL part of the Windows repo" | Not chosen |
| **B** | **Two repos: `setup-dev-win` (Windows host) and `setup-dev-linux-wsl` (Linux dev environment, WSL being one target)** | Clean ownership; Linux repo reusable on any Ubuntu box; cost is two repos to keep in step and a defined handoff | **Chosen [user]** |
| C | Windows drives everything, pushing config into WSL from PowerShell | One place to look; but WSL can't verify or repair itself and Mac parity drops | Rejected |

**Naming [user]:** the Linux repo is `setup-dev-linux-wsl`. The operator's existing `istvano/setup-dev-linux` (Ansible, SDKMAN/NVM, GNOME desktop, September 2026) is a separate project with its own decisions; this design does not touch, reuse or depend on it.


### Package manager on Windows

| | winget | Scoop | Chocolatey |
|---|---|---|---|
| Installer origin | Publisher's site; redirectors rejected | Publisher's site | Publisher's site, via maintainer script |
| Integrity | SHA256 mandatory per manifest | SHA256 in manifest, but auto-update bot computes it from whatever it downloaded | Checksum required only for non-HTTPS |
| What executes | The vendor installer only | Installer + optional arbitrary PowerShell hooks | Maintainer-written PowerShell, usually as admin |
| Review of new versions | Microsoft pipeline: multi-AV, Defender dynamic analysis, domain check, moderators | Mostly none (bot commits) | Human review except "trusted" maintainers |
| Vendor's own warning | — | — | "DOES NOT RECOMMEND using the community repository" for organisations |

**Decision: winget only [user].** It is Microsoft's, the closest equivalent to Homebrew casks (vendor installer, pinned hash), and has the strongest review. Scoop and Chocolatey are not installed.

### Package managers on Linux **[call, accepted by user in conversation]**

Mirror the Mac:

| Class | Source | Mac equivalent |
|---|---|---|
| Base OS, libraries, a few low-churn tools | Ubuntu apt (signed by Ubuntu, unattended security upgrades) | macOS itself |
| Daemons and system integrations: Docker Engine, NVIDIA CUDA toolkit + Container Toolkit, Claude Code | The vendor's own signed apt repo, versions pinned | Homebrew cask / vendor pkg |
| User-space CLI tools (ripgrep, fd, fzf, bat, eza, zoxide, atuin, jq, yq, delta, btop, just, gh, sops, age, gitleaks, shellcheck, shfmt, actionlint, hadolint, trivy, kubectl, helm, k9s, chezmoi, starship, direnv, …) | **Homebrew on Linux**, `brew bundle` with profile Brewfiles | Homebrew formulae — same tokens |
| Language runtimes | mise | mise |
| Python | uv | uv |

Why Homebrew rather than mise-for-everything (the earlier research recommendation): the operator values staying close to the Mac. Homebrew on x86_64 Ubuntu is Tier 1, `homebrew-core` is the same reviewed project with CI-built bottles, and the Brewfile tokens carry over almost unchanged. The cost: `brew bundle` does not pin versions (the Mac accepts the same), and Homebrew owns `/home/linuxbrew/.linuxbrew`. mise stays the runtime manager exactly as on the Mac.

---

## 4. System overview

```
Windows 11 (Home → Pro)                        setup-dev-win (PowerShell 7, winget, chezmoi-on-Windows)
├─ winget configuration profiles  ─────────── apps, font (local manifest), Windows Terminal
├─ windows-defaults / hardening-check ──────── registry tables, Defender/ASR, UAC, privacy, firewall read-back
├─ features: VirtualMachinePlatform, WSL; Hyper-V (Pro only)
├─ .wslconfig (chezmoi on Windows)
├─ installs distro "dev" → D:\WSL\dev  (SHA256-verified Ubuntu 26.04 .wsl, cloud-init user)
│     │
│     └── handoff: clone + run setup-dev-linux-wsl inside "dev"
│
└─ WSL2 distro "dev" (Ubuntu 26.04, ext4 on D:)   setup-dev-linux-wsl (bash, apt, Homebrew, mise, chezmoi)
   ├─ apt base + vendor apt repos (docker, nvidia, claude-code)
   ├─ brew bundle profiles (CLI tools)
   ├─ mise runtimes, uv
   ├─ chezmoi dotfiles ported from setup-dev-mac (zsh/fish, git, ssh, starship, conn, …)
   ├─ /etc/wsl.conf (WSL target only)
   ├─ Docker Engine (loopback-only), NVIDIA toolkit (eGPU optional)
   └─ AI agents + managed policy
```

---

## 5. Repo boundary and handoff

### 5.1 Ownership

Each file or setting has exactly one owner. Neither repo writes into the other's territory.

| Item | Owner |
|---|---|
| winget apps, fonts, Windows Terminal, PowerShell profile, Windows settings, Defender/ASR, UAC, privacy policy, firewall (Windows + Hyper-V firewall checks), simplewall | win |
| Windows optional features, WSL install/update, Hyper-V | win |
| `%UserProfile%\.wslconfig` | win |
| Downloading, verifying and installing the distro; cloud-init user-data; distro name and location | win |
| `C:\Program Files\ClaudeCode\managed-settings.json` (Windows-side policy for WSL to inherit) | win |
| VS Code **user settings** (host side) and the `remote-wsl` extension | win |
| Everything inside the distro: apt, Homebrew, mise, dotfiles, Docker, CUDA, agents | linux |
| `/etc/wsl.conf` | linux (WSL target only) |
| `/etc/claude-code/managed-settings.json`, `/etc/codex/requirements.toml` | linux |
| VS Code **server-side extensions** (installed into `~/.vscode-server` from WSL) | linux |
| Network exposure verify: Windows listeners, portproxy, Hyper-V firewall | win |
| Network exposure verify: Linux listeners, Docker binds | linux |

### 5.2 Handoff contract

`setup-dev-win`'s WSL stage ends by running, as the distro's default user:

```
git clone https://github.com/<owner>/setup-dev-linux-wsl ~/workspace/setup-dev-linux-wsl
~/workspace/setup-dev-linux-wsl/bootstrap --target wsl [--profiles …]
```

- The Linux repo must be fully runnable without the Windows repo (on bare Ubuntu, `--target linux`). The Windows repo only knows the clone URL, the entrypoint and its exit codes.
- The Linux repo detects WSL itself (`/proc/sys/kernel/osrelease` contains `microsoft`, or `WSL_DISTRO_NAME` set) and fails if `--target wsl` disagrees with detection.
- Default ref is the default branch **[call]**; an override (`-LinuxRef`) exists for testing a branch.
- The clone URL is a parameter with the operator's GitHub repo as default, not a hardcoded host.
- `git` must be present in the stock Ubuntu WSL image **[verify]**; if not, the Windows stage installs it with `apt-get install git` as root before cloning.

### 5.3 What stays in step across repos (and with `setup-dev-mac`)

- The MCP server catalogue: each repo carries its own copy (`mcp/managed-settings.json`). No cross-repo fetch at runtime. An `update-report` check in each repo flags divergence from the Mac copy **[call]**.
- Brewfile tokens for CLI tools: same names as the Mac where the formula exists on Linux.
- Telemetry opt-out set: Linux shells carry the Mac's verified set (Homebrew's applies again); Windows has its own verified set.
- Docs structure: README, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md` (ADRs), `docs/OPERATIONS.md`, `TASKS.md`, root `AGENTS.md` (and `CLAUDE.md` pointing at it).

---

## 6. setup-dev-win

### 6.1 Repo layout **[call]**

```
bootstrap.ps1                 stage-0, Windows PowerShell 5.1-compatible
script/                       PowerShell 7 scripts (setup, verify, windows-defaults, hardening-check, wsl-install, test-vm, …)
script/lib/                   shared module (logging, elevation, state, detection)
profiles/*.winget.yaml        WinGet Configuration v3 files, one per profile
manifests/fonts/…             repo-owned local winget manifest(s)
chezmoi/                      Windows-side dotfiles (.chezmoiroot)
defaults/*.psd1               declared registry tables (Windows "defaults write")
wsl/                          distro lock (URL + SHA256), cloud-init user-data template
mcp/                          policy catalogue (copy)
tests/                        Pester 6 tests
docs/ AGENTS.md CLAUDE.md README.md TASKS.md   (no justfile — see 6.10)
.gitattributes                * text=auto eol=lf, with explicit CRLF exceptions
```

### 6.2 Language and standards

- PowerShell 7.6 LTS for everything except stage-0.
- Strict mode in every script: `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, `$PSNativeCommandUseErrorActionPreference = $true` (scoped off around tools that use non-zero exits for success, e.g. robocopy).
- Stage-0 (`bootstrap.ps1`) runs under Windows PowerShell 5.1, so it is 5.1-compatible and checks `$LASTEXITCODE` by hand.
- PSScriptAnalyzer (lint + `Invoke-Formatter`), Pester 6.x pinned to one major.
- Elevation is per step, never for the whole run. The daily account is an administrator **[user]**, so an elevated step runs as the same user (same HKCU, same profile) after a UAC consent. Elevated steps self-elevate with `Start-Process -Verb RunAs -Wait` (or Windows `sudo` if enabled) and the script states why. User-scope steps (HKCU, user-scope winget, chezmoi, `.wslconfig`) refuse to run elevated, so nothing lands in an elevated context by accident. `hardening-check` still reports the account type; a standard daily user is not supported in v1.

### 6.3 Bootstrap (stage-0) and the trust boundary

Getting the repo onto a fresh machine:

1. Sign in once (winget's App Installer registers only after first interactive login).
2. `winget install --id Git.Git -e --source winget` (manual, documented first command).
3. `git clone` this repo to a location of the operator's choice (docs suggest `D:\src\setup-dev-win`; nothing depends on the path).
4. `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1` (process scope; nothing persisted).

Stage-0 then:
- Asserts Windows 11 x64 and a **minimum OS build** (not a named version).
- Polls for `winget.exe`; if missing, prints the `Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe` instruction and exits. It never auto-downloads winget or installs `Repair-WinGetPackageManager` from PSGallery.
- Sets winget settings: `telemetry.disable: true`; enables `LocalManifestFiles` (needed for the font manifest; admin); leaves the hash-override setting off.
- Installs PowerShell 7 with a pinned `--version` from winget (MSIX by default from 7.6: per-user, read-only `$PSHOME`, no LocalMachine execution policy).
- Sets `RemoteSigned -Scope CurrentUser`.
- Hands off to `script/setup` under `pwsh`.

**Trust boundary statement:** Windows has **no** download-and-run script at all. The only network-to-execution paths are winget (hash-pinned, Microsoft-validated), `git clone` of the operator's own repos, and the SHA256-verified Ubuntu image.

### 6.4 Resumable stages

`script/setup` is a sequence of named, idempotent stages with a state file (under `%LOCALAPPDATA%\setup-dev-win\state.json`). A stage that needs a reboot records it, exits with a distinct exit code, and the operator re-runs `script/setup` after the reboot (no RunOnce auto-resume **[call]** — keeps the operator in control and avoids an elevated autorun entry).

Stages:
1. `preflight` — edition (`Get-WindowsEdition -Online`: Home=`Core`, Pro=`Professional` **[verify strings]**), build, D: exists and is NTFS and fixed, OneDrive Known Folder Move not redirecting Documents (refuse: it breaks the PowerShell profile and chezmoi targets), virtualization enabled in firmware, Kernel DMA Protection state recorded.
2. `features` — enable `VirtualMachinePlatform`; install WSL from the Store-serviced package (`wsl --install --no-distribution`); `Microsoft-Hyper-V-All` **only when the `lab` profile is selected and the edition is Pro** **[call]** (smaller default surface; the test harness and lab VM both select `lab`). Detect with `Get-WindowsOptionalFeature`; enable with `-All -NoRestart`. Never touch `Containers-DisposableClientVM` (Sandbox) **[user]**.
3. `apps` — `winget configure` for the selected profiles.
4. `dotfiles` — chezmoi on Windows.
5. `defaults` — Windows settings tables.
6. `hardening` — apply the safe subset, then read back.
7. `wsl` — `.wslconfig`, distro install, cloud-init, handoff to `setup-dev-linux-wsl`.
8. `verify`.

Each stage is runnable alone (`script/setup -Stage apps`) and supports `-WhatIf`/plan mode that prints what would change.

### 6.5 Apps (winget configuration profiles)

- Format: WinGet Configuration **v3 (DSC v3)** YAML, `metadata.winget.processor.identifier: dscv3`, resources `Microsoft.WinGet/Package` (and native `Microsoft.Windows/Registry` where used).
- Avoid adapted PowerShell DSC resources: v3 does not auto-install their modules, and the samples' `Install-PSResource -TrustRepository` is an unpinned supply-chain hop. If one is ever needed, pin the module version in the repo. Do not use `Microsoft.Windows.Developer` (prerelease-only).
- `useLatest` for self-updating GUI apps (they update themselves regardless of pins — documented in an ADR, as on the Mac); exact `version` for tools where it matters (PowerShell, Git).
- Scope: user scope where the package supports it; machine scope (`securityContext: elevated`) only when required.
- Apply: `winget configure -f <file> --accept-configuration-agreements --disable-interactivity`.
- Verify: `winget configure test -f <file>` (declared-but-missing).
- Drift (installed-but-undeclared): diff `Get-WinGetPackage` / `winget export` against declared IDs, minus a reviewed allowlist of inbox/OEM noise kept in the repo.
- Default-profile entry cap, like the Mac's ADR-022 **[call: 40 for Windows]**.

**Profiles and contents [call, from the parity research]:**

| Profile | Default | Packages (winget ID) |
|---|---|---|
| core | yes | `Microsoft.WindowsTerminal`, `Microsoft.PowerShell`, `Git.Git`, `twpayne.chezmoi`, JetBrains Mono Nerd Font (local manifest) |
| dev | yes | `Microsoft.VisualStudioCode`, `ZedIndustries.Zed` |
| security | yes | `Bitwarden.Bitwarden`, `Henry++.simplewall` |
| productivity | yes | `Obsidian.Obsidian` |
| productivity-extra | no | `Google.Chrome`, `Mozilla.Firefox.DeveloperEdition`, `SlackTechnologies.Slack`, `Anthropic.Claude`, `OpenAI.ChatGPT`, `OBSProject.OBSStudio`, `mpv.net`, `Tailscale.Tailscale`, `OpenVPNTechnologies.OpenVPN` |
| backup | yes | `restic.restic`, `Rclone.Rclone` |
| local-llm | no | `ElementLabs.LMStudio` |
| lab | no (Pro only) | none from winget; enables Hyper-V and the lab VM scripts |

Dropped from the Mac with reasons recorded: BetterDisplay (user), iTerm2 (Windows Terminal), Pearcleaner (`winget uninstall`), Latest (`winget upgrade`), FreeRDP (`mstsc.exe`), Ghostty (no Windows build), LuLu (simplewall), MLX (Apple-only; CUDA in WSL instead), Razer Synapse, NVIDIA App.

**Font:** repo-owned local manifest — `InstallerType: zip`, `NestedInstallerType: font`, `InstallerUrl` = the upstream `ryanoasis/nerd-fonts` v3.5.1 `JetBrainsMono.zip`, pinned `InstallerSha256`, `NestedInstallerFiles` limited to the `*NerdFontMono-*.ttf` faces. Installed with `winget install --manifest`. Terminal face: `JetBrainsMono Nerd Font Mono`.

**Per-app hardening after install** (via chezmoi or policy files, verified by read-back):
- VS Code: `telemetry.telemetryLevel: off`, `update.mode: manual`, add `ms-vscode-remote.remote-wsl`.
- Zed: `auto_update: false`, telemetry off.
- Firefox Dev: `policies.json` with `DisableTelemetry`, `DisableAppUpdate` per the Mac's posture **[verify Mac posture]**.
- Tailscale: `TS_NO_LOGS_NO_SUPPORT=true` in `%ProgramData%\Tailscale\tailscaled-env.txt`; `tailscale set --auto-update=false`. Tailscale runs on the host only; WSL reaches the tailnet through it.
- OpenVPN: limit MSI components with `ADDLOCAL`, set services to Manual **[verify 2.7 feature names]**.

### 6.6 Terminal

**Windows Terminal [call, accepted by user]**, the closest Ghostty substitute:
- Defaults match the Mac's Ghostty security posture: multi-line and large paste warnings on, copy-on-select off, OSC 52 clipboard read impossible (ConPTY filters it).
- Known loss: **no middle-click paste** (microsoft/terminal#1553, open). Right-click paste remains. Record in an ADR.
- Config ownership: the Settings UI rewrites `settings.json`. Use a chezmoi `modify_` script that merges only declared keys (profiles default, font, color scheme, paste warnings, `copyOnSelect: false`, the `dev` WSL profile) and preserves everything else — the same pattern as the Mac's Docker `modify_` script. Put the color scheme and profile in a JSON Fragment where possible **[call]**.
- The WSL profile runs `wsl.exe -d dev --cd ~` and the login shell inside the distro; it does not change the account's login shell.
- Stop Store auto-updates of Terminal? **No [call]**: Terminal is a Microsoft inbox component and Store updates are its security patch channel. Recorded as an accepted self-update, like Chrome.

### 6.7 Windows settings ("defaults")

Mirror the Mac's `macos-defaults` (`--diff`, `apply`, verify by read-back):
- Declared tables in `defaults/*.psd1`: key path, value name, type, desired value, scope (HKCU/HKLM), why, source URL.
- Initial set: show file extensions, show hidden files, dark mode, taskbar search mode, Widgets off, long paths (`LongPathsEnabled=1`, HKLM), Developer Mode **off by default** (it enables Device Portal/Discovery SSH options; not needed because chezmoi uses file mode, not symlinks).
- Privacy (Pro-honoured only): diagnostic data at **Required (1)** — 0 is Enterprise-only and is not shipped; tailored experiences off; advertising ID off; activity history off; search highlights off; cloud search off; feedback notifications off. **Not shipped** because Pro ignores them: `DoNotUseWebResults`, `DisableWindowsConsumerFeatures`, Spotlight and tips policies.
- Copilot app: removed with `winget uninstall` if present, not by the contradictory Pro policy **[verify]**. Recall: check only (285HX is not a Copilot+ PC **[verify]**).

### 6.8 Hardening

Two scripts, as on the Mac:

**`script/hardening-check` (read-only, `-Strict` exits non-zero):**
- Secure Boot (`Confirm-SecureBootUEFI`), TPM (`Get-Tpm`).
- Defender: Active mode, real-time, behaviour monitoring, tamper protection, cloud protection (`Get-MpComputerStatus`).
- Memory integrity (HVCI) running, read from `Win32_DeviceGuard`.
- LSA protection (`RunAsPPL`).
- UAC: `EnableLUA=1`, `PromptOnSecureDesktop=1`, `ConsentPromptBehaviorAdmin`.
- Firewall profiles enabled with inbound Block.
- **Hyper-V firewall for WSL: `DefaultInboundAction` = Block**; no inbound allow rules for the WSL VMCreatorId.
- **`netsh interface portproxy show all` is empty.**
- No listener on a non-loopback address owned by `wslrelay`, `vmmem`/`vmmemWSL` or `docker-proxy` (via `Get-NetTCPConnection -State Listen`).
- Smart App Control state (report only).
- Kernel DMA Protection (report).
- Account type and whether the daily account is an administrator (report).
- Device encryption state (report only; BitLocker is out of scope **[user]**, but state is reported so it is never a surprise).
- WSL distro BasePath under `D:\` (from `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\*\BasePath` **[verify key]**).

**`script/hardening` apply (safe subset only):**
- ASR rules via `Set-MpPreference`: Block for the low-friction standard-protection set (vulnerable signed drivers, LSASS credential theft, WMI persistence); Audit for the rest first.
- HVCI: `Enabled=1`, `Locked=0` only, after a driver-compatibility check.
- LSA protection: `RunAsPPL=2` (no UEFI lock).
- UAC: secure-desktop prompt on.
- **Never:** `Locked=1`, `Mandatory=1`, `RunAsPPL=1`, `EnableLUA=0`, scripting Smart App Control, Hyper-V firewall `DefaultInboundAction Allow`, portproxy entries, Controlled Folder Access on by default (it blocks writes to Documents, where the PowerShell profile lives), automatic Defender exclusions.
- Tamper protection makes Defender writes silently no-op: every change is verified by reading it back, never by exit code.

**Windows Update and the NVIDIA driver [call]:**
- Quality updates stay automatic. Feature updates deferred by a documented number of days (Pro honours Windows Update client policies).
- Do **not** set `ExcludeWUDriversInQualityUpdate`: it blocks chipset and Thunderbolt drivers too. Accept that WU may offer an older NVIDIA DCH driver; reinstall the Studio driver when that happens (documented recovery). Revisit if it becomes a real problem (a per-device hardware-ID block is the narrower option **[verify]**).
- NVIDIA driver is **manual**: not in winget. Runbook: nvidia.com Studio driver, Custom install, untick NVIDIA App, keep driver + HD Audio + PhysX. `verify` reports the driver version and whether `nvidia-smi.exe` sees the GPU (absent eGPU is "absent", not "failed").

### 6.9 WSL stage

1. **`.wslconfig`** (chezmoi on Windows, template variables derived from the host at apply time):
   ```
   [wsl2]
   memory=48GB            # 50% of 96 GB; leaves room for LM Studio on the host
   processors=<logical-2>
   swap=16GB
   networkingMode=nat     # NOT mirrored (see §8.1)
   localhostForwarding=true
   firewall=true
   telemetry=false        # ADR-046 equivalent
   [general]
   distributionInstallPath=D:\\WSL
   [experimental]
   sparseVhd=true
   autoMemoryReclaim=gradual
   ```
   Followed by `wsl --shutdown` (changes apply only after the VM stops).
2. **Distro image lock** (`wsl/ubuntu.lock`): the `Ubuntu-26.04` `.wsl` URL and SHA256 from Microsoft's `DistributionInfo.json`. The stage downloads it to a temp dir with `curl.exe`, verifies SHA256, and refuses on mismatch. Never the bare `Ubuntu` alias (it moves).
3. **cloud-init user-data**, written to `%USERPROFILE%\.cloud-init\dev.user-data` before first boot: creates the operator's user, adds it to `sudo`, sets it as `[user] default` in `/etc/wsl.conf`, enables systemd. Contains no secrets. Removed after first boot.
4. **Install:** `wsl --install --from-file <verified>.wsl --name dev --location D:\WSL\dev --no-launch`, then start once and wait for cloud-init to finish (`cloud-init status --wait`).
5. **Password:** `wsl -d dev -u root -- passwd <user>` interactively **[call]**. Documented honestly: with interop on, any WSL process can run `wsl.exe -u root`, so the sudo password is not a security boundary inside WSL; it exists for parity and to stop accidents.
   **Login shell [call]:** cloud-init creates the user with Ubuntu's default (bash). `setup-dev-linux-wsl` installs the selected shell and, like the Mac's `run_onchange_after_30_report-login-shell`, reports the one `chsh -s /usr/bin/zsh` command for the operator to run; it never runs `chsh` itself. Until then the Windows Terminal profile starts the selected shell explicitly (`wsl.exe -d dev --cd ~ -- zsh -l`).
6. **Handoff** (§5.2).
7. **Verify:** distro exists, is WSL2, BasePath on D:, default user set, `setup-dev-linux-wsl verify` passes.

Re-provisioning = `wsl --export` (optional backup to D:) → `wsl --unregister dev` → re-run the stage. cloud-init runs only once per instance.

### 6.10 Commands and task runner

- PowerShell scripts in `script/` are the interface. A `justfile` is not used on Windows **[call]**: `just` would be an extra host tool whose only job is aliasing. `script/` names match the Mac (`setup`, `verify`, `hardening-check`, `windows-defaults`, `update-report`, `test`, `test-install`).

### 6.11 Testing

- **`script/test`** (the gate, runs locally and in CI): PSScriptAnalyzer, formatting check, Pester unit tests, gitleaks, yamllint on configuration files, schema validation of configuration files, `.gitattributes`/line-ending checks, invariant tests (e.g. no `DefaultInboundAction Allow`, no `RunAsPPL = 1`, no `Locked = 1`, no `Invoke-Expression` of downloaded content, no `iwr | iex`, no Scoop/Chocolatey references in code, cap on default profile). Same "no silent skips" rule: `REQUIRE_LINTERS=1` fails if a linter is missing.
- **CI:** GitHub Actions `windows-2025` (Server 2025, not client) for lint + Pester + config validation. It cannot prove client-only behaviour (Store registration, Settings, edition logic, Hyper-V).
- **Destructive test harness (`script/test-vm`, Pro only):** Gen2 Hyper-V VM (vTPM, Secure Boot) from the Windows 11 Enterprise evaluation ISO (90 days; needs a Microsoft account; rebuild before expiry). Nested virtualization (`Set-VMProcessor -ExposeVirtualizationExtensions $true`, MAC spoofing, fixed memory) so WSL2 runs inside. Golden checkpoint after OOBE; per run: restore checkpoint → bootstrap → reboot/resume → verify. VM files on `D:\Hyper-V`. Detect nested-virt support; do not assume it.
- **Known gap:** the eval is Enterprise, not Pro or Home. Edition gating and Pro-only policy behaviour cannot be proven in the harness. Stated, not hidden.

### 6.12 Lab VM

The Mac's `lab` profile (Lima/UTM) becomes a Hyper-V VM on Pro. A second WSL distro is **not** an isolation boundary (shared kernel, `/mnt/c`, interop) and must not be offered as one. v1 scope: a script that creates an isolated Ubuntu Hyper-V VM on an internal or NAT switch with no host shares **[call: later phase]**.

---

## 7. setup-dev-linux-wsl

### 7.1 Targets

- `--target wsl`: Ubuntu 26.04 LTS in WSL2, systemd on.
- `--target linux`: Ubuntu 26.04 LTS on bare metal or a VM, headless.
- Fail on any other distro or release. Detect WSL; never assume.
- x86_64 only **[call]**. No arm64 branches.
- **Release fallback [call]:** in phase L1, before anything is locked, check that every vendor repo in the default and `gpu-nvidia` profiles publishes packages for 26.04 ("resolute"). If one does not (CUDA is the likeliest), the whole repo targets 24.04 LTS for v1. Repos from different Ubuntu releases are never mixed.

### 7.2 Repo layout **[call]** (mirrors `setup-dev-mac`)

```
bootstrap                    entrypoint; plan | apply
script/                      setup, verify, hardening-check, update-report, test, test-install, docker-substrate, gpu-check, wsl-integration, …
script/lib/common.sh
profiles/*.Brewfile          Homebrew-on-Linux profiles (formulae only)
apt/*.list + apt/repos/*.sources + apt/keys/*.asc + apt/pins.lock   base packages, vendor repos, pinned versions
chezmoi/                     dotfiles ported from setup-dev-mac (.chezmoiroot)
mcp/                         policy catalogue (copy)
tests/                       bash tests, as on the Mac
docs/ AGENTS.md CLAUDE.md README.md TASKS.md justfile
```

Bash scripts follow the Mac's shell standards exactly (`#!/usr/bin/env bash`, `set -Eeuo pipefail`, arrays, `mktemp` + traps, discovery by shebang via `script/shell-files`). `just` is available here (from Homebrew), so the Mac's justfile pattern carries over.

### 7.3 Bootstrap order

1. Preflight: Ubuntu 26.04, not root, target detection, ext4 home, no repo under `/mnt/`.
2. **apt base** (`apt/base.list`): zsh, build-essential, ca-certificates, curl, git, socat, uidmap, procps, file, unzip, gnupg (the Homebrew-on-Linux prerequisites plus the shell).
3. **Vendor apt repos**: keys committed under `apt/keys/` with their fingerprints asserted by a test (Docker; NVIDIA CUDA keyring; NVIDIA Container Toolkit; Anthropic `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`). deb822 `.sources` with `Signed-By`. Versions pinned in `apt/pins.lock`; installed only when the matching profile is selected.
4. **Homebrew** installed to `/home/linuxbrew/.linuxbrew`. Preferred method **[call]**: `git clone` of `Homebrew/brew` at a pinned release tag into the prefix (Homebrew's documented alternative install), then `brew update`. No `install.sh` pipe. If the pinned-clone path proves unsupported **[verify]**, fall back to the official installer **downloaded, reviewed (hash pinned in a lock file), then run** — documented as the repo's single remote-script exception, mirroring the Mac's Homebrew boundary. `HOMEBREW_NO_ANALYTICS=1` set before the first brew command.
5. `brew bundle` for the rendered profiles (formulae only; casks don't apply on Linux). Same render-and-cap logic as the Mac.
6. **mise** runtimes (node, python, go, rust, java as on the Mac), and `uv`.
7. **chezmoi** apply.
8. Target-specific: WSL integration (§7.6).
9. Docker, GPU, agents per profile.
10. `verify`.

### 7.4 Profiles **[call]**

| Profile | Default | Contents |
|---|---|---|
| core | yes | Brewfile: chezmoi, starship, tmux, ripgrep, fd, fzf, bat, eza, zoxide, atuin, jq, yq, git-delta, btop, just, xh, trash-cli, git-lfs, neovim, gh, age, sops, gitleaks, direnv, mise, uv |
| dev | yes | shellcheck, shfmt, actionlint, yamllint, hadolint, trivy; agent CLIs (codex, opencode via Homebrew if the formula exists on Linux **[verify]**, else mise) |
| security | yes | openssl@3 |
| kubernetes | yes | kubectl, helm, k9s, kubectx, stern, k3d, kind, kubeconform, krew, argocd, kustomize, helmfile, kubeseal (as on the Mac, ADR-038) |
| productivity-extra | no | htop, midnight-commander, rsync (real rsync on Linux) |
| backup | yes | restic, rclone (backs up non-git state in `$HOME` only) |
| runtime-docker | yes | Docker Engine from Docker's apt repo (§7.7) |
| gpu-nvidia | no | CUDA toolkit + NVIDIA Container Toolkit (§7.8) |
| ai-agents | yes | Claude Code (Anthropic apt), managed policy (§7.9) |
| local-llm | no | The LM Studio relay (§8.2), WSL target only; pairs with the Windows `local-llm` profile |
| shell-zsh / shell-fish | zsh default | mutually exclusive, as on the Mac |

Each Brewfile entry keeps the Mac's purpose comment. Entries whose formula is unavailable or broken on Linux are listed in an ADR with the replacement.

### 7.5 Dotfiles (port from `setup-dev-mac`)

Port, don't fork-and-forget: each file starts from the Mac template, and Apple-only lines are removed with a comment saying why.

| File | Changes from the Mac |
|---|---|
| `.zshrc` / fish config | `brew shellenv` from `/home/linuxbrew/.linuxbrew`; no `/opt/homebrew`; no Rancher/Colima branches; same telemetry set (`HOMEBREW_NO_ANALYTICS`, `AZURE_CORE_COLLECT_TELEMETRY`, `CHECKPOINT_DISABLE`, `DO_NOT_TRACK`), re-verified for Linux; same atuin-after-fzf order; `GPG_TTY`; same aliases |
| `.gitconfig` | SSH signing (`gpg.format=ssh`, `allowed_signers`), `core.autocrlf=false`; no `osxkeychain` |
| `.ssh/config` | Same allowlists and `IdentitiesOnly`; **no `UseKeychain`** (Ubuntu ssh rejects it); `IdentityFile ~/.ssh/id_ed25519`; per-host `config.d/` include first |
| `~/.local/bin/conn` | Ported as-is (zsh + fzf); verify it parses `config.d` the same way |
| starship, atuin, ripgreprc, mise config, direnv | Ported unchanged where possible |
| `.docker/config.json` | `modify_` script as on the Mac (ADR-039: never base64 tokens on disk). Credential store **[call]**: on `--target wsl`, `docker-credential-wincred.exe` from docker/docker-credential-helpers (hash-pinned, called through interop via an explicit wrapper, storing tokens in Windows Credential Manager) **[verify: works without Docker Desktop]**; on `--target linux`, or if wincred fails, `docker-credential-pass` with a per-machine encryption-only GPG key and `pinentry-curses` |
| `includeIf gitdir:` work identity | Carried over unchanged from the Mac (work identity by directory) **[call]** |

**Identity [user]: SSH signing with a per-machine key.** This deliberately differs from the Mac, which signs with OpenPGP (ADR-017, `gitSigningMethod = gpg`); record it as an ADR in the Linux repo.

- A per-machine `~/.ssh/id_ed25519` generated inside the distro on first run, never copied, enrolled at the forge as both an authentication key and a signing key.
- git: `gpg.format=ssh`, `user.signingkey` pointing at the public key file, `gpg.ssh.allowedSignersFile` maintained by the repo (the operator's machine keys, public only) so `git log --show-signature` verifies locally.
- Commits from Windows and from the Mac verify on the forge under different keys; both show as Verified.
- The template keeps `gitSigningMethod` so `gpg` remains selectable later, but `ssh` is the Linux default.
- No Bitwarden SSH agent bridge (single-pipe instance hangs, agent forwarding wedges it). HTTPS fallback: `gh auth git-credential` for GitHub.
- gnupg is not in the default profiles; it arrives only if `docker-credential-pass` is needed.

### 7.6 WSL integration (`--target wsl` only)

- **`/etc/wsl.conf`** (root-owned, written by the repo):
  ```
  [boot]      systemd=true
  [automount] options="metadata,umask=022,fmask=011"
  [interop]   enabled=true
              appendWindowsPath=false
  [user]      default=<user>
  ```
  `appendWindowsPath=false` stops Windows `git.exe`, `ssh.exe`, `docker.exe`, `code` shadowing Linux tools and keeps one PATH owner. Selected Windows binaries are exposed by explicit wrappers in `~/.local/bin`: `code` (VS Code's WSL launcher), `explorer.exe`, `clip.exe`/`wsl-open`-style helpers **[call: start with `code` and `explorer`]**.
- Check: no git repo under `/mnt/` (verify fails if found).
- Check: `wslc` (WSL containers, 3.0.1+) is not active alongside dockerd — one container runtime **[verify whether it's on by default]**.
- systemd units the WSL docs recommend masking are masked only if they cause a verified problem **[call]**.

### 7.7 Docker Engine

- Packages from Docker's signed apt repo, versions pinned: `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. Remove `docker.io`, `podman-docker` first. Never the convenience script.
- Rootful `dockerd` under systemd by default; the operator is added to the `docker` group, with the docs stating plainly that this is root-equivalent (the Mac tolerates the Colima socket on the same basis). Rootless as an opt-in profile **[call]**.
- `/etc/docker/daemon.json`:
  ```json
  {
    "ip": "127.0.0.1",
    "default-network-opts": { "bridge": { "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1" } },
    "log-driver": "local"
  }
  ```
  (containerd image store is the default from Docker 29; no flag needed **[verify]**.)
- iptables backend: **detect** which of iptables-nft / iptables-legacy works on the running kernel; never blindly `update-alternatives`.
- No `tcp://` listener. Windows tools never talk to the daemon; VS Code Remote-WSL and Dev Containers run on the Linux side.
- `script/docker-substrate`: the Mac's `container-substrate` equivalent minus the VM — one shared network, image cache, build cache; **no stateful service** (ADR-010/037 rule carried over).
- Verify: daemon running; `ss -ltnH` shows no non-loopback listener from `docker-proxy`; a throwaway `-p 8080:80` container binds 127.0.0.1 only.

### 7.8 GPU (profile `gpu-nvidia`)

- CUDA toolkit from NVIDIA's standard Ubuntu `cuda-keyring` repo, `cuda-toolkit-13-x` pinned. **Never** a Linux display driver (`cuda-drivers`, `nvidia-open`, `nvidia-driver-*`); a test refutes those package names. The WSL-specific CUDA repo is deprecated and not used.
- NVIDIA Container Toolkit from NVIDIA's apt repo; `--gpus all` only under WSL.
- **Provisioning must succeed with the eGPU absent.** `script/gpu-check` compares Windows `nvidia-smi.exe` (via interop, WSL target only) with Linux `nvidia-smi` and reports one of: `present`, `absent`, `stale` (Windows sees it, Linux doesn't → print the `wsl --shutdown` recovery), `failed`.
- Runbook: attach the eGPU before WSL starts; hot-unplug under load can hang or crash the VM; recovery sequence documented.
- Project-local ML: each project's uv environment selects the PyTorch CUDA index itself (the Mac's MLX boundary, translated). The repo installs no ML framework.

### 7.9 AI agents

- Claude Code from Anthropic's signed apt repo (pinned; apt installs don't self-update).
- Codex and opencode per §7.4.
- Policy generated from `mcp/managed-settings.json`:
  - `/etc/claude-code/managed-settings.json` (+ `managed-mcp.json`), root-owned 0644.
  - `/etc/codex/requirements.toml`.
  - On WSL, documented as **advisory**: the user can become root (`wsl -u root`). The stronger copy is the Windows-side `C:\Program Files\ClaudeCode\managed-settings.json` with `wslInheritsWindowsSettings`, owned by `setup-dev-win` **[call: ship both; Windows copy in a later phase]**.
- Telemetry/env opt-outs for agents carried from the Mac where verified for Linux.

### 7.10 Testing

- **`./script/test`**: shell syntax + shellcheck + shfmt over files found by shebang, actionlint, gitleaks, yamllint, chezmoi template execution for both targets, Brewfile render + cap, apt key fingerprint assertions, invariant tests (loopback daemon.json, no Linux NVIDIA driver packages, no `curl | sh` outside the documented exception, no `UseKeychain`/`osxkeychain` in templates, telemetry set parity across shells). Same `REQUIRE_LINTERS=1 REQUIRE_CHEZMOI=1` no-silent-skip mode.
- **CI**: `ubuntu-24.04`/`ubuntu-latest` for static checks; a systemd-enabled `ubuntu:26.04` container for apt + repo provisioning; optionally a `windows-2025` job with a WSL setup action for an end-to-end WSL install incl. Docker and port-binding assertions (cannot prove GPU or real Pro firewall state).
- **`script/test-install`** (destructive):
  - On Windows: a throwaway distro (`wsl --install --from-file <verified> --name dev-test-<n>`), run bootstrap, verify, `wsl --unregister`.
  - Before the Windows machine is ready, the proof is GitHub Actions on x86_64 (static checks plus a systemd-enabled Ubuntu container running the real bootstrap). No arm64 VM on the Mac is used as evidence **[call]**.

---

## 8. Cross-cutting decisions

### 8.1 WSL networking: NAT, not mirrored **[call]**

Mirrored mode would let WSL reach host loopback (LM Studio), but it (a) makes WSL services reachable from the LAN on the host IP, (b) is documented alongside advice to set the Hyper-V firewall to inbound Allow, and (c) breaks Docker 28+ loopback-published ports. NAT keeps everything off the LAN. Enforced at four layers: Docker `daemon.json`, `.wslconfig`, Windows checks (Hyper-V firewall Block, portproxy empty), runtime listener checks on both sides.

### 8.2 Reaching LM Studio from WSL

NAT-mode WSL cannot reach a Windows service bound to 127.0.0.1. Options:
**Decision: a local relay [user].** A listener in WSL on `127.0.0.1:1234` forwards each connection through Windows interop to LM Studio on Windows' `127.0.0.1:1234`. Nothing listens on a network interface on either side, and LM Studio's "Serve on Local Network" stays off.

- Owned by `setup-dev-linux-wsl` (profile `local-llm`, WSL target only), started on demand or as a systemd user unit. The Windows-side half must be an inbox binary or a hash-pinned helper; no new unpinned host tool.
- It must be proven on the real machine first (phase W7/L5) **[verify]**: streaming responses, concurrent requests, and behaviour after `wsl --shutdown`.
- If the relay cannot be made reliable, the fallback is "Serve on Local Network" plus a Windows Firewall allow rule scoped to the WSL vEthernet subnet, with `hardening-check` accepting exactly that rule. Choosing the fallback is a new decision for the operator, not something the builder switches to silently.
- Never: mirrored mode or an unscoped LAN bind.

### 8.3 Self-updating apps

Accepted and documented (as the Mac's ADR-028): Chrome, Slack, VS Code (set to manual), Zed (set off), Claude, ChatGPT/Terminal (Store), Bitwarden, LM Studio, Obsidian, Firefox (policy). Pins constrain winget only.

### 8.4 Telemetry

- Windows: winget `telemetry.disable`; `.wslconfig telemetry=false`; `POWERSHELL_TELEMETRY_OPTOUT=1` (user environment); VS Code and Zed settings; Tailscale log opt-out; diagnostic data at the Pro floor (Required). NVIDIA App not installed.
- Linux: the Mac's shell set, re-verified per tool on Linux.
- Every entry cites what reads it.

### 8.5 Line endings

Both repos: `.gitattributes` `* text=auto eol=lf`; CRLF only where a Windows consumer requires it (e.g. `.cmd`), declared per file. WSL git `core.autocrlf=false`. The workspace repos moving between Mac and Windows carry their own `.gitattributes`.

### 8.6 Backup

- Windows: restic + rclone, Windows profile and D: data (excluding `D:\WSL`), with VSS (`--use-fs-snapshot`).
- WSL: restic of non-git `$HOME` state (gnupg, age keys, atuin, kube contexts). Code is in git.
- Occasional `wsl --export` of the distro to D: as a disaster image.
- Credentials for the backup target never in the repo.

---

## 9. Phasing (to be detailed by the implementation plans)

Ordered so the machine is usable early and each phase ends verified.

| # | Repo | Phase | Done when |
|---|---|---|---|
| W0 | win | Skeleton: AGENTS.md, docs, ADR log seeded with the decisions above, `script/test`, CI | `script/test` green in CI |
| L0 | linux | Skeleton: same, Mac test harness ported | `./script/test` green in CI |
| W1 | win | Stage-0 bootstrap, preflight, winget settings, PowerShell 7, state/resume framework | Fresh machine reaches `script/setup` |
| W2 | win | Features + `.wslconfig` + verified distro install on D: + cloud-init + handoff stub | `dev` distro on D:, user set, systemd on |
| L1 | linux | Bootstrap: apt base, vendor repos, Homebrew, core profile, mise, uv | Core tools run in WSL and in CI container |
| L2 | linux | Dotfiles port (zsh/fish, git, ssh, starship, atuin, conn, telemetry) + identity | Shell feels like the Mac; signed commit works |
| L3 | linux | WSL integration + Docker Engine + substrate + exposure checks | `docker compose` works; nothing beyond loopback |
| W3 | win | App profiles, font manifest, verify + drift | `winget configure test` clean; drift report |
| W4 | win | Windows-side chezmoi: Terminal (modify_), PowerShell profile, VS Code/Zed settings | Terminal opens `dev` with the font and posture |
| W5 | win | Windows defaults, hardening apply + check, network exposure checks | `hardening-check -Strict` passes |
| L4 | linux | GPU profile + gpu-check | eGPU present/absent both handled |
| L5 | linux | AI agents + policy; kubernetes, dev, backup profiles | Agents run with policy |
| L6 | linux | verify / update-report / test-install | Throwaway distro install passes |
| W6 | win | Hyper-V test harness + lab VM (Pro) | Full bootstrap passes in the VM |
| W7 | both | LM Studio bridge (per §10), Windows-side Claude policy, backup, runbooks | OPERATIONS complete |

Linux phases L0–L2 can be written on the Mac and proven in x86_64 GitHub Actions before the Windows machine is ready.

---

## 10. Questions resolved after the builder check

| Question | Answer |
|---|---|
| Is the daily Windows account an administrator? | Yes **[user]** (§6.2) |
| How does WSL sign commits? | SSH, per-machine key **[user]** (§7.5), differing from the Mac's GPG |
| Where do Docker registry credentials go? | wincred via interop on WSL, `pass` otherwise **[call]** (§7.5) |
| How does WSL reach LM Studio? | Local interop relay; firewall-scoped bind only as an operator-approved fallback **[user]** (§8.2) |
| Repo visibility | Both public, like setup-dev-mac **[user]**; bootstrap clones over HTTPS without credentials. Creating the GitHub repos is done only with the operator's go-ahead |
| Login shell in WSL | Reported, operator runs `chsh` **[call]** (§6.9) |
| Testing architecture | x86_64 only; CI before the Windows box **[call]** (§7.1, §7.10) |
| Ubuntu release if a vendor lags | Whole repo drops to 24.04 for v1; no mixing **[call]** (§7.1) |
| Hyper-V on every Pro machine? | Only with `lab` **[call]** (§6.4) |
| Work/personal git identity split | Carried over **[call]** (§7.5) |

## 11. Left to the builder

- Exact PowerShell module structure, function names, state-file schema.
- Pester/bash test organisation.
- Exact pinned versions (resolved at implementation time and recorded in lock files).
- Wording of runbooks.
- Exact winget allowlist for drift noise (gathered from a real machine).
