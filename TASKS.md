# Tasks

Unfinished work only. Phase names follow the spec (section 9); phase W0 (this
skeleton and the gate) and phases W1-W2 (milestone 1) and the W3 code are implemented. "Phase Wn" is a
spec phase, not a decision; decisions are the ADRs in `docs/DECISIONS.md`.

- [ ] Milestone 1 acceptance leftovers, checked only in CI so far: the `-DistroRoot`
      hand-over on a machine without `D:`, the elevated-launch refusals and the forced
      `-Name Bogus` log line on hardware, `cloud-init status --wait` exit codes, and
      the disabled/pending `InstallState` values. Run them on the next fresh machine.
- [ ] Phase W3 acceptance: the code, ADR-020 to ADR-022 and the runbook are done; run
      the "W3 acceptance" checklist in `docs/OPERATIONS.md` on a machine that already
      has Chrome and Firefox installed by hand.
- [ ] Phase W4: Windows-side chezmoi: Terminal (`modify_`), PowerShell profile, VS Code
      and Zed settings. Done when Terminal opens `dev` with the font and posture.
- [ ] Phase W5: Windows defaults, hardening apply and check, network exposure checks.
      Done when `hardening-check -Strict` passes.
- [ ] Phase W6: Hyper-V test harness and lab VM (Pro). Done when the full bootstrap
      passes in the VM.
- [ ] Phase W7 (both repositories): the LM Studio bridge, Windows-side Claude policy,
      backup and runbooks. Done when `docs/OPERATIONS.md` is complete.

## M1 hardening backlog

Deferred review findings from milestone 1, one line each; none blocks the milestone.

- [ ] Gate: fail on any PSScriptAnalyzer record that is not Information, so a ParseError is never filtered out (N1).
- [ ] Gate: Information-severity rules in the settings can never fail; comment or remove them (N2).
- [ ] Gate: the formatting check's TrimEnd ignores trailing-newline drift (N3).
- [ ] Invariants: `<# #>` help text counts as code lines (N4).
- [ ] Invariants: enforce `$PSNativeCommandUseErrorActionPreference = $true` in PowerShell 7 files (N5).
- [ ] Invariants: the package-manager scan covers only .ps1/.psm1; add .yaml and .psd1 (N6).
- [ ] `.gitignore`: the `testResults.xml` entry is unneeded (N7).
- [ ] Workflow invariants: scan all non-comment lines for `@(latest|main|master)`, not only `uses:` (N8).
- [ ] Workflow invariants: the checkout `with:` block scan can run into the next job (N9).
- [ ] Workflow invariants: the `@v\d` alternative is redundant (N10).
- [ ] Workflow: comment why the gate step runs a nested `pwsh -File` (N11).
- [ ] Anchor validation regexes with `\z` instead of `$` (N12, Task 3 name checks; N20, `ConvertTo-CommandLineArgument` `(\\+)$`).
- [ ] State: tolerate clock skew in the reboot comparison (N13).
- [ ] State: a non-object stage entry gives a raw error (N14).
- [ ] Use `New-Item -LiteralPath` (N15).
- [ ] Detect: the `Get-Volume` catch hides the cause (N16).
- [ ] Detect: Kernel DMA Protection `on` means available, not enforced; reword (N17).
- [ ] Tests: some mocks lack a ParameterFilter; UTC handling is not asserted (N18).
- [ ] wsl.exe parsing: `WSL_UTF8` versus `[Console]::OutputEncoding` decoding (N19).
- [ ] Tests: Bootstrap tests leak `$env:ProgramFiles` (N23).
- [ ] Runner: a `Set-StageResult` throw escapes the int contract and masks the stage error (N26).
- [ ] Tests: duplicate Write-Info/Write-Ok mocks in Setup.Tests (N27).
- [ ] Tests: `-Stage` records its result, noisy stage output, an elevated run reads no state (N28).
- [ ] Runner: "$null" return wording in comments (N29).
- [ ] Tests: `Should-NotInvoke Enable-WindowsOptionalFeature` is only a tripwire (N30).
- [ ] Tests: unknown edition (Enterprise) with and without lab (N31).
- [ ] Preflight: `D:/WSL` is rejected; say so in the message (N32).
- [ ] Runner: `Get-EditionInfo` is unguarded (N34).
- [ ] WindowsFeatures: check the WQL quote escaping (`''` versus `\'`) comment and test (N35).
- [ ] Tests: remove the leftover `Get-WindowsOptionalFeature` stub (N36).
- [ ] WslConfig: the `Request-WslRestart` catch is silent; log a line (N38).
- [ ] WslConfig: the backup timestamp has one-second resolution (N39).
- [ ] WslConfig: Test-Path then write race (N40).
- [ ] Distro: a `Get-FileHash` throw leaves `.partial` behind (self-healing) (N41).
- [ ] Tests: `.partial` cleanup when the download throws (N42).
- [ ] Distro: the reserved-name list lacks group names (sudo, adm, users, staff) and more Ubuntu system users (N43).
- [ ] Distro: a rethrow loses the ErrorRecord (N44).
- [ ] Distro: the `Get-LastResultLine` comment says Internal but it is exported (N47).
- [ ] Verify: check 6 output is buffered, not streamed (N48).
- [ ] `script/verify.ps1` does not refuse to run elevated (N49).
- [ ] `script/verify.ps1`: the `exit` wrapper itself is untested; `Invoke-VerifyCommand` is (N51).
- [ ] README step 3 is paraphrased (N52).
- [ ] chezmoi: pin `sourceDir` in the generated config and prefer the winget-installed binary over another chezmoi earlier on PATH (m11).
