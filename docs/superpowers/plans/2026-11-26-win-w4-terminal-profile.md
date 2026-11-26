# W4: Windows Terminal, PowerShell Profile and VS Code Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows Terminal opens the `dev` distro by default in JetBrainsMono Nerd Font Mono with the Mac's terminal posture; PowerShell gets a repository-owned profile and its telemetry opt-out; VS Code gets a declared Windows-side extension list. VS Code and Zed settings files stay the operator's (Mac parity).

**Architecture:** `script/lib/TerminalSettings.psm1` merges only declared keys into Windows Terminal's `settings.json` (a pure merge function plus a read/backup/write wrapper) and is called by the dotfiles stage, which now runs on every setup pass. chezmoi owns one more file, the PowerShell profile. `vscode/extensions.list` declares Windows-side extensions, installed (missing only, latest) by the apps stage when `dev` is selected. Verify checks each.

**Tech Stack:** PowerShell 7.6+, chezmoi, Windows Terminal JSON settings, VS Code CLI, Pester 6.2.0, PSScriptAnalyzer 1.25.0.

**Spec:** `docs/superpowers/specs/2026-11-24-setup-dev-win-linux-design.md` (6.5 per-app hardening, 6.6 Terminal, phase W4), with operator decision of 2026-11-26: VS Code and Zed `settings.json` are the operator's, as on the Mac (`vscode/README.md` there: "The scripts do not edit settings.json — that file is yours"); their telemetry and update switches become documented manual steps.

## Global Constraints

- Branch `milestone-3-w4` from `main`. Commit per task with trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.
- Gate after every task: `docker run --rm -v "$PWD":/src -w /src setup-dev-win-test:local pwsh -NoLogo -NoProfile -File script/test.ps1 -RequireLinters`.
- Module header in every module: `#Requires -Version 7.6`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, `$PSNativeCommandUseErrorActionPreference = $true`; native calls through `Invoke-Native`. ASCII only in `.ps1/.psm1/.psd1`; no string literal starts with `~`.
- Nothing here elevates; the dotfiles and apps stages run as the operator (HKCU, user profile files only).
- Never edit VS Code's or Zed's `settings.json`. Never uninstall a VS Code extension.
- Latest stable (ADR-016): extensions install with no version.
- Terminal settings file: `$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`. Merge only declared keys; every other key, profile, scheme, action and comment-free value survives. Before writing a changed file, copy it to `settings.json.backup.<UTC yyyyMMddTHHmmssZ>`. Skip (with an info line) when the `Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState` directory does not exist.
- Declared Terminal values, exactly:
  - top level: `defaultProfile` = `{6f9c1a52-3d4e-4b8a-9c17-2e5d8f0b7a31}`, `copyOnSelect` = `false`, `multiLinePasteWarning` = `true`, `largePasteWarning` = `true`, `confirmCloseAllTabs` = `true`.
  - `profiles.defaults`: `font.face` = `JetBrainsMono Nerd Font Mono`, `font.size` = `12`, `colorScheme` = `@{ dark = 'Catppuccin Mocha'; light = 'Catppuccin Latte' }`, `padding` = `8, 6`.
  - `profiles.list`: one profile with `guid` `{6f9c1a52-3d4e-4b8a-9c17-2e5d8f0b7a31}`, `name` `dev`, `commandline` `wsl.exe -d dev --cd ~`, `hidden` `false` (added when absent; its declared keys reset when present). Any other profile named `dev` whose `source` is `Windows.Terminal.Wsl` or `Microsoft.WSL` gets `hidden` = `true`.
  - `schemes`: `Catppuccin Mocha` and `Catppuccin Latte`, added or replaced by `name`, with the exact colours of the upstream catppuccin/windows-terminal port (fetch `mocha.json` and `latte.json` from github.com/catppuccin/windows-terminal with `gh api` and copy the values; record the commit used in a comment).
- PowerShell telemetry opt-out: user environment variable `POWERSHELL_TELEMETRY_OPTOUT` = `1` (HKCU), set with `[Environment]::SetEnvironmentVariable(..., 'User')` only when not already `1`.
- PowerShell profile target: `Documents\PowerShell\Microsoft.PowerShell_profile.ps1` under the user's home (preflight already refuses a redirected Documents folder); chezmoi source `chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`.
- Windows-side VS Code extensions, exactly (UI and remote clients; language extensions run in WSL and belong to the Linux repo): `ms-vscode-remote.remote-wsl`, `ms-vscode-remote.remote-ssh`, `ms-vscode-remote.remote-containers`, `vscode-icons-team.vscode-icons`.
- No machine names, usernames or personal paths in tracked files.

