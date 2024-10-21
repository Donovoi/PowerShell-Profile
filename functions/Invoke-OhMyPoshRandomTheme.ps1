function Invoke-OhMyPoshRandomTheme {
    [CmdletBinding()]
    param()

    # Specify a default theme configuration to prevent the banner
    $null = oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\default.omp.json" | Invoke-Expression | Out-Null

    $themes = $(Get-PoshThemes -Path $env:POSH_THEMES_PATH -List -ErrorAction SilentlyContinue | Out-String)

    $themesarray = @()

    $themes -split [System.Environment]::NewLine | ForEach-Object {
        if ($_ -like '*.omp.json') {
            $themesarray += $_
        } return $themesarray }

    # Select a random theme
    $theme = Get-Random -InputObject $themesarray

    # Initialize Oh My Posh with the random theme
    oh-my-posh init pwsh --config $theme | Invoke-Expression
}
