function Invoke-OhMyPoshRandomTheme {
    # Get a list of all available Oh My Posh themes
    & oh-my-posh init pwsh | out-null
    $themes = Get-PoshThemes

    # Select a random theme
    $theme = Get-Random -InputObject $themes

    # Initialize Oh My Posh with the random theme
    & oh-my-posh init pwsh --config $theme.FullName
}