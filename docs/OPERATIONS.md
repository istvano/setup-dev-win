# Operations

Runbook for milestone 1: from a fresh Windows 11 x64 machine to a working WSL2 distro
`dev`. State lives in `%LOCALAPPDATA%\setup-dev-win\state.json`. Exit codes of
`script\setup.ps1`: 0 done, 3010 reboot required, 1 failure.

With the MSIX PowerShell these files may be virtualised under `%LOCALAPPDATA%\Packages\Microsoft.PowerShell_8wekyb3d8bbwe\LocalCache\Local\setup-dev-win\`. To find where they landed: `Get-ChildItem $env:LOCALAPPDATA -Recurse -Filter state.json -ErrorAction SilentlyContinue | Select-Object FullName`. The same applies to
`elevated.log` (`-Filter elevated.log`).

## New machine

1. Sign in once; winget registers only after the first interactive login.
2. `winget install --id Git.Git -e --source winget`, then open a new terminal: the
   installer changes PATH for new processes only, so `git` is not found in the old one.
3. `git clone` this repository to a path of your choice.
4. `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1` from a normal (not
   elevated) terminal (Windows PowerShell 5.1, process-scope bypass only;
   `Set-ExecutionPolicy` is never called). An elevated launch is refused. On a machine
   without a `D:` drive, pick the distro root on this first run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -DistroRoot C:\WSL
   ```

Stage-0 checks the OS, runs `winget source update`, installs the latest stable
PowerShell 7 through winget when no pwsh 7.6 or later is present (ADR-016) and hands off
to `script\setup.ps1`, which runs `preflight`, `features`, `dotfiles`, `wsl` and
`verify`. `bootstrap.ps1` takes `-Profiles`, `-DistroRoot` and `-LinuxUser` and passes
each on only when given. `setup.ps1` options: `-Profiles core,lab`, `-DistroRoot D:\WSL`,
`-LinuxUser <name>`, `-LinuxRef <ref>`, `-Plan` (show what would change, change
nothing), `-Stage <name>` (run one stage). If preflight reports that the distro drive
was not found, re-run with `-DistroRoot <drive>:\WSL`.

`-Profiles`, `-DistroRoot` and `-LinuxUser` are remembered in `state.json` (ADR-015): a
flag you pass wins and is kept; a later run without it uses the kept value; the first
run without it uses the default (`core`, `D:\WSL`, and your Windows user name lowercased
with invalid characters removed, printed as `Linux user: <name>` before the distro is
installed). Pass the flag again to change a choice. `-Plan` changes nothing, including
the kept choices.

### UAC prompts

The repository elevates only through `script/elevated/` (ADR-004). Expect these
prompts on a first run, each from the source named:

| Prompt | Source |
|---|---|
| Git installer | README step 2 (`winget install Git.Git`), before this repository runs |
| PowerShell 7 | stage-0 installs the latest stable package, which is MSIX: a per-user install that normally raises no prompt (ADR-016) |
| Enable Windows features and install WSL | this repository: `script/elevated/Enable-Features.ps1`, one prompt for all missing features plus `wsl --install --no-distribution` and `wsl --update` when WSL is missing or too old (ADR-018) |

A re-run with everything in place raises none of them.

Things to expect:

- `features` enables `VirtualMachinePlatform` (and Hyper-V with `lab` on Pro) from one
  elevated pwsh: one UAC prompt from this repository. Feature state is read through
  CIM without elevation. The elevated window closes when it ends, so its `[warn]` and
  `[fail]` lines are also appended to `%LOCALAPPDATA%\setup-dev-win\elevated.log`, and
  the stage prints the new ones after a failure. If a restart is needed the run exits
  3010; see "After a reboot".
- `dotfiles` installs the latest stable chezmoi when none is present and applies
  `.wslconfig` (sections `[wsl2]`, `[general]`, `[experimental]`). An existing,
  different `.wslconfig` is backed up to `.wslconfig.backup.<timestamp>` first. Run
  non-elevated.
- `wsl` reads the newest `Ubuntu-26.04` image URL and SHA256 from Microsoft's
  `DistributionInfo.json` (it stops if that cannot be read), downloads the image to
  `<DistroRoot>\cache`, verifies its SHA256, installs it as `dev` under
  `<DistroRoot>\dev`, then hands off to `setup-dev-linux-wsl` inside it. The handoff
  is interactive: the Linux bootstrap asks for your git identity. The cached image is
  reused on a rebuild; delete `<DistroRoot>\cache` to free the space.
- `verify` always runs last and prints `OK <check>` or `FAIL <check>: <reason>`.

## After a reboot

When a run ends with `Reboot, then run pwsh -File script\setup.ps1 again ...` (exit
3010), restart Windows and run, from the repository root in a normal terminal:

```powershell
pwsh -File script\setup.ps1
```

