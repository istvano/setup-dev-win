#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

# Windows Terminal settings.json: merge only the keys this repository declares.
# Everything else the operator has (profiles, schemes, actions, unknown keys)
# survives. The file is read with ConvertFrom-Json -AsHashtable, which accepts the
# // and /* */ comments the Settings UI writes; comments are lost on a rewrite, so
# a file whose declared values are already present is never rewritten.

$script:ProfileGuid = '{6f9c1a52-3d4e-4b8a-9c17-2e5d8f0b7a31}'
$script:LegacyWarningKeys = @('multiLinePasteWarning', 'largePasteWarning', 'confirmCloseAllTabs', 'warning.confirmCloseAllTabs')
$script:DynamicSources = @('Windows.Terminal.Wsl', 'Microsoft.WSL')

# The colour scheme is Windows Terminal's built-in 'Solarized Light' (defined in
# microsoft/terminal, src/cascadia/TerminalSettingsModel/defaults.json), so this
# repository declares no scheme of its own and merges no 'schemes' entry. Schemes
# already in the operator's file are left alone (ADR-028).

function Get-TerminalSettingsPath {
    # Internal, mockable. The stable Terminal's settings.json.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json')
}

function ConvertTo-DeepCopy {
    # Internal. A deep copy through JSON, so the caller's hashtable is never touched.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Value)
    return (ConvertTo-Json -InputObject $Value -Depth 32 | ConvertFrom-Json -AsHashtable -NoEnumerate)
}

function ConvertTo-SortedValue {
    # Internal. Recursively orders hashtable keys so equal content compares equal.
    [CmdletBinding()]
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object { [string]$_ })) { $sorted[[string]$key] = ConvertTo-SortedValue $Value[$key] }
        return $sorted
    }
    if ($Value -is [System.Collections.IList]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-SortedValue $item)) }
        return , $items.ToArray()
    }
    return $Value
}

function ConvertTo-CanonicalJson {
    # Internal. Key-order-independent JSON used only to decide "unchanged".
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Value)
    return (ConvertTo-Json -InputObject (ConvertTo-SortedValue $Value) -Depth 32 -Compress)
}

function Find-ByKey {
    # Internal. Index of the first hashtable in $List whose $Key equals $Match (case-insensitive); -1 when none.
    [CmdletBinding()]
    [OutputType([int])]
    param([System.Collections.IList]$List, [string]$Key, [string]$Match)
    for ($i = 0; $i -lt $List.Count; $i++) {
        $item = $List[$i]
        if ($item -is [System.Collections.IDictionary] -and $item.Contains($Key) -and ([string]$item[$Key]) -ieq $Match) { return $i }
    }
    return -1
}

function Test-TerminalLocalState {
    <#
    .SYNOPSIS
        True when the Windows Terminal LocalState directory exists for this user.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Test-Path -LiteralPath (Split-Path -Parent (Get-TerminalSettingsPath)) -PathType Container)
}

