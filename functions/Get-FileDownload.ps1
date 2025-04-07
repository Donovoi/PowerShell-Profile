function Get-FileDownload {
    <#
        .SYNOPSIS
            Downloads files from a list of URLs using either aria2c or BITS, with special handling for Google Drive files.

        .DESCRIPTION
            This function downloads files from the specified URLs and saves them to a designated directory.
            When a URL points to a Google Drive file (matching "/file/d/"), the function makes an initial web request
            and then examines the HTML content (via the .Content property) to locate a <form> with id "download-form".
            It uses regex to extract the entire form block and then all hidden input fields to build a complete
            download URL (ensuring that the base action URL is fully qualified). If no form is found, it falls back to
            using a confirmation token. The final URL is then used with aria2c (if specified) or BITS to download the file.

        .PARAMETER URL
            An array of file URLs to download.

        .PARAMETER DestinationDirectory
            The directory where the downloaded files will be saved.

        .PARAMETER UseAria2
            Switch to use aria2c for downloading. Ensure aria2c is installed and in your PATH.

        .PARAMETER aria2cExe
            Optional: The path to the aria2c executable.

        .PARAMETER Token
            Optional GitHub token (used if downloading from a private GitHub repo).

        .PARAMETER Headers
            An IDictionary of custom headers to use during the download.

        .PARAMETER IsPrivateRepo
            Switch indicating whether the source is a private repository.

        .PARAMETER GitHub
            Switch indicating that the URL is from GitHub.

        .PARAMETER NoRPCMode
            Switch to use aria2c in non-RPC mode.

        .PARAMETER AriaConsoleLogLevel
            The log level for aria2c console output. Valid values: debug, info, notice, warn, error. Default is 'error'.

        .PARAMETER LogToFile
            Switch to log aria2c output to file.

        .PARAMETER LoadCookiesFromFile
            A file path from which to load cookies.

        .EXAMPLE
            Get-FileDownload -URL "https://drive.google.com/file/d/141h4BQh8f5ziZii9q4CH9bhkD9HF9Avn/view?usp=drive_link" -DestinationDirectory "C:\Downloads" -UseAria2 -Verbose
            This example downloads the specified Google Drive file to the C:\Downloads folder using aria2c.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$URL,

        [Parameter(Mandatory = $true, Position = 1)]
        [Alias('OutputDir')]
        [string]$DestinationDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$UseAria2,

        [Parameter(Mandatory = $false)]
        [string]$aria2cExe,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [ValidateNotNull()]
        [System.Collections.IDictionary]$Headers,

        [Parameter(Mandatory = $false)]
        [switch]$IsPrivateRepo,

        [Parameter()]
        [switch]$GitHub,

        [Parameter()]
        [switch]$NoRPCMode,

        [Parameter(Mandatory = $false)]
        [ValidateSet('debug', 'info', 'notice', 'warn', 'error')]
        [string]$AriaConsoleLogLevel = 'error',

        [Parameter(Mandatory = $false)]
        [switch]$LogToFile,

        [Parameter(Mandatory = $false)]
        [string]$LoadCookiesFromFile = '',

        [Parameter(Mandatory = $false)]
        [string[]]$WebSession = ''
    )
    begin {
        # Import needed cmdlets if not already available
        $neededcmdlets = @('Install-Dependencies', 'Get-LatestGitHubRelease', 'Invoke-AriaDownload')
        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose "Importing cmdlet: $cmd"
                $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $cmd
                $Cmdletstoinvoke | Import-Module -Force
            }
        }
        $DownloadedFile = ''
    }
    process {
        try {
            if ($UseAria2) {
                $aria2cExe = Get-ChildItem -Path $DestinationDirectory -Recurse -Filter 'aria2c.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
                if (-not (Test-Path -Path $aria2cExe)) {
                    Get-LatestGitHubRelease -OwnerRepository 'aria2/aria2' -AssetName '-win-64bit-' -ExtractZip -DownloadPathDirectory $DestinationDirectory
                    $aria2cExe = Get-ChildItem -Path $DestinationDirectory -Recurse -Filter 'aria2c.exe' | Select-Object -ExpandProperty FullName -First 1
                }
            }

            # Ensure destination directory exists
            if (-not (Test-Path -Path $DestinationDirectory)) {
                New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
            }

            foreach ($download in $URL) {
               

                # Override the download URL with the constructed final URL.
                $download = $finalUrl
            }
            try {
                if ($GitHub) {
                    $tempHeaders = @{ 'User-Agent' = 'PowerShell'; 'Accept' = 'application/vnd.github.v3+json' }
                }
                else {
                    $tempHeaders = $Headers
                }
                $headResponse = Invoke-WebRequest -Uri $download -Method Head -Headers $tempHeaders -UseBasicParsing
                $contentDisp = $headResponse.Headers['Content-Disposition']
                if ($contentDisp -match 'filename="?([^";]+)"?') {
                    $finalFileName = $matches[1]
                }
                else {
                    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $finalFileName = "TempFile-$timestamp"
                }
                $OutFile = Join-Path -Path $DestinationDirectory -ChildPath $finalFileName
                    
            
            }
            catch {
                $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $OutFile = Join-Path -Path $DestinationDirectory -ChildPath "TempFile-$timestamp"
            }
            Write-Verbose "Output file will be: $OutFile"
            $DownloadedFile = ''

            # --- Download using aria2c or fallback ---
            if ($UseAria2) {
                if ($IsPrivateRepo -and $Token) {
                    $DownloadedFile = Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath:$aria2cExe -Token:$Token
                }
                elseif ($NoRPCMode) {
                    $DownloadedFile = Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath:$aria2cExe -Headers:$Headers -AriaConsoleLogLevel:$AriaConsoleLogLevel -LogToFile:$LogToFile -LoadCookiesFromFile:$LoadCookiesFromFile -Verbose:$VerbosePreference
                }
                else {
                    $DownloadedFile = Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath:$aria2cExe -Headers:$Headers -RPCMode -AriaConsoleLogLevel:$AriaConsoleLogLevel -LogToFile:$LogToFile -LoadCookiesFromFile:$LoadCookiesFromFile -Verbose:$VerbosePreference
                }
            }
            else {
                Write-Verbose "Downloading $download using BITS transfer."
                $bitsJob = Start-BitsTransfer -Source $download -Destination $OutFile -Asynchronous -Dynamic
                while (($null -eq $bitsJob.JobState) -or ([string]::IsNullOrEmpty($bitsJob.JobState)) -or ($bitsJob.JobState -eq 'Transferring') -or ($bitsJob.JobState -eq 'Connecting')) {
                    Start-Sleep -Seconds 5
                    Write-Verbose "Waiting for BITS job to complete. Current state: $($bitsJob.JobState)"
                }
                if ($bitsJob.JobState -eq 'Transferred') {
                    $bitsJob.FileList | ForEach-Object { $DownloadedFile = $_.LocalName }
                    $bitsJob | Complete-BitsTransfer
                }
                else {
                    Write-Error "BITS job did not complete successfully. State: $($bitsJob.JobState)"
                }
            }
            # --- End Download method ---
            Write-Verbose "Downloaded file saved as: $DownloadedFile"
        }
    }
    catch {
        Write-Error "An error occurred: $_"
        throw
    }

    if ($DownloadedFile -is [array]) {
        return $DownloadedFile[1]
    }
    else {
        return $DownloadedFile
    }
}
}

# Example usage:
Get-FileDownload -URL 'https://drive.google.com/file/d/141h4BQh8f5ziZii9q4CH9bhkD9HF9Avn' -DestinationDirectory 'C:\users\toor\Downloads' -UseAria2 -NoRPCMode -ErrorAction break -Verbose -AriaConsoleLogLevel 'debug'