`pwsh -File` matters: the default Windows shell is Windows PowerShell 5.1, which cannot
run `script\setup.ps1`. Re-running `powershell -ExecutionPolicy Bypass -File
.\bootstrap.ps1` also works; it skips the PowerShell install and hands off again.
Nothing resumes automatically (ADR-005). The runner skips stages recorded as done,
resumes the one that asked for the reboot only once the machine has actually rebooted
since, and always re-runs `verify`. The same command resumes after a failure.

## Verify

`pwsh -File script\verify.ps1 [-DistroRoot D:\WSL] [-Profiles core] [-LinuxUser <name>]`
runs the same checks as the verify stage without the runner; exit 0 when all pass, 1
otherwise. Without a flag it uses the choice `setup.ps1` kept in `state.json`, else the
default; it never writes. Every failure is shown, not just the first.

1. Windows build is at least `MinOsBuild`; the edition is reported.
2. Required features are `Enabled`; Hyper-V is `Disabled` or `Absent` unless `lab`.
3. WSL version is at least `MinWslVersion`.
4. `chezmoi verify` reports no drift for `.wslconfig`.
5. Distro `dev` is registered, under the root, WSL 2, and starts as the configured user
   with uid >= 1000.
6. `~/workspace/setup-dev-linux-wsl/script/verify` exits 0 inside `dev` (its output is
   shown). If it says chezmoi is not initialised, the Linux bootstrap never completed:
   re-run `pwsh -File script\setup.ps1 -Stage wsl`.
7. Informational only: Kernel DMA Protection state and `systemctl is-system-running`
   in `dev` (`running` and `degraded` are normal).

## Re-provision dev

Back up, remove and rebuild the distro (this destroys its filesystem):

