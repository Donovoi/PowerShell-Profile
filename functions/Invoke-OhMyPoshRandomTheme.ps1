function Invoke-OhMyPoshRandomTheme {
    [CmdletBinding()]
    param()

    # Specify a default theme configuration to prevent the banner
    $null = oh-my-posh init pwsh | Invoke-Expression | Out-Null

    # Get the list of themes
    $themes = Get-ChildItem -Path "$env:POSH_THEMES_PATH\*.omp.json" | Select-Object -Property FullName

    # Select a random theme
    $theme = Get-Random -InputObject $themes

    # Initialize Oh My Posh with the random theme
    oh-my-posh init pwsh --config $theme.FullName | Invoke-Expression | Out-Null
}