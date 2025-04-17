function Get-FileDownload {
    <#
    .SYNOPSIS
        Downloads files from a list of URLs with improved handling for Google Drive files.

    .DESCRIPTION
        Enhanced download function that intelligently handles different download sources, particularly Google Drive.

        For Google Drive URLs:
        - Auto-detects Google Drive links and uses appropriate download strategies
        - Falls back to native PowerShell download when aria2c encounters issues
        - Properly handles authentication cookies and session state

        For general downloads:
        - Uses aria2c for optimal download performance when available
        - Falls back to BITS transfer when aria2c is not available
        - Supports multiple URLs, headers, and authentication tokens

    .PARAMETER URL
        An array of file URLs to download.

    .PARAMETER DestinationDirectory
        The directory where the downloaded files will be saved.

    .PARAMETER UseAria2
        Switch to use aria2c for downloading. Ensure aria2c is installed and in your PATH.

    .PARAMETER aria2cExe
        Optional: The path to the aria2c executable. Will auto-download if not provided.

    .PARAMETER Token
        Optional GitHub token (used if downloading from a private GitHub repo).

    .PARAMETER Headers
        An IDictionary of custom headers to use during the download.

    .PARAMETER IsPrivateRepo
        Switch indicating whether the source is a private repository.

    .PARAMETER GitHub
        Switch indicating that the URL is from GitHub.

    .PARAMETER NoRPCMode
        Switch to use aria2c in non-RPC mode.

    .PARAMETER AriaConsoleLogLevel
        The log level for aria2c console output. Valid values: debug, info, notice, warn, error. Default is 'error'.

    .PARAMETER LogToFile
        Switch to log aria2c output to file.

    .PARAMETER LoadCookiesFromFile
        A file path from which to load cookies.

    .PARAMETER ForceNativeDownload
        Switch to force using PowerShell's native download methods instead of aria2c.

    .EXAMPLE
        Get-FileDownload -URL "https://drive.google.com/file/d/141h4BQh8f5ziZii9q4CH9bhkD9HF9Avn/view" -DestinationDirectory "C:\Downloads" -Verbose
        Downloads the specified Google Drive file to the C:\Downloads folder using the most appropriate method.

    .EXAMPLE
        Get-FileDownload -URL "https://github.com/username/repo/releases/download/v1.0/file.zip" -DestinationDirectory "C:\Downloads" -UseAria2 -Token "ghp_token123" -IsPrivateRepo
        Downloads a file from a private GitHub repository using aria2c with authentication.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$URL,

        [Parameter(Mandatory = $true, Position = 1)]
        [Alias('OutputDir')]
        [string]$DestinationDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$UseAria2,

        [Parameter(Mandatory = $false)]
        [string]$aria2cExe,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [ValidateNotNull()]
        [System.Collections.IDictionary]$Headers,

        [Parameter(Mandatory = $false)]
        [switch]$IsPrivateRepo,

        [Parameter()]
        [switch]$GitHub,

        [Parameter()]
        [switch]$NoRPCMode,

        [Parameter(Mandatory = $false)]
        [ValidateSet('debug', 'info', 'notice', 'warn', 'error')]
        [string]$AriaConsoleLogLevel = 'error',

        [Parameter(Mandatory = $false)]
        [switch]$LogToFile,

        [Parameter(Mandatory = $false)]
        [string]$LoadCookiesFromFile = '',

        [Parameter(Mandatory = $false)]
        [switch]$ForceNativeDownload
    )

    begin {
        # Import needed cmdlets if not already available
        $neededcmdlets = @(
            'Install-Dependencies'     # For installing dependencies
            'Get-LatestGitHubRelease'  # For downloading aria2c if needed
            'Invoke-AriaDownload'
            'Get-FileDetailsFromResponse'
            'Get-OutputFilename'
            'Test-InPath'
            'Invoke-AriaRPCDownload'
        )

        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose "Importing cmdlet: $cmd"
            $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -Force

            # Check if the returned value is a ScriptBlock and import it properly
            if ($scriptBlock -is [scriptblock]) {
                $moduleName = "Dynamic_$cmd"
                New-Module -Name $moduleName -ScriptBlock $scriptBlock | Import-Module -Force -Global
                Write-Verbose "Imported $cmd as dynamic module: $moduleName"
            }
            elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                # If a module info was returned, it's already imported
                Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
            }
            elseif ([System.IO.FileInfo]$scriptBlock -is [System.IO.FileInfo]) {
                # If a file path was returned, import it
                Import-Module -Name $scriptBlock -Force -Global
                Write-Verbose "Imported $cmd from file: $scriptBlock"
            }
            else {
                Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
            }
            
        }

        # Initialize session for web requests
        $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession

        # Ensure destination directory exists
        if (-not (Test-Path -Path $DestinationDirectory)) {
            New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
            Write-Verbose "Created destination directory: $DestinationDirectory"
        }

        # Setup aria2c if requested
        if ($UseAria2 -and (-not $ForceNativeDownload)) {
            try {
                if (-not $aria2cExe -or -not (Test-Path -Path $aria2cExe)) {
                    Write-Verbose 'Searching for aria2c executable in destination directory...'
                    $aria2cExe = Get-ChildItem -Path $DestinationDirectory -Recurse -Filter 'aria2c.exe' -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty FullName -First 1

                    if (-not $aria2cExe) {
                        Write-Verbose 'aria2c not found. Downloading latest version...'
                        Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '-win-64bit-' -ExtractZip -DownloadPathDirectory $DestinationDirectory
                        $aria2cExe = Get-ChildItem -Path $DestinationDirectory -Recurse -Filter 'aria2c.exe' |
                            Select-Object -ExpandProperty FullName -First 1

                        if (-not $aria2cExe) {
                            Write-Warning 'Failed to download aria2c. Falling back to native download methods.'
                            $UseAria2 = $false
                        }
                        else {
                            Write-Verbose "aria2c executable found at: $aria2cExe"
                        }
                    }
                    else {
                        Write-Verbose "aria2c executable found at: $aria2cExe"
                    }
                }
            }
            catch {
                Write-Warning "Error setting up aria2c: $_. Falling back to native download methods."
                $UseAria2 = $false
            }
        }

        # Initialize download tracking
        $DownloadedFile = ''

        # Function to determine if a URL is a Google Drive link
        function Test-GoogleDriveUrl {
            param([string]$Url)
            return $Url -match '\.google\.com'
        }
    }

    process {
        foreach ($download in $URL) {
            Write-Verbose "Processing download URL: $download"
            $OutFile = ''

            # Determine if this is a Google Drive URL
            $isGoogleDrive = Test-GoogleDriveUrl -Url $download
            if ($isGoogleDrive) {
                Write-Verbose 'Detected Google Drive URL'

                # For Google Drive, force native download if using aria2c caused issues previously
                if ($UseAria2 -and (-not $ForceNativeDownload)) {
                    Write-Verbose 'Using aria2c for Google Drive with special handling'
                }
            }

            # Get appropriate output filename
            $OutFile = Get-OutputFilename -Url $download -DestDir $DestinationDirectory -HeadersToUse $Headers
            Write-Verbose "Output file will be: $OutFile"

            try {
                # Choose download method
                if ($UseAria2 -and -not $ForceNativeDownload -and (-not $isGoogleDrive -or -not $ForceNativeDownload)) {
                    Write-Verbose 'Downloading using aria2c'

                    $ariaArgs = @{
                        URL                 = $download
                        OutFile             = $OutFile
                        Aria2cExePath       = $aria2cExe
                        AriaConsoleLogLevel = $AriaConsoleLogLevel
                        LogToFile           = $LogToFile
                    }

                    # Add optional parameters
                    if ($Token) {
                        $ariaArgs['Token'] = $Token
                    }
                    if ($Headers) {
                        $ariaArgs['Headers'] = $Headers
                    }
                    if ($LoadCookiesFromFile) {
                        $ariaArgs['LoadCookiesFromFile'] = $LoadCookiesFromFile
                    }
                    if ($NoRPCMode) {
                        $ariaArgs['RPCMode'] = $false
                    }

                    # Additional handling for Google Drive URLs
                    if ($isGoogleDrive) {
                        Write-Verbose 'Using special handling for Google Drive with aria2c'

                        # Write the cookies to a file for aria2c
                        if ($webSession -and $webSession.Cookies.Count -gt 0) {
                            $cookieFile = Join-Path -Path $env:TEMP -ChildPath 'gdrive_cookies.txt'
                            $webSession.Cookies.GetAllCookies() | ForEach-Object {
                                "$($_.Domain) $($_.Path) $($_.Name) $($_.Value)"
                            } | Out-File -FilePath $cookieFile -Encoding ASCII -Force
                            $ariaArgs['LoadCookiesFromFile'] = $cookieFile
                        }

                        # Try aria2c with special parameters for Google Drive
                        try {
                            $DownloadedFile = Invoke-AriaDownload @ariaArgs

                            # Check if download succeeded
                            if (-not (Test-Path -Path $DownloadedFile) -or (Get-Item -Path $DownloadedFile).Length -eq 0) {
                                throw 'aria2c download failed or produced empty file'
                            }
                        }
                        catch {
                            Write-Warning "aria2c failed for Google Drive download: $_"
                            Write-Verbose 'Falling back to native PowerShell download for Google Drive'
                            $useNativeDownload = $true
                        }
                    }
                    else {
                        # Standard aria2c download for non-Google Drive URLs
                        $DownloadedFile = Invoke-AriaDownload @ariaArgs
                    }
                }
                else {
                    # Use native PowerShell download methods
                    $useNativeDownload = $true
                }

                # Native download method (fallback or forced)
                if ($useNativeDownload -or $ForceNativeDownload) {
                    Write-Verbose "Downloading using native PowerShell methods: $download"

                    # Set up request parameters
                    $webRequestParams = @{
                        Uri             = $download
                        OutFile         = $OutFile
                        UseBasicParsing = $true
                        WebSession      = $webSession
                    }

                    # Add headers if provided
                    if ($Headers) {
                        $webRequestParams['Headers'] = $Headers
                    }

                    # Add GitHub token if applicable
                    if ($GitHub -and $Token) {
                        $authHeader = @{
                            'Authorization' = "token $Token"
                            'Accept'        = 'application/octet-stream'
                        }
                        $webRequestParams['Headers'] = $authHeader
                    }

                    # Perform the download
                    Write-Verbose "Starting native download to $OutFile"
                    Invoke-WebRequest @webRequestParams

                    # Verify download
                    if (Test-Path -Path $OutFile) {
                        $DownloadedFile = $OutFile
                        Write-Verbose "Native download successful: $DownloadedFile (Size: $((Get-Item -Path $DownloadedFile).Length) bytes)"
                    }
                    else {
                        throw 'Native download failed to create output file'
                    }
                }
            }
            catch {
                Write-Error "Download failed for $download : $_"
                throw
            }
        }
    }

    end {
        # Return the path to the downloaded file
        if ($DownloadedFile -is [array]) {
            Write-Verbose "Returning first file path from array: $($DownloadedFile[0])"
            return $DownloadedFile[0]
        }
        else {
            Write-Verbose "Returning file path: $DownloadedFile"
            return $DownloadedFile
        }
    }
}