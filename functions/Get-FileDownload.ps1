<#
  .SYNOPSIS
  Downloads files from given URLs using either aria2c or Invoke-WebRequest, with controlled concurrency.

  .DESCRIPTION
  This function downloads files from a list of specified URLs. It uses either aria2c (if specified) or Invoke-WebRequest to perform the download. The function allows for concurrent downloads with a user-specified or default maximum limit to prevent overwhelming the network.

  .PARAMETER URLs
  An array of URLs of the files to be downloaded.

  .PARAMETER OutFileDirectory
  The directory where the downloaded files will be saved.

  .PARAMETER UseAria2
  Switch to use aria2c for downloading. Ensure aria2c is installed and in your PATH if this switch is used.

  .PARAMETER SecretName
  Name of the secret containing the GitHub token. This is used when downloading from a private repository.

  .PARAMETER IsPrivateRepo
  Switch to indicate if the repository from where the file is being downloaded is private.

  .PARAMETER MaxConcurrentDownloads
  The maximum number of concurrent downloads allowed. Default is 5. Users can specify a higher number if they have a robust internet connection.

  .PARAMETER Headers
  An IDictionary containing custom headers to be used during the file download process.

  .EXAMPLE
  $URL = "http://example.com/file1.zip", "http://example.com/file2.zip"
  Get-FileDownload -URLs $URL -OutFileDirectory "C:\Downloads" -UseAria2 -MaxConcurrentDownloads 10

  This example demonstrates how to use the function to download files from a list of URLs using aria2c, with a maximum of 10 concurrent downloads.

  .NOTES
  Ensure aria2c is installed and in the PATH if the UseAria2 switch is used.
  When downloading from a private repository, ensure the secret containing the GitHub token is properly configured.
  #>

function Get-FileDownload {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType([string])]
    param (
        [Parameter(
            Mandatory = $true,
            ValueFromPipeline = $true,
            Position = 0
        )]
        [ValidateNotNullOrEmpty()]
        [string[]]$URL,

        [Parameter(
            Mandatory = $true,
            Position = 1
        )]
        [Alias('OutputDir')]
        [string]$OutFileDirectory,

        [Parameter(
            Mandatory = $false,
            ParameterSetName = 'UseAria2'
        )]
        [switch]$UseAria2,

        [Parameter(
            Mandatory = $false,
            ParameterSetName = 'UseAria2'
        )]
        [ValidateScript({
                if (-not (Test-Path $_ -PathType Leaf)) {
                    throw "The aria2 executable at '$_' does not exist."
                }
                $true
            })]
        [string]$aria2cExe = $(Resolve-Path 'c:\aria2*\*\aria2c.exe' -ErrorAction SilentlyContinue).Path,

        [Parameter(
            Mandatory = $false,
            ParameterSetName = 'Auth'
        )]
        [ValidateNotNullOrEmpty()]
        [string]$SecretName = 'ReadOnlyGitHubToken',

        [Parameter(
            Mandatory = $false
        )]
        [ValidateNotNull()]
        [System.Collections.IDictionary]$Headers,

        [Parameter(
            Mandatory = $false,
            ParameterSetName = 'Auth'
        )]
        [switch]$IsPrivateRepo
    )
    process {
        try {
            if ($UseAria2) {
                if (-not(Test-Path -Path $aria2cExe -ErrorAction SilentlyContinue)) {
                    $aria2directory = Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '-win-64bit-' -ExtractZip
                    $aria2cExe = $(Get-ChildItem -Recurse -Path $aria2directory -Filter 'aria2c.exe').FullName
                }
            }
            foreach ($download In $url) {
                # Construct the output file path for when the url has the filename in it
                #First we check if the url has the filename in it
                $UriParts = [System.Uri]::new($download)
                if ($UriParts.IsFile -or ($download.Split('/')[-1] -match '\.')) {
                    $originalFileName = [System.IO.Path]::GetFileName($UriParts)

                    # Get the base file name without the query string
                    $fileNameWithoutQueryString = $originalFileName -split '\?' | Select-Object -First 1

                    # Sanitize the file name by removing invalid characters
                    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
                    $validChars = $fileNameWithoutQueryString.ToCharArray() | Where-Object { $invalidChars -notcontains $_ }

                    # Join the valid characters into a single string
                    [string]$Outfile = -join $validChars

                    if ($OutFile) {
                        $OutFile = Join-Path -Path $OutFileDirectory -ChildPath $OutFile
                    }
                }
                else {
                    # If the url does not have the filename in it, we get the filename from the headers
                    # Make a HEAD request to get headers
                    $response = Invoke-WebRequest -Uri $download -Headers $Headers -Method Head
                    $potentialFileNames = @()

                    # Check Content-Disposition first
                    $filenamematch = $false
                    if ($response.Headers['Content-Disposition']) {
                        $contentDisposition = $response.Headers['Content-Disposition']
                        $filenamematch = $([regex]::Match($contentDisposition, '([a-zA-Z0-9-.]{3,}\.[a-zA-Z0-9-.]{3,6})'))
                        if ($filenamematch.Success) {
                            $fileName = $filenamematch.Value
                            if ($fileName -match "^UTF-8''(.+)$") {
                                $fileName = [System.Web.HttpUtility]::UrlDecode($matches[1])
                            }
                            else {
                                $fileName = $fileName.Trim('"')
                            }
                            $potentialFileNames += $fileName
                        }
                    }
                    if (-not ($filenamematch)) {
                        # Regex search across all headers for additional filenames
                        foreach ($header in $response.Headers.GetEnumerator()) {
                            if ($header.Value -match '([a-zA-Z0-9-.]{3,}\.[a-zA-Z0-9-.]{3,6})') {
                                $potentialFileNames += $matches[1]
                            }
                        }
                    }


                    # Determine the final filename
                    $finalFileName = $null
                    if ($potentialFileNames.Count -gt 0) {
                        $finalFileName = $potentialFileNames[0]
                    }
                    else {
                        # Generate a temp filename
                        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                        $fileExtension = [System.IO.Path]::GetExtension([System.Uri]::new($download).LocalPath)
                        $finalFileName = "TempFile-$timestamp$fileExtension"
                    }

                    # Combine with the output directory
                    $OutFile = Join-Path -Path $OutFileDirectory -ChildPath $finalFileName
                }

                if ($UseAria2) {
                    # If it's a private repo, handle the secret
                    if ($IsPrivateRepo) {
                        # Install any needed modules and import them
                        if (-not (Get-Module -Name Microsoft.PowerShell.SecretManagement) -or (-not (Get-Module -Name Microsoft.PowerShell.SecretStore))) {
                            Install-Dependencies -PSModules 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore' -NoNugetPackages -RemoveAllModules
                        }
                        if ($null -ne $SecretName) {
                            # Validate the secret exists and is valid
                            if (-not (Get-SecretInfo -Name $SecretName)) {
                                Write-Logg -Message "The secret '$SecretName' does not exist or is not valid." -Level ERROR
                                throw
                            }

                            Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath $aria2cExe -SecretName $SecretName -Headers:$Headers
                        }
                    }
                    else {
                        $DownloadedFile = Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath $aria2cExe -Headers:$Headers
                    }
                }
                else {
                    Write-Logg -Message 'Using Invoke-WebRequest for download.' -Level Info
                    Invoke-WebRequest -Uri $download -OutFile $OutFile -Headers $Headers
                }
            }
        }
        catch {
            Write-Logg -Message "An error occurred: $_" -Level Error
            throw
        }
        return $DownloadedFile
    }
}