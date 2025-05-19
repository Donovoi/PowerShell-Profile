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
            'Get-OutputFilename'
        )
        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose "Importing cmdlet: $cmd"
                $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal
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
