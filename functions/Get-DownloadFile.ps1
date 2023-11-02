<#
  .SYNOPSIS
  Downloads files from given URLs using either aria2c or Invoke-WebRequest, with controlled concurrency.
  
  .DESCRIPTION
  This function downloads files from a list of specified URLs. It uses either aria2c (if specified) or Invoke-WebRequest to perform the download. The function allows for concurrent downloads with a user-specified or default maximum limit to prevent overwhelming the network.
  
  .PARAMETER URLs
  An array of URLs of the files to be downloaded.
  
  .PARAMETER OutFileDirectory
  The directory where the downloaded files will be saved.
  
  .PARAMETER UseAria2
  Switch to use aria2c for downloading. Ensure aria2c is installed and in your PATH if this switch is used.
  
  .PARAMETER SecretName
  Name of the secret containing the GitHub token. This is used when downloading from a private repository.
  
  .PARAMETER IsPrivateRepo
  Switch to indicate if the repository from where the file is being downloaded is private.
  
  .PARAMETER MaxConcurrentDownloads
  The maximum number of concurrent downloads allowed. Default is 5. Users can specify a higher number if they have a robust internet connection.
  
  .PARAMETER Headers
  An IDictionary containing custom headers to be used during the file download process.
  
  .EXAMPLE
  $URL = "http://example.com/file1.zip", "http://example.com/file2.zip"
  Get-DownloadFile -URLs $URL -OutFileDirectory "C:\Downloads" -UseAria2 -MaxConcurrentDownloads 10
  
  This example demonstrates how to use the function to download files from a list of URLs using aria2c, with a maximum of 10 concurrent downloads.
  
  .NOTES
  Ensure aria2c is installed and in the PATH if the UseAria2 switch is used.
  When downloading from a private repository, ensure the secret containing the GitHub token is properly configured.
  #>
  
function Get-DownloadFile {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType([string])]
    param (
        [Parameter(
            Mandatory = $true,
            ValueFromPipeline = $true,
            Position = 0
        )]
        [ValidateNotNullOrEmpty()]
        [string[]]$URL,

        [Parameter(
            Mandatory = $true,
            Position = 1
        )]
        [Alias('OutputDir')]
        [ValidateScript({
                if ($_ -match '\.[a-zA-Z0-9]{1,5}$') {
                    throw "Parameter OutFileDirectory must be valid directory."
                }
                $true
            })]
        [string]$OutFileDirectory,

        [Parameter(
            Mandatory = $false,
            ParameterSetName = 'UseAria2'
        )]
        [switch]$UseAria2,

        [Parameter(
            Mandatory = $false,
            ParameterSetName = 'UseAria2'
        )]
        [ValidateScript({
                if (-not (Test-Path $_ -PathType Leaf)) {
                    throw "The aria2 executable at '$_' does not exist."
                }
                $true
            })]
        [string]$aria2cExe = "c:\aria2\aria2c.exe",

        [Parameter(
            Mandatory = $false,
            ParameterSetName = 'Auth'
        )]
        [ValidateNotNullOrEmpty()]
        [string]$SecretName = 'ReadOnlyGitHubToken',

        [Parameter(
            Mandatory = $false
        )]
        [ValidateNotNull()]
        [System.Collections.IDictionary]$Headers,

        [Parameter(
            Mandatory = $false,
            ParameterSetName = 'Auth'
        )]
        [switch]$IsPrivateRepo
    )
    process {
        try {
            foreach ($download In $url) { 
                # Construct the output file path for when the url has the filename in it
                #First we check if the url has the filename in it
                $outfile = ''
                if ($download.Split('/')[-1] -match '\.[a-zA-Z0-9]{1,5}$') {
                    $OutFile = Join-Path -Path $OutFileDirectory -ChildPath $download.Split('/')[-1]
                }
                else {
                    # If the url does not have the filename in it, we get the filename from the headers
                    $HeadersForFileType = Invoke-WebRequest -Uri $download -Headers:$Headers -Method Head
                    $OutFile = Join-Path -Path $OutFileDirectory -ChildPath $HeadersForFileType.Headers['Content-Disposition'].Split('=')[-1]
                }
                
                if ($UseAria2) {
                    # Get functions from my github profile
                    $functions = @("Write-Log", "Invoke-AriaDownload", "Install-ExternalDependencies", "Get-LatestGitHubRelease")
                    $functions.ForEach{
                        $function = $_                        
                        Out-Host -InputObject "Getting $function from https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/$function.ps1"
                        $Webfunction = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/$function.ps1"
                        $Webfunction.Content | Invoke-Expression
                    }

                    if (-not(Test-Path -Path $aria2cExe)) {
                        Get-LatestGitHubRelease -OwnerRepository "aria2/aria2" -AssetName "-win-64bit-" -DownloadPathDirectory "C:\aria2" -ExtractZip
                        $aria2cExe = $(Get-ChildItem -Recurse -Path "C:\aria2\" -Filter "aria2c.exe").FullName
                    }
                    Write-Host "Using aria2c for download."

                    # If it's a private repo, handle the secret
                    if ($IsPrivateRepo) {
                        # Install any needed modules and import them
                        if (-not (Get-Module -Name Microsoft.PowerShell.SecretManagement) -or (-not (Get-Module -Name Microsoft.PowerShell.SecretStore))) {
                            Install-ExternalDependencies -PSModules 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore' -NoNugetPackages -RemoveAllModules
                        }
                        if ($null -ne $SecretName) {
                            # Validate the secret exists and is valid
                            if (-not (Get-SecretInfo -Name $SecretName)) {
                                Write-Log -Message "The secret '$SecretName' does not exist or is not valid." -Level ERROR
                                throw
                            }      

                            $OutFile = Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath $aria2cExe -SecretName $SecretName -Headers:$Headers
                        }
                    }
                    else {
                        $OutFile = Invoke-AriaDownload -URL $download -OutFile $OutFile -Aria2cExePath $aria2cExe -Headers:$Headers
                    }
                }
                else {
                    Write-Host "Using Invoke-WebRequest for download."
                    Invoke-WebRequest -Uri $download -OutFile $OutFile -Headers $Headers
                }
            }
        }
        catch {
            Write-Host "An error occurred: $_" -ForegroundColor Red
            throw
        }
        return $OutFile
    }
}