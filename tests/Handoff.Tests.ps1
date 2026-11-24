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
        $script.Contains('t=$(git rev-parse --verify --quiet "origin/$ref^{commit}" || git rev-parse --verify --quiet "$ref^{commit}") || { echo "unknown ref $ref" >&2; exit 1; }; git checkout --quiet --detach "$t";') | Should-BeTrue
        $script.Contains('2>/dev/null') | Should-BeFalse
        $script.Contains('existing clone points at $origin, expected $url') | Should-BeTrue
        # The configured url, not the insteadOf-rewritten one that remote get-url reports.
        $script.Contains('git -C "$dir" config --get remote.origin.url') | Should-BeTrue
        $script.Contains('get-url') | Should-BeFalse
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

# Runs the real bash program against a local bare repository. Linux only: it needs
# bash and git, and the CI windows job proves the PowerShell side. No network: a
# test-only global git config rewrites the https URL to the bare repository with
# url.<bare>.insteadOf, which is also what proves the origin check reads the
# configured url rather than the rewritten one.
Describe 'handoff program executed by bash' -Skip:(-not $IsLinux) {
    BeforeAll {
        $script:Program = & (Get-Module Handoff) { $script:HandoffScript }
        $script:Work = Join-Path $TestDrive 'exec'
        $script:FakeHome = Join-Path $script:Work 'home'
        $script:Bare = Join-Path $script:Work 'upstream.git'
        $script:Seed = Join-Path $script:Work 'seed'
        $script:Clone = Join-Path $script:FakeHome 'workspace/setup-dev-linux-wsl'
        $script:Ran = Join-Path $script:FakeHome 'ran'
        $null = New-Item -ItemType Directory -Path $script:FakeHome -Force

        $script:SavedEnv = @{}
        foreach ($name in 'HOME', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM') {
            $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:HOME = $script:FakeHome
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:Work 'gitconfig'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        Set-Content -LiteralPath $env:GIT_CONFIG_GLOBAL -Value @(
            '[user]', '    name = Test', '    email = test@example.invalid',
            '[init]', '    defaultBranch = main',
            "[url `"$script:Bare`"]", "    insteadOf = $script:Url"
        )

        function script:Invoke-Git {
            param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            # The gate sets this to $true; the exit code is checked here instead.
            $PSNativeCommandUseErrorActionPreference = $false
            $out = & git @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($out -join ' ')" }
        }
        function script:Add-UpstreamCommit {
            param([string]$Text)
            Set-Content -LiteralPath (Join-Path $script:Seed 'README') -Value $Text
            Invoke-Git -C $script:Seed commit --quiet -am $Text
            Invoke-Git -C $script:Seed push --quiet origin HEAD:main
            (& git -C $script:Seed rev-parse HEAD).Trim()
        }
        function script:Invoke-Program {
            param([string]$Ref = 'main', [string]$Url = $script:Url)
            $PSNativeCommandUseErrorActionPreference = $false
            $out = & bash -c $script:Program handoff $Url $Ref 2>&1
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = (@($out | ForEach-Object { "$_" }) -join "`n") }
        }

        Invoke-Git init --quiet --bare $script:Bare
        Invoke-Git clone --quiet $script:Bare $script:Seed
        # The stub stands in for ./bootstrap: it records the commit it ran at and its arguments.
        $stub = Join-Path $script:Seed 'bootstrap'
        Set-Content -LiteralPath $stub -Value "#!/bin/sh`necho `"`$(git rev-parse HEAD) `$*`" > `"`$HOME/ran`""
        & chmod +x $stub
        Set-Content -LiteralPath (Join-Path $script:Seed 'README') -Value 'first'
        Invoke-Git -C $script:Seed add bootstrap README
        Invoke-Git -C $script:Seed commit --quiet -m first
        Invoke-Git -C $script:Seed tag v1
        Invoke-Git -C $script:Seed push --quiet --tags origin HEAD:main
        $script:First = (& git -C $script:Seed rev-parse HEAD).Trim()
    }

    AfterAll {
        foreach ($name in $script:SavedEnv.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name])
        }
    }

    BeforeEach {
        Remove-Item -LiteralPath (Join-Path $script:FakeHome 'workspace') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Ran -Force -ErrorAction SilentlyContinue
    }

    It 'clones on first run and runs bootstrap at the upstream tip' {
        $tip = (& git -C $script:Seed rev-parse HEAD).Trim()
        $r = Invoke-Program
        $r.Code | Should-Be 0 -Because $r.Output
        (Get-Content -LiteralPath $script:Ran) | Should-Be "$tip apply --target wsl"
    }

    It 're-run after upstream advanced runs the new tip' {
        (Invoke-Program).Code | Should-Be 0
        $tip = Add-UpstreamCommit -Text 'second'
        Remove-Item -LiteralPath $script:Ran
        $r = Invoke-Program
        $r.Code | Should-Be 0 -Because $r.Output
        (Get-Content -LiteralPath $script:Ran) | Should-Be "$tip apply --target wsl"
    }

    It 'a tag resolves through the fallback' {
        $null = Add-UpstreamCommit -Text 'after-tag'
        $r = Invoke-Program -Ref 'v1'
        $r.Code | Should-Be 0 -Because $r.Output
        (Get-Content -LiteralPath $script:Ran) | Should-Be "$script:First apply --target wsl"
    }

    It 'fails loudly without running bootstrap when local changes conflict' {
        (Invoke-Program).Code | Should-Be 0
        Set-Content -LiteralPath (Join-Path $script:Clone 'README') -Value 'local edit'
        $null = Add-UpstreamCommit -Text 'upstream edit'
        Remove-Item -LiteralPath $script:Ran
        $r = Invoke-Program
        $r.Code | Should-NotBe 0
        $r.Output | Should-BeLikeString '*would be overwritten*'
        Test-Path -LiteralPath $script:Ran | Should-BeFalse
    }

    It 'exits 1 with "unknown ref" for a ref that does not exist' {
        $r = Invoke-Program -Ref 'no-such-ref'
        $r.Code | Should-Be 1
        $r.Output | Should-BeLikeString '*unknown ref no-such-ref*'
        Test-Path -LiteralPath $script:Ran | Should-BeFalse
    }

    It 'exits 1 when an existing clone points at another origin' {
        Invoke-Git clone --quiet $script:Bare $script:Clone
        Invoke-Git -C $script:Clone config remote.origin.url 'https://github.com/someone/else'
        $r = Invoke-Program
        $r.Code | Should-Be 1
        $r.Output | Should-BeLikeString '*existing clone points at https://github.com/someone/else, expected*'
        Test-Path -LiteralPath $script:Ran | Should-BeFalse
    }
}
