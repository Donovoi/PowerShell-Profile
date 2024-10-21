function Invoke-OhMyPoshRandomTheme {
    [CmdletBinding()]
    param()

    # Specify a default theme configuration to prevent the banner
    $null = oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\default.omp.json" | Invoke-Expression | Out-Null

    # Function to get the list of themes without Eric Bannerman
    function Get-PoshThemes {
        param(
            [Parameter(Mandatory = $false, HelpMessage = 'The themes folder')]
            [string]
            $Path = $env:POSH_THEMES_PATH,
            [switch]
            [Parameter(Mandatory = $false, HelpMessage = 'List themes path')]
            $List
        )

        while (-not (Test-Path -LiteralPath $Path)) {
            $Path = Read-Host 'Please enter the themes path'
        }

        $Path = (Resolve-Path -Path $Path).ProviderPath

        # Get all themes
        $themes = Get-ChildItem -Path "$Path/*" -Include '*.omp.json' | Sort-Object Name

        if ($List -eq $true) {
            $themes | Select-Object @{ Name = 'hyperlink'; Expression = { Get-FileHyperlink -Uri $_.FullName } } | Format-Table -HideTableHeaders
        }
        else {
            $nonFSWD = Get-NonFSWD
            $stackCount = Get-PoshStackCount
            $terminalWidth = Get-TerminalWidth
            $themes | ForEach-Object -Process {
                Write-Host "Theme: $(Get-FileHyperlink -Uri $_.FullName -Name ($_.BaseName -replace '\.omp$', ''))`n"
                Invoke-Utf8Posh @(
                    'print', 'primary'
                    "--config=$($_.FullName)"
                    "--shell=$script:ShellName"
                    "--shell-version=$script:PSVersion"
                    "--pswd=$nonFSWD"
                    "--stack-count=$stackCount"
                    "--terminal-width=$terminalWidth"
                )
                Write-Host "`n"
            }
        }

        Write-Host @"

    Themes location: $(Get-FileHyperlink -Uri "$Path")

    To change your theme, adjust the init script in $PROFILE.
    Example:
      oh-my-posh init pwsh --config '$((Join-Path $Path 'jandedobbeleer.omp.json') -replace "'", "''")' | Invoke-Expression

"@
    }

    # Get the list of themes
    $themes = Get-PoshThemes -Path $env:POSH_THEMES_PATH -List -ErrorAction SilentlyContinue | Out-String

    # Create a dynamic list to store the themes
    $themesarray = New-Object System.Collections.Generic.List[string]

    # Process the themes list, suppressing output from the loop
    $themes -split [System.Environment]::NewLine | ForEach-Object {
        if ($_ -like '*.omp.json') {
            [void]$themesarray.Add($_)
        }
    }

    # Select a random theme
    $theme = Get-Random -InputObject $themesarray

    # Initialize Oh My Posh with the random theme
    oh-my-posh init pwsh --config $theme | Invoke-Expression | Out-Null
}
