function Invoke-OhMyPoshRandomTheme {
    [CmdletBinding()]
    param()
    oh-my-posh init pwsh | Invoke-Expression | Out-Null
    # Get a list of all available Oh My Posh themes
    $themes = Get-PoshThemes -Path $env:POSH_THEMES_PATH -List

    # Create an empty array to store the themes
    $themearray = @()

    # create an array from the list of themes
    $themearray += $themes | ForEach-Object { $_ }

    # Select a random theme
    $theme = Get-Random -InputObject $themearray

    # Initialize Oh My Posh with the random theme
    oh-my-posh init pwsh --config $theme | Invoke-Expression
}