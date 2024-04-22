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
    [CmdletBinding()]
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
            Mandatory = $false

        )]
        [switch]$UseAria2,

        [Parameter(
            Mandatory = $false

        )]
        [ValidateScript({
                if (-not (Test-Path $_ -PathType Leaf)) {
                    throw "The aria2 executable at '$_' does not exist."
                }
                $true
            })]
        [string]$aria2cExe = $(Resolve-Path 'c:\aria2*\*\aria2c.exe' -ErrorAction SilentlyContinue).Path,

        [Parameter(
            Mandatory = $false

        )]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(
            Mandatory = $false
        )]
        [ValidateNotNull()]
        [System.Collections.IDictionary]$Headers,

        [Parameter(
            Mandatory = $false

        )]
        [switch]$IsPrivateRepo,

        [Parameter()]
        [switch]
        $GitHub

    )
    process {
        try {
            $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Get-LatestGitHubRelease', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
            $neededcmdlets | ForEach-Object {
                if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
                    if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                        $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                        $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                        New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                    }
                    Write-Verbose -Message "Importing cmdlet: $_"
                    $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
                    $Cmdletstoinvoke | Import-Module -Force
                }
            }
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
                    if ($GitHub) {
                        $headers = @{
                            'User-Agent' = 'PowerShell'
                            'Accept'     = 'application/vnd.github.v3+json'
                        }
                    }


                    if (-not [string]::IsNullOrEmpty($token)) {
                        $headers['Authorization'] = "token $token"
                    }

                    $httpresponse = Invoke-WebRequest -Uri $download -Method Head -Headers $headers
                    $headersHashTable = @{}
                    $httpresponse.Headers.GetEnumerator() | ForEach-Object {
                        $headersHashTable[$_.Key] = $_.Value
                    }

                    $potentialFileNames = @()

                    # Check Content-Disposition first
                    $filenamematch = $false

                    if ($headersHashTable) {
                        $fileName = $($headersHashTable['Content-Disposition'] -split 'filename')[1].TrimStart('=').Trim('"').split(';')[0]
                        $potentialFileNames += $fileName
                    }
                    else {
                        $contentDisposition = $httpresponse.Headers['Content-Disposition']
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
                        if (-not ($filenamematch)) {
                            # Regex search across all headers for additional filenames
                            foreach ($header in $response.Headers.GetEnumerator()) {
                                if ($header.Value -match '([a-zA-Z0-9-.]{3,}\.[a-zA-Z0-9-.]{3,6})') {
                                    $potentialFileNames += $matches[1]
                                }
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
                    if (-not(Test-Path -Path $OutFileDirectory -ErrorAction SilentlyContinue)) {
                        New-Item -Path $OutFileDirectory -ItemType Directory -Force -ErrorAction SilentlyContinue
                    }
                    $OutFile = Join-Path -Path $OutFileDirectory -ChildPath $finalFileName
                }
                $Script:DownloadedFile = @()
                if ($UseAria2) {
                    # If it's a private repo, handle the secret
                    if ($IsPrivateRepo) {
                        if ($null -ne $Token) {
                            $Script:DownloadedFile += Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath $aria2cExe -Token:$Token
                        }
                    }
                    else {
                        $Script:DownloadedFile += Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath $aria2cExe -Headers:$Headers -RPCMode
                    }
                }
                else {
                    Write-Warning -Message "Downloading $Download Using Bitstransfer."
                    # Create a BITS job to download the file
                    $bitsJob = Start-BitsTransfer -Source $download -Destination $OutFile -Asynchronous -Dynamic

                    # Wait for the BITS job to complete we will check if the state is like error or an empty string
                    while (($null -eq $bitsJob.JobState) -or ([string]::IsNullOrEmpty($bitsJob.JobState)) -or ($bitsJob.JobState -eq 'Transferring') -or ($bitsJob.JobState -eq 'Connecting')) {
                        Start-Sleep -Seconds 5
                        # every five seconds with will change the foreground of the text to something different as long as it is not the same color as the background

                        # convert the random number to a color
                        $colors = [Enum]::GetValues([ConsoleColor])
                        $newcolor = $colors[(Get-Random -Minimum 0 -Maximum $colors.Length)]
                        # make sure foreground and background are not the same
                        while ($newcolor -eq $Host.UI.RawUI.BackgroundColor) {
                            $newcolor = $colors[(Get-Random -Minimum 0 -Maximum $colors.Length)]
                        }
                        Write-Host -ForegroundColor $newcolor -Object "Waiting for download to complete. Current state: $($bitsJob.JobState)"
                    }

                    # If the job completed successfully, print the path of the downloaded file
                    if ($bitsJob.JobState -eq 'Transferred') {
                        $bitsJob.FileList | ForEach-Object {
                            Write-Host "File downloaded to: $($_.LocalName)"
                            $Script:DownloadedFile += $_.LocalName
                        }
                        $bitsJob | Complete-BitsTransfer
                    }
                    else {
                        Write-Error "BITS job did not complete successfully. State: $($bitsJob.JobState)"
                    }
                }
            }
        }
        catch {
            Write-Error -Message "An error occurred: $_"
            throw
        }
        return $Script:DownloadedFile
    }
}