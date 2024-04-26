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
        $cmdlets = @('Get-FileDownload', 'Write-Logg')
        $cmdlets.foreach{
            if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
            }
        }
        Write-Verbose -Message "Importing cmdlets: $cmdlets"
        $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $cmdlets
        $Cmdletstoinvoke | Import-Module -Force

        # Print the name of the running script
        Write-Logg -Message "Script is running as $($MyInvocation.MyCommand.Name)"

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
                    Version          = 'stable'
                    URL              = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
                    OutFileDirectory = "$ENV:USERPROFILE\downloads\vscodestable"
                    DestinationPath  = "$($XWAYSUSB.DriveLetter)\vscode\"
                },
                @{
                    Version          = 'insider'
                    URL              = 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive'
                    OutFileDirectory = "$ENV:USERPROFILE\downloads\vscodeinsiders"
                    DestinationPath  = "$($XWAYSUSB.DriveLetter)\vscode-insider\"
                }
            )

            # Switch on the version parameter
            switch ($Version) {
                'both' {
                    # If 'both' is specified, download and expand both versions
                    foreach ($url in $urls) {
                        if (-not( Test-Path -Path $url.OutFileDirectory -ErrorAction SilentlyContinue)) {
                            New-Item -Path $url.OutFileDirectory -ItemType Directory -Force
                        }

                        $OutFile = Get-FileDownload -URL $url.URL -DestinationDirectory $url.OutFileDirectory -UseAria2
                        if ( Resolve-Path -Path $OutFile -ErrorAction SilentlyContinue) {
                            Expand-Archive -Path $OutFile -DestinationPath $url.DestinationPath -Force
                            Remove-Item $OutFile
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
                        if (-not( Test-Path -Path $url.OutFileDirectory -ErrorAction SilentlyContinue)) {
                            New-Item -Path $url.OutFileDirectory -ItemType Directory -Force
                        }
                        $OutFile = Get-FileDownload -URL $url.URL -DestinationDirectory $url.OutFileDirectory -UseAria2
                        if ( Test-Path -Path $OutFile -ErrorAction SilentlyContinue) {
                            Expand-Archive -Path $OutFile -DestinationPath $url.DestinationPath -Force
                            Remove-Item $OutFile
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
                $folderstoadd = @("$($XWAYSUSB.DriveLetter)\vscode\data", "$($XWAYSUSB.DriveLetter)\vscode-insider\data")
                $folderstoadd | ForEach-Object {
                    if (-not(Test-Path -Path $_)) {
                        New-Item -Path $_ -ItemType Directory -Force
                    }
                }
                Write-Logg -Message 'Data folders Created' -Level Info
            }
            Write-Logg -Message 'Update-VSCode function execution completed.' -Level Info
        }
    }
}