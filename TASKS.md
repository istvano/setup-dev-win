# Tasks

Unfinished work only. Phase names follow the spec (section 9), where W0 (this
skeleton and the gate) is done.

- [ ] W3: app profiles (`profiles/*.winget.yaml`), the font manifest, `verify` and a
      drift report. Done when `winget configure test` is clean and drift is reported.
- [ ] W4: Windows-side chezmoi: Terminal (`modify_`), PowerShell profile, VS Code and
      Zed settings. Done when Terminal opens `dev` with the font and posture.
- [ ] W5: Windows defaults, hardening apply and check, network exposure checks. Done
      when `hardening-check -Strict` passes.
- [ ] W6: Hyper-V test harness and lab VM (Pro). Done when the full bootstrap passes
      in the VM.
- [ ] W7 (both repositories): the LM Studio bridge, Windows-side Claude policy,
      backup and runbooks. Done when `docs/OPERATIONS.md` is complete.
