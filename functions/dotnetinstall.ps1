#
# PowerShell CI script to install .NET Core SDK and the shared runtime.
# <https://jonlabelle.com/snippets/view/powershell/powershell-script-to-install-net-core-sdk>
#
# Will check to see if the specified SDK version is already installed.
#
# Hat-tip to Azure/DotNetty build.ps1 CI build script:
# https://github.com/Azure/DotNetty/blob/dev/build.ps1
#
# Dotnet Install Script Reference:
#   - Homepage: https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-install-script
#   - Bash (Linux/macOS): https://dot.net/v1/dotnet-install.sh
#   - PowerShell (Windows): https://dot.net/v1/dotnet-install.ps1
#
 
function Install-LatestDotNet {
    [CmdletBinding()]
    param (
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Continue'
 
    $DotNetChannel = 'Preview';
    $DotNetVersion = '7.0.100-preview.7.22377.5';
    $DotNetInstallScript = 'dotnet-install.ps1';
    $DotNetInstallerUri = "https://dot.net/v1/$DotNetInstallScript";
    $DotNetInstallDir = Join-Path -Path $PSScriptRoot -ChildPath '.dotnet';
    $DotNetToolsDir = Join-Path -Path $DotNetInstallDir -ChildPath 'tools'; # https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-tool-install
    $DotNetInstallScriptPath = Join-Path -Path $DotNetInstallDir -ChildPath $DotNetInstallScript;
    $OSVersion = [System.Environment]::OSVersion | Select-Object -ExpandProperty Platform
 
    function Remove-PathVariable([string] $VariableToRemove) {
        if (($OSVersion -eq 'Unix') -or ($OSVersion -eq 'Linux')) {
            # *NIX
            $path = [System.Environment]::GetEnvironmentVariable('PATH')
            if ($null -ne $path) {
                $newItems = $path.Split(':', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { "$($_)" -INotLike $VariableToRemove }
                [System.Environment]::SetEnvironmentVariable('PATH', [System.String]::Join(':', $newItems))
            }
 
            $path = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Process)
            if ($null -ne $path) {
                $newItems = $path.Split(':', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { "$($_)" -INotLike $VariableToRemove }
                [System.Environment]::SetEnvironmentVariable('PATH', [System.String]::Join(':', $newItems), [System.EnvironmentVariableTarget]::Process)
            }
 
            $path = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
            if ($null -ne $path) {
                $newItems = $path.Split(':', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { "$($_)" -INotLike $VariableToRemove }
                [System.Environment]::SetEnvironmentVariable('PATH', [System.String]::Join(':', $newItems), [System.EnvironmentVariableTarget]::Machine)
            }
        }
        else {
            # Windows
            $path = [System.Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::User)
            if ($null -ne $path) {
                $newItems = $path.Split(';', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { "$($_)" -INotLike $VariableToRemove }
                [System.Environment]::SetEnvironmentVariable('Path', [System.String]::Join(';', $newItems), [System.EnvironmentVariableTarget]::User)
            }
 
            $path = [System.Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Process)
            if ($null -ne $path) {
                $newItems = $path.Split(';', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { "$($_)" -INotLike $VariableToRemove }
                [System.Environment]::SetEnvironmentVariable('Path', [System.String]::Join(';', $newItems), [System.EnvironmentVariableTarget]::Process)
            }
        }
    }
 
    # function Get-HttpResource {
    #     <#
    # .SYNOPSIS
    #     Downloads the contents from a URL
 
    # .DESCRIPTION
    #     Get-HttpResource downloads the contents of an HTTP url.
    #     When -PassThru is specified it returns the string content.
 
    # .PARAMETER Url
    #     The url containing the content to download.
 
    # .PARAMETER OutputPath
    #     If provided, the content will be saved to this path.
 
    # .PARAMETER PassThru
    #     If provided, the string will be output to the pipeline.
 
    # .EXAMPLE
    #     $content = Get-HttpResource -Url 'http://my/url' -OutputPath 'c:\myfile.txt' -PassThru
 
    #     This downloads the content located at http://my/url and
    #     saves it to a file at c:\myfile.txt and also returns
    #     the downloaded string.
 
    # .LINK
    #     https://boxstarter.org
    # #>
    #     param (
    #         [string]$Url,
    #         [string]$OutputPath = $null,
    #         [switch]$PassThru
    #     )
 
    #     Write-Verbose "Downloading $url"
 
    #     $str = Invoke-RetriableScript -RetryScript {
    #         $downloader = New-Object System.Net.WebClient
    #         $wp = [System.Net.WebProxy]::GetDefaultProxy()
    #         $wp.UseDefaultCredentials = $true
    #         $downloader.Proxy = $wp
    #         $downloader.UseDefaultCredentials = $true
 
    #         # Fixes: "Powershell Invoke-WebRequest Fails with SSL/TLS Secure Channel"
    #         [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 
    #         try {
    #             if ($args[1]) {
    #                 Write-Verbose "Saving $($args[0]) to $($args[1])"
    #                 $downloader.DownloadFile($args[0], $args[1])
    #             } else {
    #                 $downloader.DownloadString($args[0])
    #             }
    #         } catch {
    #             if ($VerbosePreference -eq "Continue") {
    #                 Write-Error $($_.Exception | Format-List * -Force | Out-String)
    #             }
    #             throw $_
    #         }
    #     } $Url $OutputPath
 
    #     if ($PassThru) {
    #         if ($str) {
    #             Write-Output $str
    #         } elseif ($OutputPath) {
    #             Get-Content -Path $OutputPath
    #         }
    #     }
    # }
 
    function Invoke-RetriableScript {
        <#
.SYNOPSIS
    Retries a script 5 times or until it completes without terminating errors.
    All Unnamed arguments will be passed as arguments to the script
#>
        param([ScriptBlock] $RetryScript)
 
        $currentErrorAction = $ErrorActionPreference
 
        try {
            $ErrorActionPreference = 'Stop'
            for ($count = 1; $count -le 5; $count++) {
                try {
                    Write-Verbose "Attempt #$count..."
                    $ret = Invoke-Command -ScriptBlock $RetryScript -ArgumentList $args
                    return $ret
                    break
                }
                catch {
                    if ($global:Error.Count -gt 0) {
                        $global:Error.RemoveAt(0)
                    }
                    if ($count -eq 5) {
                        throw $_
                    }
                    else {
                        Start-Sleep 10
                    }
                }
            }
        }
        finally {
            $ErrorActionPreference = $currentErrorAction
        }
    }
 
    # Get .NET Core CLI path if installed.
    $FoundDotNetCliVersion = $null;
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $FoundDotNetCliVersion = dotnet --version;
    }
 
    if ($FoundDotNetCliVersion -ne $DotNetVersion) {
        if (!(Test-Path $DotNetInstallDir)) {
            New-Item -Path $DotNetInstallDir -ItemType Directory -Force | Out-Null;
        }
 
        Invoke-WebRequest -Uri $DotNetInstallerUri -OutFile $DotNetInstallScriptPath
        . $DotNetInstallScriptPath -Channel $DotNetChannel -Version $DotNetVersion -InstallDir $DotNetInstallDir;
 
        # Run `Get-ChildItem -Path Env:` to list current env variables
        Remove-PathVariable "$DotNetToolsDir"
        Remove-PathVariable "$DotNetInstallDir"
        $env:PATH = "$DotNetInstallDir;$DotNetToolsDir;$env:PATH"
    }
 
    # Opt out of dotnet first time setup and telemetry
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = 1
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = 1

}


