#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

function Get-AppCatalog {
    <#
    .SYNOPSIS
        The parsed application catalogue (profiles/apps.psd1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return Import-PowerShellDataFile -LiteralPath (Join-Path (Get-RepoRoot) (Join-Path 'profiles' 'apps.psd1'))
}

function Get-ValidProfiles {
    <#
    .SYNOPSIS
        Every profile name, in catalogue order.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names fixed by the task interface; the value is a list.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@((Get-AppCatalog).Order)
}

function Get-DefaultProfileText {
    <#
    .SYNOPSIS
        The default profile set as the comma-separated text -Profiles takes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (@((Get-AppCatalog).Default) -join ',')
}

function Get-AppPackages {
    <#
    .SYNOPSIS
        The catalogue entries of the selected profiles.
    .DESCRIPTION
        Catalogue order (not the order of -Profiles), de-duplicated by Id; each
        entry is a copy with a Profile key naming the profile that declares it.
    .PARAMETER Profiles
        Profile names; names the catalogue does not hold are ignored.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names fixed by the task interface; the value is a list.')]
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([string[]]$Profiles)
    $catalog = Get-AppCatalog
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($name in $catalog.Order) {
        if ($name -notin @($Profiles)) { continue }
        foreach ($entry in @($catalog.Profiles[$name])) {
            if (-not $seen.Add($entry.Id)) { continue }
            $copy = $entry.Clone()
            $copy.Profile = $name
            $result.Add($copy)
        }
    }
    return $result.ToArray()
}

Export-ModuleMember -Function Get-AppCatalog, Get-ValidProfiles, Get-DefaultProfileText, Get-AppPackages
