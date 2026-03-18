function Invoke-OhMyPoshRandomTheme {
    [CmdletBinding()]
    param(
        [switch]$AuthenticateIfNeeded = $true,
        [int]$ThemeListCacheDays = 14
    )

    function Get-OhMyPoshThemeCachePath {
        $cacheRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PowerShellProfile\Cache'
        if (-not (Test-Path -Path $cacheRoot)) {
            $null = New-Item -Path $cacheRoot -ItemType Directory -Force
        }

        return (Join-Path -Path $cacheRoot -ChildPath 'oh-my-posh-themes.json')
    }

    function Get-CachedOhMyPoshThemeNames {
        param(
            [switch]$IgnoreAge
        )

        $cacheFile = Get-OhMyPoshThemeCachePath
        if (-not (Test-Path -Path $cacheFile)) {
            return @()
        }

        try {
            $cache = Get-Content -Path $cacheFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $themeNames = @($cache.ThemeNames | Where-Object { $_ -and $_ -like '*.omp.json' })

            if (-not $themeNames) {
                return @()
            }

            if ($IgnoreAge) {
                return $themeNames
            }

            if ($cache.CachedAt) {
                $cachedAt = [datetime]$cache.CachedAt
                if ($cachedAt -lt (Get-Date).AddDays( - [math]::Abs($ThemeListCacheDays))) {
                    return @()
                }
            }

            return $themeNames
        }
        catch {
            Write-Verbose "Failed to read cached oh-my-posh themes: $($_.Exception.Message)"
            return @()
        }
    }

    function Save-CachedOhMyPoshThemeNames {
        param(
            [string[]]$ThemeNames
        )

        if (-not $ThemeNames) {
            return
        }

        try {
            $cacheFile = Get-OhMyPoshThemeCachePath
            @{
                CachedAt   = (Get-Date).ToString('o')
                ThemeNames = @($ThemeNames | Sort-Object -Unique)
            } |
                ConvertTo-Json -Depth 3 |
                    Set-Content -Path $cacheFile -Encoding UTF8 -Force
        }
        catch {
            Write-Verbose "Failed to cache oh-my-posh themes: $($_.Exception.Message)"
        }
    }

    function Get-GitHubTokenFromEnvironment {
        foreach ($variableName in 'GH_TOKEN', 'GITHUB_TOKEN') {
            $token = [Environment]::GetEnvironmentVariable($variableName)
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                Write-Verbose "Using GitHub token from `$$variableName."
                return $token.Trim()
            }
        }

        return $null
    }

    function Get-GitHubTokenFromGhCli {
        if (-not (Get-Command -Name 'gh' -ErrorAction SilentlyContinue)) {
            return $null
        }

        try {
            $token = (& gh auth token 2>$null | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                Write-Verbose 'Using GitHub token from GitHub CLI credentials.'
                return $token.Trim()
            }
        }
        catch {
            Write-Verbose "GitHub CLI token lookup failed: $($_.Exception.Message)"
        }

        return $null
    }

    function Get-GitHubTokenFromSecretStore {
        if (-not (Get-Command -Name 'Get-Secret' -ErrorAction SilentlyContinue)) {
            if (-not (Get-Module -ListAvailable -Name 'Microsoft.PowerShell.SecretManagement')) {
                return $null
            }

            try {
                Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Verbose "SecretManagement import failed: $($_.Exception.Message)"
                return $null
            }
        }

        foreach ($secretName in 'GitHubToken', 'GH_TOKEN', 'GITHUB_TOKEN') {
            try {
                $token = Get-Secret -Name $secretName -AsPlainText -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($token)) {
                    Write-Verbose "Using GitHub token from SecretStore secret '$secretName'."
                    return $token.Trim()
                }
            }
            catch {
                continue
            }
        }

        return $null
    }

    function Get-GitHubToken {
        $token = Get-GitHubTokenFromEnvironment
        if ($token) {
            return $token
        }

        $token = Get-GitHubTokenFromGhCli
        if ($token) {
            return $token
        }

        return (Get-GitHubTokenFromSecretStore)
    }

    function Ensure-GitHubCliAuthentication {
        if (-not $AuthenticateIfNeeded) {
            return $false
        }

        if (-not [Environment]::UserInteractive) {
            Write-Verbose 'Skipping GitHub CLI sign-in because the session is not interactive.'
            return $false
        }

        if (-not (Get-Command -Name 'gh' -ErrorAction SilentlyContinue)) {
            Write-Verbose 'GitHub CLI is not installed; cannot prompt for GitHub authentication.'
            return $false
        }

        try {
            & gh auth status 1>$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
        }
        catch {
            Write-Verbose "GitHub CLI auth status check failed: $($_.Exception.Message)"
        }

        try {
            Write-Warning 'GitHub authentication is needed to avoid API rate limits. Starting GitHub CLI login...'
            & gh auth login --web --clipboard --hostname github.com
            return [bool](Get-GitHubTokenFromGhCli)
        }
        catch {
            Write-Warning "GitHub CLI authentication did not complete: $($_.Exception.Message)"
            return $false
        }
    }

    function Get-GitHubErrorMessage {
        param(
            [System.Management.Automation.ErrorRecord]$ErrorRecord
        )

        $message = $null

        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            try {
                $details = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
                if ($details.message) {
                    $message = $details.message
                }
            }
            catch {
                $message = $ErrorRecord.ErrorDetails.Message
            }
        }

        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = $ErrorRecord.Exception.Message
        }

        return $message.Trim()
    }

    function Get-RemoteOhMyPoshThemeNames {
        $uri = 'https://api.github.com/repos/JanDeDobbeleer/oh-my-posh/contents/themes'
        $headers = @{
            Accept                 = 'application/vnd.github+json'
            'User-Agent'           = "Invoke-OhMyPoshRandomTheme/$($PSVersionTable.PSVersion)"
            'X-GitHub-Api-Version' = '2022-11-28'
        }

        $token = Get-GitHubToken
        if ($token) {
            $headers['Authorization'] = "Bearer $token"
        }

        $retryCount = 0
        $authRetried = $false

        while ($true) {
            try {
                $listing = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
                $themeNames = @($listing | Where-Object { $_.name -like '*.omp.json' } | Select-Object -ExpandProperty name)

                if ($themeNames) {
                    Save-CachedOhMyPoshThemeNames -ThemeNames $themeNames
                }

                return $themeNames
            }
            catch {
                $message = Get-GitHubErrorMessage -ErrorRecord $_
                $statusCode = $null

                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode.value__
                }
                catch {
                }

                if ($statusCode -ge 500 -and $statusCode -lt 600 -and $retryCount -lt 2) {
                    Start-Sleep -Seconds (2 * ++$retryCount)
                    continue
                }

                $rateLimited = $message -match 'rate limit' -or $statusCode -eq 403
                if ($rateLimited -and -not $token -and -not $authRetried -and (Ensure-GitHubCliAuthentication)) {
                    $authRetried = $true
                    $token = Get-GitHubToken

                    if ($token) {
                        $headers['Authorization'] = "Bearer $token"
                    }

                    continue
                }

                $cachedThemeNames = Get-CachedOhMyPoshThemeNames -IgnoreAge
                if ($cachedThemeNames.Count -gt 0) {
                    Write-Verbose 'Using cached oh-my-posh theme names after GitHub fetch failed.'
                    return $cachedThemeNames
                }

                Write-Warning "Failed to fetch oh-my-posh themes from GitHub: $message"
                return @()
            }
        }
    }

    function Get-LocalOhMyPoshThemes {
        $themePaths = @()

        if (-not [string]::IsNullOrWhiteSpace($env:POSH_THEMES_PATH)) {
            $themePaths += $env:POSH_THEMES_PATH
        }

        if (-not [string]::IsNullOrWhiteSpace($env:POSH_PATH)) {
            $themePaths += (Join-Path -Path $env:POSH_PATH -ChildPath 'themes')
        }

        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $themePaths += (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\oh-my-posh\themes')

            $packagesRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Packages'
            if (Test-Path -Path $packagesRoot) {
                $storePackages = Get-ChildItem -Path $packagesRoot -Directory -Filter 'ohmyposh.cli*' -ErrorAction SilentlyContinue
                foreach ($storePackage in $storePackages) {
                    $themePaths += (Join-Path -Path $storePackage.FullName -ChildPath 'LocalCache\Local\oh-my-posh\themes')
                    $themePaths += (Join-Path -Path $storePackage.FullName -ChildPath 'LocalCache\Local\Programs\oh-my-posh\themes')
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $themePaths += (Join-Path -Path $env:ProgramFiles -ChildPath 'oh-my-posh\themes')
            $themePaths += (Join-Path -Path $env:ProgramFiles -ChildPath 'JanDeDobbeleer.OhMyPosh\themes')
        }

        $themeFiles = foreach ($themePath in ($themePaths | Where-Object { $_ } | Select-Object -Unique)) {
            if (Test-Path -Path $themePath) {
                Get-ChildItem -Path (Join-Path -Path $themePath -ChildPath '*.omp.json') -ErrorAction SilentlyContinue
            }
        }

        return @($themeFiles)
    }

    # ensure Oh My Posh is installed
    if (-not (Get-Command -Name 'oh-my-posh' -ErrorAction SilentlyContinue)) {
        Write-Host 'Oh My Posh not found. Installing via winget...'
        winget install JanDeDobbeleer.OhMyPosh --source winget

        if ($env:Path -notcontains "$env:LOCALAPPDATA\Programs\oh-my-posh\bin") {
            $env:Path += ";$env:LOCALAPPDATA\Programs\oh-my-posh\bin"
        }
    }

    $themes = Get-LocalOhMyPoshThemes
    if ($themes.Count -gt 0) {
        $theme = (Get-Random -InputObject $themes).FullName
    }
    else {
        $baseUrl = 'https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes'
        $themeNames = Get-CachedOhMyPoshThemeNames

        if (-not $themeNames) {
            $themeNames = Get-RemoteOhMyPoshThemeNames
        }

        if (-not $themeNames) {
            Write-Warning 'No oh-my-posh themes available. Falling back to the default oh-my-posh initialization.'
            oh-my-posh init pwsh | Invoke-Expression
            return
        }

        $themeName = Get-Random -InputObject $themeNames
        $theme = "$baseUrl/$themeName"
    }

    oh-my-posh init pwsh --config $theme | Invoke-Expression
}