```powershell
wsl --export dev <root>\backup\dev.tar
wsl --unregister dev
pwsh -File script\setup.ps1 -Stage wsl
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

## winget source errors (0x80070005)

Stage-0 runs `winget source update` before installing. If it or an install fails with
`0x80070005` (Access is denied) or `Failed to open the predefined source`, stage-0 stops
and prints these steps:

1. In an administrator terminal: `winget source reset --force`
2. In a normal terminal: `winget source update`
3. If it still fails, update App Installer from the Microsoft Store (Library > Get
   updates).

Then re-run `bootstrap.ps1`.

## Password / sudo

cloud-init creates the Linux user with a locked password, and `sudo` needs one. On every
run the `wsl` stage reads `passwd -S <user>` as root: status `L` (locked) or `NP` (none)
starts an interactive `passwd` (typed into passwd, never through this script); `P` skips
it. A non-interactive run only warns and prints the command to run later:
`wsl -d dev -u root -- passwd <user>`.

Be clear about what this password protects. WSL interop is on, so any process in the
distro can run `wsl.exe -u root` and become root without it: `sudo` inside WSL is not a
security boundary (spec 6.9, ADR-012). The password exists for parity with a normal
Linux machine and to stop accidents. Hostile work belongs in a Hyper-V VM.

## Wrong Linux user

If your Windows user name does not make a valid Linux name, the wsl stage stops and
asks for one: `pwsh -File script\setup.ps1 -LinuxUser <name>`. If `dev` already exists
with another user, the default-user check fails with `dev starts as '<x>', expected
'<y>'`; either pass `-LinuxUser <x>` or rebuild with `wsl --unregister dev`, then
`pwsh -File script\setup.ps1 -Stage wsl` (this destroys the distro's filesystem).

## Handoff failures

The `wsl` stage clones `setup-dev-linux-wsl` into `~/workspace/setup-dev-linux-wsl`
inside `dev` and runs its bootstrap at the requested ref (ADR-013). It never runs stale
or foreign code silently; instead it stops with one of these:

- `existing clone points at <url>, expected <url>`: the clone's `remote.origin.url` is
  another repository. Inspect it (`wsl -d dev -- git -C ~/workspace/setup-dev-linux-wsl
  remote -v`); if it is not yours, move it aside or delete it, then re-run
  `pwsh -File script\setup.ps1 -Stage wsl`. If it is a fork you mean to use, pass
  `-LinuxRepoUrl <its https URL>`.
- `unknown ref <ref>`: neither `origin/<ref>` nor a tag or commit `<ref>` exists after
  fetching. Check the spelling of `-LinuxRef` (default `main`).
- git's own `Your local changes ... would be overwritten by checkout`: you edited files
  in the clone. Commit, stash or discard them inside `dev`, then re-run.
- `git is still missing in dev after installing it`: `apt-get install git` as root
  failed; its output is above. Fix the distro's network or apt sources and re-run.

A non-zero exit from the Linux bootstrap itself is reported with its exit code; fix the
cause it printed and re-run `pwsh -File script\setup.ps1 -Stage wsl`.

## Milestone 1 acceptance

Task 13: the operator's run on the real machine (Windows 11 x64, build 26100 or later),
after CI is green. It answers what CI and mocks cannot. Record each answer (value, exit
code, message) next to the item, and update the matching `[verify on real machine]`
comment in the code where one exists.

Stage-0 and elevation:

- [ ] winget source health: `winget source update` succeeds before the install on a
      fresh machine; if `0x80070005` appears, the printed reset steps fix it.
- [ ] PowerShell: winget installs the MSIX package (7.7 or later) without a UAC prompt,
      and after the PATH refresh `pwsh.exe` resolves to the app execution alias
      `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`, which stage-0 hands off to.
- [ ] Version floor: an installed pwsh 7.6 or later (an existing MSI, for example) is
      kept with no install.
- [ ] Elevation under the MSIX pwsh: `[Environment]::ProcessPath` is under
      `C:\Program Files\WindowsApps\` (record it), and the features stage's elevated
      pwsh starts from the alias path and runs `Enable-Features.ps1`, which calls `dism.exe /online /enable-feature`
      (ADR-017); a failure shows dism's exit code in `elevated.log`.
- [ ] Re-run with the distro `dev` already registered: no manifest fetch and no download
      (the wsl stage prints no `Distro image:` line), and `<root>\cache` holds only the
      current `.wsl` after a fresh install.
- [ ] `-DistroRoot C:\WSL` given to `bootstrap.ps1` reaches `setup.ps1` and is kept in
      `state.json`; on a machine without `D:` and no flag, preflight names the
      `-DistroRoot` re-run.
- [ ] Each UAC prompt and its source, against the table in "UAC prompts".
- [ ] Stage-0 returns promptly once `setup.ps1` exits (no hang on wslhost or another
      long-lived child).
- [ ] An elevated launch of `bootstrap.ps1` and of `script\setup.ps1` is refused with
      `Run from a normal (non-elevated) terminal; elevation is requested per step.`
- [ ] Record where `state.json` and `elevated.log` actually land under the MSIX pwsh
      (`%LOCALAPPDATA%\setup-dev-win\` or the `Packages\Microsoft.PowerShell_8wekyb3d8bbwe\LocalCache\Local\setup-dev-win\` copy), with the find command above.
- [ ] `%LOCALAPPDATA%\setup-dev-win\elevated.log` gets a timestamped `[fail]` line on a
      forced failure: in an elevated terminal run
      `pwsh -File script\elevated\Enable-Features.ps1 -Name Bogus` (expect exit 2 and
      `[fail] Refusing feature 'Bogus'` in the log). Also note whether the features
      stage prints the new lines after a real failed run.

Windows features and WSL:

- [ ] `wsl --version` on the inbox stub (before WSL is installed) returns without
      waiting for a keypress.
- [ ] Exit codes of `wsl --install --no-distribution` and `wsl --update`, run elevated by
      `Enable-Features.ps1 -InstallWsl`, before the reboot (non-elevated, WSL 3.0.5's
      installer fails: "The requested operation requires elevation", ADR-018).
- [ ] After a run that enabled a feature but failed later, the re-run returns
      reboot-required (CBS `RebootPending` present) before the WSL stage.
- [ ] `Win32_OptionalFeature` `InstallState` read as a standard (non-elevated) user, for
      a feature that is enabled, one pending a restart and one disabled.
- [ ] `EditionID` strings for Home and Pro (`Core`, `Professional`).

The dev distro:

- [ ] The image URL resolved from `DistributionInfo.json` is printed, the file lands in
      `<DistroRoot>\cache` (not `%TEMP%`), and `wsl --install --from-file` reads it.
- [ ] Lxss registry value names: `DistributionName`, `BasePath`, `Version`, `DefaultUid`.
- [ ] Registry `DefaultUid` before and after `wsl --manage dev --set-default-user`, and
      whether that option exists in the installed WSL.
- [ ] `cloud-init status --wait` exit codes seen (0, 2).
- [ ] A duplicate `[boot]` section in `/etc/wsl.conf` is harmless (systemd still on).
- [ ] Whether Ubuntu's out-of-box experience appears on the first interactive
      `wsl -d dev`.
- [ ] `passwd -S <user>` output format (status in the second field: `L`, `NP`, `P`).
- [ ] git is present in the image before the handoff (or the probe installs it).
- [ ] `wsl -d dev --cd ~ -- bash -c '...' handoff <url> <ref>` passes the rest of the
      line to the user's shell intact: the handoff quoting holds.

Dotfiles and verify:

- [ ] `chezmoi verify` works without `--promptString` after the dotfiles stage's init.
- [ ] `pwsh -File script\verify.ps1` passes with no flags after setup (it reads the kept
      choices).

## Running the gate

```powershell
pwsh -File script/test.ps1 -RequireLinters
```

Without pwsh on the machine, run it in a throwaway PowerShell container that installs
the versions in `tests/tool-versions.psd1` inside the container only. CI on
`windows-2025` is authoritative; Windows-only behaviour is otherwise proven by mocks.

## Line endings

`.gitattributes` is `* text=auto eol=lf`. A file that needs CRLF is declared per file.
