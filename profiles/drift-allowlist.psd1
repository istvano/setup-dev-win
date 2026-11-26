# Installed winget packages that belong to Windows or winget itself, not to a profile.
# The verify drift report ignores ids matching any of these -like patterns (case-insensitive).
@{
    Patterns = @(
        'Microsoft.AppInstaller'
        'Microsoft.UI.Xaml.*'
        'Microsoft.VCLibs.*'
        'Microsoft.VCRedist.*'
        'Microsoft.WindowsAppRuntime.*'
        'Microsoft.DotNet.*'
        'Microsoft.Edge'
        'Microsoft.EdgeWebView2Runtime'
        'Microsoft.OneDrive'
        'Microsoft.WSL'
        'Microsoft.DSC'
    )
}
