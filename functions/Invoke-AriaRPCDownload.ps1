
<#
.SYNOPSIS
    Invokes a download using the Aria2 RPC.

.DESCRIPTION
    Takes a URL and an output file as parameters. Checks if the necessary
    cmdlets are available and if the Aria2 executable is in the PATH. Ensures
    the Aria2 RPC server is running, removes any existing output file, and
    constructs a JSON object for the RPC call. Invokes the download and handles
    any errors.

.PARAMETER URL
    The URL of the file to download. Mandatory.

.PARAMETER OutFile
    The path where the downloaded file will be saved. Mandatory.

.PARAMETER Aria2cExePath
    The path to the Aria2 executable. Mandatory.

.PARAMETER Token
    An optional token for authorization.

.PARAMETER Headers
    An optional dictionary of headers for the request.

.PARAMETER LogToFile
    An optional switch to log the download to a file.

.EXAMPLE
    Invoke-AriaRPCDownload -URL "http://example.com/file.zip"
    -OutFile "C:\Downloads\file.zip"
    -Aria2cExePath "C:\Program Files\aria2\aria2c.exe"

    Downloads a file from example.com and saves it to the Downloads folder.
    The path to the Aria2 executable is specified.

.NOTES
    Ensure that the Aria2 executable is correctly installed and in the PATH.
#>
function Invoke-AriaRPCDownload {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$URL,

        # Here we do the same thing as the two parameters above, but we do it in the ValidateScript block
        [Parameter(Mandatory = $true)]
        [string]$OutFile,

        [Parameter(Mandatory = $true)]
        [string]$Aria2cExePath,

        [Parameter(Mandatory = $false)]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]$Headers,

        [Parameter(Mandatory = $false)]
        [switch]$LogToFile
    )

    $neededcmdlets = @('Test-InPath', 'Get-NextAvailablePort')
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
    # Ensure Aria RPC server is running
    if (-not (Get-Process -Name 'aria2c' -ErrorAction SilentlyContinue)) {
        Write-Verbose -Message 'Starting aria2c in RPC mode.'
        $portnumber = Get-NextAvailablePort
        Write-Verbose -Message "Making sure aria2c is in RPC mode on port $portnumber"
        $Aria2cRPCArgs = @(
            '--enable-rpc=true',
            '--rpc-listen-all=true',
            '--rpc-allow-origin-all=true',
            "--rpc-listen-port=$portnumber"
        )
        Start-Process -FilePath $Aria2cExePath -ArgumentList $Aria2cRPCArgs
    }
    else {
        $portnumber = $(Get-Process -Name 'aria2c').CommandLine | Select-String -Pattern '\d{4,5}' -AllMatches | ForEach-Object { $_.Matches.Value }
        Write-Verbose -Message "aria2c is already running in RPC mode. on $portnumber"
    }



    try {
        # If the output file already exists, remove it
        if (Test-Path $OutFile) {
            Remove-Item -Path $OutFile -Force -ErrorAction Stop
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

        # Construct the JSON for the RPC call
        $RPCDownloadJSONParams = @{
            'continue'                  = 'false'
            'max-connection-per-server' = '16'
            'max-concurrent-downloads'  = '16'
            'disable-ipv6'              = 'true'
            'split'                     = '16'
            'min-split-size'            = '1M'
            'file-allocation'           = 'trunc'
            'enable-mmap'               = 'true'
            'max-tries'                 = '0'
            'multiple-interface'        = $interfaceString
            'allow-overwrite'           = 'true'
            'min-tls-version'           = 'TLSv1.2'
            'out'                       = $(Split-Path -Path $OutFile -Leaf)
            'dir'                       = $(Split-Path -Path $OutFile -Parent)
        }

        # If the LogToFile switch is used, we need to add the log parameter to the JSON
        if ($LogToFile) {
            $RPCDownloadJSONParams['log'] = 'aria2c.log'
        }

        # Construct the authorization header if a valid secret is provided and the url is from github
        if ($URL -like '*github.com*') {
            if (-not [string]::IsNullOrEmpty($Token)) {
                # Install any needed modules and import them
                $RPCDownloadJSONParams['header'] = "Authorization: token $Token"
                $RPCDownloadJSONParams['header'] = 'Accept: application/octet-stream'
            }
        }

        # Add any additional headers to the JSON
        if ($Headers) {
            foreach ($key in $Headers.Keys) {
                $RPCDownloadJSONParams['header'] = "$key`: $($Headers[$key])"
            }
        }

        $RPCDownloadJSON = @{
            'jsonrpc' = '2.0'
            'id'      = '1'
            'method'  = 'aria2.addUri'
            'params'  = @(
                @($URL),
                $RPCDownloadJSONParams
            )
        } | ConvertTo-Json -Depth 5

        $requestinfo = Invoke-RestMethod -Uri "http://localhost:$portnumber/jsonrpc" -Method Post -Body $RPCDownloadJSON
        $requestgid = $requestinfo.result

        # Get the status of the download and wait for it to finish
        $downloadstatus = ''
        while (($downloadstatus.status -notlike 'complete')) {
            $downloadstatus = Invoke-RestMethod -Uri "http://localhost:$portnumber/jsonrpc" -Method Post -Body @"
        {
            "jsonrpc": "2.0",
            "id": "2",
            "method": "aria2.tellStatus",
            "params": ["$requestgid"]
        }
"@ | Select-Object -ExpandProperty result
            Write-Verbose -Message "Still Downloading $(Split-Path -Leaf $OutFile). Download status: $($downloadstatus.status)"
            Start-Sleep -Seconds 1
            # if download status is an error throw an error
            if ($downloadstatus.status -eq 'error') {
                throw "Download failed with error: $($downloadstatus.errorMessage)"
            }
        }
        Write-Verbose -Message "Download complete. Status: $($downloadstatus.status)"
        return $OutFile
    }
    catch {
        Write-Error $_
    }

}