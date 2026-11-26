Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Common.psm1') -Force
    # Dotfiles first: it re-imports WslConfig with -Force, which would otherwise
    # remove WslConfig's exports from this scope.
    Import-Module (Join-Path $script:Root 'script/stages/Dotfiles.psm1') -Force
    Import-Module (Join-Path $script:Root 'script/lib/WslConfig.psm1') -Force
    $script:Template = Join-Path $script:Root 'chezmoi/dot_wslconfig.tmpl'
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/chezmoi'

    # Renders the template with a fixture as chezmoi data. Returns the text with
    # LF line endings and the chezmoi exit code.
    function script:Invoke-Render {
        param([Parameter(Mandatory)][string]$Fixture)
        $PSNativeCommandUseErrorActionPreference = $false
        $text = Get-Content -LiteralPath $script:Template -Raw
        $out = $text | & chezmoi execute-template --config (Join-Path $script:Fixtures $Fixture) 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text = (($out | ForEach-Object { "$_" }) -join "`n") -replace "`r`n", "`n"
        }
    }
}

Describe 'dot_wslconfig.tmpl' {
    It 'renders the exact .wslconfig for the ms02 fixture' {
        $expected = @'
[wsl2]
# Half of host RAM, so the Windows side and the lab VMs keep the rest.
memory=47GB
# Logical processors minus 2, never below 2: the host stays responsive.
processors=22
# Fixed swap so a runaway build cannot grow the page file unbounded.
swap=16GB
# NAT, never mirrored: the Windows Firewall stays in the path.
networkingMode=nat
# Windows tools reach WSL services on localhost; nothing is exposed to the LAN.
localhostForwarding=true
# Apply Windows Firewall rules to WSL traffic.
firewall=true
# Do not send WSL diagnostics to Microsoft.
telemetry=false

[general]
# Distro VHDs live on the data volume, not the system drive.
distributionInstallPath=D:\\WSL

[experimental]
# Sparse VHDs return freed space to the host.
sparseVhd=true
# Hand idle page cache back to Windows gradually.
autoMemoryReclaim=gradual
'@ -replace "`r`n", "`n"
        $result = Invoke-Render -Fixture 'ms02.toml'
        $result.ExitCode | Should-Be 0
        $result.Text.TrimEnd() | Should-Be $expected.TrimEnd()
    }

    It 'places every key in the section Microsoft documents' {
        # https://learn.microsoft.com/en-us/windows/wsl/wsl-config: WSL ignores a misplaced key.
        $result = Invoke-Render -Fixture 'ms02.toml'
        $sections = @{}
        $current = $null
        foreach ($line in ($result.Text -split "`n")) {
            if ($line -match '^\[(\w+)\]\s*$') { $current = $Matches[1]; $sections[$current] = [System.Collections.Generic.List[string]]::new() }
            elseif ($line -match '^(\w+)=') { $sections[$current].Add($Matches[1]) }
        }
        @($sections.Keys | Sort-Object) | Should-BeCollection @('experimental', 'general', 'wsl2')
        @($sections['wsl2'] | Sort-Object) | Should-BeCollection @('firewall', 'localhostForwarding', 'memory', 'networkingMode', 'processors', 'swap', 'telemetry')
        @($sections['general']) | Should-BeCollection @('distributionInstallPath')
        @($sections['experimental'] | Sort-Object) | Should-BeCollection @('autoMemoryReclaim', 'sparseVhd')
    }

    It 'never lets processors fall below 2' {
        $result = Invoke-Render -Fixture 'tiny-cpu.toml'
        $result.ExitCode | Should-Be 0
        $result.Text | Should-BeLikeString '*processors=2*'
        $result.Text | Should-NotBeLikeString '*processors=0*'
    }

    It 'fails closed when host memory detection yielded less than 4 GB' {
        $result = Invoke-Render -Fixture 'no-memory.toml'
        $result.ExitCode | Should-NotBe 0
        $result.Text | Should-BeLikeString '*hostMemoryGB*'
    }

    It 'fails closed when the processor count is missing' {
        $result = Invoke-Render -Fixture 'no-cpu.toml'
        $result.ExitCode | Should-NotBe 0
        $result.Text | Should-BeLikeString '*NUMBER_OF_PROCESSORS*'
    }
}

