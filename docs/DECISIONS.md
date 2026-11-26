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
repositories, the SHA256-verified Ubuntu image (the hash comes from Microsoft's
manifest, ADR-016) and the SHA256-verified Nerd Font zip from GitHub (ADR-021; never
executed). Stage-0 never downloads winget and never installs a module from PSGallery. `Invoke-Expression`, `iex` and
`DownloadString` are banned and enforced by `tests/Repo.Tests.ps1`.

Stage-0 does not call `Set-ExecutionPolicy`. The documented launch is
`powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1`, and under that
process-scope override `Set-ExecutionPolicy` raises ExecutionPolicyOverride and
would abort before the handoff. PowerShell 7 keeps its own execution policy, which
defaults to RemoteSigned on Windows, so nothing needs persisting.

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

## ADR-009: Elevated launch quotes every argument and elevates the running pwsh

Status: accepted; amended by ADR-016 (the MSIX package is elevated through its app
execution alias). Spec section 6.2; amends the plan's `Start-Process pwsh -Verb RunAs`.

`Invoke-ElevatedScript` builds ONE argument string, quoting each token by the
`CommandLineToArgvW` rules (embedded quotes escaped, backslashes before a quote or at
the end doubled): `Start-Process -ArgumentList` joins an array with bare spaces, which
breaks a repository path that contains a space. It elevates the absolute path of the
running pwsh (`[Environment]::ProcessPath`), not a `pwsh` looked up on PATH, so a binary
planted earlier on PATH is never what runs elevated. A declined UAC prompt is a
terminating error that the caller turns into a failed stage. Tests assert the exact
argument string for paths with spaces and trailing backslashes.

## ADR-010: Optional-feature state is read through CIM; one elevation, no re-read

Status: accepted. Spec section 6.4; replaces `Get-WindowsOptionalFeature` and the
plan's `-CheckOnly` channel.

