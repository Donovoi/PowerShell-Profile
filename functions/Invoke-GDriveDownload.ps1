function Invoke-GDriveDownload {
    <#
    .SYNOPSIS
    Downloads files from Google Drive using a sharing link.

    .DESCRIPTION
    The Invoke-GDriveDownload function downloads files from Google Drive that are shared via links.
    It handles both direct download links and confirmation pages that require form submission.
    The function manages cookies, user agents, and redirects to properly retrieve the file.

    .PARAMETER Url
    The Google Drive sharing URL for the file to download.

    .PARAMETER OutputPath
    The path where the downloaded file should be saved.
    If the path is a directory, the original filename will be used.
    If the path is a filename, the file will be saved with that name.

    .PARAMETER UserAgent
    Optional user agent string to use for the web requests.
    Defaults to a Chrome user agent.

    .PARAMETER Force
    If specified, will overwrite existing files without prompting.

    .EXAMPLE
    Invoke-GDriveDownload -Url "https://drive.google.com/file/d/1ABC123XYZ/view?usp=sharing" -OutputPath "C:\Downloads\"

    Downloads the file specified by the Google Drive link to the C:\Downloads directory with its original filename.

    .EXAMPLE
    Invoke-GDriveDownload -Url "https://drive.google.com/file/d/1ABC123XYZ/view?usp=sharing" -OutputPath "C:\Downloads\myfile.pdf" -Force

    Downloads the file specified by the Google Drive link to C:\Downloads\myfile.pdf, overwriting if it exists.

    .NOTES
    Requires HtmlAgilityPack for parsing the Google Drive confirmation page.
    If the script cannot find HtmlAgilityPack at the expected location, it will try to download it from NuGet.

    Author: PowerShell Profile
    Version: 1.0
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Link', 'Uri')]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [string]$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    begin {

        # Import needed cmdlets if not already available
        $neededcmdlets = @(
            'Install-Dependencies'                  # Installs required dependencies
            'Get-FinalOutputPath'                   # Determines final output path for downloaded files
            'Add-NuGetDependencies'                 # Adds NuGet package dependencies
            'Get-FormDataFromGDriveConfirmation'    # Parses Google Drive confirmation page for form data
            'Invoke-AriaDownload'                   # Alternative download method for large files
            'Get-FileDetailsFromResponse'           # Extracts file details from web response
            'Save-BinaryContent'                    # Saves binary content to disk
            'Add-FileToAppDomain'
            'Write-Logg'
            'Get-FileDownload'
        )
        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose "Importing cmdlet: $cmd"
                $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $cmd -PreferLocal
                $Cmdletstoinvoke | Import-Module -Force
            }
        }

        Install-Dependencies -NugetPackage @{'HtmlAgilityPack' = '1.12.0' } -AddCustomAssemblies @('System.Web')
    }

    process {
        Write-Verbose "Processing URL: $Url"

        # Normalize Google Drive URLs for easier handling
        if ($Url -match 'drive\.google\.com/file/d/([^/]+)') {
            $fileId = $matches[1]
            $Url = "https://drive.google.com/uc?id=$fileId&export=download"
            Write-Verbose "Normalized URL to: $Url"
        }

        # Create a new WebRequestSession to capture cookies
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

        try {
            # Make the initial request using the session.
            Write-Verbose "Making initial request to: $Url"
            try {
                $response = Invoke-WebRequest -Uri $Url -Method GET -MaximumRedirection 0 -WebSession $session -UserAgent $UserAgent -ErrorAction SilentlyContinue
            }
            catch {
                # Handle redirection response (status code 3xx)
                if ($_.Exception.Response.StatusCode -ge 300 -and $_.Exception.Response.StatusCode -lt 400) {
                    $redirectUrl = $_.Exception.Response.Headers.Location
                    if ($redirectUrl) {
                        Write-Verbose "Following redirect to: $redirectUrl"
                        $response = Invoke-WebRequest -Uri $redirectUrl -Method GET -WebSession $session -UserAgent $UserAgent
                    }
                }
                else {
                    throw "Failed to access the URL: $_"
                }
            }

            # Parse the response HTML
            try {
                $formInfo = Get-FormDataFromGDriveConfirmation -Contents $response.Content
            }
            catch {
                throw "Error retrieving download information: $_"
            }

            # Handle the download based on the form info
            if ($formInfo.ContainsKey('FormAction')) {
                # We have a form to submit
                Write-Verbose 'Processing form submission for download...'
                $formData = $formInfo.FormData

                # Build query string from form data instead of using POST body
                $queryParams = [System.Web.HttpUtility]::ParseQueryString([string]::Empty)
                foreach ($key in $formData.Keys) {
                    $queryParams.Add($key, $formData[$key])
                }

                # Create the final URL with query parameters
                $uriBuilder = New-Object System.UriBuilder($formInfo.FormAction)
                $uriBuilder.Query = $queryParams.ToString()
                $finalUrl = $uriBuilder.Uri.ToString()

                Write-Verbose "Downloading from URL: $finalUrl"

                if ($PSCmdlet.ShouldProcess("$finalUrl", 'Download file')) {
                    # Write the cookies to a file
                    $cookieFile = Join-Path -Path $env:TEMP -ChildPath 'gdrive_cookies.txt'
                    $session.Cookies.GetAllCookies() | ForEach-Object {
                        "$($_.Name)=$($_.Value)"
                    } | Out-File -FilePath $cookieFile -Encoding ASCII -Force

                    # Get file output path (directory or specific file)
                    $isDirectory = Test-Path -Path $OutputPath -PathType Container
                    $destinationDir = if ($isDirectory) {
                        $OutputPath 
                    }
                    else {
                        Split-Path -Path $OutputPath -Parent 
                    }

                    # Ensure destination directory exists
                    if (-not (Test-Path -Path $destinationDir)) {
                        New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
                    }

                    # Download the file using Get-FileDownload, which saves directly to disk
                    $downloadedFilePath = Get-FileDownload -URL $finalUrl -LoadCookiesFromFile $cookieFile -DestinationDirectory $destinationDir -UseAria2 -NoRpcMode

                    # If a specific file path was provided (not just a directory), rename the file
                    if (-not $isDirectory) {
                        $requestedFileName = Split-Path -Path $OutputPath -Leaf
                        $downloadDir = Split-Path -Path $downloadedFilePath -Parent
                        $newPath = Join-Path -Path $downloadDir -ChildPath $requestedFileName

                        if ($Force -or -not (Test-Path -Path $newPath)) {
                            Move-Item -Path $downloadedFilePath -Destination $newPath -Force:$Force
                            $downloadedFilePath = $newPath
                        }
                    }

                    # Get file information from the downloaded file
                    $fileInfo = Get-Item -Path $downloadedFilePath

                    Write-Verbose "File successfully downloaded to: $downloadedFilePath"

                    # Return information about the download
                    [PSCustomObject]@{
                        Success     = $true
                        FilePath    = $downloadedFilePath
                        FileName    = $fileInfo.Name
                        FileSize    = $fileInfo.Length
                        ResponseUri = $finalUrl
                        FinalUrl    = $finalUrl
                        SourceUrl   = $Url
                    }
                }
            }
            elseif ($formInfo.ContainsKey('DirectUrl')) {
                # We have a direct URL to download from
                Write-Verbose "Downloading from direct URL: $($formInfo.DirectUrl)"

                if ($PSCmdlet.ShouldProcess("$($formInfo.DirectUrl)", 'Download file')) {
                    $downloadResponse = Invoke-WebRequest -Uri $formInfo.DirectUrl -Method GET -WebSession $session -UserAgent $UserAgent

                    # Get file details from response
                    $fileDetails = Get-FileDetailsFromResponse -Response $downloadResponse -Force:$Force

                    # Determine final output path
                    $actualOutputPath = Get-FinalOutputPath -BasePath $OutputPath -FileName $fileDetails.FileName -Force:$Force

                    # Save the downloaded content
                    Save-BinaryContent -Content $downloadResponse.Content -Path $actualOutputPath
                    Write-Verbose "File saved to: $actualOutputPath"

                    # Return information about the download
                    [PSCustomObject]@{
                        Success     = $true
                        FilePath    = $actualOutputPath
                        FileName    = $fileDetails.FileName
                        FileSize    = $fileDetails.FileSize
                        ResponseUri = $downloadResponse.BaseResponse.ResponseUri
                        FinalUrl    = $formInfo.DirectUrl
                        SourceUrl   = $Url
                    }
                }
            }
            else {
                throw 'No valid download method found. The file might be unavailable or require specific permissions.'
            }
        }
        catch {
            Write-Error "Failed to download the file: $_"
            throw $_
        }
    }

    end {
        Write-Verbose 'Download operation completed.'
    }
}