Describe 'Install-Chezmoi' {
    BeforeEach {
        Mock -ModuleName WslConfig Write-Info {}
        Mock -ModuleName WslConfig Write-Ok {}
        Mock -ModuleName WslConfig Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = @('noise') } }
    }
    It 'skips winget when any chezmoi is present' {
        Mock -ModuleName WslConfig Get-ChezmoiPath { 'C:\Users\a\AppData\Local\Microsoft\WinGet\Links\chezmoi.exe' }
        Install-Chezmoi
        Should-NotInvoke -ModuleName WslConfig -CommandName Invoke-Native
    }
    It 'installs the latest stable twpayne.chezmoi at user scope, with no --version, when absent' {
        Mock -ModuleName WslConfig Get-ChezmoiPath { $null }
        Install-Chezmoi
        Should-Invoke -ModuleName WslConfig -CommandName Invoke-Native -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'winget.exe' -and
            ($ArgumentList -join ' ') -eq ('install --id twpayne.chezmoi --source winget --exact --scope user --silent ' +
                '--accept-package-agreements --accept-source-agreements --disable-interactivity')
        }
    }
    It 'says before the winget install that it can take a while' {
        Mock -ModuleName WslConfig Get-ChezmoiPath { $null }
        Install-Chezmoi
        Should-Invoke -ModuleName WslConfig -CommandName Write-Info -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'Installing the latest stable chezmoi with winget (this can take a minute)...' }
    }
    It 'returns nothing on the pipeline' {
        Mock -ModuleName WslConfig Get-ChezmoiPath { $null }
        @(Install-Chezmoi).Count | Should-Be 0
    }
}

Describe 'Invoke-ChezmoiApply' {
    BeforeEach {
        Mock -ModuleName WslConfig Write-Info {}
        Mock -ModuleName WslConfig Get-ChezmoiPath { 'chezmoi' }
        Mock -ModuleName WslConfig Invoke-Native {
            $output = switch ($ArgumentList[0]) {
                'cat' { @('rendered', 'content') }
                'managed' { @($script:Managed) }
                default { @('applied') }
            }
            [pscustomobject]@{ ExitCode = 0; Output = $output }
        }
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wslcfg-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:TmpDir
        $script:Cfg = Join-Path $script:TmpDir '.wslconfig'
        $cfg = $script:Cfg
        $script:Managed = @($cfg)
        Mock -ModuleName WslConfig Get-WslConfigPath { $cfg }.GetNewClosure()
    }
    AfterEach {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force
    }
    It 'reports Changed when the file hash differs' {
        $script:hashes = [System.Collections.Generic.Queue[string]]::new([string[]]@('', 'ABC'))
        Mock -ModuleName WslConfig Get-WslConfigHash { $script:hashes.Dequeue() }
        (Invoke-ChezmoiApply).Changed | Should-BeTrue
    }
    It 'reports unchanged when the hash is the same' {
        Mock -ModuleName WslConfig Get-WslConfigHash { 'SAME' }
        (Invoke-ChezmoiApply).Changed | Should-BeFalse
    }
    It 'applies the repo chezmoi source non-interactively and passes the distro root to the prompt' {
        Mock -ModuleName WslConfig Get-WslConfigHash { 'SAME' }
        $null = Invoke-ChezmoiApply -DistroRoot 'E:\WSL'
        Should-Invoke -ModuleName WslConfig -CommandName Invoke-Native -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'init' -and $ArgumentList -contains '--apply' -and
            $ArgumentList -contains '--force' -and $ArgumentList -contains '--no-tty' -and
            $ArgumentList[([array]::IndexOf($ArgumentList, '--source') + 1)] -like '*chezmoi' -and
            $ArgumentList -contains 'WSL distro root=E:\WSL'
        }
    }
    It 'backs up an existing .wslconfig that differs from what chezmoi would write' {
        Mock -ModuleName WslConfig Get-WslConfigHash { 'SAME' }
        Set-Content -LiteralPath $script:Cfg -Value 'kernelCommandLine=custom'
        $null = Invoke-ChezmoiApply
        $backups = @(Get-ChildItem -LiteralPath $script:TmpDir -Force -Filter '.wslconfig.backup.*')
        $backups.Count | Should-Be 1
        $backups[0].Name | Should-MatchString '^\.wslconfig\.backup\.\d{8}T\d{6}Z$'
        (Get-Content -LiteralPath $backups[0].FullName -Raw).Trim() | Should-Be 'kernelCommandLine=custom'
        Should-Invoke -ModuleName WslConfig -CommandName Write-Info -ParameterFilter { $Message -like '*backup*' }
    }
    It 'does not back up an identical .wslconfig' {
        Mock -ModuleName WslConfig Get-WslConfigHash { 'SAME' }
        Set-Content -LiteralPath $script:Cfg -Value @('rendered', 'content')
        $null = Invoke-ChezmoiApply
        @(Get-ChildItem -LiteralPath $script:TmpDir -Force -Filter '.wslconfig.backup.*').Count | Should-Be 0
    }
    It 'does not back up when there is no .wslconfig' {
        Mock -ModuleName WslConfig Get-WslConfigHash { '' }
        $null = Invoke-ChezmoiApply
        @(Get-ChildItem -LiteralPath $script:TmpDir -Force -Filter '.wslconfig.backup.*').Count | Should-Be 0
    }
}

