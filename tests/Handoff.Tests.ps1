Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'script/lib/Handoff.psm1') -Force
    $script:Url = 'https://github.com/istvano/setup-dev-linux-wsl'
}

Describe 'Test-LinuxRepoUrl' {
    It 'accepts <_>' -ForEach @('https://github.com/o/setup-dev-linux-wsl', 'https://github.com/o/setup-dev-linux-wsl.git') {
        Test-LinuxRepoUrl -Url $_ | Should-BeTrue
    }
    It 'rejects <_>' -ForEach @('http://github.com/o/r', 'https://github.com/o/r;rm -rf ~', 'git@github.com:o/r.git',
        'https://evil.example/o/r', 'https://github.com/o/r"x', '', 'https://github.com/o/r/extra') {
        Test-LinuxRepoUrl -Url $_ | Should-BeFalse
    }
}

Describe 'Test-GitRef' {
    It 'accepts <_>' -ForEach @('main', 'v1.2.3', 'feature/x-y_z', 'a1b2c3d') {
        Test-GitRef -Ref $_ | Should-BeTrue
    }
    It 'rejects <_>' -ForEach @('--upload-pack=x', '-x', 'a b', '$(id)', 'a;b', "a'b", 'a"b', '', ('a' * 201)) {
        Test-GitRef -Ref $_ | Should-BeFalse
    }
}

Describe 'Invoke-LinuxHandoff' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Codes = [System.Collections.Generic.Queue[int]]::new()
        $script:Codes.Enqueue(0)
        Mock -ModuleName Handoff Write-Info { }
        Mock -ModuleName Handoff Write-Warn { }
        Mock -ModuleName Handoff Invoke-HandoffProcess { $script:Calls.Add($ArgumentLine); $script:Codes.Dequeue() }
        $script:Probes = [System.Collections.Generic.Queue[int]]::new()
        $script:Probes.Enqueue(0)
        Mock -ModuleName Handoff Invoke-Native {
            $isProbe = ($ArgumentList -join ' ') -like '*command -v git'
            [pscustomobject]@{ ExitCode = $(if ($isProbe) { $script:Probes.Dequeue() } else { 0 }); Output = @() }
        }
    }

    It 'passes url and ref only as trailing quoted arguments, never in the script text' {
        Invoke-LinuxHandoff -Url $script:Url -Ref 'v1.0' | Should-Be 0
        $line = $script:Calls[0]
        $line | Should-BeLikeString -Expected '-d dev --cd ~ -- bash -c ''*'' handoff "https://github.com/istvano/setup-dev-linux-wsl" "v1.0"'
        $script = $line.Substring($line.IndexOf("'") + 1, $line.LastIndexOf("'") - $line.IndexOf("'") - 1)
        $script.Contains($script:Url) | Should-BeFalse
        $script.Contains('v1.0') | Should-BeFalse
        $script.Contains("'") | Should-BeFalse
        $script | Should-BeLikeString -Expected 'set -Eeuo pipefail; url=$1; ref=$2; *exec ./bootstrap apply --target wsl'
        $script.Contains('exit 2') | Should-BeFalse
        $script.Contains('pull') | Should-BeFalse
        $script.Contains('command -v git >/dev/null || { echo "git missing" >&2; exit 1; }') | Should-BeTrue
        $script.Contains('git checkout --quiet --detach "origin/$ref" -- 2>/dev/null || git checkout --quiet --detach "$ref" --') | Should-BeTrue
        $script.Contains('existing clone points at $origin, expected $url') | Should-BeTrue
        $script.Contains('git remote get-url origin') | Should-BeTrue
    }

    It 'rejects an invalid url or ref before running anything' {
        { Invoke-LinuxHandoff -Url 'https://github.com/o/r;id' -Ref 'main' } | Should-Throw -ExceptionMessage '*url*'
        { Invoke-LinuxHandoff -Url $script:Url -Ref '--upload-pack=x' } | Should-Throw -ExceptionMessage '*ref*'
        Should-NotInvoke -CommandName Invoke-HandoffProcess -ModuleName Handoff
    }

    It 'returns a non-zero exit code without retrying' {
        $script:Codes.Clear(); $script:Codes.Enqueue(1)
        Invoke-LinuxHandoff -Url $script:Url -Ref 'main' | Should-Be 1
        $script:Calls.Count | Should-Be 1
    }

    It 'installs git as root when the probe finds none, probes again, then hands off once' {
        $script:Probes.Clear(); $script:Probes.Enqueue(1); $script:Probes.Enqueue(0)
        Invoke-LinuxHandoff -Url $script:Url -Ref 'main' | Should-Be 0
        $script:Calls.Count | Should-Be 1
        Should-Invoke -CommandName Invoke-Native -ModuleName Handoff -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'wsl.exe' -and ($ArgumentList -join ' ') -like '-d dev -u root -- sh -c *apt-get update*apt-get install -y git*' }
    }

    It 'fails without handing off when git is still missing after the install' {
        $script:Probes.Clear(); $script:Probes.Enqueue(1); $script:Probes.Enqueue(1)
        { Invoke-LinuxHandoff -Url $script:Url -Ref 'main' } | Should-Throw -ExceptionMessage '*still missing*'
        Should-NotInvoke -CommandName Invoke-HandoffProcess -ModuleName Handoff
    }

    It 'does not install git when the probe finds it' {
        Invoke-LinuxHandoff -Url $script:Url -Ref 'main' | Should-Be 0
        Should-NotInvoke -CommandName Invoke-Native -ModuleName Handoff -ParameterFilter { ($ArgumentList -join ' ') -like '*apt-get*' }
    }
}

Describe 'Invoke-HandoffProcess' {
    It 'attaches to the console and returns exactly one int; ArgumentList is the one string given' {
        $fake = [pscustomobject]@{ Handle = [IntPtr]::Zero; ExitCode = 7 }
        $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
        Mock -ModuleName Handoff Start-Process { 'stdout noise'; $fake }
        $line = '-d dev --cd ~ -- bash -c ''echo hi'' handoff "https://github.com/o/r" "main"'
        $r = & (Get-Module Handoff) { param($l) Invoke-HandoffProcess -ArgumentLine $l } $line
        @($r).Count | Should-Be 1
        $r | Should-Be 7
        Should-Invoke -CommandName Start-Process -ModuleName Handoff -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'wsl.exe' -and $ArgumentList -ceq $line -and $NoNewWindow -and $PassThru -and -not $Wait }
    }
}
