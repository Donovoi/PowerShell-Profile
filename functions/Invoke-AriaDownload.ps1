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

.EXAMPLE
Invoke-AriaDownload -URL "http://example.com/file.zip" -OutFile "C:\Downloads\file.zip"

.NOTES
Make sure aria2c is installed and accessible from your PATH.
#>
function Invoke-AriaDownload {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$URL,
        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )
    begin {
        # Print the name of the running script
        Write-Host "Script is running as $($MyInvocation.MyCommand.Name)" 
        # Ensure aria2c is in the PATH
        if (-not (Get-Command 'aria2c' -ErrorAction SilentlyContinue)) {
            throw 'aria2c was not found in the PATH. Please install it or add it to the PATH.'
        }
    }
    process {
        try {
            # If the output file already exists, remove it
            if (Test-Path $OutFile) {
                Remove-Item -Path $OutFile -Force -Verbose -ErrorAction Stop
            }
            # Start the download process using aria2c
            Start-Process -FilePath 'aria2c' -ArgumentList @(
                '--file-allocation=none',
                '--continue=false',
                '--max-connection-per-server=16',
                "--log=$($(Split-Path -Parent $OutFile) + '\aria2c.log')",
                '--split=16',
                '--min-split-size=1M',
                '--max-tries=0',
                '--allow-overwrite=true',
                "--dir=$(Split-Path -Parent $OutFile)",
                "--out=$(Split-Path -Leaf $OutFile)",
                $URL
            ) -NoNewWindow -Wait -ErrorAction Stop

            return $OutFile
        }
        catch {
            Write-Error $_.Exception.Message
        }
    }
}