Describe 'Invoke-ChezmoiApply generic backup' {
    BeforeEach {
        Mock -ModuleName WslConfig Write-Info {}
        Mock -ModuleName WslConfig Get-ChezmoiPath { 'chezmoi' }
        Mock -ModuleName WslConfig Get-WslConfigHash { 'SAME' }
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wslcfg-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:TmpDir
        $script:Cfg = Join-Path $script:TmpDir '.wslconfig'
        $script:Prof = Join-Path $script:TmpDir 'Microsoft.PowerShell_profile.ps1'
        $script:Gone = Join-Path $script:TmpDir 'absent.txt'
        $script:Managed = @($script:Cfg, $script:Prof, $script:Gone)
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName WslConfig Invoke-Native {
            $script:Calls.Add(($ArgumentList -join ' '))
            $output = switch ($ArgumentList[0]) {
                'cat' { @('wanted', 'content') }
                'managed' { @($script:Managed) }
                default { @('applied') }
            }
            [pscustomobject]@{ ExitCode = 0; Output = $output }
        }
        $cfg = $script:Cfg
        Mock -ModuleName WslConfig Get-WslConfigPath { $cfg }.GetNewClosure()
    }
    AfterEach { Remove-Item -LiteralPath $script:TmpDir -Recurse -Force }
    It 'asks chezmoi for every managed file as an absolute path, with the same source' {
        $null = Invoke-ChezmoiApply
        $managed = @($script:Calls | Where-Object { $_ -like 'managed *' })
        $managed.Count | Should-Be 1
        $managed[0] | Should-BeLikeString -Expected '*--include files*--path-style absolute*--source *chezmoi*'
    }
    It 'backs up a hand-written PowerShell profile that differs, before chezmoi replaces it' {
        Set-Content -LiteralPath $script:Prof -Value 'Set-Alias ll Get-ChildItem'
        $null = Invoke-ChezmoiApply
        $backups = @(Get-ChildItem -LiteralPath $script:TmpDir -Force -Filter 'Microsoft.PowerShell_profile.ps1.backup.*')
        $backups.Count | Should-Be 1
        $backups[0].Name | Should-MatchString '\.backup\.\d{8}T\d{6}Z$'
        (Get-Content -LiteralPath $backups[0].FullName -Raw).Trim() | Should-Be 'Set-Alias ll Get-ChildItem'
    }
    It 'does not back up a managed file that already matches, or one that does not exist' {
        Set-Content -LiteralPath $script:Prof -Value @('wanted', 'content')
        $null = Invoke-ChezmoiApply
        @(Get-ChildItem -LiteralPath $script:TmpDir -Force -Filter '*.backup.*').Count | Should-Be 0
    }
}

