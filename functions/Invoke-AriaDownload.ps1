<#
.SYNOPSIS
    Downloads files using aria2c with advanced configuration options and multi-interface support.

.DESCRIPTION
    Invoke-AriaDownload is a PowerShell function that provides a wrapper for aria2c, enabling advanced download capabilities
    with features like multi-connection downloads, GitHub authentication, custom headers, and multi-interface support.
    The function supports both single URL downloads and batch downloads from a file.

.PARAMETER URL
    The URL to download from. Cannot be used together with URLFile parameter.

.PARAMETER URLFile
    Path to a file containing URLs to download. Cannot be used together with URL parameter.

.PARAMETER OutFile
    The path where the downloaded file should be saved. Used with URL parameter.
    Cannot be used together with DownloadDirectory parameter.

.PARAMETER DownloadDirectory
    The directory where files should be downloaded when using URLFile parameter.
    Cannot be used together with OutFile parameter.

.PARAMETER Aria2cExePath
    The full path to the aria2c executable. Required.

.PARAMETER Token
    GitHub authentication token for downloading from GitHub repositories.

.PARAMETER Headers
    Hashtable of custom HTTP headers to be included in the download request.

.PARAMETER AriaConsoleLogLevel
    Sets the console log level for aria2c. Valid values are: 'debug', 'info', 'notice', 'warn', 'error'.
    Default is 'error'.

.PARAMETER LogToFile
    Switch to enable logging to a file (aria2c.log).

.PARAMETER RPCMode
    Switch to enable RPC mode for aria2c downloads.

.PARAMETER LoadCookiesFromFile
    Path to a cookies file to use for the download.

.PARAMETER UserAgent
    Custom User-Agent string for the download request.
    Defaults to Edge browser user agent string.

.EXAMPLE
    Invoke-AriaDownload -URL "https://example.com/file.zip" -OutFile "C:\Downloads\file.zip" -Aria2cExePath "C:\aria2c\aria2c.exe"
    Downloads a single file from the specified URL.

.EXAMPLE
    Invoke-AriaDownload -URLFile "C:\downloads\urls.txt" -DownloadDirectory "C:\Downloads" -Aria2cExePath "C:\aria2c\aria2c.exe"
    Downloads multiple files from URLs listed in the specified file.

.EXAMPLE
    Invoke-AriaDownload -URL "https://api.github.com/repos/user/repo/releases/assets/1234" -OutFile "C:\file.zip" -Token "ghp_xxxx" -Aria2cExePath "aria2c.exe"
    Downloads a file from GitHub using authentication token.

.NOTES
    Author: Donovoi
    Requires: aria2c executable
    Dependencies: Test-InPath, Invoke-AriaRPCDownload cmdlets

.LINK
    https://aria2.github.io/

.OUTPUTS
    [String]
    Returns the path to the downloaded file or download directory.
