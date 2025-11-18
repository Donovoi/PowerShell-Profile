function Invoke-OhMyPoshRandomTheme {
    [CmdletBinding()]
    param()

    # ensure Oh My Posh is installed
    if (-not (Get-Command -Name 'oh-my-posh' -ErrorAction SilentlyContinue)) {
        # Install Oh My Posh via winget
        Write-Host 'Oh My Posh not found. Installing via winget...'
        winget install JanDeDobbeleer.OhMyPosh --source winget
        # Add Oh My Posh to the PATH if not already present
        if ($env:Path -notcontains "$env:LOCALAPPDATA\Programs\oh-my-posh\bin") {
            $env:Path += ";$env:LOCALAPPDATA\Programs\oh-my-posh\bin"
        }
    }

    # Specify a default theme configuration to prevent the banner
    $null = oh-my-posh init pwsh | Invoke-Expression | Out-Null

    # Get the list of themes
    $themes = Get-ChildItem -Path "$env:POSH_THEMES_PATH\*.omp.json" | Select-Object -Property FullName

    # Select a random theme
    $theme = Get-Random -InputObject $themes

    # Initialize Oh My Posh with the random theme
    oh-my-posh init pwsh --config $theme.FullName | Invoke-Expression | Out-Null
}