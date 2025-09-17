function Invoke-Tron {
    <#
.SYNOPSIS
Downloads and (optionally) runs the latest Tron .exe from the official repository.

.DESCRIPTION
Queries the official Tron repository’s checksum list to identify the newest .exe, downloads it,
validates SHA-256, and optionally launches it (optionally elevated). Uses approved verbs, avoids
automatic variables, and follows common PS best practices.

.PARAMETER DestinationDirectory
Directory where the executable will be saved. Defaults to $env:TEMP. Created if missing.

.PARAMETER DownloadOnly
Download but do not launch the executable.

.PARAMETER Wait
Wait for the launched process to exit and return its exit code in the output object.

.PARAMETER Elevate
Launch the executable elevated (Start-Process -Verb RunAs). Ignored with -DownloadOnly.

.PARAMETER AdditionalArguments
Additional arguments to pass to the Tron executable when launching.

.PARAMETER Force
Overwrite any existing file with the same name at the destination.

.PARAMETER Proxy
HTTP/HTTPS proxy URI to use for downloads, e.g. http://proxy:8080

.PARAMETER ProxyCredential
Credentials for the proxy. Use (Get-Credential).

.PARAMETER SkipHashValidation
Skip SHA-256 validation (NOT recommended).

.PARAMETER BaseUri
Base URI for the Tron repo. Defaults to https://bmrf.org/repos/tron/

.EXAMPLE
Invoke-Tron -Verbose
Downloads the latest Tron .exe to '$env:USERPROFILE\Downloads' and runs it, with verbose logging.

.EXAMPLE
Invoke-Tron -DestinationDirectory 'C:\Tools' -DownloadOnly
Downloads the latest Tron .exe to C:\Tools but does not run it.

.EXAMPLE
Invoke-Tron -Elevate -Wait -AdditionalArguments '/?'
Downloads, runs elevated, waits for completion, and passes '/?' to the executable.

.OUTPUTS
[pscustomobject] with: Name, Version, ReleaseDate, Url, OutFile, HashExpected, HashActual,
Verified, Launched, ProcessId, ExitCode (if -Wait), DownloadedBytes.

.LINK
Approved verbs: https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands
PSScriptAnalyzer rules: https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/useapprovedverbs
Automatic variables: https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_automatic_variables
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationDirectory = "$env:USERPROFILE\Downloads",

        [Parameter()]
        [switch]$DownloadOnly,

        [Parameter()]
        [switch]$Wait,

        [Parameter()]
        [switch]$Elevate,

        [Parameter()]
        [string]$AdditionalArguments,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Proxy,

        [Parameter()]
        [System.Management.Automation.PSCredential]$ProxyCredential,

        [Parameter()]
        [switch]$SkipHashValidation,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [uri]$BaseUri = 'https://bmrf.org/repos/tron/'
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
                [Parameter(Mandatory)][uri]$Uri,
                [Parameter()][string]$OutFile
            )
            $common = @{
                Uri             = $Uri
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            if ($Proxy) {
                $common.Proxy = $Proxy 
            }
            if ($ProxyCredential) {
                $common.ProxyCredential = $ProxyCredential 
            }

            if ($PSBoundParameters.ContainsKey('OutFile') -and $OutFile) {
                Invoke-WebRequest @common -OutFile $OutFile
            }
            else {
                Invoke-WebRequest @common
            }
        }

        function ConvertFrom-TronSha256Sums {
            <#
            .SYNOPSIS
            Converts sha256sums.txt content to objects (FileName, Sha256, Size, Version, ReleaseDate).
            #>
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
    }

    process {
        try {
            New-DirectoryIfMissing -Path $DestinationDirectory

            # 1) Fetch and parse sha256sums
            Write-Verbose "Fetching sha256sums.txt from $BaseUri"
            $shaUri = [uri]::new($BaseUri, 'sha256sums.txt')
            $shaResp = Invoke-WebRequestSafe -Uri $shaUri
            $entries = ConvertFrom-TronSha256Sums -Text $shaResp.Content
            if (-not $entries) {
                throw "Failed to parse sha256sums from $shaUri" 
            }

            # 2) Pick “latest” by Version then ReleaseDate
            $latest = $entries | Sort-Object Version, ReleaseDate -Descending | Select-Object -First 1
            $exeName = $latest.FileName
            $exeUri = [uri]::new($BaseUri, $exeName)
            $outFile = Join-Path -Path $DestinationDirectory -ChildPath $exeName

            Write-Verbose ('Latest: {0} (Version {1}{2})' -f $exeName, $latest.Version,
                $(if ($latest.ReleaseDate) {
                        ", released $($latest.ReleaseDate.ToString('yyyy-MM-dd'))"
                    }
                    else {
                        ''
                    }))
            Write-Verbose "Source URL: $($exeUri.AbsoluteUri)"
            Write-Verbose "Destination: $outFile"

            # 3) Download (honor ShouldProcess)
            if (Test-Path -LiteralPath $outFile) {
                if ($Force) {
                    if ($PSCmdlet.ShouldProcess($outFile, 'Overwrite existing file')) {
                        Remove-Item -LiteralPath $outFile -Force -ErrorAction Stop
                    }
                    else {
                        Write-Verbose 'Skipping overwrite due to ShouldProcess'
                    }
                }
                else {
                    throw "Destination file already exists: $outFile (use -Force to overwrite)."
                }
            }

            $downloadedBytes = $null
            if ($PSCmdlet.ShouldProcess($exeUri.AbsoluteUri, 'Download')) {
                Invoke-WebRequestSafe -Uri $exeUri -OutFile $outFile | Out-Null
                $downloadedBytes = (Get-Item -LiteralPath $outFile).Length
            }
            else {
                Write-Verbose 'WhatIf: download skipped.'
            }

            # 4) Validate SHA-256 unless skipped
            $expected = $latest.Sha256
            $actual = $null
            $verified = $false
            if (-not $SkipHashValidation -and (Test-Path -LiteralPath $outFile)) {
                Write-Verbose 'Computing SHA-256 for downloaded file…'
                $actual = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash.ToLowerInvariant()
                $verified = ($actual -eq $expected.ToLowerInvariant())
                if (-not $verified) {
                    throw "SHA-256 validation failed. Expected: $expected Actual: $actual" 
                }
                Write-Verbose 'SHA-256 verified.'
            }
            elseif ($SkipHashValidation) {
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

            # 6) Emit result object
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
                OutFile         = (Resolve-Path -LiteralPath $outFile -ErrorAction SilentlyContinue).Path
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
            try {
                [Net.ServicePointManager]::SecurityProtocol = $prevProto 
            }
            catch { 
            }
        }
    }
}
