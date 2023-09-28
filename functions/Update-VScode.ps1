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
        # Check PowerShell version
        $psVersion = $PSVersionTable.PSVersion.Major

        # Conditional logic for ChildPath based on PS version
        $childPath = if ($psVersion -eq 5.1) {
            'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        }
        else {
            'PowerShell\Microsoft.PowerShell_profile.ps1'
        }

        $myDocuments = [Environment]::GetFolderPath('MyDocuments')
        $myProfile = Join-Path -Path $myDocuments -ChildPath $childPath

        if (Test-Path -Path $myProfile) {
            . $myProfile
        }
        else {
            Write-Log -NoConsoleOutput -Message "No PowerShell profile found at $myProfile"
        }

        # Print the name of the running script
        Write-Log -Message "Script is running as $($MyInvocation.MyCommand.Name)"
    
    } process {
        try {
            # Get the drive with label like 'X-Ways'
            $XWAYSUSB = Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'"
            if (-not $XWAYSUSB) {
                # If the drive is not found, throw an error and return
                throw 'X-Ways USB drive not found.'
            }

            # Define the URLs for downloading stable and insider versions of VSCode
            $urls = @(
                @{
                    Version         = 'stable'
                    URL             = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
                    OutFile         = "$ENV:USERPROFILE\downloads\vscode.zip"
                    DestinationPath = "$($XWAYSUSB.DriveLetter)\vscode\"
                },
                @{
                    Version         = 'insider'
                    URL             = 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive'
                    OutFile         = "$ENV:USERPROFILE\downloads\insiders.zip"
                    DestinationPath = "$($XWAYSUSB.DriveLetter)\vscode-insider\"
                }
            )

            # Switch on the version parameter
            switch ($Version) {
                'both' {
                    # If 'both' is specified, download and expand both versions
                    foreach ($url in $urls) {
                        Get-DownloadFile -URL $url.URL -OutFile $url.OutFile -UseAria2 
                        if (Test-Path $url.OutFile) {
                            Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force -Verbose
                            Remove-Item $url.OutFile
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
                        Get-DownloadFile -URL $url.URL -OutFile $url.OutFile -UseAria2 
                        if (Test-Path $url.OutFile) {
                            # Expand the downloaded archive to the destination path
                            Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force -Verbose
                            Remove-Item $url.OutFile
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
            Write-Log -Message "$($_.Exception.Message)" -Level Error
        }
        finally {
            if (-not($DoNotAddDataFolder)) {
                # add data folder to keep everything within the parent folder
                $folderstoadd = @("$($XWAYSUSB.DriveLetter)\vscode\data", "$($XWAYSUSB.DriveLetter)\vscode-insider\data")
                $folderstoadd.ForEach
                {
                    if (-not(Test-Path -Path $_)) {
                        New-Item -Path $_ -ItemType Directory -Force
                    }
                    
                }
                Write-Log -Message "Data folders Created" -Level Info
            }
            Write-Log -Message 'Update-VSCode function execution completed.' -Level Info
        }
    }
} Update-VSCode -Version both -Verbose -ErrorAction Break