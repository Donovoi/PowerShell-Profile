function Get-OutputFilename {
    <#
    .SYNOPSIS
        Determines an appropriate output filename for a downloaded file based on a URL.

    .DESCRIPTION
        The Get-OutputFilename function analyzes a provided URL and determines the most appropriate
        filename to use for saving the downloaded content. It uses specialized extraction methods for
        Google Drive URLs and falls back to standard methods for other URLs.

        The function attempts several strategies to find a filename:
        1. For Google Drive URLs: Extract filename using Get-FileDetailsFromResponse
        2. For URLs with filenames in the path: Extract and sanitize the filename
        3. For other URLs: Attempt to get filename from Content-Disposition header
        4. As a last resort: Generate a timestamp-based filename

    .PARAMETER Url
        The URL of the file to be downloaded. This is used to determine an appropriate filename.

    .PARAMETER DestDir
        The destination directory where the file will be saved. This is combined with the
        determined filename to create a full path.

    .PARAMETER HeadersToUse
        Optional. A hashtable of HTTP headers to use when making web requests.
        If not provided, a default User-Agent will be used.

    .EXAMPLE
        $filename = Get-OutputFilename -Url "https://example.com/files/document.pdf" -DestDir "C:\Downloads"

        Gets the output filename for a standard URL and returns the path "C:\Downloads\document.pdf".

    .EXAMPLE
        $filename = Get-OutputFilename -Url "https://drive.google.com/file/d/1ABC123XYZ/view" -DestDir "D:\Files" -HeadersToUse @{ 'Authorization' = 'Bearer token123' }

        Gets the output filename for a Google Drive URL using custom headers and returns the appropriate path.

    .OUTPUTS
        System.String
        Returns the complete path (destination directory + filename) where the file should be saved.

    .NOTES
        This function requires network connectivity when analyzing URLs without clear filenames.
        For Google Drive URLs, it requires the companion function Get-FileDetailsFromResponse.
        The function sanitizes filenames by removing invalid characters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0,
            HelpMessage = 'The URL of the file to be downloaded')]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(Mandatory = $true, Position = 1,
            HelpMessage = 'The destination directory where the file will be saved')]
        [ValidateNotNullOrEmpty()]
        [string]$DestDir,

        [Parameter(Mandatory = $false, Position = 2,
            HelpMessage = 'Optional hashtable of HTTP headers to use when making web requests')]
        [hashtable]$HeadersToUse
    )
    $neededcmdlets = @(               # Alternative download method for large files
        'Get-FileDetailsFromResponse'           # Extracts file details from web response


    )

    foreach ($cmd in $neededcmdlets) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose "Importing cmdlet: $cmd"
            $scriptBlock = Install-Cmdlet -donovoicmdlets $cmd -PreferLocal -Force

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
            elseif ($scriptBlock -is [System.IO.FileInfo]) {
                # If a file path was returned, import it
                Import-Module -Name $scriptBlock.FullName -Force -Global
                Write-Verbose "Imported $cmd from file: $($scriptBlock.FullName)"
            }
            else {
                Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
            }
        }
    }

    try {
        # Check if it's a Google URL (Drive or other Google services)
        if ($Url -match '(\.google\.com)') {
            Write-Verbose "Google URL detected: $Url - Using specialized extraction method"

            # Make a GET request to get response headers for Google URLs
            try {
                # Use provided headers or default to a standard User-Agent
                $tempHeaders = $HeadersToUse ?? @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.81 Safari/537.36' }
                $response = Invoke-WebRequest -Uri $Url -Headers $tempHeaders -UseBasicParsing -WebSession $webSession -Method HEAD

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
            # Extract filename from the URL path
            $originalFileName = [System.IO.Path]::GetFileName($UriParts.LocalPath)

            # Remove query parameters from the filename
            $fileNameWithoutQuery = $originalFileName -split '\?' | Select-Object -First 1

            # Remove invalid characters from the filename
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
                # Use provided headers or default to a standard User-Agent
                $tempHeaders = $HeadersToUse ?? @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.81 Safari/537.36' }
                $headResponse = Invoke-WebRequest -Uri $Url -Method HEAD -Headers $tempHeaders -UseBasicParsing -WebSession $webSession

                # Extract filename from Content-Disposition header if present
                $contentDisp = $headResponse.Headers['Content-Disposition']
                if ($contentDisp -match 'filename="?([^";]+)"?') {
                    # Standard filename format
                    $fileName = $matches[1]
                }
                elseif ($contentDisp -match 'filename\*=UTF-8''([^'']+)') {
                    # UTF-8 encoded filename format
                    $fileName = [System.Web.HttpUtility]::UrlDecode($matches[1])
                }
                else {
                    # No usable filename found in headers, generate one
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

        # Ensure we have a non-empty filename
        if ([string]::IsNullOrWhiteSpace($cleanFileName)) {
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $cleanFileName = "Download-$timestamp"
        }

        return Join-Path -Path $DestDir -ChildPath $cleanFileName
    }
    catch {
        # Final fallback - if all else fails, generate a timestamp-based filename
        Write-Verbose "Error determining output filename: $_"
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        return Join-Path -Path $DestDir -ChildPath "Download-$timestamp"
    }
}