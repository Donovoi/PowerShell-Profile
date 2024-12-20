<#
.SYNOPSIS
This function downloads a file from a given URL using aria2c.

.DESCRIPTION
The Invoke-AriaDownload function uses aria2c to download a file from a provided URL.
If the output file already exists, it will be removed before the download starts.

.PARAMETER URL
The URL of the file to download.

.PARAMETER OutFile
The name of the output file.

.PARAMETER Aria2cExePath
The path to the aria2c executable.

.PARAMETER SecretName
The name of the secret in the secret store which contains the GitHub Personal Access Token.

.EXAMPLE
$links = 'driversforlinuxurls.txt'
Invoke-AriaDownload -AriaConsoleLogLevel notice -URLFile $links -DownloadDirectory 'H:\5820 drivers' -Aria2cExePath 'H:\chocolatey apps\chocolatey\bin\bin\aria2c.exe'

.NOTES
Make sure aria2c is installed and accessible from your PATH.
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

        # useragent string
        [Parameter(Mandatory = $false)]
        [string]
        $UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/42.0.2311.135 Safari/537.36 Edge/12.246"
    )
    begin {
        $neededcmdlets = @('Test-InPath', 'Invoke-AriaRPCDownload')
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