function Merge-TerminalSettings {
    <#
    .SYNOPSIS
        Returns the settings with the repository's declared Terminal values merged in.
    .DESCRIPTION
        Pure: the input is not mutated. Declared keys are set; every other key,
        profile, scheme and action is kept. A legacy profiles array becomes
        @{ list = <array> }. The repository's dev profile is matched by guid,
        case-insensitively; a dynamic WSL profile also named dev is hidden.
    .PARAMETER Settings
        The parsed current settings (an empty hashtable for no file).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Terminal settings is the name of the file; the interface is fixed.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Settings)

    $merged = ConvertTo-DeepCopy -Value $Settings

    $merged['defaultProfile'] = $script:ProfileGuid
    $merged['copyOnSelect'] = $false
    # Warning keys use the names Terminal 1.21+ reads (src/cascadia/TerminalSettingsModel/
    # MTSMSettings.h). Terminal migrates the legacy names on load and rewrites the file,
    # so writing them would make every setup run rewrite settings.json; they are removed.
    # 'automatic' warns on a multi-line paste unless the shell enabled bracketed paste,
    # the same rule as Ghostty's clipboard-paste-protection on the Mac (ADR-024).
    foreach ($legacy in $script:LegacyWarningKeys) { $null = $merged.Remove($legacy) }
    $merged['warning.multiLinePaste'] = 'automatic'
    $merged['warning.largePaste'] = $true
    $merged['warning.confirmOnClose'] = 'automatic'

    # profiles: object form, or the legacy array.
    if ($merged.ContainsKey('profiles') -and $merged['profiles'] -is [System.Collections.IList]) {
        $merged['profiles'] = @{ list = $merged['profiles'] }
    }
    if (-not ($merged.ContainsKey('profiles') -and $merged['profiles'] -is [System.Collections.IDictionary])) {
        $merged['profiles'] = @{}
    }
    $profiles = $merged['profiles']

    if (-not ($profiles.ContainsKey('defaults') -and $profiles['defaults'] -is [System.Collections.IDictionary])) {
        $profiles['defaults'] = @{}
    }
    $defaults = $profiles['defaults']
    if (-not ($defaults.ContainsKey('font') -and $defaults['font'] -is [System.Collections.IDictionary])) {
        $defaults['font'] = @{}
    }
    $defaults['font']['face'] = 'JetBrainsMono Nerd Font Mono'
    $defaults['font']['size'] = 12
    $defaults['colorScheme'] = 'Solarized Light'
    # Terminal's default intenseTextStyle 'bright' paints bold text with the bright
    # palette slots. In Solarized those hold the base tones and brightWhite equals the
    # background (#FDF6E3), so bold white text would be invisible. 'bold' keeps the
    # normal colour and only thickens the glyphs.
    $defaults['intenseTextStyle'] = 'bold'
    $defaults['padding'] = '8, 6'

    $list = [System.Collections.Generic.List[object]]::new()
    if ($profiles.ContainsKey('list') -and $profiles['list'] -is [System.Collections.IList]) {
        foreach ($item in $profiles['list']) { $list.Add($item) }
    }
    foreach ($item in $list) {
        if ($item -is [System.Collections.IDictionary] -and $item.Contains('name') -and $item['name'] -ceq 'dev' -and
            $item.Contains('source') -and $item['source'] -in $script:DynamicSources) {
            if (-not ($item.Contains('guid') -and ([string]$item['guid']) -ieq $script:ProfileGuid)) { $item['hidden'] = $true }
        }
    }
    $index = Find-ByKey -List $list -Key 'guid' -Match $script:ProfileGuid
    if ($index -lt 0) {
        $list.Add(@{})
        $index = $list.Count - 1
    }
    $dev = $list[$index]
    $dev['guid'] = $script:ProfileGuid
    $dev['name'] = 'dev'
    $dev['commandline'] = 'wsl.exe -d dev --cd ~'
    $dev['hidden'] = $false
    $profiles['list'] = $list.ToArray()

    return $merged
}

function Read-TerminalSettingsFile {
    # Internal. Parsed settings (comments allowed); @{} for an absent or blank file. Throws on invalid JSON.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $text = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
    try { $parsed = $text | ConvertFrom-Json -AsHashtable -NoEnumerate }
    catch { throw "Cannot parse $Path ($($_.Exception.Message)); fix or remove it, nothing was changed." }
    if ($parsed -isnot [hashtable]) { throw "$Path does not hold a JSON object; nothing was changed." }
    return $parsed
}

function Update-TerminalSettings {
    <#
    .SYNOPSIS
        Merges the declared Terminal settings into settings.json.
    .DESCRIPTION
        Skips when the Terminal LocalState directory does not exist. Compares the
        canonical JSON of the merge with the current content and writes only when
        they differ, after copying the file to settings.json.backup.<UTC stamp>.
        Writes UTF-8 without a BOM.
    .OUTPUTS
        'updated', 'unchanged' or 'skipped'.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Terminal settings is the name of the file; the interface is fixed.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()

    $path = Get-TerminalSettingsPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        Write-Info 'Windows Terminal has no LocalState directory yet; skipping its settings.'
        return 'skipped'
    }
    $existed = Test-Path -LiteralPath $path
    $current = Read-TerminalSettingsFile -Path $path
    $merged = Merge-TerminalSettings -Settings $current
    if ((ConvertTo-CanonicalJson -Value $current) -ceq (ConvertTo-CanonicalJson -Value $merged)) { return 'unchanged' }

    if (-not $PSCmdlet.ShouldProcess($path, 'Merge declared Windows Terminal settings')) { return 'unchanged' }
    if ($existed) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd\THHmmss\Z')
        $backup = "$path.backup.$stamp"
        Copy-Item -LiteralPath $path -Destination $backup
        Write-Info "Restoring the declared Windows Terminal settings; previous file saved as $backup"
    }
    $json = ConvertTo-Json -InputObject $merged -Depth 32
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    return 'updated'
}

