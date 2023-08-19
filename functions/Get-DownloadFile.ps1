<#
.SYNOPSIS
This function downloads a file from a given URL using either aria2c or Invoke-WebRequest .

.DESCRIPTION
The Get-DownloadFile function allows you to download a file from a provided URL. You can choose to use aria2c or Invoke-WebRequest  for the download process. If aria2c is selected but not found in the PATH, it will be automatically downloaded and added to the PATH.

.PARAMETER URL
The URL of the file to download.

.PARAMETER OutFile
The name of the output file.

.PARAMETER UseAria2
Switch to indicate whether to use aria2c for the download. If not specified, Invoke-WebRequest  will be used.

.EXAMPLE
Get-DownloadFile -URL "http://example.com/file.zip" -OutFile "C:\Downloads\file.zip" -UseAria2

.NOTES
If using aria2c, make sure it is installed and accessible from your PATH.
#>

function Get-DownloadFile {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$URL,
        [Parameter(Mandatory = $true)]
        [string]$OutFile,
        [Parameter(Mandatory = $false)]
        [switch]$UseAria2
    )
  
    begin {
        # If aria2 is requested but not found, download and install it
        if ($UseAria2 -and (-not (Test-Path "$PWD/aria2c/*/aria2c.exe"))) {
            # Downloading aria2c
            Write-Host 'Downloading and extracting aria2c...'
            Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '*-win-64*' -DownloadPathDirectory "$PWD/Aria2c" -ExtractZip -Verbose
  
            # Add aria2c to the PATH
            $aria2cExe = $(Resolve-Path -Path "$PWD/aria2c/*/aria2c.exe").Path
            Write-Host -Object "Downloaded Aria2c to $aria2cExe"
        }
        else {
            $aria2cExe = $(Resolve-Path -Path "$PWD/aria2c/*/aria2c.exe").Path
        }
    }
  
    process {
        try {
            if ($UseAria2) {
                Write-Host 'Downloading using aria2c...'
                Invoke-AriaDownload -URL $URL -OutFile $OutFile -Aria2cExePath $aria2cExe
            }
            else {
                Write-Host 'Downloading using Invoke-WebRequest ...'
                Invoke-WebRequest -Uri $URL -OutFile $OutFile
            }
        }
        catch {
            Write-Error $_.Exception.Message
        }
    }
}