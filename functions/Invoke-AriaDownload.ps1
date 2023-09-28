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
Invoke-AriaDownload -URL "http://example.com/file.zip" -OutFile "C:\Downloads\file.zip" -Aria2cExePath "C:\path\to\aria2c.exe" -SecretName "GitHubPAT"

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
        [string]$OutFile,
        
        [Parameter(Mandatory = $true)]
        [string]$Aria2cExePath,
        
        [Parameter(Mandatory = $false)]
        [string]$SecretName
    )
  
    begin {
        # Install any needed modules and import them
        if (-not (Get-Module -Name SecretManagement) -or (-not (Get-Module -Name SecretStore))) {
            Install-ExternalDependencies -PSModules 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore'
        }

        # Print the name of the running script
        Write-log -Message 'Downloading Faster? with Aria2' -Level INFO
        
        # Ensure aria2c is in the PATH
        if (-not (Test-Path -Path $Aria2cExePath)) {
            throw "aria2c was not found. Make sure you have the right path for $Aria2cExePath"
        }
    }
  
    process {
        try {
            # If the output file already exists, remove it
            if (Test-Path $OutFile) {
                Remove-Item -Path $OutFile -Force -ErrorAction Stop
            }
            
            # Construct the authorization header if a valid secret name is provided and the url is from github
            $authHeader = ""
            if ($URL -like '*github.com*') {               
                if (-not [string]::IsNullOrEmpty($SecretName)) {
                    $secret = Get-Secret -Name $SecretName -AsPlainText
                    if ($null -ne $secret) {
                        $authHeader = "--header=`"Authorization: token $secret`""
                    }
                }
            }
            
            # Start the download process using aria2c
            Start-Process -FilePath $Aria2cExePath -ArgumentList @(
                '--file-allocation=none',
                '--continue=false',
                '--max-connection-per-server=16',
                "--log=$($(Split-Path -Parent $OutFile) + '\aria2c.log')",
                '--disable-ipv6',
                '--split=16',
                '--min-split-size=1M',
                '--max-tries=0',
                '--allow-overwrite=true',
                "--dir=$(Split-Path -Parent $OutFile)",
                "--out=$(Split-Path -Leaf $OutFile)",
                $authHeader, # Include the authorization header if it was constructed
                $URL
            ) -NoNewWindow -Wait -ErrorAction Break

            return $OutFile
        }
        catch {
            Write-Log -Message "$($_.Exception.Message)" -Level Error
        }
    }
}