`Get-WindowsOptionalFeature -Online` needs elevation, so reading state through it would
raise a UAC prompt per read and put an admin cmdlet outside `script/elevated/`. State is
read without elevation from `Win32_OptionalFeature` (`InstallState` 1 Enabled,
2 Disabled, 3 Absent; to be confirmed for a pending state in the Milestone 1
acceptance run). The missing features are enabled by one elevated run of
`script/elevated/Enable-Features.ps1`, which only enables: there is no `-CheckOnly`
mode and no re-read after enabling. Its exit code is the result (0 done, 3010 restart
needed, 1 failed, 2 refused name); a failure after an earlier feature asked for a
restart still exits 1 and says that the restart is owed. Its `[warn]`/`[fail]` lines
also go to `%LOCALAPPDATA%\setup-dev-win\elevated.log`, which the features stage prints
after a failed run, because the elevated window closes on exit. The library module is
`script/lib/WindowsFeatures.psm1` (not `Features.psm1`, which would clash with
`script/stages/Features.psm1` under Pester's `Mock -ModuleName`).

## ADR-011: The effective default user is asserted, not the registry DefaultUid

Status: accepted. Spec section 6.9; replaces the plan's `DefaultUid -ne 0` check.

`/etc/wsl.conf` `[user] default` (written by cloud-init) is not written back to the
`Lxss` registry value `DefaultUid`, and `.wsl` images update it only after the
out-of-box experience on a first interactive shell, so a registry check fails a correct
install. After cloud-init and `wsl --terminate dev` the stage runs
`wsl --manage dev --set-default-user <name>` (a failure there, including an unknown
option, is only a warning), then asserts what the distro itself reports:
`wsl -d dev -- id -un` equals the name and `id -u` is at least 1000. The registry value is
printed for diagnosis only. `Assert-DistroPlacement` keeps the `BasePath` and WSL
version checks. The wsl stage and verify both assert the user, because the install
step returns early when `dev` already exists.

## ADR-012: The Linux password is set whenever passwd -S says it is unset

Status: accepted. Spec section 6.9; replaces the plan's "first install only".

cloud-init creates the user with a locked password and `sudo` needs one. Keying the
`passwd` prompt on "dev was installed by this run" left the user without a password
forever when any later step of that first run failed. Every wsl-stage run reads
`wsl -d dev -u root -- passwd -S <user>`: `L` (locked) or `NP` (none) runs the
interactive `passwd`; `P` skips it; an unreadable status asks (fail safe). The
password is typed into `passwd`, never through this repository. With WSL interop on,
any WSL process can run `wsl.exe -u root`, so this password is not a security boundary
inside WSL; it exists for parity and to stop accidents (spec 6.9).

## ADR-013: Handoff hardening: no stale or foreign code runs silently

Status: accepted. Spec section 5.2; replaces the plan's handoff script.

The handoff runs a fixed bash program, wrapped in single quotes and containing none,
with the URL and ref passed only as `$1` and `$2`. The URL must be
`https://github.com/<owner>/<repo>[.git]` and the ref `[A-Za-z0-9._/-]{1,200}` not
starting with `-`; both are validated at the top of the wsl stage, `-Plan` included,
before anything is downloaded. git is probed first (`command -v git`) and installed as
root when missing, replacing the plan's exit-2 heuristic. An existing clone must have
`remote.origin.url` (read with `git config --get`, which an `insteadOf` rewrite cannot
mask, unlike `git remote get-url`) equal to the URL, ignoring a trailing `.git`;
otherwise the run stops with `existing clone points at ...`. After `git fetch --tags`
the target is resolved first (`origin/<ref>^{commit}`, else `<ref>^{commit}` for a tag
or commit) and the run stops with `unknown ref <ref>` when neither exists; it is then
checked out detached, once, with git's errors visible, so local changes that conflict
stop the run. The plan's `git checkout "$ref"; git pull --ff-only || true` could
silently keep running an old branch and is gone. Linux-only tests execute the real
program against a local bare repository.

## ADR-014: PowerShell is a floor within the 7.6 LTS line, installed as the MSI

Status: superseded by ADR-016. Superseded the exact `7.6.6` pin in the plan and spec.

An exact pin failed every re-run after Windows Update or winget moved pwsh to a later
7.6 patch. `pins.psd1` `PowerShell` is now a floor: stage-0 accepts an installed
`7.6.x` at or above it (same major and minor, not a 7.7, not a preview), both when
deciding to skip the install and when choosing the pwsh to hand off to. When it must
install, it installs exactly the pinned version with
`winget install --id Microsoft.PowerShell --exact --version <pin> --installer-type wix --scope machine`:
the MSI lands in `C:\Program Files\PowerShell\7`, so `[Environment]::ProcessPath`
(ADR-009) is a real path an elevated process can start, with none of the MSIX
package's file-system virtualization. The MSI raises its own UAC prompt.

Lookup, 2026-11-24, with `gh api` against `microsoft/winget-pkgs`
`manifests/m/Microsoft/PowerShell`: versions `7.6.0.0` through `7.6.10.0` and `7.7.0.0`
are present. `7.6.10.0` (`ReleaseDate: 2026-11-10`, merged 2026-11-11 in PR #476823) is
the latest 7.6; its installer manifest has an x64 `InstallerType: wix`, `Scope: machine`,
`ElevationRequirement: elevatesSelf` entry for
`PowerShell-7.6.10-win-x64.msi` (SHA256 `7D8DAEA48B450D4D62FCD1AC4D6FAA7AC2DB5E11ABA5061EE81B7496ADCA8C07`)
alongside the MSIX bundle. The pin is `7.6.10`. The flags: Microsoft's `winget install`
reference (`install.md`, ms.date 2025-07-15) documents `--scope` and
`--installer-type`; winget-cli `ConvertToInstallerTypeEnum` accepts `wix`; winget's
`Version` drops trailing zero parts, so `--version 7.6.10` matches `7.6.10.0`.

## ADR-015: Operator choices are persisted; -LinuxUser exists

Status: accepted. Spec section 6.4.

`bootstrap.ps1` also takes `-DistroRoot` and `-LinuxUser` and passes each to
`script\setup.ps1` only when given, as its own quoted argument, so a machine without
`D:` can start with `-DistroRoot C:\WSL` and a later run still uses the kept value.
When the distro drive does not exist, preflight says to re-run with
`-DistroRoot <drive>:\WSL`.

`-Profiles`, `-DistroRoot` and `-LinuxUser` are kept under `settings` in
`%LOCALAPPDATA%\setup-dev-win\state.json`, written atomically like stage results. A flag
given explicitly wins and is persisted; without the flag the persisted value is used;
without either, the default (`core`, `D:\WSL`, and a Linux user derived from the Windows
user name, which the wsl stage persists once derived and prints before installing).
`-Plan` reads the choices and persists nothing. An explicit or persisted Linux user is
validated before use. `script/verify.ps1` reads the same values when its flags are
absent and never writes. Without this, a re-run after a reboot silently fell back to
the defaults (dropping `lab`, or looking for `dev` under the wrong root), and an invalid
Windows user name was a dead end because the message named a `-LinuxUser` that did not
exist.

## ADR-016: Install the latest stable components

Status: accepted. Operator decision, 2026-11-25 (rulings W21, W22). Supersedes ADR-014,
the frozen image URL and SHA256 in the spec and plan, and the pinned chezmoi version;
amends ADR-009.

Every component the setup installs on the machine is the latest stable release at
install time, not a pinned version:

- PowerShell: stage-0 runs `winget install --id Microsoft.PowerShell --source winget
  --exact --silent --accept-package-agreements --accept-source-agreements
  --disable-interactivity`, with no `--version`, `--installer-type` or `--scope`.
  `pins.psd1` `MinPowerShell = '7.6'` is a floor with no upper bound: an installed
  stable pwsh at or above it is kept and handed off to, an older one triggers the
  install. The handoff target is resolved after refreshing PATH: `pwsh.exe` on PATH,
  then `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`, then
  `%ProgramFiles%\PowerShell\7\pwsh.exe`; stage-0 throws naming what each reported.
- chezmoi: `twpayne.chezmoi` through winget at user scope with no `--version`, skipped
  when any chezmoi is present. CI's own chezmoi stays pinned in
  `tests/tool-versions.psd1`: it is the test harness, not installed on the machine.
- Ubuntu image: `wsl/ubuntu.lock.psd1` keeps only `Name` (`Ubuntu-26.04`) and `Source`
  (Microsoft's `DistributionInfo.json`). `Resolve-DistroImage` fetches `Source` over
  https and takes the `Amd64Url` `Url` and `Sha256` of the `ModernDistributions` entry
  with that name, so the newest point release is installed. The download is verified
  against that SHA256 exactly as before. An unreachable manifest, a missing or
  duplicated entry, a non-https URL or a hash that is not 64 hex characters stops the
  stage before anything is downloaded. The URL must also be on `releases.ubuntu.com` or
  `cdimage.ubuntu.com` (host compared exactly, case-insensitively) and its path must end
  with `.wsl`, so a changed manifest cannot point the download elsewhere. The wsl stage
  reads the manifest and downloads only when `dev` is not registered, and after a
  verified download removes other `*.wsl` and stale `*.partial` files from
  `<DistroRoot>\cache`.
- winget health: stage-0 runs `winget source update` before installing. A
  `0x80070005` / "Failed to open the predefined source" failure (seen on the real
  machine) stops it with the fix: `winget source reset --force` in an administrator
  terminal, `winget source update` in a normal one, then an App Installer update from
  the Microsoft Store if it persists.

Consequences of the MSIX package. winget's current `Microsoft.PowerShell` (7.7) ships
only as MSIX: a per-user install that normally raises no UAC prompt, started through
its app execution alias in `%LOCALAPPDATA%\Microsoft\WindowsApps`, which is on the user
PATH. The running pwsh's `[Environment]::ProcessPath` is then under
`C:\Program Files\WindowsApps\`, whose files are not meant to be started by path, so
`Invoke-ElevatedScript` elevates the alias instead and throws when it is missing
(amends ADR-009; verify on the real machine). Writes under AppData from a packaged
process can be virtualised and hidden from `wsl.exe`, so the image is cached in
`<DistroRoot>\cache` rather than `%TEMP%`, which also keeps it off `C:`.

Trade-offs, accepted by the operator:

- Trust in the image hash moves from a value reviewed in this repository to
  Microsoft's manifest, fetched over HTTPS from `raw.githubusercontent.com`
  (`microsoft/WSL`, branch `master`). Whoever can change that file can choose the image
  and its hash together; the SHA256 check now proves only that the download matches
  the manifest.
- Runs are not reproducible over time: machines provisioned weeks apart can get
  different PowerShell, chezmoi and Ubuntu point releases. Verify checks behaviour,
  not versions.
- A later PowerShell can change behaviour the modules rely on; `#Requires -Version 7.6`
  is a floor, not a ceiling.
- winget's own review (ADR-002) still covers the PowerShell and chezmoi installers.

## ADR-017: Enable features with dism.exe

Status: accepted. Operator ruling W23, from a real-machine failure (Windows 11 Home,
PowerShell 7.7.0 MSIX, run elevated through the app alias).

`Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All
-NoRestart` failed with "Class not registered". The DISM PowerShell module activates a
COM class that is not registered for the packaged (MSIX) pwsh, so the cmdlet cannot
work in the shell this repository now installs (ADR-016). The elevated script itself
ran and the log mechanism worked; only the cmdlet failed.

`Enable-Features.ps1` now runs the native CLI, once per allowlisted name:
`%SystemRoot%\System32\dism.exe /online /enable-feature /featurename:<name> /all
/norestart`, with output captured by `Invoke-Dism`. Exit 0 is success, 3010 means a
restart is needed (the script still exits 3010 if any feature needed it), and anything
else writes a `[fail]` line with the exit code and dism's output to the elevated log
and exits 1, after the existing warning that an earlier feature still owes a restart.
It fails clearly if `SystemRoot` is empty or `dism.exe` is missing. The allowlist is
unchanged.

The repository invariant widens accordingly: `dism.exe` and the DISM cmdlets
(`Enable-`, `Disable-`, `Get-WindowsOptionalFeature`) may appear in code only under
`script/elevated`. State is still read through CIM (ADR-010).

Superseded by implementation: the spec and plan text that names
`Enable-WindowsOptionalFeature` (spec section 6.4 and plan task for `Enable-Features.ps1`)
describes the cmdlet; the implementation uses `dism.exe` as above.

## ADR-018: Install the WSL package through the elevated script

Status: accepted. Operator ruling W24, from a real-machine failure (Windows 11 Home,
PowerShell 7.7.0 MSIX, after ADR-017 enabled `VirtualMachinePlatform`).

The design assumed `wsl --install --no-distribution` elevates itself. Run from the
non-elevated runner it downloaded "Windows Subsystem for Linux 3.0.5", then failed at
"Installing" with "Catastrophic failure / The requested operation requires elevation."
and exit code 1. wsl.exe does not raise its own UAC prompt.

`Enable-Features.ps1` therefore takes `-InstallWsl`: after enabling the allowlisted
features it runs `%SystemRoot%\System32\wsl.exe --install --no-distribution`, then
`--update` (absolute path, output shown in the elevated window and captured). Exit 0 is
success, 3010 a restart, anything else a `[fail]` line with wsl's output in the elevated
log and exit 1; a failed feature skips the WSL step. The features stage makes one
elevated call for both, so a first run raises one UAC prompt from this repository. Its
`-Name` may be empty only with `-InstallWsl`. The repository still elevates only
through `script/elevated/` (ADR-004), and still installs the latest WSL (ADR-016).

The same failure exposed a lost restart: features were enabled (exit 3010) but the
stage failed afterwards, so `reboot-required` was never recorded. The features stage
now also returns `reboot-required` when the Component Based Servicing `RebootPending`
key exists (readable without elevation), so the WSL stage never runs on a platform
whose features are still pending.

Superseded by implementation: the spec and plan text that says wsl.exe raises its own
UAC prompt.

## ADR-019: Milestone 1 accepted on real hardware

Status: accepted, 2026-11-26. Results item by item are in `docs/OPERATIONS.md`,
"Milestone 1 acceptance".

Machine: Minisforum MS-02 Ultra (Intel Core Ultra 9 285HX, Intel graphics), Windows 11
Home (`Core`) build 26300, unactivated, with a `D:` drive. From a fresh install,
`bootstrap.ps1` reached a verified Ubuntu 26.04 `dev` distro with setup-dev-linux-wsl
applied, and `script\verify.ps1` passed all 6 checks.

Defects the runs found, each fixed before acceptance: winget `0x80070005` on a fresh
source (stage-0 runs `winget source update` first); "Class not registered" from the
DISM cmdlets in the MSIX pwsh (ADR-017); `wsl --install` needing elevation and a lost
restart after a failed run (ADR-018); PowerShell 7.5+ expanding a leading `~` in a
native argument to the Windows profile, which broke the Linux verify call (it now passes
`$HOME`, and a repository test refuses string literals that start with `~`); and, on the
Linux side, the `/mnt` check flagging this repository's own checkout (its ADR-012) and
the login shell left as bash (documented as an operator step in both repositories).

Facts settled: the MSIX pwsh writes `state.json` to the real `%LOCALAPPDATA%`, not the
package's `LocalCache`; the Lxss values `DistributionName`, `BasePath`, `Version` and
`DefaultUid` exist; `wsl --manage <distro> --set-default-user` exists in WSL 3.0.5;
`passwd -S` puts the status in the second field (`P` once set); `cloud-init status`
reports `disabled` after install because the user-data file is deleted; systemd runs.

An incident on the first attempt is recorded here because its cause is unknown. After
`VirtualMachinePlatform` was enabled and the elevated WSL install failed with
"Catastrophic failure", the first restart hung on a black screen with only the mouse
pointer; Ctrl+Alt+Del did not respond. The operator restored the system, updated the
BIOS and reinstalled Windows. On the fresh install the hypervisor runs
(`VirtualizationBasedSecurityStatus` 2) and every later restart was normal, so the
hypervisor on this hardware is not the cause in general; an early BIOS combined with the
half-finished WSL install is the leading suspect. The recovery path (WinRE Command
Prompt, `bcdedit /set {default} hypervisorlaunchtype off`) is in the operator's
bring-up notes; a preflight warning before enabling the feature is a possible later
hardening, not a requirement.

Checked only by CI and unit tests, listed in `TASKS.md` for the next fresh machine:
the `-DistroRoot` hand-over without `D:`, the elevated-launch refusals, the forced
elevated-log line, `cloud-init status --wait` exit codes and the non-enabled
`InstallState` values.

## ADR-020: Apps through a winget install loop, not winget configure

Status: accepted, 2026-11-26. Supersedes spec 6.5's "WinGet Configuration v3",
`winget configure test`, exact versions for PowerShell and Git (ADR-016) and
`securityContext: elevated`.

The apps stage installs the packages of the selected profiles with a plain loop over
`winget list` and `winget install` (`script/stages/AppsStage.psm1`, catalogue in
`profiles/apps.psd1`). `winget configure` was rejected for four reasons. It needs a DSC
processor, and DSC v3 is the separate `Microsoft.DSC` package: one more dependency to
install and trust before any app. It runs units declaratively and possibly in parallel
and leaves the results to be checked afterwards, whereas the loop knows per package
which outcome happened and names the package Id with a clear message per known return
code, plus winget's own text for anything else. A loop
adopts what is already there (below) with a mockable exit-code check. And stage-0 and
chezmoi already install through the same `winget install` calls, so there is one
mechanism, not two.

Kept from the spec: declared profiles, check-then-install, and verify with a drift
report. Detection uses the exit code of `winget list --id <id> --exact`, never the
printed table, which truncates long Ids and is localised. Installs carry no
`--version` (ADR-016) and no `--scope` unless a catalogue entry sets `Scope`; browsers
never do, so an app the operator installed by hand is adopted, not duplicated. When
`winget list` does not correlate such an app, the install is attempted and winget's
"already installed", "another version already installed" or "no applicable update"
return codes count as success (adopted). A failing package does not stop the others:
the stage returns `failed` naming each Id and reason, and the re-run installs only what
is still missing. Installers that need admin raise their own UAC prompt through winget;
the stage never elevates (ADR-004).

The catalogue Ids were confirmed present in microsoft/winget-pkgs on 2026-11-26 (the
catalogue holds 21; the font is separate).

## ADR-021: Nerd Font per user from the upstream release

Status: accepted, 2026-11-26. Supersedes spec 6.5's local font manifest and the
`LocalManifestFiles` setting it needed.

The winget package `DEVCOM.JetBrainsMonoNerdFont` is a third-party WiX MSI repack
(DevelopersCommunity/wix-JetBrainsMonoNF) at 3.3.0 with `ElevationRequirement:
elevatesSelf`, while upstream ryanoasis/nerd-fonts is at v3.5.1 (published 2026-08-21).
A local manifest would need the administrator-only `LocalManifestFiles` winget setting
and a pinned version, against ADR-016. So `script/lib/Font.psm1` installs the font
itself: the newest upstream release's `JetBrainsMono.zip`, verified against the SHA256
in the release asset's `digest` field (a missing or malformed digest fails closed), from
`github.com` or GitHub's asset hosts only, and only the `JetBrainsMonoNerdFontMono-*.ttf`
files, by leaf name, into the per-user fonts directory with HKCU registration. No
elevation, no web call when the font is already installed. The font belongs to `core`
and runs after the packages. This is the one place the repository downloads a
non-winget artefact besides the Ubuntu image; it is hash-verified and never executed
(ADR-003). The digest and the download URL come from the same GitHub API response, so
the hash guards against corruption and transport or CDN tampering, not against a
compromised upstream release (unlike the Ubuntu image, whose hash comes from
Microsoft's separate manifest). The family name registered is `JetBrainsMono Nerd Font
Mono`.

## ADR-022: Profiles and the apps stage

Status: accepted, 2026-11-26.

Eight profiles, in catalogue order: `core`, `dev`, `security`, `productivity`, `backup`,
`productivity-extra`, `local-llm`, `lab` (no packages; Hyper-V only, Pro only). The
default set is `core,dev,security,productivity`; `core` is always included. `backup`
(restic, rclone) is opt-in by operator decision, not part of the default. The default
set is capped at 40 entries (9 packages today: core 4, dev 2, security 2, productivity 1, plus the font) so the baseline stays reviewable.
`productivity-extra` holds Chrome, Firefox, Slack, Claude, ChatGPT (Store source, ADR-023), OBS Studio, mpv.net,
Tailscale and OpenVPN. Firefox is the regular `Mozilla.Firefox`, not the Developer
Edition (operator decision). Hand-installed apps are adopted (ADR-020).

The apps stage runs on every setup run, like verify, so a profile added later installs;
the runner's rule that a stage recorded `done` is skipped exempts `apps` and `verify`.
It prints the profiles in use, and how to change them, as its first line. A `profiles`
value kept in `state.json` by an earlier run wins over the new default (flag, then kept
value, then default, ADR-015), so a machine that persisted `core` in milestone 1 gets
only `core` until the operator passes `-Profiles core,dev,security,productivity`.
Installer UAC prompts come from the installers themselves (OPERATIONS).

A failed `apps` stage does not stop the run (controller ruling, 2026-11-26): the runner
records `apps` as failed, warns, runs the remaining stages and ends with exit 1 (a later
reboot-required still returns 3010 at once). One package that cannot install must not
block dotfiles, WSL and verify, and `-Stage apps` retries it. Every other stage keeps
stop-on-failure, because their successors depend on them. The first line shows the
profiles in use, the default and the available profiles.

## ADR-023: Microsoft Store source for MSIX packages that declare services

Status: accepted, 2026-11-26, from the first W3 run on real hardware.

`OpenAI.ChatGPT` from the winget community source is an MSIX package that declares
packaged services. Deploying such a package needs administrator rights, and the apps
stage never elevates (ADR-004), so the install failed with `0x80073d28` ("administrator
privileges are required"). The same app from the Microsoft Store source,
`winget install --id 9PLM9XGG6VKS --source msstore`, installed from the same non-elevated
terminal with no UAC prompt and exit 0: the Store's install service performs the
deployment.

A catalogue entry may therefore set `Source = 'msstore'`, with the Store product Id
(12 upper-case letters and digits) as its `Id`. `Test-WingetPackage` and
`Install-WingetPackage` take `-Source winget|msstore` (default winget), and the apps
stage and verify pass the entry's source. Only ChatGPT uses it today. A Store entry also
sets `WingetId`, the community-source id `winget export` lists the installed app under
(`OpenAI.ChatGPT`), so the drift line counts it as declared; the second hardware run
showed that name in the drift line until this was added. The winget
community source stays the default: it carries the installer hash in its manifest,
while a Store install is validated by the Store. The drift line reads `winget export
--source winget` only, so Store apps never appear in it.

The first run also tuned the drift allowlist with what a Windows 11 Home machine ships:
`Microsoft.365Copilot`, `Microsoft.Outlook`, `Microsoft.Teams`, and `Nvidia.PhysX` from
the OEM driver bundle.
