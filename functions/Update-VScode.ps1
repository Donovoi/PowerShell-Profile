<#
.SYNOPSIS
Downloads and installs Visual Studio Code stable and/or insider versions from the official website.

.DESCRIPTION
This function downloads and installs Visual Studio Code stable and/or insider versions from the official website. 
It checks for the presence of an X-Ways USB drive and saves the downloaded files to the appropriate destination path. 
The function uses BITS transfer to download the files and Expand-Archive cmdlet to extract the files.

.PARAMETER Version
Specifies the version of Visual Studio Code to download. The default value is 'both'. 
Valid values are 'stable', 'insider', or 'both'.

.EXAMPLE
Update-VSCode -Version stable
Downloads and installs the stable version of Visual Studio Code.

.EXAMPLE
Update-VSCode -Version insider
Downloads and installs the insider version of Visual Studio Code.

.EXAMPLE
Update-VSCode -Version both
Downloads and installs both stable and insider versions of Visual Studio Code.

#>
function Update-VSCode {
    [CmdletBinding()]
    param(
        [ValidateSet('stable', 'insider')]
        [string]$Version = 'both'
    )
    process {
        Write-Host "Script is running as $($MyInvocation.MyCommand.Name)" 

        $drive = Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'"
        if ($drive) {
            $global:XWAYSUSB = $drive.DriveLetter
        }
        else {
            Write-Error 'X-Ways USB drive not found.'
            return
        }

        $urls = @(
            @{
                Version         = 'stable'
                URL             = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
                OutFile         = "$ENV:USERPROFILE\downloads\vscode.zip"
                DestinationPath = "$XWAYSUSB\vscode\"
            },
            @{
                Version         = 'insider'
                URL             = 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive'
                OutFile         = "$ENV:USERPROFILE\downloads\insiders.zip"
                DestinationPath = "$XWAYSUSB\vscode-insider\"
            }
        )

        if ($Version -eq 'both') {
            foreach ($url in $urls) {
                Start-BitsTransferAndShowProgress -URL $url.URL -OutFile $url.OutFile
                Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force 
            }
        }
        elseif ($urls.Version -contains $Version) {
            $url = $urls | Where-Object { $_.Version -eq $Version }
            Start-BitsTransferAndShowProgress -URL $url.URL -OutFile $url.OutFile
            Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force -Verbose
        }
        else {
            Write-Error "Invalid version specified. Please choose 'stable', 'insider', or 'both'."
            return
        }
    }
}