## Review Focus

1. Terminal `settings.json` that the Settings UI wrote with comments (`//`), or that does not exist yet (Terminal never launched): the merge parses comments (PowerShell 7 `ConvertFrom-Json` accepts them), starts from an empty object when the file is absent, and never throws away the operator's other profiles or keys. Tests in Task 1.
2. A second setup run after nothing changed: Terminal settings are not rewritten and no new backup appears (merge result compared to the current content first). Test in Task 1.
3. An existing hand-written PowerShell profile: it is backed up before chezmoi replaces it (generic backup of every chezmoi-managed target that differs). Test in Task 2.
4. VS Code installed per user or per machine, or its CLI not on this session's PATH right after install: the extension step finds `code.cmd` in both install locations and reports a clear skip when VS Code is absent. Test in Task 3.
5. The operator changes a declared Terminal key in the Settings UI: the next setup run restores it (dotfiles runs every pass) and says so; undeclared keys they change stay. Test in Task 1/2.

---

### Task 1: Terminal settings merge

**Files:**
- Create: `script/lib/TerminalSettings.psm1`, `tests/TerminalSettings.Tests.ps1`, `tests/fixtures/terminal/` (a commented settings.json from a fresh Terminal, one with an operator profile and a dynamic `dev` profile)

**Interfaces:**
- Produces: `Merge-TerminalSettings -Settings [hashtable]` -> [hashtable] (pure; input not mutated); `Get-TerminalSettingsPath` -> [string] (mockable); `Update-TerminalSettings` -> `updated` | `unchanged` | `skipped` (reads with `ConvertFrom-Json -AsHashtable`, merges, compares canonical JSON, backs up, writes UTF-8 without BOM with `ConvertTo-Json -Depth 32`); `Test-TerminalSettings` -> [string] ('' when the declared values are present, else a reason naming the first missing key).

- [ ] **Step 1: Write the failing tests:** every declared value from Global Constraints is present after a merge of `@{}`; an operator profile, an operator scheme, `actions` and an unknown top-level key survive unchanged; the dynamic `dev` profile (both sources) becomes `hidden = true`, other dynamic profiles untouched; merging twice equals merging once; the commented fixture parses and merges; `Update-TerminalSettings` returns `skipped` when the LocalState directory is absent, `updated` plus exactly one backup when content changes, `unchanged` and no backup on a second run; `Test-TerminalSettings` reports `defaultProfile` when it is wrong.
- [ ] **Step 2: Run the gate; expect failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the gate; expect pass.**
- [ ] **Step 5: Commit** `feat(terminal): merge the declared Windows Terminal settings`.

### Task 2: Dotfiles stage: Terminal, PowerShell profile, telemetry opt-out

**Files:**
- Create: `chezmoi/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`
- Modify: `script/stages/Dotfiles.psm1`, `script/lib/WslConfig.psm1` (`Invoke-ChezmoiApply` backup becomes generic), `script/lib/Runner.psm1` (dotfiles joins apps and verify in the every-pass set), `script/stages/Verify.psm1`, tests (`tests/Dotfiles*.Tests.ps1` or the existing file covering the stage, `tests/WslConfig.Tests.ps1`, `tests/Setup.Tests.ps1`, `tests/Verify.Tests.ps1`)

**Interfaces:**
- Consumes: `Update-TerminalSettings`, `Test-TerminalSettings`.
- Produces: verify checks named `Terminal settings` and `PowerShell telemetry opt-out`; the existing check `chezmoi verify (.wslconfig)` is renamed `chezmoi verify (dotfiles)`.