Describe 'Request-WslRestart' {
    BeforeEach {
        Mock -ModuleName WslConfig Write-Warn {}
        Mock -ModuleName WslConfig Write-Ok {}
        Mock -ModuleName WslConfig Invoke-Native {
            [pscustomobject]@{ ExitCode = 0; Output = $(if ($ArgumentList -contains '--running') { @('dev') } else { @() }) }
        }
    }
    It 'does not shut down WSL non-interactively' {
        Mock -ModuleName WslConfig Test-InteractiveSession { $false }
        Request-WslRestart -Changed $true
        Should-NotInvoke -ModuleName WslConfig -CommandName Invoke-Native -ParameterFilter { $ArgumentList -contains '--shutdown' }
        Should-Invoke -ModuleName WslConfig -CommandName Write-Warn -Times 1 -Exactly -ParameterFilter { $Message -eq 'Run wsl --shutdown to apply .wslconfig' }
    }
    It 'treats a failing or missing wsl as nothing running' {
        Mock -ModuleName WslConfig Invoke-Native { throw 'wsl.exe exited with code 4294967295' }
        Mock -ModuleName WslConfig Test-InteractiveSession { $true }
        $threw = $false
        try { Request-WslRestart -Changed $true } catch { $threw = $true }
        $threw | Should-BeFalse
        Should-NotInvoke -ModuleName WslConfig -CommandName Write-Warn
    }
    It 'does nothing when the file did not change' {
        Request-WslRestart -Changed $false
        Should-NotInvoke -ModuleName WslConfig -CommandName Invoke-Native
    }
    It 'does nothing when no distro is running' {
        Mock -ModuleName WslConfig Invoke-Native { [pscustomobject]@{ ExitCode = 0; Output = @('') } }
        Mock -ModuleName WslConfig Test-InteractiveSession { $true }
        Request-WslRestart -Changed $true
        Should-NotInvoke -ModuleName WslConfig -CommandName Invoke-Native -ParameterFilter { $ArgumentList -contains '--shutdown' }
        Should-NotInvoke -ModuleName WslConfig -CommandName Write-Warn
    }
    It 'shuts WSL down after an interactive yes' {
        Mock -ModuleName WslConfig Test-InteractiveSession { $true }
        Mock -ModuleName WslConfig Read-Host { 'y' }
        Request-WslRestart -Changed $true
        Should-Invoke -ModuleName WslConfig -CommandName Invoke-Native -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--shutdown' }
    }
    It 'leaves WSL running after an interactive no' {
        Mock -ModuleName WslConfig Test-InteractiveSession { $true }
        Mock -ModuleName WslConfig Read-Host { '' }
        Request-WslRestart -Changed $true
        Should-NotInvoke -ModuleName WslConfig -CommandName Invoke-Native -ParameterFilter { $ArgumentList -contains '--shutdown' }
    }
}

