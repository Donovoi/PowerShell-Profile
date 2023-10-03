<#
.SYNOPSIS
Downloads a file from a given URL using either aria2c or Invoke-WebRequest.

.DESCRIPTION
Downloads a file from a URL. Optionally uses aria2c for the download; otherwise, uses Invoke-WebRequest.

.PARAMETER URL
The URL of the file to download.

.PARAMETER OutFile
The output file path.

.PARAMETER UseAria2
Switch to use aria2c for downloading.

.PARAMETER SecretName
Name of the secret containing the GitHub token.

.PARAMETER IsPrivateRepo
Switch to indicate if the repo is private.

.EXAMPLE
Get-DownloadFile -URL "http://example.com/file.zip" -OutFile "C:\Downloads\file.zip" -UseAria2 -SecretName "GitHubPAT"

.NOTES
If using aria2c, ensure it's installed and in your PATH.
#>

function Get-DownloadFile {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$URL,

        [Parameter(Mandatory = $true)]
        [string]$OutFile,

        [switch]$UseAria2,

        [string]$SecretName = 'ReadOnlyGitHubToken',

        [switch]$IsPrivateRepo
    )

    begin {        
        if ($UseAria2) {
            # Check for aria2c, download if not found
            if (-not (Test-Path "$PWD/aria2c/*/aria2c.exe")) {
                Write-Host "Downloading aria2c..."
                Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '*-win-64*' -DownloadPathDirectory "$PWD/Aria2c" -ExtractZip
            
                # Add aria2c to the PATH
                $aria2cExe = $(Resolve-Path -Path "$PWD/aria2c/*/aria2c.exe").Path
                Write-log -Message "Downloaded Aria2c to $aria2cExe" -Level INFO
            }
            else {
                $aria2cExe = $(Resolve-Path -Path "$PWD/aria2c/*/aria2c.exe").Path
            }
        }
    }

    process {
        try {
            if ($UseAria2) {
                Write-Host "Using aria2c for download."

                # If it's a private repo, handle the secret
                if ($IsPrivateRepo) {
                    # Install any needed modules and import them
                    if (-not (Get-Module -Name Microsoft.PowerShell.SecretManagement) -or (-not (Get-Module -Name Microsoft.PowerShell.SecretStore))) {
                        Install-ExternalDependencies -PSModules 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore' -NoNugetPackages -RemoveAllModules
                    }
                    if ($null -ne $SecretName) {
                        # Validate the secret exists and is valid
                        if (-not (Get-SecretInfo -Name $SecretName)) {
                            Write-log -Message "The secret '$SecretName' does not exist or is not valid." -Level ERROR
                            throw
                        }      
                    
                        Invoke-AriaDownload -URL $URL -OutFile $OutFile -Aria2cExePath $aria2cExe -SecretName $SecretName
                    }
                }
                Invoke-AriaDownload -URL $URL -OutFile $OutFile -Aria2cExePath $aria2cExe
            }
            else {
                Write-Host "Using Invoke-WebRequest for download."
                Invoke-WebRequest -Uri $URL -OutFile $OutFile
            }
        }
        catch {
            Write-Host "An error occurred: $_" -ForegroundColor Red
            throw
        }
    }
}