- [ ] **Step 1: Write the failing tests:**
  - the profile file is ASCII, sets `Set-PSReadLineOption -HistoryNoDuplicates`, `-MaximumHistoryCount 10000`, `-PredictionSource History` (guarded by `Get-Module -ListAvailable PSReadLine`), and defines `function dev { wsl.exe -d dev --cd ~ @args }`; it contains no secrets and no network calls.
  - `Invoke-ChezmoiApply` backs up every managed target that exists and whose content differs from `chezmoi cat` (use `chezmoi managed --include files --path-style absolute`), not only `.wslconfig`.
  - the stage sets `POWERSHELL_TELEMETRY_OPTOUT` to `1` for the user only when it is not already `1`, calls `Update-TerminalSettings` and prints `Windows Terminal settings updated.` / `... are up to date.` / `Windows Terminal is not set up for this user yet; skipped.`; a Terminal failure fails the stage with the reason.
  - runner: with `dotfiles` recorded `done`, a full run still invokes it.
  - verify: `Terminal settings` passes or fails from `Test-TerminalSettings` (skip-as-OK with a note when Terminal's LocalState is absent); `PowerShell telemetry opt-out` fails with `POWERSHELL_TELEMETRY_OPTOUT is not 1 for this user; run pwsh -File script\setup.ps1 -Stage dotfiles.`
  - plan mode lists the three actions and changes nothing.
- [ ] **Step 2: Run the gate; expect failure.**
- [ ] **Step 3: Implement.** The environment read/write goes through small mockable functions.
- [ ] **Step 4: Run the gate; expect pass.**
- [ ] **Step 5: Commit** `feat(dotfiles): Terminal settings, PowerShell profile and telemetry opt-out`.

### Task 3: VS Code Windows-side extensions

**Files:**
- Create: `vscode/extensions.list`, `script/lib/VSCode.psm1`, `tests/VSCode.Tests.ps1`
- Modify: `script/stages/AppsStage.psm1` (after the packages, when `dev` is selected), `script/stages/Verify.psm1` (`Apps` check also lists missing extensions), tests

**Interfaces:**
- Produces: `Get-VSCodeExtensionList` -> [string[]] (ids from the list file: one id per line, `#` comments and blank lines ignored, ids lower-cased for comparison); `Get-VSCodeCli` -> [string] or `$null` (`code.cmd` from PATH, else `$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd`, else `$env:ProgramFiles\Microsoft VS Code\bin\code.cmd`); `Install-VSCodeExtensions` -> @{ Installed = [string[]]; Failed = [string[]] } (only missing ones, `--install-extension <id>`, no version); `Get-MissingVSCodeExtensions` -> [string[]].

- [ ] **Step 1: Write the failing tests:** the list file holds exactly the four Global Constraints ids; parsing ignores comments, blank lines and case; CLI lookup order; with VS Code absent the apps stage prints `VS Code is not installed; skipping its extensions.` and does not fail; only missing extensions are installed; one failed extension is listed in the stage failures like a package (`<id> (<reason>)`) and the others still install; nothing ever calls `--uninstall-extension`; verify `Apps` names missing extensions as `VS Code extension <id>` (only when `dev` is selected and VS Code is installed).
- [ ] **Step 2: Run the gate; expect failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the gate; expect pass.**
- [ ] **Step 5: Commit** `feat(apps): declared Windows-side VS Code extensions`.

### Task 4: Decisions, manual settings and runbook

**Files:**
- Modify: `docs/DECISIONS.md` (ADR-024, ADR-025), `docs/OPERATIONS.md`, `docs/ARCHITECTURE.md`, `README.md`, `TASKS.md`, `AGENTS.md` (sources of truth: `vscode/extensions.list`, the Terminal merge module), the spec's "Superseded by implementation" addendum (one line)

- [ ] **Step 1: ADRs.** ADR-024 "Windows Terminal settings merged by the dotfiles stage": declared keys only, why PowerShell rather than a chezmoi `modify_` script (testable merge, chezmoi's `.ps1` modify-script target naming unverified, backups), Catppuccin Mocha/Latte and the font to match the Mac's Ghostty, `copyOnSelect` off and paste warnings on, the known loss of middle-click paste (microsoft/terminal#1553), the dynamic `dev` profile hidden, the dotfiles stage running every pass. ADR-025 "Editor settings are the operator's": Mac parity (operator decision 2026-11-26), what the repository does own (Windows-side extension list, latest, never uninstalls), PowerShell telemetry via the user environment variable.
- [ ] **Step 2: Runbook.** OPERATIONS: dotfiles stage text; a "Manual settings" section with the exact VS Code (`telemetry.telemetryLevel`: `off`, `update.mode`: `manual`) and Zed (`auto_update`: `false`, `telemetry.diagnostics`: `false`, `telemetry.metrics`: `false`) values and where to set them; a "W4 acceptance" checklist: Terminal opens `dev` by default in `JetBrainsMono Nerd Font Mono` with Catppuccin following the Windows theme; a multi-line paste warns; the operator's own profiles survive; a second run reports Terminal settings up to date with no new backup; a new pwsh session has `POWERSHELL_TELEMETRY_OPTOUT=1` and the `dev` function; VS Code lists the four extensions and `code .` from WSL opens a Remote-WSL window. README, ARCHITECTURE, TASKS (W4 done except acceptance; W5 next), AGENTS.
- [ ] **Step 3: Run the gate; expect pass.**
- [ ] **Step 4: Commit** `docs: W4 decisions, manual editor settings and runbook`.