# Function to generate an output filename from URL
function Get-OutputFilename {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$DestDir,

        [Parameter(Mandatory = $false)]
        [hashtable]$HeadersToUse
    )

    try {
        # Check if it's a Google URL (Drive or other Google services)
        if ($Url -match '(drive\.google\.com|drive\.usercontent\.google\.com|google\.com)') {
            Write-Verbose "Google URL detected: $Url - Using specialized extraction method"

            # Make a GET request to get response headers for Google URLs
            try {
                $tempHeaders = $HeadersToUse ?? @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.81 Safari/537.36' }
                $response = Invoke-WebRequest -Uri $Url -Headers $tempHeaders -UseBasicParsing -WebSession $webSession -Method GET

                # Use the specialized function to extract file details
                $fileDetails = Get-FileDetailsFromResponse -Response $response

                if (-not [string]::IsNullOrWhiteSpace($fileDetails.FileName) -and $fileDetails.FileName -ne 'downloaded_file') {
                    Write-Verbose "Successfully extracted filename from Google response: $($fileDetails.FileName)"
                    return Join-Path -Path $DestDir -ChildPath $fileDetails.FileName
                }
                else {
                    Write-Verbose 'Could not extract meaningful filename from Google response, falling back to standard methods'
                    # Fall back to standard method if Get-FileDetailsFromResponse didn't find a good filename
                }
            }
            catch {
                Write-Verbose "Error getting Google file details: $_"
                # Continue to standard method
            }
        }

        # Standard method for non-Google URLs or as fallback
        $UriParts = [System.Uri]::new($Url)

        # If URL has a filename with extension
        if ($UriParts.IsFile -or ($Url.Split('/')[-1] -match '\.')) {
            $originalFileName = [System.IO.Path]::GetFileName($UriParts.LocalPath)
            $fileNameWithoutQuery = $originalFileName -split '\?' | Select-Object -First 1
            $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
            $validChars = $fileNameWithoutQuery.ToCharArray() | Where-Object { $invalidChars -notcontains $_ }
            [string]$fileName = -join $validChars

            # Add additional uniqueness if needed
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $fileName = "Download-$timestamp"
            }
        }
        else {
            # Try to get filename from content-disposition header
            try {
                $tempHeaders = $HeadersToUse ?? @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.81 Safari/537.36' }
                $headResponse = Invoke-WebRequest -Uri $Url -Method Head -Headers $tempHeaders -UseBasicParsing -WebSession $webSession

                $contentDisp = $headResponse.Headers['Content-Disposition']
                if ($contentDisp -match 'filename="?([^";]+)"?') {
                    $fileName = $matches[1]
                }
                elseif ($contentDisp -match 'filename\*=UTF-8''([^'']+)') {
                    $fileName = [System.Web.HttpUtility]::UrlDecode($matches[1])
                }
                else {
                    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $fileName = "Download-$timestamp"
                }
            }
            catch {
                Write-Verbose "Could not determine filename from headers: $_"
                $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $fileName = "Download-$timestamp"
            }
        }

        # Sanitize filename (additional check for invalid characters)
        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        $validChars = $fileName.ToCharArray() | Where-Object { $invalidChars -notcontains $_ }
        [string]$cleanFileName = -join $validChars

        if ([string]::IsNullOrWhiteSpace($cleanFileName)) {
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $cleanFileName = "Download-$timestamp"
        }

        return Join-Path -Path $DestDir -ChildPath $cleanFileName
    }
    catch {
        Write-Verbose "Error determining output filename: $_"
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        return Join-Path -Path $DestDir -ChildPath "Download-$timestamp"
    }
}

# Example usage (commented out for module inclusion)

Invoke-GDriveDownload -Url 'https://drive.google.com/file/d/141h4BQh8f5ziZii9q4CH9bhkD9HF9Avn/view' -OutputPath 'C:\Temp\' -Verbose

