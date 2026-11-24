# Operations

Runbook. Sections for installation, update, verification and recovery are added as the
commands they describe are built; none exists yet.

## Running the gate

```powershell
pwsh -File script/test.ps1 -RequireLinters
```

Without pwsh on the machine, run it in a throwaway PowerShell container that installs
the versions in `tests/tool-versions.psd1` inside the container only. CI on
`windows-2025` is authoritative; Windows-only behaviour is otherwise proven by mocks.

## Line endings

`.gitattributes` is `* text=auto eol=lf`. A file that needs CRLF is declared per file.
