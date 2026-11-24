# Operations

Runbook for milestone 1: from a fresh Windows 11 x64 machine to a working WSL2 distro
`dev`. State lives in `%LOCALAPPDATA%\setup-dev-win\state.json`. Exit codes of
`script\setup.ps1`: 0 done, 3010 reboot required, 1 failure.

## New machine

1. Sign in once; winget registers only after the first interactive login.
2. `winget install --id Git.Git -e --source winget`
3. `git clone` this repository to a path of your choice.
4. `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1` (Windows PowerShell 5.1,
   process-scope bypass only; `Set-ExecutionPolicy` is never called).

Stage-0 checks the OS, installs the pinned PowerShell 7 through winget and hands off to
`script\setup.ps1`, which runs `preflight`, `features`, `dotfiles`, `wsl` and `verify`.
Options: `-Profiles core,lab`, `-DistroRoot D:\WSL`, `-LinuxRef <ref>`, `-Plan` (show
what would change, change nothing), `-Stage <name>` (run one stage).

Things to expect:

- `features` enables `VirtualMachinePlatform` (and Hyper-V with `lab` on Pro) from one
  elevated pwsh: exactly one UAC prompt. Feature state is read through CIM without
  elevation. If a restart is needed the run exits 3010; see "After a reboot".
- `dotfiles` installs the pinned chezmoi and applies `.wslconfig` (sections `[wsl2]`,
  `[general]`, `[experimental]`). An existing, different `.wslconfig` is backed up to
  `.wslconfig.backup.<timestamp>` first. Run non-elevated.
- `wsl` downloads the pinned Ubuntu image, verifies its SHA256, installs it as `dev`
  under `<DistroRoot>\dev`, then hands off to `setup-dev-linux-wsl` inside it. The
  handoff is interactive: the Linux bootstrap asks for your git identity.
- `verify` always runs last and prints `OK <check>` or `FAIL <check>: <reason>`.

## After a reboot

When a run ends with `Reboot, then run script\setup.ps1 again.` (exit 3010), restart
Windows and run `script\setup.ps1` again. Nothing resumes automatically (ADR-005). The
runner skips stages recorded as done, resumes the one that asked for the reboot only
once the machine has actually rebooted since, and always re-runs `verify`.

## Verify

`pwsh -File script\verify.ps1 [-DistroRoot D:\WSL] [-Profiles core]` runs the same checks
as the verify stage with no state file; exit 0 when all pass, 1 otherwise. Every failure
is shown, not just the first.

1. Windows build is at least `MinOsBuild`; the edition is reported.
2. Required features are `Enabled`; Hyper-V is `Disabled` or `Absent` unless `lab`.
3. WSL version is at least `MinWslVersion`.
4. `chezmoi verify` reports no drift for `.wslconfig`.
5. Distro `dev` is registered, under the root, WSL 2, and starts as the configured user
   with uid >= 1000.
6. `~/workspace/setup-dev-linux-wsl/script/verify` exits 0 inside `dev` (its output is
   shown). If it says chezmoi is not initialised, the Linux bootstrap never completed:
   re-run `script\setup.ps1 -Stage wsl`.
7. Informational only: Kernel DMA Protection state and `systemctl is-system-running`
   in `dev` (`running` and `degraded` are normal).

## Re-provision dev

Back up, remove and rebuild the distro (this destroys its filesystem):

```powershell
wsl --export dev <root>\backup\dev.tar
wsl --unregister dev
script\setup.ps1 -Stage wsl
```

`<root>` is the distro root (default `D:\WSL`); create `<root>\backup` first. Restore
the backup instead with `wsl --import dev <root>\dev <root>\backup\dev.tar`.

## dev is on C:

`verify` (and the `wsl` stage) fail with `dev is at C:\..., not under D:\WSL`. Move the
distro, then re-run verify:

```powershell
wsl --shutdown
wsl --manage dev --move D:\WSL\dev
```

Use your own `-DistroRoot` in place of `D:\WSL`.

## winget not found

winget (App Installer) registers only after the first interactive sign-in. If stage-0
cannot find `winget.exe`, sign in once, wait a minute, or run:

```powershell
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
```

Then re-run `bootstrap.ps1`. Nothing downloads winget for you.

## Password / sudo

cloud-init creates the Linux user with a locked password, and `sudo` needs one. On every
run the `wsl` stage reads `passwd -S <user>` as root: status `L` (locked) or `NP` (none)
starts an interactive `passwd` (typed into passwd, never through this script); `P` skips
it. A non-interactive run only warns and prints the command to run later:
`wsl -d dev -u root -- passwd <user>`.

## Running the gate

```powershell
pwsh -File script/test.ps1 -RequireLinters
```

Without pwsh on the machine, run it in a throwaway PowerShell container that installs
the versions in `tests/tool-versions.psd1` inside the container only. CI on
`windows-2025` is authoritative; Windows-only behaviour is otherwise proven by mocks.

## Line endings

`.gitattributes` is `* text=auto eol=lf`. A file that needs CRLF is declared per file.
