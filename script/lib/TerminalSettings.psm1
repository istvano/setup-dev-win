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
$script:DynamicSources = @('Windows.Terminal.Wsl', 'Microsoft.WSL')

# Catppuccin scheme colours are copied verbatim from mocha.json and latte.json of
# github.com/catppuccin/windows-terminal at commit
# 4d8bb2f00fb86927a98dd3502cdec74a76d25d7b (fetched 2026-11-26).
function Get-CatppuccinScheme {
    # Internal. A fresh copy of one declared scheme per call.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][ValidateSet('Mocha', 'Latte')][string]$Flavour)
    if ($Flavour -eq 'Mocha') {
        return [ordered]@{
            name = 'Catppuccin Mocha'
            cursorColor = '#F5E0DC'
            selectionBackground = '#585B70'
            background = '#1E1E2E'
            foreground = '#CDD6F4'
            black = '#45475A'
            red = '#F38BA8'
            green = '#A6E3A1'
            yellow = '#F9E2AF'
            blue = '#89B4FA'
            purple = '#F5C2E7'
            cyan = '#94E2D5'
            white = '#BAC2DE'
            brightBlack = '#585B70'
            brightRed = '#F38BA8'
            brightGreen = '#A6E3A1'
            brightYellow = '#F9E2AF'
            brightBlue = '#89B4FA'
            brightPurple = '#F5C2E7'
            brightCyan = '#94E2D5'
            brightWhite = '#A6ADC8'
        }
    }
    return [ordered]@{
        name = 'Catppuccin Latte'
        cursorColor = '#DC8A78'
        selectionBackground = '#ACB0BE'
        background = '#EFF1F5'
        foreground = '#4C4F69'
        black = '#5C5F77'
        red = '#D20F39'
        green = '#40A02B'
        yellow = '#DF8E1D'
        blue = '#1E66F5'
        purple = '#EA76CB'
        cyan = '#179299'
        white = '#ACB0BE'
        brightBlack = '#ACB0BE'
        brightRed = '#D20F39'
        brightGreen = '#40A02B'
        brightYellow = '#DF8E1D'
        brightBlue = '#1E66F5'
        brightPurple = '#EA76CB'
        brightCyan = '#179299'
        brightWhite = '#BCC0CC'
    }
}

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
    $merged['multiLinePasteWarning'] = $true
    $merged['largePasteWarning'] = $true
    $merged['confirmCloseAllTabs'] = $true

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
    $defaults['colorScheme'] = @{ dark = 'Catppuccin Mocha'; light = 'Catppuccin Latte' }
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

    # schemes: added or replaced by name.
    $schemes = [System.Collections.Generic.List[object]]::new()
    if ($merged.ContainsKey('schemes') -and $merged['schemes'] -is [System.Collections.IList]) {
        foreach ($item in $merged['schemes']) { $schemes.Add($item) }
    }
    foreach ($flavour in 'Mocha', 'Latte') {
        $scheme = Get-CatppuccinScheme -Flavour $flavour
        $at = Find-ByKey -List $schemes -Key 'name' -Match $scheme['name']
        if ($at -ge 0) { $schemes[$at] = $scheme } else { $schemes.Add($scheme) }
    }
    $merged['schemes'] = $schemes.ToArray()

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

    foreach ($key in 'defaultProfile', 'copyOnSelect', 'multiLinePasteWarning', 'largePasteWarning', 'confirmCloseAllTabs') {
        if (-not $s.ContainsKey($key) -or $s[$key] -ne $declared[$key]) { return "$key is not $($declared[$key])" }
    }
    $profiles = if ($s.ContainsKey('profiles')) { $s['profiles'] } else { $null }
    if ($profiles -is [System.Collections.IList]) { $profiles = @{ list = $profiles } }
    $defaults = if ($profiles -is [System.Collections.IDictionary] -and $profiles.Contains('defaults')) { $profiles['defaults'] } else { $null }
    $want = $declared['profiles']['defaults']
    $font = if ($defaults -is [System.Collections.IDictionary] -and $defaults.Contains('font')) { $defaults['font'] } else { $null }
    foreach ($k in 'face', 'size') {
        if (-not ($font -is [System.Collections.IDictionary] -and $font.Contains($k) -and $font[$k] -eq $want['font'][$k])) { return "profiles.defaults.font.$k is not $($want['font'][$k])" }
    }
    $scheme = if ($defaults -is [System.Collections.IDictionary] -and $defaults.Contains('colorScheme')) { $defaults['colorScheme'] } else { $null }
    foreach ($k in 'dark', 'light') {
        if (-not ($scheme -is [System.Collections.IDictionary] -and $scheme.Contains($k) -and $scheme[$k] -ceq $want['colorScheme'][$k])) { return "profiles.defaults.colorScheme.$k is not $($want['colorScheme'][$k])" }
    }
    if (-not ($defaults -is [System.Collections.IDictionary] -and $defaults.Contains('padding') -and $defaults['padding'] -ceq $want['padding'])) { return "profiles.defaults.padding is not $($want['padding'])" }

    $list = @(if ($profiles -is [System.Collections.IDictionary] -and $profiles.Contains('list') -and $profiles['list'] -is [System.Collections.IList]) { $profiles['list'] })
    $at = Find-ByKey -List $list -Key 'guid' -Match $script:ProfileGuid
    if ($at -lt 0) { return "profiles.list has no dev profile $($script:ProfileGuid)" }
    $wantDev = @($declared['profiles']['list'] | Where-Object { $_['guid'] -eq $script:ProfileGuid })[0]
    foreach ($k in 'name', 'commandline', 'hidden') {
        if (-not ($list[$at].Contains($k) -and $list[$at][$k] -ceq $wantDev[$k])) { return "dev profile $k is not $($wantDev[$k])" }
    }

    $schemes = @(if ($s.ContainsKey('schemes') -and $s['schemes'] -is [System.Collections.IList]) { $s['schemes'] })
    foreach ($wantScheme in $declared['schemes']) {
        $at = Find-ByKey -List $schemes -Key 'name' -Match $wantScheme['name']
        if ($at -lt 0) { return "scheme $($wantScheme['name']) is missing" }
        foreach ($k in $wantScheme.Keys) {
            if (-not ($schemes[$at].Contains($k) -and $schemes[$at][$k] -ceq $wantScheme[$k])) { return "scheme $($wantScheme['name']) differs at $k" }
        }
    }
    return ''
}

Export-ModuleMember -Function Merge-TerminalSettings, Update-TerminalSettings, Test-TerminalSettings