#>
function Invoke-AriaDownload {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false, ParameterSetName = 'URL')]
        [ValidateScript({
                if (-not $_ -and -not $PSBoundParameters['URLFile']) {
                    throw 'Either URL or URLFile must be specified.'
                }
                elseif ($_ -and $PSBoundParameters['URLFile']) {
                    throw 'Only one of URL or URLFile can be specified.'
                }
                return $true
            })]
        [string]$URL,

        [Parameter(Mandatory = $false, ParameterSetName = 'URLFile')]
        [ValidateScript({
                if (-not $_ -and -not $PSBoundParameters['URL']) {
                    throw 'Either URLFile or URL must be specified.'
                }
                elseif ($_ -and $PSBoundParameters['URL']) {
                    throw 'Only one of URLFile or URL can be specified.'
                }
                return $true
            })]
        [string]$URLFile,

        # Here we do the same thing as the two parameters above, but we do it in the ValidateScript block
        [Parameter(Mandatory = $false, ParameterSetName = 'URL')]
        [ValidateScript({
                if (-not $_ -and -not $PSBoundParameters['DownloadDirectory']) {
                    throw 'Either URL or DownloadDirectory must be specified.'
                }
                elseif ($_ -and $PSBoundParameters['DownloadDirectory']) {
                    throw 'Only one of URL or DownloadDirectory can be specified.'
                }
                return $true
            })]
        [string]$OutFile,

        [Parameter(Mandatory = $false, ParameterSetName = 'URLFile')]
        [ValidateScript({
                if (-not $_ -and -not $PSBoundParameters['OutFile']) {
                    throw 'Either URLFile or OutFile must be specified.'
                }
                elseif ($_ -and $PSBoundParameters['OutFile']) {
                    throw 'Only one of URLFile or OutFile can be specified.'
                }
                return $true
            })]
        [string]$DownloadDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Aria2cExePath,

        [Parameter(Mandatory = $false)]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]$Headers,

        [Parameter(Mandatory = $false)]
        [ValidateSet('debug', 'info', 'notice', 'warn', 'error')]
        [string]$AriaConsoleLogLevel = 'error',

        [Parameter(Mandatory = $false)]
        [switch]$LogToFile,

        [Parameter(Mandatory = $false)]
        [switch]$RPCMode,

        [Parameter(Mandatory = $false)]
        [string]$LoadCookiesFromFile = '',

        [Parameter(Mandatory = $false)]
        [string[]]$WebSession = '',

        # useragent string
        [Parameter(Mandatory = $false)]
        [string]
        $UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/42.0.2311.135 Safari/537.36 Edge/12.246'
    )
    begin {
        $neededcmdlets = @('Test-InPath', 'Invoke-AriaRPCDownload')
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
        # Ensure aria2c is in the PATH
        if (-not (Test-Path -Path $Aria2cExePath)) {
            $IsInPATH = Test-InPath -ExeName 'aria2c.exe'
            if (-not $IsInPATH) {
                throw "aria2c was not found. Make sure you have the right path for `$Aria2cExePath: $Aria2cExePath"
            }
            else {
                Write-Verbose -Message 'aria2c was found in the PATH.'
                $Aria2cExePath = 'aria2c.exe'
            }
        }
    }

    process {
        try {
            # If the output file already exists, remove it
            if (Test-Path $OutFile) {
                Remove-Item -Path $OutFile -Force -ErrorAction Stop
            }

            # Construct the authorization header if a valid secret name is provided and the url is from github
            $authHeader = @()
            if ($URL -like '*github.com*') {
                if (-not [string]::IsNullOrEmpty($Token)) {
                    # Install any needed modules and import them
                    $authHeader += "--header=`"Authorization: token $Token`""
                    $authHeader += "--header=`"Accept: application/octet-stream`""
                }
            }

            # Create an array to hold header arguments for aria2c
            $headerArgs = @()
            if ($Headers) {
                foreach ($key in $Headers.Keys) {
                    $headerArgs += "--header=`"$key`: $($Headers[$key])`""
                }
                if (-not [string]::IsNullOrEmpty($LoadCookiesFromFile)) {
                    if (Test-Path -Path $LoadCookiesFromFile) {
                        $headerArgs += "--Load-Cookies=$LoadCookiesFromFile"
                    }
                    else {
                        Write-Error -Message "The file $LoadCookiesFromFile does not exist."
                    }
                }

            }
            # Get all interfaces that can download the file
            $interfaces = @()
            Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
                $adapter = $_
                Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Where-Object {
                    $_.AddressFamily -eq 'IPv4' -and $_.PrefixOrigin -ne 'WellKnown' -and $_.SuffixOrigin -ne 'WellKnown'
                } | ForEach-Object {
                    $interfaces += $_.IPAddress
                }
            }

            # Join the IP addresses into a single string separated by commas
            $interfaceString = $interfaces -join ','

            # while downloading we need to be in the same directory as the output file (because spaces in the path)
            if (-not $RPCMode) {
                if ($OutFile) {
                    $Outdir = $(Split-Path -Path $OutFile -Parent)
                    Push-Location -Path $Outdir
                }
                else {
                    Push-Location -Path $DownloadDirectory
                }
            }

            if ($URL) {
                $urlfileargument = ''
                $outfileargument = "--out=`"$(Split-Path -Leaf ${OutFile})`""
            }
            else {
                $URL = ''
                $outfileargument = ''
                $urlfileargument = "--input-file=$URLFile"
            }
            if ($LogToFile) {
                $LogOutputToFile = '--log=aria2c.log'
            }
            # Start the download process using aria2c
            $asciiEncoding = [System.Text.Encoding]::ASCII
            $ariaarguments = @(
                "--console-log-level=$AriaConsoleLogLevel"
                '--continue=true',
                $urlfileargument,
                '--max-connection-per-server=16',
                '--max-concurrent-downloads=16',
                $LogOutputToFile,
                '--disable-ipv6',
                '--split=16',
                '--min-split-size=1M',
                '--file-allocation=trunc',
                '--enable-mmap=true',
                '--max-tries=0',
                "--multiple-interface=$interfaceString",
                '--allow-overwrite=true',
                '--min-tls-version=TLSv1.2',
                "--user-agent=`"$UserAgent`"",
                $outfileargument
            )

            # Add each item from $headerArgs to $ariaarguments
            $headerArgs.GetEnumerator() | ForEach-Object {
                $ariaarguments += $asciiEncoding.GetString($asciiEncoding.GetBytes($_))
            }

            # Add each item from $authHeader to $ariaarguments
            $authHeader.GetEnumerator() | ForEach-Object {
                $ariaarguments += $asciiEncoding.GetString($asciiEncoding.GetBytes($_))
            }

            # Add the URL to $ariaarguments
            $ariaarguments += $asciiEncoding.GetString($asciiEncoding.GetBytes($URL))

            if (-not $RPCMode) {
                Start-Process -FilePath $Aria2cExePath -ArgumentList $ariaarguments -NoNewWindow -Wait
                # Return the output file path
                Pop-Location
                if ($PSBoundParameters['OutFile']) {
                    return $OutFile
                }
                else {
                    return $DownloadDirectory
                }
            }
            else {
                $outputFile = Invoke-AriaRPCDownload -url $URL -OutFile $OutFile -Token:$Token -LogToFile -Aria2cExePath $Aria2cExePath -Verbose:$VerbosePreference
                return $outputFile
            }


        }
        catch {
            Write-Error $_
        }
    }
}