Describe 'Invoke-DotfilesStage' {
    BeforeEach {
        $script:ctx = @{ Profiles = @('core'); DistroRoot = 'D:\WSL'; LinuxRepoUrl = 'u'; LinuxRef = 'main'; Plan = $false; Edition = $null }
        Mock -ModuleName Dotfiles Write-Info {}
        Mock -ModuleName Dotfiles Write-Ok {}
        Mock -ModuleName Dotfiles Write-Warn {}
        Mock -ModuleName Dotfiles Test-IsElevated { $false }
        Mock -ModuleName Dotfiles Install-Chezmoi {}
        Mock -ModuleName Dotfiles Invoke-ChezmoiApply { @{ Changed = $true } }
        Mock -ModuleName Dotfiles Request-WslRestart {}
        $script:Optout = ''
        $script:Set = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Dotfiles Get-UserEnvironmentVariable { $script:Optout }
        Mock -ModuleName Dotfiles Set-UserEnvironmentVariable { $script:Set.Add("$Name=$Value") }
        $script:TermResult = 'updated'
        Mock -ModuleName Dotfiles Update-TerminalSettings { $script:TermResult }
    }
    It 'sets the telemetry opt-out for the user only when it is not already 1' {
        Invoke-DotfilesStage -Context $script:ctx | Should-Be 'done'
        $script:Set | Should-BeCollection @('POWERSHELL_TELEMETRY_OPTOUT=1')
        $script:Set.Clear()
        $script:Optout = '1'
        Invoke-DotfilesStage -Context $script:ctx | Should-Be 'done'
        $script:Set.Count | Should-Be 0
    }
    It 'reports each Terminal outcome' {
        foreach ($case in @(@('updated', 'Windows Terminal settings updated.'), @('unchanged', 'Windows Terminal settings are up to date.'))) {
            $script:TermResult = $case[0]
            Invoke-DotfilesStage -Context $script:ctx | Should-Be 'done'
            Should-Invoke -ModuleName Dotfiles -CommandName Write-Ok -ParameterFilter { $Message -eq $case[1] }
        }
        $script:TermResult = 'skipped'
        Invoke-DotfilesStage -Context $script:ctx | Should-Be 'done'
        Should-Invoke -ModuleName Dotfiles -CommandName Write-Info -ParameterFilter { $Message -eq 'Windows Terminal is not set up for this user yet; skipped.' }
    }
    It 'fails the stage with the reason when Terminal settings cannot be merged' {
        Mock -ModuleName Dotfiles Update-TerminalSettings { throw 'settings.json is not valid JSON' }
        Invoke-DotfilesStage -Context $script:ctx | Should-Be 'failed'
        Should-Invoke -ModuleName Dotfiles -CommandName Write-Warn -ParameterFilter { $Message -like '*settings.json is not valid JSON*' }
    }
    It 'plan mode lists the three actions and changes nothing' {
        Invoke-DotfilesStage -Context $script:ctx -Plan | Should-Be 'done'
        Should-Invoke -ModuleName Dotfiles -CommandName Write-Info -ParameterFilter { $Message -like '*chezmoi*' }
        Should-Invoke -ModuleName Dotfiles -CommandName Write-Info -ParameterFilter { $Message -like '*POWERSHELL_TELEMETRY_OPTOUT*' }
        Should-Invoke -ModuleName Dotfiles -CommandName Write-Info -ParameterFilter { $Message -like '*Windows Terminal*' }
        Should-NotInvoke -ModuleName Dotfiles -CommandName Set-UserEnvironmentVariable
        Should-NotInvoke -ModuleName Dotfiles -CommandName Update-TerminalSettings
    }
    It 'installs, applies, requests a restart and returns done' {
        Invoke-DotfilesStage -Context $script:ctx | Should-Be 'done'
        Should-Invoke -ModuleName Dotfiles -CommandName Install-Chezmoi -Times 1 -Exactly
        Should-Invoke -ModuleName Dotfiles -CommandName Invoke-ChezmoiApply -Times 1 -Exactly -ParameterFilter { $DistroRoot -eq 'D:\WSL' }
        Should-Invoke -ModuleName Dotfiles -CommandName Request-WslRestart -Times 1 -Exactly -ParameterFilter { $Changed -eq $true }
    }
    It 'refuses when elevated' {
        Mock -ModuleName Dotfiles Test-IsElevated { $true }
        Invoke-DotfilesStage -Context $script:ctx | Should-Be 'failed'
        Should-NotInvoke -ModuleName Dotfiles -CommandName Install-Chezmoi
    }
    It 'changes nothing under -Plan' {
        Invoke-DotfilesStage -Context $script:ctx -Plan | Should-Be 'done'
        Should-NotInvoke -ModuleName Dotfiles -CommandName Install-Chezmoi
        Should-NotInvoke -ModuleName Dotfiles -CommandName Invoke-ChezmoiApply
    }
    It 'returns failed when chezmoi apply throws' {
        Mock -ModuleName Dotfiles Invoke-ChezmoiApply { throw 'boom' }
        Invoke-DotfilesStage -Context $script:ctx | Should-Be 'failed'
        Should-NotInvoke -ModuleName Dotfiles -CommandName Request-WslRestart
    }
}
