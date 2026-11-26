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
to `script\setup.ps1`, which runs `preflight`, `features`, `apps`, `dotfiles`, `wsl`
and `verify`; `apps`, `dotfiles` and `verify` run on every pass, the others only until
recorded `done`. `bootstrap.ps1` takes `-Profiles`, `-DistroRoot` and `-LinuxUser` and passes
each on only when given. `setup.ps1` options: `-Profiles core,dev,lab`, `-DistroRoot D:\WSL`,
`-LinuxUser <name>`, `-LinuxRef <ref>`, `-Plan` (show what would change, change
nothing), `-Stage <name>` (run one stage). If preflight reports that the distro drive
was not found, re-run with `-DistroRoot <drive>:\WSL`.

`-Profiles`, `-DistroRoot` and `-LinuxUser` are remembered in `state.json` (ADR-015): a
flag you pass wins and is kept; a later run without it uses the kept value; the first
run without it uses the default (`core,dev,security,productivity`, `D:\WSL`, and your Windows user name lowercased
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
| App installers that need admin | winget, per package (the apps stage never elevates); a declined prompt fails only that app; the run continues (ADR-022) |

A re-run with everything in place raises none of them.

Things to expect:

- `features` enables `VirtualMachinePlatform` (and Hyper-V with `lab` on Pro) from one
  elevated pwsh: one UAC prompt from this repository. Feature state is read through
  CIM without elevation. The elevated window closes when it ends, so its `[warn]` and
  `[fail]` lines are also appended to `%LOCALAPPDATA%\setup-dev-win\elevated.log`, and
  the stage prints the new ones after a failure. If a restart is needed the run exits
  3010; see "After a reboot".
- `apps` prints `Profiles: ...` first, then installs what is missing with winget and
  the `JetBrainsMono Nerd Font Mono` font (per user, SHA256-verified, no prompt). It runs on every
  setup run, so a profile added later installs. An app already installed by hand is
  adopted, never duplicated. With `dev` selected it then installs the Windows-side VS Code
  extensions in `vscode/extensions.list` that are missing (latest version, never
  uninstalled; a skip when VS Code is absent). One failed package does not stop the other packages: the
  stage fails naming each Id and reason. A failed `apps` stage does not stop the run
  either: it is recorded failed, `dotfiles`, `wsl` and `verify` still run, and the run
  exits 1 (or 3010 if a later stage needs a restart). Every other stage still stops the
  run on failure. `pwsh -File script\setup.ps1 -Stage apps` retries only what is missing.
  The first line shows the profiles in use, the default and the available profiles.
- `dotfiles` installs the latest stable chezmoi when none is present and applies
  `.wslconfig` (sections `[wsl2]`, `[general]`, `[experimental]`) and the PowerShell
  profile. Any existing, different managed file is backed up to
  `<file>.backup.<timestamp>` first. It sets `POWERSHELL_TELEMETRY_OPTOUT=1` for the user
  when it is not already, and merges the declared Windows Terminal settings (ADR-024;
  `settings.json.backup.<UTC timestamp>` before a change, nothing written when it is
  already current, a skip when Terminal has never launched). It runs on every setup run,
  so a declared Terminal setting changed in its UI is restored. A Terminal settings
  failure (unparseable `settings.json`, file locked) is a warning, not a stage failure,
  so `wsl` still runs; `verify` keeps reporting it. On a first install Terminal generates
  its own `dev` profile only after the `wsl` stage, so the second setup run is the one
  that hides it; until the distro exists, a new Terminal window opening `dev` shows an
  error. Run non-elevated.
- `wsl` reads the newest `Ubuntu-26.04` image URL and SHA256 from Microsoft's
  `DistributionInfo.json` (it stops if that cannot be read), downloads the image to
  `<DistroRoot>\cache`, verifies its SHA256, installs it as `dev` under
  `<DistroRoot>\dev`, then hands off to `setup-dev-linux-wsl` inside it. The handoff
  is interactive: the Linux bootstrap asks for your git identity. The cached image is
  reused on a rebuild; delete `<DistroRoot>\cache` to free the space.
- `verify` always runs last and prints `OK <check>` or `FAIL <check>: <reason>`.

### Profiles

`-Profiles` takes a comma-separated list; `core` is always included. The default is
`core,dev,security,productivity` (ADR-022).

| Profile | Default | Packages (winget Id) |
|---|---|---|
| core | yes | `Microsoft.WindowsTerminal`, `Microsoft.PowerShell`, `Git.Git`, `twpayne.chezmoi`, plus the font |
| dev | yes | `Microsoft.VisualStudioCode`, `ZedIndustries.Zed` |
| security | yes | `Bitwarden.Bitwarden`, `Henry++.simplewall` |
| productivity | yes | `Obsidian.Obsidian` |
| backup | no | `restic.restic`, `Rclone.Rclone` |
| productivity-extra | no | `Google.Chrome`, `Mozilla.Firefox`, `SlackTechnologies.Slack`, `Anthropic.Claude`, ChatGPT `9PLM9XGG6VKS` (Microsoft Store source, ADR-023), `OBSProject.OBSStudio`, `mpv.net`, `Tailscale.Tailscale`, `OpenVPNTechnologies.OpenVPN` |
| local-llm | no | `ElementLabs.LMStudio` |
| lab | no | none (Hyper-V, Pro only) |

To opt in to everything:

```powershell
pwsh -File script\setup.ps1 -Profiles core,dev,security,productivity,productivity-extra,local-llm
```

A machine whose `state.json` already holds `profiles` (for example `core` from
milestone 1) keeps it: the apps stage prints the profiles in use and how to change them.
Pass `-Profiles core,dev,security,productivity` once to adopt the new default. Nothing
is ever uninstalled; `verify` lists installed apps that no profile declares as drift.

### After the first successful run: two steps inside WSL

Neither repository changes your login shell or uploads a key, so finish these once,
inside `wsl -d dev`:

1. **Make zsh your login shell:** `chsh -s /usr/bin/zsh` (it asks for your Linux
   password). Ubuntu starts you in bash, which the Linux repository does not
   configure: until you switch, `wsl -d dev` opens without Homebrew on `PATH` and
   `chezmoi`, `mise` and the rest are "command not found". Do not install the snap
   Ubuntu suggests; type `zsh` for the current session. For fish, use the lines the
   Linux bootstrap printed.
2. **Enrol the SSH key** it printed (`cat ~/.ssh/id_ed25519.pub`) at
   https://github.com/settings/ssh/new twice: once as an Authentication Key, once as a
   Signing Key.

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
4. `chezmoi verify` reports no drift for the chezmoi-managed files (`.wslconfig`, the
   PowerShell profile).
   `Terminal settings` and `PowerShell telemetry opt-out` follow check 4: Terminal carries the
   declared settings (a pass with a note before Terminal has ever launched), and
   `POWERSHELL_TELEMETRY_OPTOUT` is `1` for the user.
5. Distro `dev` is registered, under the root, WSL 2, and starts as the configured user
   with uid >= 1000.
   The `Apps` check runs after check 5 and before check 6: every package of the selected
   profiles is installed, and the font when `core` is selected; a failure names what is
   missing, including VS Code extensions from `vscode/extensions.list`, and the retry
   command (`pwsh -File script\setup.ps1 -Stage apps`).
6. `~/workspace/setup-dev-linux-wsl/script/verify` exits 0 inside `dev` (its output is
   shown). If it says chezmoi is not initialised, the Linux bootstrap never completed:
   re-run `pwsh -File script\setup.ps1 -Stage wsl`.
7. Informational only: Kernel DMA Protection state and `systemctl is-system-running`
   in `dev` (`running` and `degraded` are normal), and `apps not in any profile`: winget
   packages installed but declared in no profile, minus the Windows and winget
   infrastructure in `profiles/drift-allowlist.psd1`. Nothing is uninstalled.

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

Task 13: the operator's run on the real machine. **Accepted 2026-11-26** on a Minisforum
MS-02 Ultra (Intel Core Ultra 9 285HX), Windows 11 Home (`Core`) build 26300,
unactivated, fresh install, with a `D:` drive (default `-DistroRoot D:\WSL`). The full
bring-up finished with every stage done and `script\verify.ps1` passing all 6 checks
(exit 0). Results are recorded below and in ADR-019; `[x]` was observed on that
machine, `[ci]` is covered by CI and the unit tests but was not exercised on hardware.

Stage-0 and elevation:

- [x] winget source health: the first run failed with `0x80070005` ("Failed to open the
      predefined source"); `winget source update` first fixed it, and stage-0 now runs
      it and prints the reset steps on that failure.
- [x] PowerShell: winget installed the MSIX package 7.7.0 with no UAC prompt;
      `pwsh` resolves to `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`, the package
      lives in `C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe`.
- [ci] Version floor: an installed pwsh 7.6 or later is kept with no install.
- [x] Elevation under the MSIX pwsh: the elevated pwsh starts from the alias and runs
      `Enable-Features.ps1`. The DISM cmdlets failed there with "Class not
      registered"; `dism.exe` works (ADR-017). `wsl.exe --install --no-distribution`
      does not elevate itself ("The requested operation requires elevation"), so it
      moved into the elevated script (ADR-018).
- [x] Re-run with `dev` registered: no `Distro image:` line, every finished stage
      skipped.
- [ci] `-DistroRoot` given to `bootstrap.ps1` reaches `setup.ps1` and is kept. On the
      acceptance machine the default `D:\WSL` was used and kept in `state.json`.
- [x] UAC prompts: Git's installer, and one prompt from this repository for the
      elevated step. The PowerShell MSIX install raised none.
- [x] Stage-0 returns promptly once `setup.ps1` exits.
- [ci] An elevated launch of `bootstrap.ps1` and of `script\setup.ps1` is refused with
      `Run from a normal (non-elevated) terminal; elevation is requested per step.`
- [x] `state.json` lands in the real `%LOCALAPPDATA%\setup-dev-win\` under the MSIX
      pwsh; the `Packages\Microsoft.PowerShell_8wekyb3d8bbwe\LocalCache` copy stays
      empty.
- [x] `elevated.log` gets timestamped `[fail]` lines on a real failure, and the
      features stage printed them in the normal window (the "Class not registered" and
      wsl.exe failures). The forced `-Name Bogus` refusal is `[ci]`.

Windows features and WSL:

- [ci] `wsl --version` on the inbox stub returns without waiting for a keypress (the
      stage treated the stub as "found: none" and went on).
- [x] `wsl --install --no-distribution`: exit 1 non-elevated ("requires elevation");
      elevated, WSL 3.0.5 then also failed with "Catastrophic failure" before the
      restart owed by enabling `VirtualMachinePlatform`. After a fresh install with a
      newer BIOS, WSL 3.0.5.0 was present and current. See ADR-019 for the black screen
      that followed the first restart.
- [ci] After a run that enabled a feature but failed later, the re-run returns
      reboot-required (CBS `RebootPending`).
- [x] `Win32_OptionalFeature` `InstallState` read as a standard user: `1` for an
      enabled `VirtualMachinePlatform`. Disabled and pending states are `[ci]`.
- [x] `EditionID` for Home is `Core`. Pro (`Professional`) is `[ci]`.

The dev distro:

- [x] The image resolved from `DistributionInfo.json` was downloaded to
      `<DistroRoot>\cache`, verified and installed with `wsl --install --from-file`.
- [x] Lxss value names: `DistributionName`, `BasePath` (`D:\WSL\dev`), `Version` (2),
      `DefaultUid` (1000); also `Flags` (15).
- [x] `wsl --manage <distro> --set-default-user` exists in WSL 3.0.5; registry
      `DefaultUid` reads 1000 afterwards.
- [ci] `cloud-init status --wait` exit codes. After install `cloud-init status` reports
      `disabled`, expected once the user-data file is deleted.
- [x] systemd runs in `dev` (`systemctl is-system-running`: `running`).
- [x] `passwd -S <user>` prints the status in the second field: `<user> P <date> 0
      99999 7 -1` after the password was set.
- [x] git is in the image (2.53.0) before the handoff.
- [x] The handoff quoting holds: the Linux bootstrap ran from `wsl -d dev --cd ~ -- bash
      -c '...' handoff <url> <ref>` and completed.

Dotfiles and verify:

- [x] `script\verify.ps1` checks `.wslconfig` through chezmoi with the repository's
      source and passes after setup.
- [x] `pwsh -File script\verify.ps1` passes with no flags after setup (exit 0, 6 of 6),
      after the fix for PowerShell's `~` expansion in native arguments (ADR-019).

## W3 acceptance

To run on a machine where Chrome and Firefox were installed by hand. Mark each `[x]`
with the date when observed on hardware. First run: 2026-11-26 on the milestone-1
acceptance machine (Windows 11 Home), profiles
`core,dev,security,productivity,productivity-extra,local-llm`.

- [x] 2026-11-26: the default profiles and the opt-in extras installed with no elevated
      run; the only failure was ChatGPT from the winget source (see below).
- [ ] Chrome and Firefox installed by hand and a run with `productivity-extra` adopts
      them: no second copy. 2026-11-26: Firefox was reported `already installed`; Chrome
      was not matched by `winget list` and its installer ran (`Installed Google
      Chrome`). Check Settings > Apps for a second Chrome entry.
- [x] 2026-11-26: Windows Terminal (inbox) is reported already installed.
- [x] 2026-11-26: a failed app fails only that app: the stage named it, the run continued
      through `dotfiles`, `wsl` and `verify` and exited 1 (seen with ChatGPT rather than a
      declined UAC prompt). Still to see: a re-run of `-Stage apps` installs just that one.
- [x] 2026-11-26: `verify` printed `apps not in any profile (4): Microsoft.365Copilot,
      Microsoft.Outlook, Microsoft.Teams, Nvidia.PhysX`; all four are inbox or OEM and are
      now in `profiles/drift-allowlist.psd1`.
- [ ] Close every Windows Terminal window (sign out if it is still missing), then
      `JetBrainsMono Nerd Font Mono` is in Terminal's font list.
- [ ] An immediate second `pwsh -File script\setup.ps1` run reports every app already
      installed, installs nothing and raises no UAC prompt.
- [x] 2026-11-26: `Anthropic.Claude` installed from the non-elevated run.
      `OpenAI.ChatGPT` from the winget source failed with `0x80073d28` (administrator
      privileges required: the MSIX declares services); `winget install --id
      9PLM9XGG6VKS --source msstore` installed it with no UAC prompt and exit 0. The
      catalogue now uses the Store entry (ADR-023). Still to see: the next run reports
      ChatGPT `already installed` through `winget list --source msstore`.
- [ ] A machine with `profiles = core` kept from milestone 1 prints the profiles line and
      the `-Profiles` hint.

## Manual settings

The repository never edits the `settings.json` of VS Code or Zed (ADR-025). Set these
once; they are not verified.

VS Code (Command Palette, "Preferences: Open User Settings (JSON)"):

- `"telemetry.telemetryLevel": "off"`
- `"update.mode": "manual"` (winget updates it)

Zed (`zed: open settings`, the `settings.json` it opens):

- `"auto_update": false` (winget updates it)
- `"telemetry": { "diagnostics": false, "metrics": false }`

## W4 acceptance

To run after a full setup pass on a machine with `core,dev` selected. Mark each `[x]` with
the date when observed on hardware.

- [ ] Windows Terminal opens `dev` by default, in `JetBrainsMono Nerd Font Mono`, with
      Catppuccin Mocha or Latte following the Windows theme.
- [ ] `dev` from a new pwsh opens in the Linux home directory (`pwd` prints
      `/home/<user>`), not under `/mnt/c` (the quoted `'~'` of ADR-024).
- [ ] Terminal's profile dropdown shows exactly one `dev`.
- [ ] Pasting several lines into Terminal shows the multi-line paste warning.
- [ ] The operator's own Terminal profiles and other settings survive the run.
- [ ] A second `pwsh -File script\setup.ps1` run reports Windows Terminal settings up to
      date and leaves no new `settings.json.backup.*` file.
- [ ] Changing the font size in the Terminal Settings UI, then running setup again,
      restores 12 and names a backup file.
- [ ] A new pwsh session has `POWERSHELL_TELEMETRY_OPTOUT=1` and the `dev` function.
- [ ] `code --list-extensions` shows the four extensions of `vscode/extensions.list`, and
      `code .` run inside `dev`, from a Windows Terminal window opened after the apps
      stage installed VS Code, opens a VS Code window connected to WSL. This relies on
      WSL's default `appendWindowsPath`; the Linux repo's planned `~/.local/bin/code`
      wrapper will replace that.
- [ ] The VS Code and Zed values under "Manual settings" are set.

## Running the gate

```powershell
pwsh -File script/test.ps1 -RequireLinters
```

Without pwsh on the machine, run it in a throwaway PowerShell container that installs
the versions in `tests/tool-versions.psd1` inside the container only. CI on
`windows-2025` is authoritative; Windows-only behaviour is otherwise proven by mocks.

## Line endings

`.gitattributes` is `* text=auto eol=lf`. A file that needs CRLF is declared per file.