function Test-TerminalSettings {
    <#
    .SYNOPSIS
        Checks that the declared Terminal values are present.
    .OUTPUTS
        '' when they are, else a reason naming the first missing key.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Terminal settings is the name of the file; the interface is fixed.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $path = Get-TerminalSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return "settings.json not found at $path" }
    $s = Read-TerminalSettingsFile -Path $path
    $declared = Merge-TerminalSettings -Settings @{}

    foreach ($key in 'defaultProfile', 'copyOnSelect', 'warning.largePaste', 'warning.multiLinePaste', 'warning.confirmOnClose') {
        $have = if ($s.ContainsKey($key)) { $s[$key] } else { $null }
        # Terminal accepts true as a synonym for 'automatic' on the multi-line paste warning.
        if ($key -eq 'warning.multiLinePaste' -and $have -is [bool] -and $have) { $have = 'automatic' }
        if ($null -eq $have -or "$have" -ne "$($declared[$key])") { return "$key is not $($declared[$key])" }
    }
    $profiles = if ($s.ContainsKey('profiles')) { $s['profiles'] } else { $null }
    if ($profiles -is [System.Collections.IList]) { $profiles = @{ list = $profiles } }
    $defaults = if ($profiles -is [System.Collections.IDictionary] -and $profiles.Contains('defaults')) { $profiles['defaults'] } else { $null }
    $want = $declared['profiles']['defaults']
    $font = if ($defaults -is [System.Collections.IDictionary] -and $defaults.Contains('font')) { $defaults['font'] } else { $null }
    foreach ($k in 'face', 'size') {
        if (-not ($font -is [System.Collections.IDictionary] -and $font.Contains($k) -and $font[$k] -eq $want['font'][$k])) { return "profiles.defaults.font.$k is not $($want['font'][$k])" }
    }
    # A string only: the old { dark, light } object form is drift.
    $scheme = if ($defaults -is [System.Collections.IDictionary] -and $defaults.Contains('colorScheme')) { $defaults['colorScheme'] } else { $null }
    if (-not ($scheme -is [string] -and $scheme -ceq $want['colorScheme'])) { return "profiles.defaults.colorScheme is not $($want['colorScheme'])" }
    $intense = if ($defaults -is [System.Collections.IDictionary] -and $defaults.Contains('intenseTextStyle')) { $defaults['intenseTextStyle'] } else { $null }
    if (-not ($intense -is [string] -and $intense -ceq $want['intenseTextStyle'])) { return "profiles.defaults.intenseTextStyle is not $($want['intenseTextStyle'])" }
    if (-not ($defaults -is [System.Collections.IDictionary] -and $defaults.Contains('padding') -and $defaults['padding'] -ceq $want['padding'])) { return "profiles.defaults.padding is not $($want['padding'])" }

    $list = @(if ($profiles -is [System.Collections.IDictionary] -and $profiles.Contains('list') -and $profiles['list'] -is [System.Collections.IList]) { $profiles['list'] })
    $at = Find-ByKey -List $list -Key 'guid' -Match $script:ProfileGuid
    if ($at -lt 0) { return "profiles.list has no dev profile $($script:ProfileGuid)" }
    $wantDev = @($declared['profiles']['list'] | Where-Object { $_['guid'] -eq $script:ProfileGuid })[0]
    foreach ($k in 'name', 'commandline', 'hidden') {
        if (-not ($list[$at].Contains($k) -and $list[$at][$k] -ceq $wantDev[$k])) { return "dev profile $k is not $($wantDev[$k])" }
    }

    return ''
}

Export-ModuleMember -Function Test-TerminalLocalState, Merge-TerminalSettings, Update-TerminalSettings, Test-TerminalSettings
