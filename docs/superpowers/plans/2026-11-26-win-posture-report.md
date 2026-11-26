# Windows Posture Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pwsh -File script\hardening-check.ps1` reads the machine's security and privacy settings and prints each value with a recommendation. It changes nothing.

**Architecture:** A declarative check table (`script/lib/PostureChecks.psm1`): each check has an id, a group, a mockable reader, the recommended value and a recommendation text (what to change and where, in the Settings app or one command). A small runner prints `OK`, `RECOMMEND`, `INFO` or `UNKNOWN` per check and a summary. Reads that need administrator rights report `UNKNOWN (needs an elevated terminal)` instead of elevating. No apply script in this phase (operator decision 2026-11-26: "skip hardening; check values and list recommendations").

**Tech Stack:** PowerShell 7.6+, CIM, registry reads, Defender and NetSecurity cmdlets, Pester 6.2.0.

**Spec:** `docs/superpowers/specs/2026-11-24-setup-dev-win-linux-design.md` 6.7 and 6.8, narrowed by the operator: report only, Windows 11 Home first (Pro-only policies are reported as such, not recommended).

## Global Constraints

- Branch `posture-report` from `main`. Commit per task with trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.
- Gate: `docker run --rm -v "$PWD":/src -w /src setup-dev-win-test:local pwsh -NoLogo -NoProfile -File script/test.ps1 -RequireLinters`.
- Read-only: no registry write, no `Set-*`, no `Enable-*`, no `netsh ... set/add`, no elevation. A repository test enforces it for the new files.
- Every reader is a small internal function so tests mock it; tests run on Linux.
- Exit code 0 always; with `-Strict`, exit 1 when any check is `RECOMMEND`. `UNKNOWN` never fails.
- Output line format exactly: `<STATUS> <group>: <title> = <value>` and, for RECOMMEND, an indented `     -> <recommendation>` line.
- ASCII only; module header as in the repository.

## Checks (exact set)

