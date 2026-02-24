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

    # Try local themes first, then fall back to GitHub
    $themes = $null
    if (-not [string]::IsNullOrEmpty($env:POSH_THEMES_PATH)) {
        $themes = Get-ChildItem -Path "$env:POSH_THEMES_PATH\*.omp.json" -ErrorAction SilentlyContinue
    }

    if (-not $themes) {
        # Check common install location
        $localThemesPath = "$env:LOCALAPPDATA\Programs\oh-my-posh\themes"
        $themes = Get-ChildItem -Path "$localThemesPath\*.omp.json" -ErrorAction SilentlyContinue
    }

    if ($themes) {
        $theme = (Get-Random -InputObject $themes).FullName
    }
    else {
        # Fetch theme list from GitHub
        $baseUrl = 'https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes'
        try {
            $listing = Invoke-RestMethod 'https://api.github.com/repos/JanDeDobbeleer/oh-my-posh/contents/themes' -ErrorAction Stop
            $themeNames = ($listing | Where-Object { $_.name -like '*.omp.json' }).name
        }
        catch {
            Write-Warning "Failed to fetch oh-my-posh themes from GitHub: $_"
            return
        }
        if (-not $themeNames) {
            Write-Warning 'No oh-my-posh themes found.'
            return
        }
        $themeName = Get-Random -InputObject $themeNames
        $theme = "$baseUrl/$themeName"
    }

    # Initialize Oh My Posh with the selected theme
    oh-my-posh init pwsh --config $theme | Invoke-Expression
}