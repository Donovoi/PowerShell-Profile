function Invoke-OhMyPoshRandomTheme {
    # Get a list of all available Oh My Posh themes
    # check if folder exists
    if (Test-Path "$ENV:USERPROFILE\AppData\Local\Programs\oh-my-posh\themes") {
        $themes = Get-ChildItem "$ENV:USERPROFILE\AppData\Local\Programs\oh-my-posh\themes" -Filter '*.omp.json'
    }
    else {
  
        $themes = Get-PoshThemes
  
    }
    # Select a random theme
    $theme = Get-Random -InputObject $themes
  
    # Initialize Oh My Posh with the random theme
    oh-my-posh init pwsh --config $theme.FullName | Invoke-Expression
}