| Group | Check | Reader | Recommended | Recommendation when not |
|---|---|---|---|---|
| Platform | Secure Boot | `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State` `UEFISecureBootEnabled` | 1 | Turn on Secure Boot in the firmware setup. |
| Platform | TPM | `tpmtool getdeviceinformation` (TPM Present / Version) | present, 2.0 | Enable the TPM (fTPM/PTT) in the firmware setup. |
| Platform | Memory integrity (HVCI) | `Win32_DeviceGuard.SecurityServicesRunning` contains 2 | running | Settings > Privacy & security > Windows Security > Device security > Core isolation > Memory integrity (restart required; check drivers first). |
| Platform | Virtualization-based security | `Win32_DeviceGuard.VirtualizationBasedSecurityStatus` | 2 | report only |
| Platform | LSA protection | `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa` `RunAsPPL` | 1 or 2 | Core isolation > Local Security Authority protection, on (restart). |
| Platform | Kernel DMA protection | existing `Get-KernelDmaProtectionState` | on | report only |
| Platform | Smart App Control | `HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy` `VerifiedAndReputablePolicyState` (0 off, 1 on, 2 evaluation) | report | INFO only (cannot be turned back on without a reinstall). |
| Platform | Device encryption | `Get-BitLockerVolume -MountPoint $env:SystemDrive` (needs admin) | on | Settings > Privacy & security > Device encryption. |
| Defender | Running mode, real-time, behaviour monitoring, tamper protection | `Get-MpComputerStatus` (`AMRunningMode` Normal, `RealTimeProtectionEnabled`, `BehaviorMonitorEnabled`, `IsTamperProtected`) | Normal / true | Windows Security > Virus & threat protection settings. |
| Defender | Cloud protection | `Get-MpPreference` `MAPSReporting` (not 0) | not 0 | Virus & threat protection settings > Cloud-delivered protection, on. |
| Defender | Attack surface reduction rules | `Get-MpPreference` `AttackSurfaceReductionRules_Ids` | INFO (count; note "ASR is documented for Pro/Enterprise") | INFO only |
| UAC | UAC on | `HKLM:\...\Policies\System` `EnableLUA` | 1 | Never turn UAC off; restore with the UAC slider. |
| UAC | Secure desktop prompt | same key `PromptOnSecureDesktop` | 1 | Control Panel > User Accounts > Change User Account Control settings, default level. |
| Firewall | Profiles enabled, inbound blocked | `Get-NetFirewallProfile` (`Enabled` true, `DefaultInboundAction` Block or NotConfigured) | per profile | Windows Security > Firewall & network protection. |
| Firewall | WSL Hyper-V firewall inbound | `Get-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'` `DefaultInboundAction` | Block | `Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Block` (elevated). |
| Network | Port proxy | `netsh interface portproxy show all` | empty | Remove entries with `netsh interface portproxy delete` (elevated). |
| Network | WSL/Docker listeners | `Get-NetTCPConnection -State Listen` owned by `wslrelay`, `vmmem`, `vmmemWSL`, `docker-proxy`, `LM Studio` on a non-loopback address | none | Bind the service to 127.0.0.1; never mirrored mode or a LAN bind (ADR-006). |
| Legacy | SMBv1 | CIM `Win32_OptionalFeature` `SMB1Protocol` | not Enabled | `Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol` (elevated). |
| Legacy | PowerShell 2.0 engine | CIM `MicrosoftWindowsPowerShellV2Root` | not Enabled | disable the optional feature (elevated). |
| Legacy | Remote Assistance | `HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance` `fAllowToGetHelp` | 0 | System > Remote Desktop / sysdm.cpl > Remote, untick Remote Assistance. |
| Legacy | AutoPlay | `HKCU:\...\Explorer\AutoplayHandlers` `DisableAutoplay` | 1 | Settings > Bluetooth & devices > AutoPlay, off. |
| Privacy | Advertising ID | `HKCU:\...\AdvertisingInfo` `Enabled` | 0 | Settings > Privacy & security > General. |
| Privacy | Tailored experiences | `HKCU:\...\Privacy` `TailoredExperiencesWithDiagnosticDataEnabled` | 0 | Settings > Privacy & security > Diagnostics & feedback. |
| Privacy | Diagnostic data | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection` `AllowTelemetry` (absent = Settings value) | Required (1) | Diagnostics & feedback > Send optional diagnostic data, off. |
| Privacy | Activity history | `HKCU:\...\ActivityHistory`-equivalent (`PublishUserActivities` policy if set) | off | Settings > Privacy & security > Activity history. |
| Apps | Copilot apps | `Get-WingetInstalledIds` contains `Microsoft.Copilot` or `Microsoft.365Copilot` | INFO | INFO only (operator decides). |
| Apps | simplewall filtering | simplewall installed (`Test-WingetPackage Henry++.simplewall`) | INFO | "Installed; filtering is off until you enable it in simplewall." |
| Account | Daily account is an administrator | `Test-IsElevated`-independent group check (`S-1-5-32-544` membership of the current token's groups) | INFO | INFO (operator decision: daily account is admin). |

Exact registry paths not fully spelled out above (`...`) are the standard `HKCU:\Software\Microsoft\Windows\CurrentVersion\...` / `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\...` keys; the implementer writes them in full and cites Microsoft documentation in a comment per check. A reader that throws or lacks rights yields `UNKNOWN (<reason>)`.

## Review Focus

1. Run from a normal (non-elevated) terminal: admin-only reads (BitLocker, some Defender preferences) print `UNKNOWN (needs an elevated terminal)` and never throw or prompt. Test.
2. A cmdlet missing on the machine (NetSecurity or Defender module unavailable): that check is `UNKNOWN`, the rest still run. Test.
3. Tamper protection hiding Defender preferences: values that come back empty are `UNKNOWN`, never `RECOMMEND`. Test.
4. `-Strict` exit code: 1 only with at least one RECOMMEND. Test.
5. Nothing in the new files writes: a repository test greps them for `Set-`, `New-ItemProperty`, `Remove-`, `Enable-`, `Disable-` (outside recommendation strings), `netsh .* (add|set|delete)`, `Start-Process -Verb RunAs`.

---

### Task 1: Check table and runner

**Files:** Create `script/lib/PostureChecks.psm1`, `script/hardening-check.ps1`, `tests/PostureChecks.Tests.ps1`; modify `tests/Repo.Tests.ps1` (read-only rule).

**Interfaces:** `Get-PostureChecks` -> [hashtable[]] (Id, Group, Title, Read [scriptblock], Evaluate [scriptblock returning OK|RECOMMEND|INFO], Recommendation); `Invoke-PostureReport [-Strict]` -> [int] exit code.

- [ ] Step 1: failing tests for every check in the table (mock each reader: recommended value -> OK; other value -> RECOMMEND with the exact recommendation text; reader throws -> UNKNOWN), the output format, the summary line `Summary: <n> OK, <n> RECOMMEND, <n> INFO, <n> UNKNOWN`, and the five Review Focus items.
- [ ] Step 2: run the gate; expect failure.
- [ ] Step 3: implement.
- [ ] Step 4: run the gate; expect pass.
- [ ] Step 5: commit `feat(posture): read-only Windows security and privacy report`.

### Task 2: Runbook and decision

**Files:** Modify `docs/DECISIONS.md` (ADR-026 "Posture is reported, not applied, for now": operator decision, Home edition limits, what an apply phase would need), `docs/OPERATIONS.md` (how to run, how to read each status, a "Posture acceptance" item: run it on the test machine non-elevated and elevated and record the output), `README.md`, `TASKS.md` (W5 apply deferred, posture report done except acceptance), `AGENTS.md`.

- [ ] Step 1: write the docs (every check name and command must match the code).
- [ ] Step 2: run the gate; expect pass.
- [ ] Step 3: commit `docs: posture report decision and runbook`.
