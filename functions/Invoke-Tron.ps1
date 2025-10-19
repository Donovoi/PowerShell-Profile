function Invoke-Tron {
    <#
.SYNOPSIS
Downloads and (optionally) runs the latest Tron .exe from the official repository.

.DESCRIPTION
Discovers the newest Tron .exe from the official directory by reading sha256sums.txt,
verifies the SHA-256, then downloads the EXE using Get-FileDownload with aria2c in
**non-RPC mode** for performance and reliability. Optionally launches the EXE (with
elevation and/or waiting).

.PARAMETER DestinationDirectory
Directory where the executable will be saved. Defaults to "$env:USERPROFILE\Downloads". Created if missing.

.PARAMETER DownloadOnly
Download but do not launch the executable.

.PARAMETER Wait
Wait for the launched process to exit and include ExitCode in the output object.

.PARAMETER Elevate
Launch the executable elevated (Start-Process -Verb RunAs).

.PARAMETER AdditionalArguments
Additional arguments to pass to the Tron executable when launching.

.PARAMETER Force
Overwrite any existing file with the same name at the destination.

.PARAMETER Proxy
HTTP/HTTPS proxy URI (sets $env:http_proxy / $env:https_proxy during download).

.PARAMETER ProxyCredential
(Reserved for future use.) Present for parity with earlier versions.

.PARAMETER SkipHashValidation
Skip SHA-256 validation (NOT recommended).

.PARAMETER BaseUri
Base URI for the Tron repo. Defaults to https://bmrf.org/repos/tron/

.PARAMETER Aria2cExe
Optional: Path to aria2c.exe (passed through to Get-FileDownload).

.PARAMETER AriaConsoleLogLevel
aria2c console log level passed to Get-FileDownload. debug|info|notice|warn|error. Default: error.

.PARAMETER AriaLogToFile
Switch: ask Get-FileDownload to log aria2c output to file.

.PARAMETER LoadCookiesFromFile
Optional cookie file path to pass to Get-FileDownload.

.EXAMPLE
Invoke-Tron -Verbose
Downloads (via aria2c non-RPC) the latest Tron .exe to Downloads, verifies SHA-256, then runs it.

.EXAMPLE
Invoke-Tron -DownloadOnly -DestinationDirectory 'C:\Tools' -AriaLogToFile
Downloads only (aria2c non-RPC), with aria2c logging enabled.

.OUTPUTS
[pscustomobject] with: Name, Version, ReleaseDate, Url, OutFile, HashExpected, HashActual,
Verified, Launched, ProcessId, ExitCode (if -Wait), DownloadedBytes.

.LINK
Repo index & checksums: https://bmrf.org/repos/tron/
aria2c manual (non-RPC CLI): https://aria2.github.io/manual/en/html/aria2c.html
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][ValidateNotNullOrEmpty()]
        [string]$DestinationDirectory = "$env:USERPROFILE\Downloads",

        [Parameter()][switch]$DownloadOnly,
        [Parameter()][switch]$Wait,
        [Parameter()][switch]$Elevate,
        [Parameter()][string]$AdditionalArguments,

        [Parameter()][ValidateNotNullOrEmpty()]
        [string]$Proxy,

        [Parameter()]
        [System.Management.Automation.PSCredential]$ProxyCredential,

        [Parameter()][switch]$SkipHashValidation,

        [Parameter()][ValidateNotNullOrEmpty()]
        [uri]$BaseUri = 'https://bmrf.org/repos/tron/',

        # --- aria2 / Get-FileDownload pass-throughs ---
        [Parameter()][string]$Aria2cExe,
        [Parameter()][ValidateSet('debug', 'info', 'notice', 'warn', 'error')]
        [string]$AriaConsoleLogLevel = 'error',
        [Parameter()][switch]$AriaLogToFile,
        [Parameter()][string]$LoadCookiesFromFile
    )

    begin {
        # Ensure TLS 1.2+ (don’t clobber caller’s defaults)
        $prevProto = [Net.ServicePointManager]::SecurityProtocol
        try {
            $tls = [Net.SecurityProtocolType]::Tls12
            if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
                $tls = $tls -bor [Net.SecurityProtocolType]::Tls13 
            }
            [Net.ServicePointManager]::SecurityProtocol = $prevProto -bor $tls
        }
        catch {
        }

        # -------------------------------
        # Ensure dependency cmdlets exist
        # -------------------------------
        $neededcmdlets = @(
            'Get-FileDownload'
        )

        foreach ($name in $neededcmdlets) {
            if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name Install-Cmdlet -ErrorAction SilentlyContinue)) {
                    # Ensure TLS 1.2 when pulling raw from GitHub on WinPS5.1
                    try {
                        if (-not ([Net.ServicePointManager]::SecurityProtocol.HasFlag([Net.SecurityProtocolType]::Tls12))) {
                            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                            Write-Information 'Enabled TLS 1.2 for secure web requests.' -InformationAction Continue
                        }
                    }
                    catch {
                        Write-Warning "Unable to adjust SecurityProtocol for TLS 1.2: $($_.Exception.Message). Proceeding anyway."
                    }

                    try {
                        Write-Information 'Downloading Install-Cmdlet from repository...' -InformationAction Continue
                        $method = Invoke-RestMethod -Uri $script:INSTALL_CMDLET_URL -TimeoutSec $script:WEB_REQUEST_TIMEOUT -ErrorAction Stop
                        if (-not $method) {
                            throw 'Empty response for Install-Cmdlet.ps1' 
                        }
                        $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                        New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module -ErrorAction Stop
                        Write-Information 'Successfully imported Install-Cmdlet module.' -InformationAction Continue
                    }
                    catch {
                        Write-Warning "Failed to retrieve/import Install-Cmdlet.ps1: $($_.Exception.Message)"
                        return
                    }
                }

                try {
                    $mods = Install-Cmdlet -RepositoryCmdlets $name
                    if ($mods) {
                        $mods | Import-Module -Force 
                    }
                    else {
                        Write-Verbose "Install-Cmdlet returned no modules for '$name'" 
                    }
                }
                catch {
                    Write-Warning "Failed to install/import cmdlet '$name': $($_.Exception.Message)"
                }
            }
        }

        function New-DirectoryIfMissing {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) {
                Write-Verbose "Creating directory: $Path"
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
            }
        }

        function Invoke-WebRequestSafe {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][uri]$Uri
            )
            $common = @{ Uri = $Uri; UseBasicParsing = $true; ErrorAction = 'Stop' }
            Invoke-WebRequest @common
        }

        function ConvertFrom-TronSha256Sums {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Text)
            $regex = '^(?<size>\d+),(?<hash>[0-9a-f]{64}),(?<file>.+?\.exe)$'
            foreach ($line in ($Text -split "`r?`n")) {
                $line = $line.Trim()
                if ($line -match $regex) {
                    $file = $matches['file']
                    $ver = $null; $date = $null
                    if ($file -match 'v(?<ver>\d+\.\d+\.\d+)') {
                        $ver = $matches['ver'] 
                    }
                    if ($file -match '\((?<date>\d{4}-\d{2}-\d{2})\)') {
                        $date = Get-Date $matches['date'] 
                    }
                    [pscustomobject]@{
                        FileName    = $file
                        Sha256      = $matches['hash']
                        Size        = [int64]$matches['size']
                        Version     = if ($ver) {
                            [version]$ver 
                        }
                        else {
                            [version]'0.0.0' 
                        }
                        ReleaseDate = $date
                    }
                }
            }
        }

        # Respect Proxy by environment variables for aria2c / web engines
        $prevHttp = $env:http_proxy
        $prevHttps = $env:https_proxy
        if ($Proxy) {
            $env:http_proxy = $Proxy
            $env:https_proxy = $Proxy
            Write-Verbose "Proxy set via environment variables for download: $Proxy"
        }
    }

    process {
        try {
            New-DirectoryIfMissing -Path $DestinationDirectory

            # 1) Discover the latest EXE from sha256sums.txt
            Write-Verbose "Fetching sha256sums.txt from $BaseUri"
            $shaUri = [uri]::new($BaseUri, 'sha256sums.txt')
            $shaResp = Invoke-WebRequestSafe -Uri $shaUri
            $entries = ConvertFrom-TronSha256Sums -Text $shaResp.Content
            if (-not $entries) {
                throw "Failed to parse sha256sums from $shaUri" 
            }

            $latest = $entries | Sort-Object Version, ReleaseDate -Descending | Select-Object -First 1
            $exeName = $latest.FileName
            $exeUri = [uri]::new($BaseUri, $exeName)
            $expected = $latest.Sha256
            $expectedOut = Join-Path -Path $DestinationDirectory -ChildPath $exeName

            Write-Verbose ('Latest: {0} (Version {1}{2})' -f $exeName, $latest.Version,
                $(if ($latest.ReleaseDate) {
                        ", released $($latest.ReleaseDate.ToString('yyyy-MM-dd'))"
                    }
                    else {
                        ''
                    }))
            Write-Verbose "Source URL: $($exeUri.AbsoluteUri)"
            Write-Verbose "Expected destination: $expectedOut"

            # 2) Remove existing file if present (always download fresh copy)
            if (Test-Path -LiteralPath $expectedOut) {
                Write-Verbose "Removing existing file: $expectedOut"
                Remove-Item -LiteralPath $expectedOut -Force -ErrorAction SilentlyContinue
            }

            # 3) Download via Get-FileDownload using aria2c NON-RPC mode
            $downloadedPath = $null
            if ($PSCmdlet.ShouldProcess($exeUri.AbsoluteUri, 'Download via Get-FileDownload (aria2c non-RPC)')) {
                $gfdParams = @{
                    URL                  = $exeUri.AbsoluteUri
                    DestinationDirectory = $DestinationDirectory
                    UseAria2             = $true
                    NoRPCMode            = $true          # <-- non-RPC as requested
                    AriaConsoleLogLevel  = $AriaConsoleLogLevel
                }
                if ($PSBoundParameters.ContainsKey('Aria2cExe') -and $Aria2cExe) {
                    $gfdParams['aria2cExe'] = $Aria2cExe 
                }
                if ($AriaLogToFile) {
                    $gfdParams['LogToFile'] = $true 
                }
                if ($LoadCookiesFromFile) {
                    $gfdParams['LoadCookiesFromFile'] = $LoadCookiesFromFile 
                }

                Write-Verbose 'Invoking Get-FileDownload with aria2c (non-RPC)…'
                $downloadedPath = Get-FileDownload @gfdParams
                if (-not $downloadedPath -or -not (Test-Path -LiteralPath $downloadedPath)) {
                    throw 'Get-FileDownload did not return a valid path.'
                }
            }
            else {
                Write-Verbose 'WhatIf: skipping download.'
                $downloadedPath = $expectedOut
            }

            $outFile = (Resolve-Path -LiteralPath $downloadedPath -ErrorAction Stop).Path
            $downloadedBytes = (Get-Item -LiteralPath $outFile).Length

            # 4) Validate SHA-256 unless skipped
            $actual = $null
            $verified = $false
            if (-not $SkipHashValidation) {
                Write-Verbose 'Computing SHA-256 for downloaded file…'
                $actual = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash.ToLowerInvariant()
                $verified = ($actual -eq $expected.ToLowerInvariant())
                if (-not $verified) {
                    throw "SHA-256 validation failed. Expected: $expected Actual: $actual" 
                }
                Write-Verbose 'SHA-256 verified.'
            }
            else {
                Write-Warning 'Skipping hash validation at user request (-SkipHashValidation).'
            }

            # 5) Optionally launch
            $launched = $false
            $childProcessId = $null
            $exitCode = $null

            if (-not $DownloadOnly -and (Test-Path -LiteralPath $outFile)) {
                if ($PSCmdlet.ShouldProcess($outFile, 'Launch')) {
                    $startParams = @{
                        FilePath    = $outFile
                        ErrorAction = 'Stop'
                        PassThru    = $true
                    }
                    if ($AdditionalArguments) {
                        $startParams.ArgumentList = $AdditionalArguments 
                    }
                    if ($Elevate) {
                        $startParams.Verb = 'RunAs' 
                    }

                    Write-Verbose ('Starting: {0} {1}' -f $outFile, ($AdditionalArguments ?? ''))
                    $proc = Start-Process @startParams
                    $launched = $true
                    $childProcessId = $proc.Id

                    if ($Wait) {
                        Write-Verbose "Waiting for process (PID $childProcessId) to exit…"
                        $proc.WaitForExit()
                        $exitCode = $proc.ExitCode
                    }
                }
                else {
                    Write-Verbose 'WhatIf: launch skipped.'
                }
            }

            # 6) Emit result
            [pscustomobject]@{
                Name            = $exeName
                Version         = $latest.Version.ToString()
                ReleaseDate     = if ($latest.ReleaseDate) {
                    $latest.ReleaseDate.ToString('yyyy-MM-dd') 
                }
                else {
                    $null 
                }
                Url             = $exeUri.AbsoluteUri
                OutFile         = $outFile
                HashExpected    = $expected
                HashActual      = $actual
                Verified        = $verified
                DownloadedBytes = $downloadedBytes
                Launched        = $launched
                ProcessId       = $childProcessId
                ExitCode        = $exitCode
            }
        }
        catch {
            Write-Error -ErrorAction Stop $_
        }
        finally {
            # restore proxy env and TLS
            if ($PSBoundParameters.ContainsKey('Proxy')) {
                $env:http_proxy = $prevHttp
                $env:https_proxy = $prevHttps
            }
            try {
                [Net.ServicePointManager]::SecurityProtocol = $prevProto 
            }
            catch {
            }
        }
    }
}
