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
 $urls = "http://example.com/file1.zip", "http://example.com/file2.zip"
 Get-DownloadFile -URLs $urls -OutFileDirectory "C:\Downloads" -UseAria2 -MaxConcurrentDownloads 10
 
 This example demonstrates how to use the function to download files from a list of URLs using aria2c, with a maximum of 10 concurrent downloads.
 
 .NOTES
 Ensure aria2c is installed and in the PATH if the UseAria2 switch is used.
 When downloading from a private repository, ensure the secret containing the GitHub token is properly configured.
 #>
 
function Get-DownloadFile {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string[]]$URLs,
 
        [Parameter(Mandatory = $true)]
        [string]$OutFileDirectory,
 
        [switch]$UseAria2,
 
        [Parameter(Mandatory = $false)]
        [string]$aria2cExe = "c:\aria2\aria2c.exe",
 
        [string]$SecretName = 'ReadOnlyGitHubToken',
 
        [System.Collections.IDictionary]$Headers,
 
        [switch]$IsPrivateRepo,
 
        [int]$MaxConcurrentDownloads = 5
    )
 
    begin {
        $downloadScript = {
            param (
                [string]$URL,
                [string]$OutFile,
                [string]$OutFileDirectory,
                [switch]$UseAria2,
                [string]$SecretName,
                [string]$aria2cExe,
                [System.Collections.IDictionary]$Headers,
                [switch]$IsPrivateRepo
            )
 
            try {
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
                        Get-LatestGitHubRelease -OwnerRepository "aria2/aria2" -AssetName "aria2_win-64bit-build1.zip" -DownloadPathDirectory "C:\aria2"
                        Expand-Archive -Path "C:\aria2\aria2_win-64bit-build1.zip" -DestinationPath "C:\aria2"
                        $aria2cExe = $(Resolve-Path -Path "C:\aria2\aria2c.exe").Path
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
 
                            Invoke-AriaDownload -URL $URL -OutFile $OutFile -Aria2cExePath $aria2cExe -SecretName $SecretName -Headers:$Headers
                        }
                    }
                    else {
                        Invoke-AriaDownload -URL $URL -OutFile $OutFile -Aria2cExePath $aria2cExe -Headers:$Headers
                    }
                }
                else {
                    Write-Host "Using Invoke-WebRequest for download."
                    Invoke-WebRequest -Uri $URL -OutFile $OutFile -Headers $Headers
                }
            }
            catch {
                Write-Host "An error occurred: $_" -ForegroundColor Red
                throw
            }
        }
 
        $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrentDownloads)
        $runspacePool.Open()
    }
 
    process {
        $jobs = @()
        foreach ($URL in $URLs) {
            $OutFile = Join-Path -Path $OutFileDirectory -ChildPath ($URL | Split-Path -Leaf)
            $params = @{
                URL           = $URL
                OutFile       = $OutFile
                UseAria2      = $UseAria2
                aria2cExe     = $aria2cExe
                SecretName    = $SecretName
                Headers       = $Headers
                IsPrivateRepo = $IsPrivateRepo
            }
            
            $job = [powershell]::Create().AddScript($downloadScript).AddParameters($params)
            $job.RunspacePool = $runspacePool
            
            $result = $job.BeginInvoke()
            $jobs += @{
                Job    = $job
                Result = $result
            }
        }

        $jobs.Result | ForEach-Object { $_.AsyncWaitHandle.WaitOne() }
         
        $jobs | ForEach-Object {
            $jobOutput = $_.Job.EndInvoke($_.Result)
            $jobError = $_.Job.Streams.Error
            $_.Job.Dispose()
             
            if ($jobOutput) {
                Write-Output "Job completed successfully: $($jobOutput)"
            }
             
            if ($jobError) {
                Write-Error "Error occurred: $($jobError)"
            }
        }
    }
 
    end {
        $runspacePool.Close()
    }
}
 