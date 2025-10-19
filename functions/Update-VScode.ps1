<#
.SYNOPSIS
    A function to update Visual Studio Code.

.DESCRIPTION
    This function downloads and extracts the specified version(s) of Visual Studio Code.
    It supports 'stable', 'insider', or 'both' versions.

.PARAMETER Version
    The version of Visual Studio Code to downloads and extract.
    Valid values are 'stable', 'insider', or 'both'. Default is 'both'.

.EXAMPLE
    Update-VSCode -Version 'stable'
    This will downloads and extract the stable version of Visual Studio Code.

.EXAMPLE
    Update-VSCode -Version 'both'
    This will downloads and extract both the stable and insider versions of Visual Studio Code.
#>
function Update-VSCode {
    # Use CmdletBinding to enable advanced function features
    [CmdletBinding()]
    param(
        # Validate the input parameter to be one of 'stable', 'insider', or 'both'
        [ValidateSet('stable', 'insider', 'both')]
        [string]$Version = 'both' ,
        # Add data folder to keep everything within the parent folder
        [Parameter(Mandatory = $false)]
        [switch]
        $DoNotAddDataFolder
    )
    begin {
        # Set TLS 1.2 for secure connections
        if ($PSVersionTable.PSVersion.Major -le 5) {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            }
            catch {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
        }
        
        # Load shared dependency loader if not already available
        if (-not (Get-Command -Name 'Initialize-CmdletDependencies' -ErrorAction SilentlyContinue)) {
            $initScript = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
            if (Test-Path $initScript) {
                . $initScript
            }
            else {
                Write-Warning "Initialize-CmdletDependencies.ps1 not found in $PSScriptRoot"
                Write-Warning 'Falling back to direct download'
                try {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -TimeoutSec 30 -UseBasicParsing
                    $scriptBlock = [scriptblock]::Create($method)
                    . $scriptBlock
                }
                catch {
                    Write-Error "Failed to load Initialize-CmdletDependencies: $($_.Exception.Message)"
                    throw
                }
            }
        }
        
        # Load required cmdlets
        try {
            Initialize-CmdletDependencies -RequiredCmdlets @('Get-FileDownload', 'Write-Logg') -PreferLocal -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to load some dependencies: $($_.Exception.Message)"
            Write-Warning 'Attempting to continue with available cmdlets...'
        }

        # Print the name of the running script
        if (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue) {
            Write-Logg -Message "Script is running as $($MyInvocation.MyCommand.Name)"
        }
        else {
            Write-Verbose -Message "Script is running as $($MyInvocation.MyCommand.Name)"
        }
    } process {
        try {
            # Get the drive with label like 'X-Ways'
            $XWAYSUSB = Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'"
            if (-not $XWAYSUSB) {
                # If the drive is not found, throw an error and return
                throw 'X-Ways USB drive not found.'
            }

            # Resolve paths with wildcards first
            $vscodePathPattern = "$($XWAYSUSB.DriveLetter)\*\vscode"
            $vscodeInsiderPathPattern = "$($XWAYSUSB.DriveLetter)\*\vscode-insider"
            
            $vscodePath = Get-Item -Path $vscodePathPattern -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
            $vscodeInsiderPath = Get-Item -Path $vscodeInsiderPathPattern -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
            
            # If paths don't exist, try to find them or use fallback
            if (-not $vscodePath) {
                $possiblePath = Join-Path $XWAYSUSB.DriveLetter 'vscode'
                if (Test-Path $possiblePath) {
                    $vscodePath = $possiblePath
                }
                else {
                    Write-Warning "VSCode path not found, will create at: $possiblePath"
                    $vscodePath = $possiblePath
                }
            }
            
            if (-not $vscodeInsiderPath) {
                $possiblePath = Join-Path $XWAYSUSB.DriveLetter 'vscode-insider'
                if (Test-Path $possiblePath) {
                    $vscodeInsiderPath = $possiblePath
                }
                else {
                    Write-Warning "VSCode Insider path not found, will create at: $possiblePath"
                    $vscodeInsiderPath = $possiblePath
                }
            }
            
            # Define the URLs for downloading stable and insider versions of VSCode
            $urls = @(
                @{
                    Version           = 'stable'
                    URL               = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
                    DownloadDirectory = "$ENV:USERPROFILE\downloads\vscodestable"
                    DestinationPath   = $vscodePath
                },
                @{
                    Version           = 'insider'
                    URL               = 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive'
                    DownloadDirectory = "$ENV:USERPROFILE\downloads\vscodeinsiders"
                    DestinationPath   = $vscodeInsiderPath
                }
            )

            # Switch on the version parameter
            switch ($Version) {
                'both' {
                    # If 'both' is specified, download and expand both versions
                    foreach ($url in $urls) {
                        if (-not( Test-Path -Path $url.DownloadDirectory -ErrorAction SilentlyContinue)) {
                            New-Item -Path $url.DownloadDirectory -ItemType Directory -Force
                        }

                        if (Get-Command -Name 'Get-FileDownload' -ErrorAction SilentlyContinue) {
                            $OutFile = Get-FileDownload -URL $url.URL -DestinationDirectory $url.DownloadDirectory -UseAria2 -NoRPC
                        }
                        else {
                            # Fallback to Invoke-WebRequest if Get-FileDownload is not available
                            Write-Warning 'Get-FileDownload not available, using Invoke-WebRequest'
                            $OutFile = Join-Path $url.DownloadDirectory ("VSCode-$($url.Version).zip")
                            Invoke-WebRequest -Uri $url.URL -OutFile $OutFile -UseBasicParsing
                        }
                        
                        if (Test-Path -Path $OutFile -ErrorAction SilentlyContinue) {
                            Write-Verbose "Downloaded: $OutFile"
                            
                            # Ensure destination directory exists
                            if (-not (Test-Path -Path $url.DestinationPath)) {
                                New-Item -Path $url.DestinationPath -ItemType Directory -Force | Out-Null
                            }
                            
                            Expand-Archive -Path $OutFile -DestinationPath $url.DestinationPath -Force
                            Write-Verbose "Extracted to: $($url.DestinationPath)"
                            
                            Remove-Item $OutFile -Force
                            Write-Verbose "Cleaned up: $OutFile"
                        }
                        else {
                            throw "Failed to download from $($url.URL)"
                        }
                    }
                }
                default {
                    # If 'stable' or 'insider' is specified, download and expand the corresponding version
                    $url = $urls | Where-Object { $_.Version -eq $Version }
                    if ($url) {
                        if (-not( Test-Path -Path $url.DownloadDirectory -ErrorAction SilentlyContinue)) {
                            New-Item -Path $url.DownloadDirectory -ItemType Directory -Force
                        }
                        if (Get-Command -Name 'Get-FileDownload' -ErrorAction SilentlyContinue) {
                            $OutFile = Get-FileDownload -URL $url.URL -DestinationDirectory $url.DownloadDirectory -UseAria2 -NoRPC
                        }
                        else {
                            # Fallback to Invoke-WebRequest if Get-FileDownload is not available
                            Write-Warning 'Get-FileDownload not available, using Invoke-WebRequest'
                            $OutFile = Join-Path $url.DownloadDirectory ("VSCode-$($url.Version).zip")
                            Invoke-WebRequest -Uri $url.URL -OutFile $OutFile -UseBasicParsing
                        }
                        
                        if (Test-Path -Path $OutFile -ErrorAction SilentlyContinue) {
                            Write-Verbose "Downloaded: $OutFile"
                            
                            # Ensure destination directory exists
                            if (-not (Test-Path -Path $url.DestinationPath)) {
                                New-Item -Path $url.DestinationPath -ItemType Directory -Force | Out-Null
                            }
                            
                            Expand-Archive -Path $OutFile -DestinationPath $url.DestinationPath -Force
                            Write-Verbose "Extracted to: $($url.DestinationPath)"
                            
                            Remove-Item $OutFile -Force
                            Write-Verbose "Cleaned up: $OutFile"
                        }
                        else {
                            throw "Failed to download from $($url.URL)"
                        }
                    }
                    else {
                        # If an invalid version is specified, throw an error and return
                        throw "Invalid version specified. Please choose 'stable', 'insider', or 'both'."
                    }
                }
            }
        }
        catch {
            Write-Logg -Message "$($_.Exception.Message)" -Level Error
        }
        finally {
            if (-not($DoNotAddDataFolder)) {
                # add data folder to keep everything within the parent folder
                $dataFolders = @()
                
                # Resolve vscode data folder
                if ($vscodePath) {
                    $dataFolders += Join-Path $vscodePath 'data'
                }
                
                # Resolve vscode-insider data folder
                if ($vscodeInsiderPath) {
                    $dataFolders += Join-Path $vscodeInsiderPath 'data'
                }
                
                foreach ($folder in $dataFolders) {
                    if (-not (Test-Path -Path $folder)) {
                        try {
                            New-Item -Path $folder -ItemType Directory -Force | Out-Null
                            if (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue) {
                                Write-Logg -Message "Created data folder: $folder" -Level Info
                            }
                            else {
                                Write-Verbose "Created data folder: $folder"
                            }
                        }
                        catch {
                            Write-Warning "Failed to create data folder ${folder}: $($_.Exception.Message)"
                        }
                    }
                }
                
                if (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue) {
                    Write-Logg -Message 'Data folders processing completed' -Level Info
                }
            }
            
            if (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue) {
                Write-Logg -Message 'Update-VSCode function execution completed.' -Level Info
            }
            else {
                Write-Verbose 'Update-VSCode function execution completed.'
            }
        }
    }
}