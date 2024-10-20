function Invoke-OhMyPoshRandomTheme {
    # Get a list of all available Oh My Posh themes
    $themes = Get-poshThemes #"$ENV:LOCALAPPDATA\Programs\oh-my-posh\themes" | Get-ChildItem -Filter '*.omp.json'

    # Select a random theme
    $theme = Get-Random -InputObject $themes

    # Initialize Oh My Posh with the random theme
    & ([ScriptBlock]::Create((oh-my-posh init pwsh --config "$theme.FullName" --print) -join "`n"))
}